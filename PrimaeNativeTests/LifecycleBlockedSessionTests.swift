// LifecycleBlockedSessionTests.swift
// PrimaeNativeTests
//
// Fix lane L1, 2026-11-02 (bug hunt rounds 1 + 2):
//  - STATE-1 / STATE-2: a background -> foreground bounce must leave a
//    foreground app running, and the launch sentinel saying so.
//  - VERIFY-7: a trial in flight when a relaunch is pending gets its
//    `completed: false` row at the background.
//  - STATE-7: a suspended session (inactive scene, parent area) takes no
//    new stroke.
//  - AUDIO-5 / C-1 / C-2 (the sound half only): a blocked session starts no
//    arm sound and speaks no phase instruction.

import AVFoundation
import CoreGraphics
import Testing
import UIKit
@testable import PrimaeNative

// MARK: - Doubles

@MainActor
final class SentinelLog: LaunchSentinelRecording {
    private(set) var states: [String] = []
    func markCleanSuspend() { states.append(LaunchSentinel.suspended) }
    func markActive() { states.append(LaunchSentinel.running) }
}

@MainActor
final class NoOpBackgroundTasks: BackgroundTaskGranting {
    func begin(name: String, onExpiry: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        UIBackgroundTaskIdentifier(rawValue: 77)
    }
    func end(_ identifier: UIBackgroundTaskIdentifier) {}
}

/// A dashboard store whose `flush()` can be held open.
final class GatedFlushStore: ParentDashboardStoring {
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    var gateOpen = true
    private(set) var flushEntered = 0
    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?, date: Date, condition: ThesisCondition,
                       inputDevice: String?) {}
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?, comparisonConfiguration: String?) {}
    func reset() {}
    func flush() async {
        flushEntered += 1
        while !gateOpen { try? await Task.sleep(for: .milliseconds(5)) }
    }
}

private let headphonesPort = AVAudioSession.Port.headphones.rawValue
private let speakerPort = AVAudioSession.Port.builtInSpeaker.rawValue

private func stamp(route: String?) -> EnvironmentStamp {
    let d = FixedDeliveryEnvironment.defaultStamp
    return EnvironmentStamp(
        outputRoute: route, outputVolume: d.outputVolume, outputLatency: d.outputLatency,
        otherAudioPlaying: d.otherAudioPlaying, secondaryAudioHint: d.secondaryAudioHint,
        guidedAccess: d.guidedAccess, idleTimerDisabled: d.idleTimerDisabled,
        lowPowerMode: d.lowPowerMode, thermalState: d.thermalState,
        batteryLevel: d.batteryLevel)
}

/// A study rig on headphones with the r14 requirement ON.
@MainActor
private func headphoneRig(arm: PilotAudioCondition, fallback: TimeInterval = 3600) -> LifecycleRig {
    LifecycleRig(arm: arm, fallback: fallback) { d in
        d.requiresHeadphones = true
        d.panningEnabled = true
        d.deliveryEnvironment = FixedDeliveryEnvironment(stamp(route: headphonesPort))
    }
}

@MainActor
private func unplug(_ vm: TracingViewModel) {
    vm.handleAudioRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                              outputLost: true, outputPortType: speakerPort,
                              previousOutputPortType: headphonesPort)
}

// MARK: - STATE-1 / STATE-2

@MainActor
@Suite struct BackgroundBounceTests {

