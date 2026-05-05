import Testing
import CoreGraphics
import QuartzCore
@testable import PrimaeNative

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
    var initializationError: String? { nil }
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
        let vm = TracingViewModel(.stub.with(audio: TrackingMockAudio()).with(haptics: haptics).with(thesisCondition: .guidedOnly))
        haptics.reset()
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: CACurrentMediaTime())
        #expect(haptics.firedEvents.contains(.strokeBegan),
                "Expected strokeBegan, got \(haptics.firedEvents)")
    }

    @Test func prepare_calledOnInit() {
        let haptics = NullHapticEngine()
        _ = TracingViewModel(.stub.with(audio: TrackingMockAudio()).with(haptics: haptics).with(thesisCondition: .guidedOnly))
        #expect(haptics.prepareCallCount == 1)
    }

    @Test func letterCompleted_firesLetterCompleted() {
        let haptics = NullHapticEngine()
        let vm = TracingViewModel(.stub.with(audio: TrackingMockAudio()).with(haptics: haptics).with(thesisCondition: .guidedOnly))
        guard !vm.currentLetterName.isEmpty else { return }
        haptics.reset()

        let canvasSize = CGSize(width: 400, height: 400)
        let w = canvasSize.width, h = canvasSize.height
        // Align the VM's canvasSize with the size used in updateTouch so the
        // updateTouch canvas-mismatch guard doesn't reload (and reset) checkpoints
        // on every call, which would prevent progress from accumulating.
        vm.canvasSize = canvasSize
        // Trace along the stub letter's horizontal stroke at y=0.5,
        // hitting all 50 checkpoints from x=0.0 to x=0.98.
        let checkpointSequence: [CGPoint] = (0..<50).map { i in
            CGPoint(x: CGFloat(i) * 0.02 * w, y: 0.50 * h)
        }

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

}
