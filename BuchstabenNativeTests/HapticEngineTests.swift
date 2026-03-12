//  HapticEngineTests.swift
//  BuchstabenNativeTests
//
//  Tests for HapticEngineProviding protocol + NullHapticEngine,
//  and haptic event integration with TracingViewModel.

import XCTest
import CoreGraphics
@testable import BuchstabenNative

// MARK: - NullHapticEngine tests

@MainActor
final class NullHapticEngineTests: XCTestCase {

    func testPrepare_incrementsCallCount() {
        let engine = NullHapticEngine()
        XCTAssertEqual(engine.prepareCallCount, 0)
        engine.prepare()
        XCTAssertEqual(engine.prepareCallCount, 1)
        engine.prepare()
        XCTAssertEqual(engine.prepareCallCount, 2)
    }

    func testFire_recordsEvent() {
        let engine = NullHapticEngine()
        engine.fire(.strokeBegan)
        XCTAssertEqual(engine.firedEvents, [.strokeBegan])
    }

    func testFire_allEventTypes_recorded() {
        let engine = NullHapticEngine()
        let all: [HapticEvent] = [.strokeBegan, .checkpointHit, .strokeCompleted, .letterCompleted, .offPath]
        all.forEach { engine.fire($0) }
        XCTAssertEqual(engine.firedEvents, all)
    }

    func testFire_order_preserved() {
        let engine = NullHapticEngine()
        engine.fire(.strokeBegan)
        engine.fire(.checkpointHit)
        engine.fire(.strokeCompleted)
        XCTAssertEqual(engine.firedEvents[0], .strokeBegan)
        XCTAssertEqual(engine.firedEvents[1], .checkpointHit)
        XCTAssertEqual(engine.firedEvents[2], .strokeCompleted)
    }

    func testFire_multipleCheckpoints_allRecorded() {
        let engine = NullHapticEngine()
        for _ in 0..<5 { engine.fire(.checkpointHit) }
        XCTAssertEqual(engine.firedEvents.filter { $0 == .checkpointHit }.count, 5)
    }
}

// MARK: - HapticEvent equatability

final class HapticEventEquatabilityTests: XCTestCase {
    func testAllCases_selfEqual() {
        let cases: [HapticEvent] = [.strokeBegan, .checkpointHit, .strokeCompleted, .letterCompleted, .offPath]
        for c in cases { XCTAssertEqual(c, c) }
    }

    func testDifferentCases_notEqual() {
        XCTAssertNotEqual(HapticEvent.strokeBegan, .strokeCompleted)
        XCTAssertNotEqual(HapticEvent.checkpointHit, .letterCompleted)
    }
}

// MARK: - TracingViewModel haptic integration tests

@MainActor
private final class TrackingMockAudio: AudioControlling {
    func loadAudioFile(named: String, autoplay: Bool) {}
    func play() {}
    func stop() {}
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

@MainActor
private func makeVM(haptics: NullHapticEngine) -> TracingViewModel {
    TracingViewModel(audio: TrackingMockAudio(), haptics: haptics)
}

@MainActor
final class TracingViewModelHapticTests: XCTestCase {

    func testBeginTouch_firesStrokeBegan() {
        let haptics = NullHapticEngine()
        let vm = makeVM(haptics: haptics)
        haptics.reset()  // clear prepare-time events

        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: CACurrentMediaTime())
        XCTAssertTrue(haptics.firedEvents.contains(.strokeBegan),
                      "Expected strokeBegan, got \(haptics.firedEvents)")
    }

    func testPrepare_calledOnInit() {
        let haptics = NullHapticEngine()
        _ = makeVM(haptics: haptics)
        XCTAssertEqual(haptics.prepareCallCount, 1)
    }

    func testLetterCompleted_firesLetterCompleted() {
        let haptics = NullHapticEngine()
        let vm = makeVM(haptics: haptics)
        // letters is private; check via public currentLetterName instead
        guard !vm.currentLetterName.isEmpty else {
            XCTSkip("No letters loaded in test bundle")
            return
        }
        haptics.reset()

        // Disable stroke-order enforcement so the grid sweep can hit checkpoints
        // regardless of which stroke they belong to.
        vm.strokeEnforced = false

        // Drive the letter to completion by sweeping across the entire canvas.
        // With standard difficulty the checkpoint radius is generous enough that
        // a horizontal sweep will hit all checkpoints for the default A letter.
        let canvasSize = CGSize(width: 400, height: 400)
        let t0 = CACurrentMediaTime()
        vm.beginTouch(at: CGPoint(x: 0, y: 0), t: t0)

        // Sweep horizontally across the canvas at 5-pt intervals to hit checkpoints
        var t = t0
        for row in stride(from: 0, through: Int(canvasSize.height), by: 20) {
            for col in stride(from: 0, through: Int(canvasSize.width), by: 5) {
                t += 0.001
                vm.updateTouch(at: CGPoint(x: CGFloat(col), y: CGFloat(row)),
                                t: t, canvasSize: canvasSize)
            }
        }

        XCTAssertTrue(haptics.firedEvents.contains(.letterCompleted),
                      "Expected letterCompleted in \(haptics.firedEvents)")
    }

    func testNoHapticOnMultiTouchNavigation() {
        let haptics = NullHapticEngine()
        let vm = makeVM(haptics: haptics)
        haptics.reset()

        vm.beginMultiTouchNavigation()
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: CACurrentMediaTime())
        // Multi-touch active — beginTouch guard should block, no haptic
        XCTAssertFalse(haptics.firedEvents.contains(.strokeBegan),
                       "strokeBegan should not fire during multi-touch navigation")
        vm.endMultiTouchNavigation()
    }
}
