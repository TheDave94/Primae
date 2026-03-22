//  HapticEngineTests.swift
//  BuchstabenNativeTests

import Testing
import CoreGraphics
@testable import BuchstabenNative

// MARK: - NullHapticEngine tests

@Suite @MainActor struct NullHapticEngineTests {

    @Test func prepare_incrementsCallCount() {
        let engine = NullHapticEngine()
        #expect(engine.prepareCallCount == 0)
        engine.prepare()
        #expect(engine.prepareCallCount == 1)
        engine.prepare()
        #expect(engine.prepareCallCount == 2)
    }

    @Test func fire_recordsEvent() {
        let engine = NullHapticEngine()
        engine.fire(.strokeBegan)
        #expect(engine.firedEvents == [.strokeBegan])
    }

    @Test func fire_allEventTypes_recorded() {
        let engine = NullHapticEngine()
        let all: [HapticEvent] = [.strokeBegan, .checkpointHit, .strokeCompleted, .letterCompleted, .offPath]
        all.forEach { engine.fire($0) }
        #expect(engine.firedEvents == all)
    }

    @Test func fire_order_preserved() {
        let engine = NullHapticEngine()
        engine.fire(.strokeBegan)
        engine.fire(.checkpointHit)
        engine.fire(.strokeCompleted)
        #expect(engine.firedEvents[0] == .strokeBegan)
        #expect(engine.firedEvents[1] == .checkpointHit)
        #expect(engine.firedEvents[2] == .strokeCompleted)
    }

    @Test func fire_multipleCheckpoints_allRecorded() {
        let engine = NullHapticEngine()
        for _ in 0..<5 { engine.fire(.checkpointHit) }
        #expect(engine.firedEvents.filter { $0 == .checkpointHit }.count == 5)
    }
}

// MARK: - HapticEvent equatability

@Suite struct HapticEventEquatabilityTests {

    @Test func allCases_selfEqual() {
        let cases: [HapticEvent] = [.strokeBegan, .checkpointHit, .strokeCompleted, .letterCompleted, .offPath]
        for c in cases { #expect(c == c) }
    }

    @Test func differentCases_notEqual() {
        #expect(HapticEvent.strokeBegan != .strokeCompleted)
        #expect(HapticEvent.checkpointHit != .letterCompleted)
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

@Suite @MainActor struct TracingViewModelHapticTests {

    @Test func beginTouch_firesStrokeBegan() {
        let haptics = NullHapticEngine()
        let vm = TracingViewModel(.stub.with(audio: TrackingMockAudio()).with(haptics: haptics))
        haptics.reset()
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: CACurrentMediaTime())
        #expect(haptics.firedEvents.contains(.strokeBegan),
                "Expected strokeBegan, got \(haptics.firedEvents)")
    }

    @Test func prepare_calledOnInit() {
        let haptics = NullHapticEngine()
        _ = TracingViewModel(.stub.with(audio: TrackingMockAudio()).with(haptics: haptics))
        #expect(haptics.prepareCallCount == 1)
    }

    @Test func letterCompleted_firesLetterCompleted() {
        let haptics = NullHapticEngine()
        let vm = TracingViewModel(.stub.with(audio: TrackingMockAudio()).with(haptics: haptics))
        guard !vm.currentLetterName.isEmpty else { return }
        haptics.reset()

        let canvasSize = CGSize(width: 400, height: 400)
        let w = canvasSize.width, h = canvasSize.height
        let checkpointSequence: [CGPoint] = [
            CGPoint(x: 0.515 * w, y: 0.170 * h),
            CGPoint(x: 0.514 * w, y: 0.319 * h),
            CGPoint(x: 0.514 * w, y: 0.469 * h),
            CGPoint(x: 0.400 * w, y: 0.668 * h),
            CGPoint(x: 0.296 * w, y: 0.817 * h),
            CGPoint(x: 0.515 * w, y: 0.170 * h),
            CGPoint(x: 0.514 * w, y: 0.319 * h),
            CGPoint(x: 0.514 * w, y: 0.494 * h),
            CGPoint(x: 0.762 * w, y: 0.668 * h),
            CGPoint(x: 0.695 * w, y: 0.817 * h),
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
        #expect(Double(vm.progress) > 0.0,
                "Progress=0 means no checkpoints hit. Events: \(haptics.firedEvents)")
        #expect(haptics.firedEvents.contains(.letterCompleted),
                "Expected letterCompleted. progress=\(vm.progress) events=\(haptics.firedEvents)")
    }

    @Test func noHapticOnMultiTouchNavigation() {
        let haptics = NullHapticEngine()
        let vm = TracingViewModel(.stub.with(audio: TrackingMockAudio()).with(haptics: haptics))
        haptics.reset()
        vm.beginMultiTouchNavigation()
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: CACurrentMediaTime())
        #expect(!haptics.firedEvents.contains(.strokeBegan),
                "strokeBegan should not fire during multi-touch navigation")
        vm.endMultiTouchNavigation()
    }
}