    @Test("STATE-1: a return during the background flush leaves the sentinel saying running")
    func sentinelSaysRunningAfterReturnDuringFlush() async {
        let sentinel = SentinelLog()
        let store = GatedFlushStore()
        let rig = LifecycleRig { d in
            d.launchSentinel = sentinel
            d.backgroundTasks = NoOpBackgroundTasks()
            d.dashboardStore = store
        }
        store.gateOpen = false
        rig.vm.scenePhaseDidChange(to: .inactive)
        let t = rig.vm.scenePhaseDidChange(to: .background)
        await rig.waitUntil(5) { store.flushEntered > 0 }
        #expect(store.flushEntered > 0, "precondition: the background flush is in progress")
        rig.vm.scenePhaseDidChange(to: .active)
        store.gateOpen = true
        await t?.value
        #expect(sentinel.states.last == LaunchSentinel.running,
                "foreground app, but the sentinel's writes were \(sentinel.states)")
    }

    @Test("STATE-1 control: a plain background still ends with the clean-suspend marker")
    func plainBackgroundMarksCleanSuspend() async {
        let sentinel = SentinelLog()
        let rig = LifecycleRig { d in
            d.launchSentinel = sentinel
            d.backgroundTasks = NoOpBackgroundTasks()
        }
        rig.vm.scenePhaseDidChange(to: .inactive)
        await rig.vm.scenePhaseDidChange(to: .background)?.value
        #expect(sentinel.states.last == LaunchSentinel.suspended, "writes: \(sentinel.states)")
    }

    @Test("STATE-2: .background then .active before the flush Task starts leaves the session running")
    func backgroundThenActiveInOneTurnLeavesSessionRunning() async {
        let sentinel = SentinelLog()
        let rig = LifecycleRig { d in
            d.launchSentinel = sentinel
            d.backgroundTasks = NoOpBackgroundTasks()
        }
        rig.vm.scenePhaseDidChange(to: .inactive)
        let t = rig.vm.scenePhaseDidChange(to: .background)
        rig.vm.scenePhaseDidChange(to: .active)
        await t?.value
        #expect(rig.vm.playback.appIsForeground, "foreground app left with appIsForeground=false")
        #expect(rig.vm.sceneIsActive, "foreground app left with sceneIsActive=false")
        #expect(rig.vm.activeInterruptions.isEmpty, "foreground app left interrupted: \(rig.vm.activeInterruptions)")
        #expect(sentinel.states.last == LaunchSentinel.running, "sentinel: \(sentinel.states)")
    }
}

// MARK: - VERIFY-7

@MainActor
@Suite struct BlockedBackgroundInFlightRowTests {

    private func partialGuidedTrace(_ rig: LifecycleRig) {
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .guided)
        rig.strokeDown()
        rig.vm.endTouch()
    }

    @Test("VERIFY-7: a guided trial in flight when a relaunch is pending gets its completed:false row at the background")
    func inFlightTrialSurvivesSettingsBlock() async {
        let rig = LifecycleRig(arm: .phoneme)
        let vm = rig.vm
        partialGuidedTrace(rig)
        let rowsBefore = rig.store.rows.count
        vm.parentAreaDidOpen()
        vm.markComparisonSettingChanged()
        vm.parentAreaDidClose()
        #expect(vm.sessionBlockReason != nil, "precondition: relaunch required")
        await vm.scenePhaseDidChange(to: .background)?.value
        let rows = rig.store.rows.dropFirst(rowsBefore).map { "\($0.letter)/\($0.phase)/completed=\($0.completed)" }
        #expect(rows == ["A/guided/completed=false"], "rows after the background: \(rows)")
    }

    @Test("VERIFY-7 control: an unblocked background records nothing (a return resumes the letter)")
    func unblockedBackgroundRecordsNothing() async {
        let rig = LifecycleRig(arm: .phoneme)
        partialGuidedTrace(rig)
        let rowsBefore = rig.store.rows.count
        #expect(rig.vm.sessionBlockReason == nil, "precondition")
        await rig.vm.scenePhaseDidChange(to: .background)?.value
        #expect(rig.store.rows.count == rowsBefore, "rows: \(rig.store.rows.map(\.phase))")
    }
}

// MARK: - STATE-7

@MainActor
@Suite struct TouchWhileInterruptedTests {

    private enum Cover: String, CaseIterable { case inactiveScene, parentArea }

