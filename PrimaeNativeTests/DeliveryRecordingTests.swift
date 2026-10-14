// DeliveryRecordingTests.swift
// R-020 (audit 2026-10-13), view-model half: each phase row carries what
// THAT phase delivered. Batch C's per-letter counters are split per phase
// (`PhaseDeliveryTracker`), route changes are filtered by reason so the
// engine's own category changes are not counted, interruptions are
// counted, the device state is sampled at each phase start, every row
// names why it was written (child / background / navigation), and the
// launch sentinel is told when the app suspends cleanly and when it is
// active again.
//
// Hardware-only (UNVERIFIED here, by construction): a real route change,
// Guided Access, Low Power Mode, battery, a real crash before the next
// launch. Everything below drives the seams.

import Testing
import Foundation
import CoreGraphics
import AVFoundation
@testable import PrimaeNative

/// Records what the view model tells the sentinel.
@MainActor
final class SentinelSpy: LaunchSentinelRecording {
    private(set) var calls: [String] = []
    func markCleanSuspend() { calls.append("suspend") }
    func markActive() { calls.append("active") }
}

@Suite @MainActor struct DeliveryRecordingTests {

    private typealias Reason = AVAudioSession.RouteChangeReason

    private func rig(env: FixedDeliveryEnvironment? = nil,
                     store: DeliveryRowStore? = nil,
                     sentinel: LaunchSentinelRecording? = nil) -> LifecycleRig {
        let env = env ?? FixedDeliveryEnvironment()
        return LifecycleRig { deps in
            deps.deliveryEnvironment = env
            if let store { deps.dashboardStore = store }
            if let sentinel { deps.launchSentinel = sentinel }
        }
    }

