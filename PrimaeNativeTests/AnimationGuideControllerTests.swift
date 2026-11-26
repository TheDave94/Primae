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
    nonisolated private final class FakeClock: @unchecked Sendable {
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

    /// R-088, second half: dropping frames must not THIN the signal the
    /// sound couples to. The study observe sound is driven frame by frame
    /// (`TracingViewModel.handleGuideFrame`), and P4's contract is a dot
    /// tracked at the guide's own 60 Hz cadence (`ProtocolMatrixTests`
    /// counts the engine calls). A device loaded enough that a 1/60 s
    /// tick takes 0.2 s therefore has to deliver the frames it skipped on
    /// the next tick, interpolated at their own guide times — one frame
    /// per 1/60 s of STIMULUS, not per tick.
    ///
    /// Same fake device as the duration test above (12x the tick). The
    /// nominal frame count is `guide.totalDuration * 60`; before the
    /// cadence fix this loop delivered one frame per 0.2 s tick (~5 of
    /// ~61), which is how the full-suite run at f8cb49f1 turned
    /// `ProtocolMatrixTests` P4 red: fewer than 20 calls in a pass.
    @Test func couplingCadenceSurvivesAFrameDroppingDevice() async {
        let clock = FakeClock()
        let frameLatency: TimeInterval = 0.2
        let unitsPerSecond: TimeInterval = 0.8
        let strokes = sampleStrokes()
        let guide = LetterAnimationGuide.build(from: strokes,
                                               unitsPerSecond: unitsPerSecond)
        let nominalFrames = Int((guide.totalDuration * 60.0).rounded())

        var frames = 0
        var framesAtFirstCycle: Int?
        var completions = 0
        let c = AnimationGuideController(
            sleeper: { _ in
                clock.advance(frameLatency)
                await Task.yield()
            },
            now: { clock.now }
        )
        c.unitsPerSecond = unitsPerSecond
        c.onFrame = { _ in frames += 1 }
        c.onCycleComplete = {
            completions += 1
            // Snapshot at the FIRST cycle: the fake clock runs fast, so
            // the loop may complete more than one before the poll below
            // wakes, and a multi-cycle total could hide a thin cycle.
            if framesAtFirstCycle == nil { framesAtFirstCycle = frames }
        }
        c.start(strokes: strokes)
        for _ in 0..<2_000 {
            if completions > 0 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        c.stop()

        let delivered = framesAtFirstCycle ?? frames
        #expect(completions >= 1, "the guide must finish a cycle")
        // A receipt line: the audit trail wants the delivered rate, not
        // only the pass/fail (TESTING_CHECKLIST: read the number).
        print("R-088 cadence: \(delivered) frames for \(nominalFrames) nominal at \(frameLatency) s/tick")
        #expect(delivered >= Int(0.9 * Double(nominalFrames)),
                "the loaded device delivered \(delivered) frames for a nominal \(nominalFrames) (at 0.2 s/tick): the coupling signal was thinned, not just the rendering")
    }

    // MARK: - R-088 repair: the frames must describe one instant

    /// Two strokes, so the guide has a pen lift: a still window at the
    /// start of the second stroke, which is the window P4's "a jump is
    /// not velocity" test watches on the real F.
    private func twoStrokeStrokes() -> LetterStrokes {
        LetterStrokes(
            letter: "L",
            checkpointRadius: 0.05,
            strokes: [
                StrokeDefinition(id: 1, checkpoints: [
                    Checkpoint(x: 0.1, y: 0.5),
                    Checkpoint(x: 0.9, y: 0.5),
                ]),
                StrokeDefinition(id: 2, checkpoints: [
                    Checkpoint(x: 0.1, y: 0.2),
                    Checkpoint(x: 0.1, y: 0.9),
                ]),
            ]
        )
    }

    /// A device clock advanced ONLY by the guide's own sleeps, so the
    /// stall below is a property of the script and not of the runner.
    /// One tick per turn, except one turn that owes `stallTo` cycle
    /// seconds — the shape of a loaded simulator's turn, which is the
    /// only way `emitFrame` ever receives a time off the 1/60 grid.
    nonisolated private final class StallClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval = 0
        private var cycleOrigin: TimeInterval?
        private var stalled = false
        private let tick: TimeInterval
        private let stallFrom: TimeInterval
        private let stallTo: TimeInterval
        init(tick: TimeInterval, stallFrom: TimeInterval, stallTo: TimeInterval) {
            self.tick = tick
            self.stallFrom = stallFrom
            self.stallTo = stallTo
        }
        func advanceOnSleep() {
            lock.lock(); defer { lock.unlock() }
            // The 1.0 s start hold runs before the cycle clock exists;
            // its last turn is the first sleep at `>= 1 - tick/2`.
            if cycleOrigin == nil, value >= 1.0 - tick / 2 { cycleOrigin = value }
            guard let origin = cycleOrigin else { value += tick; return }
            if !stalled, value - origin >= stallFrom {
                stalled = true
                value = origin + stallTo
            } else {
                value += tick
            }
        }
        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// One `.move` as the coupling listener sees it: a straight-line
    /// distance in cell units and the guide time it was charged to.
    private struct EmittedMove {
        let from: CGPoint
        let to: CGPoint
        let seconds: TimeInterval
        var velocity: CGFloat {
            guard seconds > 0 else { return 0 }
            return hypot(to.x - from.x, to.y - from.y) / CGFloat(seconds)
        }
    }

    private func scriptedFrames(strokes: LetterStrokes,
                                unitsPerSecond: TimeInterval,
                                stallFrom: TimeInterval,
                                stallTo: TimeInterval) async -> [AnimationGuideController.Frame] {
        let tick: TimeInterval = 1.0 / 60.0
        let clock = StallClock(tick: tick, stallFrom: stallFrom, stallTo: stallTo)
        var frames: [AnimationGuideController.Frame] = []
        var completions = 0
        let c = AnimationGuideController(
            sleeper: { _ in
                clock.advanceOnSleep()
                await Task.yield()
            },
            now: { clock.now }
        )
        c.unitsPerSecond = unitsPerSecond
        c.onFrame = { frames.append($0) }
        c.onCycleComplete = { completions += 1 }
        c.start(strokes: strokes)
        // One turn per yield, and a cycle is ~280 turns: no wall clock.
        for _ in 0..<20_000 {
            if completions > 0 { break }
            await Task.yield()
        }
        c.stop()
        return frames
    }

    /// R-088 repair (2026-11-18). A stalled turn lands the guide's wide
    /// catch-up frame just PAST the still window that follows a pen
    /// lift. The still was reported on that turn, so the position
    /// bookkeeping said "the dot is at the new stroke's start" while it
    /// stamped that with a time already `overshoot` inside the new
    /// stroke. The next turn then charged `overshoot` + one tick of
    /// travel to one tick's `seconds`, and `TracingViewModel` divides
    /// distance by seconds: the coupled rate spikes above the guide's
    /// own speed.
    ///
    /// This is the mechanism behind CI run 44284705552, where P4's "a
    /// stroke-to-stroke jump is not velocity" went red on both the A16
    /// and the M5 simulator while the lane's unloaded run was green: the
    /// wide frame only exists when a turn owes more than the loop's
    /// 60-frame cap, which is a loaded device, not an idle one.
    ///
    /// `overshoot` is swept across one tick, including exactly ON the
    /// window boundary (0), which is benign and must stay benign.
    @Test func aStallPastAStillDoesNotInventVelocity() async {
        let tick: TimeInterval = 1.0 / 60.0
        let unitsPerSecond: TimeInterval = 0.36
        let strokes = twoStrokeStrokes()
        let guide = LetterAnimationGuide.build(from: strokes,
                                               unitsPerSecond: unitsPerSecond)
        // Step 0 is the pre-move still, step 1 the first stroke, step 2
        // the still the pen lift opens, step 3 the second stroke.
        let stillStart = guide.duration(for: guide.steps[0])
            + guide.duration(for: guide.steps[1])
        let stillEnd = stillStart + guide.duration(for: guide.steps[2])
        let stallFrom = stillStart - 1.75
        #expect(stillStart - stallFrom > 1.0,
                "precondition: the turn must owe more than the 60-frame cap (1 s)")

        for fraction in [0.0, 0.25, 0.5, 0.75] {
            let overshoot = fraction * tick
            let frames = await scriptedFrames(strokes: strokes,
                                              unitsPerSecond: unitsPerSecond,
                                              stallFrom: stallFrom,
                                              stallTo: stillEnd + overshoot)
            let moves = frames.compactMap { frame -> EmittedMove? in
                if case let .move(from, to, seconds) = frame {
                    return EmittedMove(from: from, to: to, seconds: seconds)
                }
                return nil
            }
            // The scenario has to be the one P4 measures: a pen lift,
            // then motion on the new stroke. Without these the bound
            // below could pass for the wrong reason.
            let jumpAt = frames.firstIndex { frame in
                if case .jump = frame { return true }
                return false
            }
            #expect(jumpAt != nil, "precondition: the pen lift was not emitted")
            let movedAfterJump = jumpAt.map { index in
                frames[(index + 1)...].contains { frame in
                    if case .move = frame { return true }
                    return false
                }
            } ?? false
            #expect(movedAfterJump, "precondition: no motion after the pen lift")
            let worst = moves.map(\.velocity).max() ?? 0
            print("R-088 stall repair: overshoot \(fraction) tick, worst \(worst) vs nominal \(unitsPerSecond) over \(moves.count) moves")
            #expect(worst <= CGFloat(unitsPerSecond) * 1.02,
                    "a stall landing \(fraction) of a tick past the pen lift's still reported \(worst) cell units/s for a guide that moves at \(unitsPerSecond)")
        }
    }

    /// A second `start` must cancel the first loop, or two guide dots run
    /// (and `onCycleComplete` fires twice per cycle). Counted through the
    /// injected sleeper: every loop parks in exactly one sleep at a time,
    /// so the number of sleeps in flight is the number of live loops.
    /// (The test used to contain no assertion at all — audit 2026-09-04.)
    @Test func start_replacesInFlightAnimation() async {
        nonisolated final class Gate: @unchecked Sendable {
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