    private func guidedRig(arm: PilotAudioCondition) -> LifecycleRig {
        let rig = LifecycleRig(arm: arm)
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .guided)
        return rig
    }

    @Test("control: a guided stroke in a running session sounds and builds ink",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func strokeInRunningSessionSounds(arm: PilotAudioCondition) async {
        let rig = guidedRig(arm: arm)
        let playsBefore = rig.audio.playCount
        rig.strokeDown()
        await rig.vm.awaitPlaybackDebounce()
        #expect(rig.vm.debugIsSingleTouchInteractionActive)
        #expect(rig.audio.playCount > playsBefore, "\(arm): events \(rig.audio.events)")
    }

    @Test("STATE-7: a suspended session takes no stroke and plays no sound",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func strokeWhileSuspendedIsRefused(arm: PilotAudioCondition) async {
        for cover in Cover.allCases {
            let rig = guidedRig(arm: arm)
            switch cover {
            case .inactiveScene: rig.vm.scenePhaseDidChange(to: .inactive)
            case .parentArea: rig.vm.parentAreaDidOpen()
            }
            let playsBefore = rig.audio.playCount
            rig.strokeDown()
            await rig.vm.awaitPlaybackDebounce()
            #expect(!rig.vm.debugIsSingleTouchInteractionActive, "\(arm)/\(cover.rawValue): the stroke was taken")
            #expect(rig.audio.playCount == playsBefore,
                    "\(arm)/\(cover.rawValue): the arm sound played behind the cover: \(rig.audio.events)")
        }
    }
}

// MARK: - AUDIO-5 / C-1 / C-2, sound half

@MainActor
@Suite struct BlockedSessionSilenceTests {

    @Test("C-1: headphones pulled during the observe cue start no arm sound behind the stop",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func unplugDuringCueStartsNoSound(arm: PilotAudioCondition) async {
        let rig = headphoneRig(arm: arm, fallback: 0.3)
        let vm = rig.vm
        #expect(vm.sessionBlockReason == nil, "precondition: headphones in")
        vm.loadLetter(name: "A")
        #expect(vm.learningPhase == .observe && rig.audio.playCount == 0, "precondition: cue first")
        unplug(vm)
        #expect(vm.sessionBlockReason == HeadphoneRequirement.refusal, "precondition: the stop is up")
        // Past the 0.3 s cue fallback and the presentation gap.
        try? await Task.sleep(for: .seconds(1.5))
        #expect(rig.audio.playCount == 0, "\(arm): sound started behind the stop: \(rig.audio.events)")
    }

    @Test("C-2: no phase instruction is spoken while the session is blocked (before, or during the fade wait)")
    func noPhasePromptWhileBlocked() async {
        // Block first, then the prompt.
        do {
            let rig = headphoneRig(arm: .phoneme)
            rig.vm.loadLetter(name: "A")
            rig.vm.phaseController.resume(at: .guided)
            unplug(rig.vm)
            rig.vm.playPhaseEntryPrompt()
            await rig.vm.awaitPendingPhasePrompt()
            #expect(rig.prompts.count(.phaseGuided) == 0, "spoken behind the stop: \(rig.prompts.keys)")
        }
        // Prompt scheduled, then the block lands inside the fade wait.
        do {
            let rig = headphoneRig(arm: .phoneme)
            rig.vm.loadLetter(name: "A")
            rig.vm.phaseController.resume(at: .guided)
            rig.vm.playPhaseEntryPrompt()
            unplug(rig.vm)
            await rig.vm.awaitPendingPhasePrompt()
            #expect(rig.prompts.count(.phaseGuided) == 0, "spoken behind the stop: \(rig.prompts.keys)")
        }
        // Control: unblocked, it is spoken.
        do {
            let rig = headphoneRig(arm: .phoneme)
            rig.vm.loadLetter(name: "A")
            rig.vm.phaseController.resume(at: .guided)
            rig.vm.playPhaseEntryPrompt()
            await rig.vm.awaitPendingPhasePrompt()
            #expect(rig.prompts.count(.phaseGuided) == 1, "control: \(rig.prompts.keys)")
        }
    }

    @Test("AUDIO-5: headphones pulled mid-stroke end the stroke; its further movement plays nothing",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func unplugMidStrokeStopsTheStroke(arm: PilotAudioCondition) async {
        let rig = headphoneRig(arm: arm)
        let vm = rig.vm
        vm.loadLetter(name: "A")
        vm.phaseController.resume(at: .guided)
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 50, y: 200)
        vm.beginTouch(at: p, t: t)
        for _ in 0..<8 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }
        await vm.awaitPlaybackDebounce()
        #expect(rig.audio.playCount > 0, "precondition: the stroke sounds (\(rig.audio.events))")
        unplug(vm)
        let eventsAtLoss = rig.audio.events.count
        #expect(!vm.debugIsSingleTouchInteractionActive, "\(arm): the stroke survived the loss")
        // The pen keeps moving, as a child's does.
        for _ in 0..<8 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }
        await vm.awaitPlaybackDebounce()
        let after = rig.audio.events.dropFirst(eventsAtLoss)
        let playsAfter = after.filter { if case .play = $0 { return true } else { return false } }
        #expect(playsAfter.isEmpty, "\(arm): sound restarted after the loss: \(Array(after))")
    }
}

