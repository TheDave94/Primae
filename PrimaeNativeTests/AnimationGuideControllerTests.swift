import Foundation
import CoreGraphics
import Testing
@testable import PrimaeNative

@MainActor
@Suite struct AnimationGuideControllerTests {

    private func sampleStrokes() -> LetterStrokes {
        // Minimal 2-checkpoint stroke so the built guide has a non-empty step list.
        LetterStrokes(
            letter: "Z",
            checkpointRadius: 0.05,
            strokes: [
                StrokeDefinition(id: 1, checkpoints: [
                    Checkpoint(x: 0.1, y: 0.5),
                    Checkpoint(x: 0.9, y: 0.5),
                ])
            ]
        )
    }

    @Test func initialState_guidePointIsNil() {
        let c = AnimationGuideController()
        #expect(c.guidePoint == nil)
    }

    @Test func stop_withNoAnimation_doesNotCrash() {
        let c = AnimationGuideController()
        c.stop()
        c.stop()
        #expect(c.guidePoint == nil)
    }

    @Test func start_setsGuidePointWithinShortWindow() async {
        let c = AnimationGuideController()
        c.start(strokes: sampleStrokes())
        for _ in 0..<20 {
            if c.guidePoint != nil { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(c.guidePoint != nil,
                "guidePoint should become non-nil within ~500 ms of start")
        c.stop()
    }

    @Test func stop_clearsGuidePoint() async {
        let c = AnimationGuideController()
        c.start(strokes: sampleStrokes())
        try? await Task.sleep(for: .milliseconds(80))
        c.stop()
        #expect(c.guidePoint == nil,
                "stop() must synchronously clear guidePoint")
    }

    @Test func startAfterDelay_doesNotFireEarly() async {
        let c = AnimationGuideController()
        c.startAfterDelay(0.2, strokes: sampleStrokes())
        try? await Task.sleep(for: .milliseconds(50))
        #expect(c.guidePoint == nil,
                "startAfterDelay must honor the delay before firing")
        c.stop()
    }

    @Test func onCycleComplete_firesAtLeastOnce() async {
        let c = AnimationGuideController()
        // Run the loop at the former default speed, not the production
        // one. Production slows the observe pass to 0.4x (2026-09-17) to
        // demonstrate the letter once, more slowly, and this test only
        // cares THAT a cycle fires — at the slow speed its wall-clock
        // budget stops fitting on a loaded runner, which is exactly how
        // it failed on the first CI run after that change.
        c.unitsPerSecond = 0.9
        var cycles = 0
        c.onCycleComplete = { cycles += 1 }
        c.start(strokes: sampleStrokes())
        // Single checkpoint gets ~0.25 s step + 0.5 s pause ≈ 750 ms/cycle.
        for _ in 0..<60 {
            if cycles >= 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(cycles >= 1,
                "onCycleComplete should fire within ~3 s; observed \(cycles) cycles")
        c.stop()
    }

    /// Thread-safe monotonic clock for the fake device in R-088.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        func advance(_ seconds: TimeInterval) {
            lock.lock(); value += seconds; lock.unlock()
        }
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// R-088: the guide is a stimulus, so its duration must be the one
    /// the guide defines, not the sum of however long each frame's sleep
    /// took on a loaded device. Simulate a device whose every frame
    /// takes 0.2 s (12x the nominal 1/60 s tick) and check the elapsed
    /// clock at the first `onCycleComplete` against the nominal cycle.
    ///
    /// Before the fix this reads ~12.6 s against a 2.52 s nominal: the
    /// loop never consults a clock, so each of the 63 sleeps stretches
    /// the cycle. After it, the cycle completes within one tick of the
    /// nominal length because frames are DROPPED, not time stretched.
    @Test func deliveredCycleDurationMatchesNominalUnderLoad() async {
        let clock = FakeClock()
        let frameLatency: TimeInterval = 0.2
        let unitsPerSecond: TimeInterval = 0.8
        let strokes = sampleStrokes()
        let guide = LetterAnimationGuide.build(from: strokes,
                                               unitsPerSecond: unitsPerSecond)
        // 1.0 s pre-move hold + all steps + 0.5 s post-pass pause.
        let nominal = 1.0 + guide.totalDuration + 0.5

        var completions: [TimeInterval] = []
        let c = AnimationGuideController(
            sleeper: { _ in
                clock.advance(frameLatency)
                await Task.yield()
            },
            now: { clock.now }
        )
        c.unitsPerSecond = unitsPerSecond
        c.onCycleComplete = { completions.append(clock.now) }
        c.start(strokes: strokes)
        for _ in 0..<2_000 {
            if !completions.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        c.stop()

        #expect(completions.count >= 1,
                "the guide must finish a cycle; observed \(completions.count)")
        guard let delivered = completions.first else { return }
        #expect(delivered <= nominal + frameLatency + 0.01,
                "delivered cycle \(delivered)s must stay within one loaded frame of nominal \(nominal)s")
    }

    /// A second `start` must cancel the first loop, or two guide dots run
    /// (and `onCycleComplete` fires twice per cycle). Counted through the
    /// injected sleeper: every loop parks in exactly one sleep at a time,
    /// so the number of sleeps in flight is the number of live loops.
    /// (The test used to contain no assertion at all — audit 2026-09-04.)
    @Test func start_replacesInFlightAnimation() async {
        final class Gate: @unchecked Sendable {
            let lock = NSLock(); var inFlight = 0; var peak = 0
            func enter() { lock.lock(); inFlight += 1; peak = max(peak, inFlight); lock.unlock() }
            func leave() { lock.lock(); inFlight -= 1; lock.unlock() }
            var current: Int { lock.lock(); defer { lock.unlock() }; return inFlight }
        }
        let gate = Gate()
        let c = AnimationGuideController(sleeper: { _ in
            gate.enter(); defer { gate.leave() }
            // Park until cancelled — a cancelled loop leaves, a live one stays.
            try await Task.sleep(for: .seconds(60))
        })
        // Bounded polls, not fixed yield counts: the cancellation
        // propagation and the new loop's entry into the sleeper are not
        // ordered by a yield count (review 2026-09-05).
        func settle(to expected: Int) async {
            for _ in 0..<500 where gate.current != expected { await Task.yield() }
        }
        c.start(strokes: sampleStrokes())
        await settle(to: 1)
        #expect(gate.current == 1, "one loop parked in its sleep, got \(gate.current)")
        c.start(strokes: sampleStrokes())
        await settle(to: 1)
        // If the first loop were NOT cancelled, the count settles at 2 and stays there.
        for _ in 0..<100 { await Task.yield() }
        #expect(gate.current == 1, "the first loop must be cancelled by the second start; live loops = \(gate.current)")
        c.stop()
        await settle(to: 0)
        #expect(gate.current == 0, "stop must cancel the live loop; live loops = \(gate.current)")
    }
}
