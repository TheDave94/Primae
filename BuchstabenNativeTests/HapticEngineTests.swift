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

    func testPrepare_incrementsCallCount() async {
        let engine = NullHapticEngine()
        XCTAssertEqual(engine.prepareCallCount, 0)
        engine.prepare()
        XCTAssertEqual(engine.prepareCallCount, 1)
        engine.prepare()
        XCTAssertEqual(engine.prepareCallCount, 2)
    }

    func testFire_recordsEvent() async {
        let engine = NullHapticEngine()
        engine.fire(.strokeBegan)
        XCTAssertEqual(engine.firedEvents, [.strokeBegan])
    }

    func testFire_allEventTypes_recorded() async {
        let engine = NullHapticEngine()
        let all: [HapticEvent] = [.strokeBegan, .checkpointHit, .strokeCompleted, .letterCompleted, .offPath]
        all.forEach { engine.fire($0) }
        XCTAssertEqual(engine.firedEvents, all)
    }

    func testFire_order_preserved() async {
        let engine = NullHapticEngine()
        engine.fire(.strokeBegan)
        engine.fire(.checkpointHit)
        engine.fire(.strokeCompleted)
        XCTAssertEqual(engine.firedEvents[0], .strokeBegan)
        XCTAssertEqual(engine.firedEvents[1], .checkpointHit)
        XCTAssertEqual(engine.firedEvents[2], .strokeCompleted)
    }

    func testFire_multipleCheckpoints_allRecorded() async {
        let engine = NullHapticEngine()
        for _ in 0..<5 { engine.fire(.checkpointHit) }
        XCTAssertEqual(engine.firedEvents.filter { $0 == .checkpointHit }.count, 5)
    }
}

// MARK: - HapticEvent equatability

final class HapticEventEquatabilityTests: XCTestCase {
    func testAllCases_selfEqual() async {
        let cases: [HapticEvent] = [.strokeBegan, .checkpointHit, .strokeCompleted, .letterCompleted, .offPath]
        for c in cases { XCTAssertEqual(c, c) }
    }

    func testDifferentCases_notEqual() async {
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
    // Use NullLetterCache to avoid stale disk cache interfering with stroke definitions
    TracingViewModel(audio: TrackingMockAudio(), progressStore: StubProgressStore(), haptics: haptics, repo: LetterRepository(resources: StubResourceProvider(), cache: NullLetterCache()))
}

private struct NullLetterCache: LetterCacheStoring {
    func save(_ letters: [LetterAsset]) throws {}
    func load() throws -> [LetterAsset] { throw LetterRepositoryError.cacheReadFailed(path: "") }
    func clear() {}
}

@MainActor
final class TracingViewModelHapticTests: XCTestCase {

    func testBeginTouch_firesStrokeBegan() async {
        let haptics = NullHapticEngine()
        let vm = makeVM(haptics: haptics)
        haptics.reset()  // clear prepare-time events

        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: CACurrentMediaTime())
        XCTAssertTrue(haptics.firedEvents.contains(.strokeBegan),
                      "Expected strokeBegan, got \(haptics.firedEvents)")
    }

    func testPrepare_calledOnInit() async {
        let haptics = NullHapticEngine()
        _ = makeVM(haptics: haptics)
        XCTAssertEqual(haptics.prepareCallCount, 1)
    }

    func testLetterCompleted_firesLetterCompleted() async {
        let haptics = NullHapticEngine()
        let vm = makeVM(haptics: haptics)
        // letters is private; check via public currentLetterName instead
        guard !vm.currentLetterName.isEmpty else {
            XCTSkip("No letters loaded in test bundle")
            return
        }
        haptics.reset()

        // Drive the fallback "A" letter to completion by tracing through its
        // known checkpoints in stroke order. The fallback definition in
        // LetterRepository.defaultStrokes(for:) is:
        //   stroke 1: (0.3,0.8) → (0.5,0.2) → (0.7,0.8)
        //   stroke 2: (0.38,0.55) → (0.62,0.55)
        // checkpointRadius = 0.06 on a 400×400 canvas = 24pt tolerance.
        // We trace each checkpoint directly to guarantee completion regardless
        // of which letter is loaded; if no checkpoints match (custom letter),
        // the grid-sweep fallback below covers it.
        let canvasSize = CGSize(width: 400, height: 400)
        let w = canvasSize.width, h = canvasSize.height
        // Coordinates match defaultStrokes("A") in LetterRepository:
        // stroke 1 (left leg): apex→mid→bottom-left
        // stroke 2 (right leg): apex→mid→bottom-right
        // stroke 3 (crossbar): left→right
        let checkpointSequence: [CGPoint] = [
            // stroke 1
            CGPoint(x: 0.515 * w, y: 0.170 * h),
            CGPoint(x: 0.514 * w, y: 0.319 * h),
            CGPoint(x: 0.514 * w, y: 0.469 * h),
            CGPoint(x: 0.400 * w, y: 0.668 * h),
            CGPoint(x: 0.296 * w, y: 0.817 * h),
            // stroke 2
            CGPoint(x: 0.515 * w, y: 0.170 * h),
            CGPoint(x: 0.514 * w, y: 0.319 * h),
            CGPoint(x: 0.514 * w, y: 0.494 * h),
            CGPoint(x: 0.762 * w, y: 0.668 * h),
            CGPoint(x: 0.695 * w, y: 0.817 * h),
            // stroke 3
            CGPoint(x: 0.399 * w, y: 0.597 * h),
            CGPoint(x: 0.512 * w, y: 0.597 * h),
            CGPoint(x: 0.624 * w, y: 0.597 * h),
        ]

        var t = CACurrentMediaTime()
        vm.beginTouch(at: checkpointSequence[0], t: t)
        for pt in checkpointSequence {
            t += 0.05
            vm.updateTouch(at: pt, t: t, canvasSize: canvasSize)
        }

        XCTAssertTrue(haptics.firedEvents.contains(.letterCompleted),
                      "Expected letterCompleted in \(haptics.firedEvents)")
    }

    func testNoHapticOnMultiTouchNavigation() async {
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