// MARK: - B1: the headphone stop is an interruption (r16)

@MainActor
private func replug(_ vm: TracingViewModel) {
    vm.handleAudioRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
                              outputLost: false, outputPortType: headphonesPort)
}

@MainActor
@Suite struct HeadphoneInterruptionTests {

    @Test("B1: an unplug mid-observe freezes the letter; the re-plug restarts observe from its cue",
          arguments: [PilotAudioCondition.phoneme, .spatial, .silent])
    func unplugMidObserveFreezesAndReplugRestarts(arm: PilotAudioCondition) async {
        let rig = headphoneRig(arm: arm, fallback: 0.2)
        let vm = rig.vm
        vm.loadLetter(name: "A")
        await rig.waitUntil(5) { vm.animation.armedStrokes != nil }
        #expect(vm.animation.armedStrokes != nil, "\(arm): precondition: the observe presentation started")
        let cuesBefore = rig.prompts.count(.phaseObserve)
        unplug(vm)
        #expect(vm.activeInterruptions == [.headphones], "\(arm): \(vm.activeInterruptions)")
        #expect(vm.animation.armedStrokes == nil, "\(arm): the observe animation ran on behind the stop")
        #expect(!rig.audio.isPlaying, "\(arm): sound behind the stop")
        // Well past the cue fallback: nothing may restart behind the stop.
        try? await Task.sleep(for: .seconds(0.6))
        #expect(vm.learningPhase == .observe, "\(arm): the letter advanced behind the stop")
        #expect(vm.animation.armedStrokes == nil, "\(arm): the presentation restarted behind the stop")
        #expect(rig.prompts.count(.phaseGuided) == 0, "\(arm): \(rig.prompts.keys)")
        replug(vm)
        #expect(vm.activeInterruptions.isEmpty, "\(arm): the re-plug did not end the interruption")
        #expect(rig.prompts.count(.phaseObserve) == cuesBefore + 1,
                "\(arm): observe did not restart from its cue: \(rig.prompts.keys)")
        #expect(vm.lifecycleCounters.observeRestarts == 1)
        await rig.waitUntil(5) { vm.animation.armedStrokes != nil }
        #expect(vm.animation.armedStrokes != nil, "\(arm): the restarted presentation never began")
    }

    @Test("B1: an unplug in guided suspends the session; the re-plug resumes it and touches are taken again")
    func unplugInGuidedSuspendsAndResumes() {
        let rig = headphoneRig(arm: .phoneme)
        let vm = rig.vm
        vm.loadLetter(name: "A")
        vm.phaseController.resume(at: .guided)
        unplug(vm)
        #expect(vm.activeInterruptions == [.headphones])
        replug(vm)
        #expect(vm.activeInterruptions.isEmpty)
        rig.strokeDown()
        #expect(vm.debugIsSingleTouchInteractionActive, "the stroke after the re-plug was refused")
    }

    @Test("B1: an unplug while backgrounded keeps the session interrupted on the return")
    func unplugWhileSuspendedStaysInterrupted() {
        // The route sampled at `.active` is the loudspeaker.
        let rig = LifecycleRig(arm: .phoneme) { d in
            d.requiresHeadphones = true
            d.panningEnabled = true
            d.deliveryEnvironment = FixedDeliveryEnvironment(stamp(route: speakerPort))
        }
        let vm = rig.vm
        replug(vm)                                  // headphones in at the start
        #expect(vm.sessionBlockReason == nil, "precondition")
        vm.scenePhaseDidChange(to: .inactive)
        vm.scenePhaseDidChange(to: .active)         // back, but on the speaker now
        #expect(vm.activeInterruptions == [.headphones], "\(vm.activeInterruptions)")
    }
}