    @Test("R-020: only DEVICE route changes are counted — not the engine's category changes")
    func routeChangesAreFilteredByReason() {
        let r = rig()
        r.vm.loadLetter(name: "A")
        for reason in [Reason.categoryChange, .wakeFromSleep, .routeConfigurationChange, .unknown] {
            r.vm.handleAudioRouteChange(reasonRawValue: reason.rawValue, outputLost: false, outputPortType: "Headphones")
        }
        r.vm.handleAudioRouteChange(reasonRawValue: nil, outputLost: false, outputPortType: "Headphones")
        #expect(r.vm.lifecycleCounters.routeChanges == 0,
                "a category change or wake is not a device change: \(r.vm.lifecycleCounters.routeChanges)")
        r.vm.handleAudioRouteChange(reasonRawValue: Reason.override.rawValue, outputLost: false, outputPortType: "Speaker")
        r.vm.handleAudioRouteChange(reasonRawValue: Reason.noSuitableRouteForCategory.rawValue, outputLost: true, outputPortType: nil)
        #expect(r.vm.lifecycleCounters.routeChanges == 2)
    }

    @Test("R-020: each phase's row carries that phase's share of the letter's counters, and the device state at its start")
    func eachPhaseCarriesItsOwnShare() throws {
        let env = FixedDeliveryEnvironment()
        let r = rig(env: env)
        r.vm.loadLetter(name: "A")
        try #require(r.vm.phaseController.currentPhase == .observe)
        r.vm.handleAudioRouteChange(reasonRawValue: Reason.newDeviceAvailable.rawValue,
                                    outputLost: false, outputPortType: "Headphones")
        env.stamp.outputRoute = "Speaker"           // the device changed before the phase ended
        r.vm.advanceLearningPhase()
        try #require(r.vm.phaseController.currentPhase == .guided)
        r.vm.handleAudioRouteChange(reasonRawValue: Reason.oldDeviceUnavailable.rawValue,
                                    outputLost: true, outputPortType: "Speaker")
        r.vm.handleAudioRouteChange(reasonRawValue: Reason.newDeviceAvailable.rawValue,
                                    outputLost: false, outputPortType: "Headphones")
        r.vm.beginInterruption(.parentArea)
        r.vm.endInterruption(.parentArea)

        let observe = try #require(r.vm.phaseRowContext(for: .observe, finalizedBy: .child).delivery,
                                   "the observe row carries no delivery")
        let guided = try #require(r.vm.phaseRowContext(for: .guided, finalizedBy: .child).delivery)
        #expect(observe.routeChanges == 1 && observe.interruptions == 0,
                "observe: \(String(describing: observe.routeChanges)) / \(String(describing: observe.interruptions))")
        #expect(guided.routeChanges == 2 && guided.interruptions == 1,
                "guided: \(String(describing: guided.routeChanges)) / \(String(describing: guided.interruptions))")
        #expect(observe.atStart?.outputRoute == "Headphones")
        #expect(observe.outputRouteAtEnd == "Speaker", "observe ended on the speaker")
        #expect(guided.atStart?.outputRoute == "Speaker", "guided started on the speaker")
        #expect(observe.atStart?.guidedAccess == true && observe.atStart?.batteryLevel == 0.8)
        #expect(guided.build == FixedDeliveryEnvironment.build, "the row does not name its binary and launch")
        #expect(observe.observeRestarts == 0 && guided.strokesCancelled == 0)
    }

    @Test("R-020: an interruption is counted once, however many sources nest inside it")
    func interruptionsAreCounted() {
        let r = rig()
        r.vm.loadLetter(name: "A")
        r.vm.beginInterruption(.scene)
        r.vm.beginInterruption(.parentArea)          // nested: the same suspension
        r.vm.endInterruption(.parentArea)
        r.vm.endInterruption(.scene)
        r.vm.beginInterruption(.parentArea)
        r.vm.endInterruption(.parentArea)
        #expect(r.vm.lifecycleCounters.interruptions == 2)
    }

    @Test("R-020: a letter the child finishes writes rows finalised by the child")
    func childCompletionIsStamped() async throws {
        let store = DeliveryRowStore()
        var deps = TracingDependencies.stub
        deps.thesisCondition = .threePhase
        deps.dashboardStore = store
        deps.letterRecognizer = StubLetterRecognizer.alwaysReturn(predicted: "A", confidence: 0.9, isCorrect: true)
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 400, height: 400)
        vm.phaseController.advance(score: 1.0)
        vm.phaseController.advance(score: 0.8)
        vm.freeWriteRecorder.startSession(now: 100.0)
        for i in 0...18 {
            vm.freeWriteRecorder.record(point: CGPoint(x: 20 + Double(i) * 20, y: 200),
                                        timestamp: 100.0 + Double(i) * 0.1, force: 0.5, canvasSize: vm.canvasSize)
        }
        vm.advanceLearningPhase()
        for _ in 0..<200 where store.rows.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        try #require(store.rows.count == 3)
        for row in store.rows {
            #expect(row.context?.finalizedBy == .child, "\(row.phase): \(String(describing: row.context?.finalizedBy))")
        }
    }

    @Test("R-020: a production finalised by backgrounding is stamped 'background', not as the child's completion")
    func backgroundFinalisationIsStamped() async throws {
        let store = DeliveryRowStore()
        let r = rig(store: store)
        r.vm.loadLetter(name: "A")
        r.vm.phaseController.resume(at: .freeWrite)
        r.strokeDown()
        r.vm.endTouch()
        await r.vm.appDidEnterBackground()
        let rows = store.rows(.freeWrite)
        try #require(!rows.isEmpty, "backgrounding did not finalise the production")
        #expect(rows.allSatisfy { $0.context?.finalizedBy == .background },
                "\(rows.map { String(describing: $0.context?.finalizedBy) })")
    }

    @Test("R-020: leaving a letter — finished-but-unscored or mid-phase — is stamped 'navigation'")
    func navigationIsStamped() throws {
        let store = DeliveryRowStore()
        let r = rig(store: store)
        r.vm.loadLetter(name: "A")
        r.vm.phaseController.resume(at: .freeWrite)
        r.strokeDown()
        r.vm.endTouch()
        r.vm.phaseTransitions.recordUnloadOfCurrentLetter(touchStillActive: false)
        let finished = store.rows(.freeWrite)
        try #require(!finished.isEmpty)
        #expect(finished.allSatisfy { $0.context?.finalizedBy == .navigation })

        let midPhase = DeliveryRowStore()
        let r2 = rig(store: midPhase)
        r2.vm.loadLetter(name: "A")
        r2.vm.phaseController.resume(at: .freeWrite)
        r2.strokeDown()                                 // pen still down: not a finished production
        r2.vm.phaseTransitions.recordUnloadOfCurrentLetter(touchStillActive: true)
        let partial = try #require(midPhase.rows.first)
        #expect(!partial.completed)
        #expect(partial.context?.finalizedBy == .navigation)
    }

    @Test("R-020: the launch sentinel is told the app suspended cleanly, and that it is active again")
    func sentinelFollowsTheLifecycle() async {
        let spy = SentinelSpy()
        let r = rig(sentinel: spy)
        await r.vm.appDidEnterBackground()
        #expect(spy.calls.last == "suspend", "\(spy.calls)")
        r.vm.appDidBecomeActive()
        #expect(spy.calls.last == "active", "\(spy.calls)")
    }

    @Test("R-020: a launch that finds the previous launch still running reports an abnormal exit")
    func sentinelDetectsAnUncleanExit() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sentinel-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = LaunchSentinel(fileURL: url)
        first.beginLaunch()
        #expect(!first.previousRunAbnormal, "no previous launch")
        let afterCrash = LaunchSentinel(fileURL: url)        // `first` never suspended
        afterCrash.beginLaunch()
        #expect(afterCrash.previousRunAbnormal)
        afterCrash.markCleanSuspend()
        let afterSuspend = LaunchSentinel(fileURL: url)
        afterSuspend.beginLaunch()
        #expect(!afterSuspend.previousRunAbnormal, "a clean suspend is not an abnormal exit")
        afterSuspend.markCleanSuspend()
        afterSuspend.markActive()                              // back in the foreground, then killed
        let afterForegroundKill = LaunchSentinel(fileURL: url)
        afterForegroundKill.beginLaunch()
        #expect(afterForegroundKill.previousRunAbnormal)
    }

    @Test("R-020: the tracker splits counters by difference and forgets the previous letter")
    func trackerArithmetic() {
        var t = PhaseDeliveryTracker()
        var c = LifecycleCounters()
        let env = FixedDeliveryEnvironment.defaultStamp
        t.beginLetter(in: .observe, counters: c, environment: env)
        c.strokesCancelled = 2; c.routeChanges = 1
        t.transition(to: .guided, counters: c, environment: env)
        c.strokesCancelled = 5; c.interruptions = 1
        #expect(t.delivery(for: .observe, counters: c, outputRouteNow: nil)?.strokesCancelled == 2)
        #expect(t.delivery(for: .guided, counters: c, outputRouteNow: "Speaker")?.strokesCancelled == 3)
        #expect(t.delivery(for: .guided, counters: c, outputRouteNow: "Speaker")?.outputRouteAtEnd == "Speaker")
        #expect(t.delivery(for: .freeWrite, counters: c, outputRouteNow: nil) == nil)
        t.beginLetter(in: .observe, counters: LifecycleCounters(), environment: env)
        #expect(t.delivery(for: .guided, counters: LifecycleCounters(), outputRouteNow: nil) == nil,
                "the previous letter's phases leaked into the next")
    }
}