// MARK: - B17: the lift's tail runs at the pre-flick rate

@MainActor
@Suite struct LiftTailRateTests {

    @Test("B17: a flick before the lift does not set the held tail's rate",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func liftTailUsesPreFlickRate(arm: PilotAudioCondition) {
        let rig = LifecycleRig(arm: arm)
        let vm = rig.vm
        vm.loadLetter(name: "A")
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 50, y: 200)
        vm.beginTouch(at: p, t: t)
        for _ in 0..<60 { t += 1.0 / 120; p.x += 1; vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }    // 120 pt/s
        for _ in 0..<4 { t += 1.0 / 120; p.x += 12.5; vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }  // 1500 pt/s flick
        #expect(vm.playback.state == .active, "precondition: the stroke sounds")
        #expect(rig.audio.rate > 1.5, "precondition: the flick drove the rate up (\(rig.audio.rate))")
        vm.endTouch()
        let expected = TouchDispatcher.mapVelocityToSpeed(120)
        #expect(abs(rig.audio.rate - expected) < 0.1,
                "\(arm): the held tail plays at \(rig.audio.rate)x, the writing rate was \(expected)x")
    }
}

// MARK: - B18: spatial pitch at most once per display frame

@MainActor
@Suite struct SpatialPitchPerFrameTests {

    private func spatialFreeWrite() -> LifecycleRig {
        let rig = LifecycleRig(arm: .spatial)
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        return rig
    }

    private func drive(_ rig: LifecycleRig, samples: Int) -> [Float] {
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 50, y: 100)
        rig.vm.beginTouch(at: p, t: t)
        var expected: [Float] = []
        for _ in 0..<samples {
            t += 1.0 / 240; p.x += 2; p.y += 10
            rig.vm.updateTouch(at: p, t: t, canvasSize: rig.canvas)
            expected.append(SpatialSonification.pitchCents(forNormalizedY: p.y / rig.canvas.height))
        }
        return expected
    }

    @Test("B18: the samples of one display frame write the pitch once; the lift writes the frame's last")
    func oneFrameOneWrite() {
        let rig = spatialFreeWrite()
        rig.vm.touchDispatcher.pitchClock = { 5000 }          // all samples in one frame
        let before = rig.audio.spatialPitches.count
        let expected = drive(rig, samples: 8)
        let written = Array(rig.audio.spatialPitches.dropFirst(before))
        #expect(written == [expected[0]], "pitch writes in one frame: \(written)")
        rig.vm.endTouch()
        #expect(rig.audio.spatialPitches.last == expected.last, "the held tail must end on the pen's last pitch")
    }

    @Test("B18 control: samples one frame apart each write their pitch")
    func everyFrameWrites() {
        let rig = spatialFreeWrite()
        var clock: CFTimeInterval = 5000
        rig.vm.touchDispatcher.pitchClock = { clock += 1.0 / 120; return clock }
        let before = rig.audio.spatialPitches.count
        let expected = drive(rig, samples: 8)
        #expect(Array(rig.audio.spatialPitches.dropFirst(before)) == expected)
    }
}

// MARK: - A13 on its own: a block that is NOT an interruption

/// The headphone tests above are also covered by B1 (the headphone stop is
/// an interruption since r16), so they cannot tell whether A13's own
/// guards hold. A failed disk write blocks the session WITHOUT an
/// interruption (`handlePersistenceFailure`); these pin A13 alone.
@MainActor
@Suite struct PersistenceBlockSilenceTests {

    @Test("A13: a session blocked during the observe cue starts no arm sound",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func blockDuringCueStartsNoSound(arm: PilotAudioCondition) async {
        let rig = LifecycleRig(arm: arm, fallback: 0.3)
        let vm = rig.vm
        vm.loadLetter(name: "A")
        #expect(vm.learningPhase == .observe && rig.audio.playCount == 0, "precondition: cue first")
        vm.handlePersistenceFailure("test")
        #expect(vm.sessionBlockReason != nil && vm.activeInterruptions.isEmpty,
                "precondition: blocked, not interrupted")
        try? await Task.sleep(for: .seconds(1.5))
        #expect(rig.audio.playCount == 0, "\(arm): arm sound started behind the block: \(rig.audio.events)")
    }

    @Test("A13 control: unblocked, the observe sound starts after the cue",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func unblockedCueStartsSound(arm: PilotAudioCondition) async {
        let rig = LifecycleRig(arm: arm, fallback: 0.3)
        rig.vm.loadLetter(name: "A")
        await rig.waitUntil(5) { rig.audio.playCount > 0 }
        #expect(rig.audio.playCount > 0, "\(arm): \(rig.audio.events)")
    }

    @Test("A13: a stroke moving on after the block plays no arm sound",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func strokeAfterBlockIsSilent(arm: PilotAudioCondition) async {
        let rig = LifecycleRig(arm: arm)
        let vm = rig.vm
        vm.loadLetter(name: "A")
        vm.phaseController.resume(at: .guided)
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 50, y: 200)
        vm.beginTouch(at: p, t: t)
        for _ in 0..<8 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }
        await vm.awaitPlaybackDebounce()
        #expect(rig.audio.playCount > 0, "precondition: the stroke sounds (\(rig.audio.events))")
        vm.handlePersistenceFailure("test")
        let eventsAtBlock = rig.audio.events.count
        // The pen keeps moving: without the block this movement plays again
        // (AudioArmRoutingTests' resume-on-move).
        for _ in 0..<8 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }
        await vm.awaitPlaybackDebounce()
        let after = rig.audio.events.dropFirst(eventsAtBlock)
        let playsAfter = after.filter { if case .play = $0 { return true } else { return false } }
        #expect(playsAfter.isEmpty, "\(arm): sound played behind the block: \(Array(after))")
        #expect(vm.playback.state != .active, "\(arm): the arm sound runs on behind the block")
    }

    @Test("A13 control: unblocked, the same further movement plays again",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func strokeWithoutBlockPlaysAgain(arm: PilotAudioCondition) async {
        let rig = LifecycleRig(arm: arm)
        let vm = rig.vm
        vm.loadLetter(name: "A")
        vm.phaseController.resume(at: .guided)
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 50, y: 200)
        vm.beginTouch(at: p, t: t)
        for _ in 0..<8 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }
        await vm.awaitPlaybackDebounce()
        let playsBefore = rig.audio.playCount
        for _ in 0..<8 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }
        await vm.awaitPlaybackDebounce()
        #expect(rig.audio.playCount > playsBefore, "\(arm): \(rig.audio.events)")
    }

    @Test("A13: no phase instruction is spoken while blocked")
    func noPhasePromptWhileBlocked() async {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .guided)
        rig.vm.handlePersistenceFailure("test")
        rig.vm.playPhaseEntryPrompt()
        await rig.vm.awaitPendingPhasePrompt()
        #expect(rig.prompts.count(.phaseGuided) == 0, "spoken behind the block: \(rig.prompts.keys)")
    }
}
