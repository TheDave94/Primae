// AnimationGuideController.swift
// PrimaeNative
//
// Drives the "blue dot follows the stroke path" animation used during
// the observe phase and the onboarding trace demo.

import CoreGraphics
import Foundation

@MainActor
@Observable
final class AnimationGuideController {

    /// Current normalized (0–1) point of the animated guide dot.
    /// `nil` when no animation is running. Views render at screen scale
    /// using `PrimaeLetterRenderer.normalizedGlyphRect`.
    private(set) var guidePoint: CGPoint? = nil

    /// Fires after each full demonstration loop. Observe phase uses this
    /// to auto-advance after N cycles for non-reading children.
    var onCycleComplete: (@MainActor () -> Void)? = nil

    /// What the dot did on one frame, for a listener that couples sound to
    /// it (the study observe phase, 2026-10-05: the sound tracks the dot
    /// like it tracks the pen — `TracingViewModel.handleGuideFrame`).
    /// Points are the same cell-normalised (0–1) points as `guidePoint`.
    enum Frame: Equatable {
        /// The dot is at `point` and not moving: the 1.0 s start hold, a
        /// new stroke's dwell, the pause after the pass.
        case still(CGPoint)
        /// The dot moved from `from` to `to` over `seconds` (the guide's
        /// own segment timing, so the velocity is the guide's speed).
        case move(from: CGPoint, to: CGPoint, seconds: TimeInterval)
        /// Stroke-to-stroke teleport: a pen lift, not motion — a listener
        /// must not read it as velocity.
        case jump(to: CGPoint)
    }

    /// Called on every frame (main actor, ~60 Hz while moving).
    var onFrame: (@MainActor (Frame) -> Void)? = nil

    private var task: Task<Void, Never>?
    /// The strokes the running or pending animation was armed with —
    /// nil when idle. Read by `TracingViewModel.canvasSize.didSet` to
    /// re-arm an observe demonstration that was armed before the canvas
    /// had laid out (audit 2026-09-06), and by tests.
    private(set) var armedStrokes: LetterStrokes? = nil
    /// Deferred-start task for `startAfterDelay(_:strokes:)`. Tracked
    /// separately so `stop()` can cancel either phase cleanly.
    private var startTask: Task<Void, Never>?
    private let sleeper: Sleeper
    private let now: MonotonicClock

    init(sleeper: @escaping Sleeper = realSleeper,
         now: @escaping MonotonicClock = realMonotonicClock) {
        self.sleeper = sleeper
        self.now = now
    }

    /// Begin the looping animation immediately for the supplied strokes.
    /// Replaces any in-flight animation.
    /// Cell-relative units per second for the observe demonstration.
    ///
    /// `AnimationSpeed.slow` has existed since the guide was written and
    /// was never wired to anything — every construction site took
    /// `LetterAnimationGuide.build`'s 0.9 default, so the enum's three
    /// cases were dead. Wired 2026-09-17 for the supervisor's "einmal
    /// vorzeigen (vielleicht etwas langsamer)": one pass at 0.4x, which
    /// is what `AnimationSpeed.slow` was defined to mean.
    ///
    /// Cell-relative, so the wall-clock length scales with the letter.
    ///
    /// THE WINDOW IS NOT LENGTH-PRESERVED — it is 1.25x LONGER. One pass
    /// at 0.4x takes `L/0.36` where two passes at 1.0x took `2L/0.9`, so
    /// the ratio is `2.778/2.222`. Halving the passes would have preserved
    /// it exactly; 0.4 is not 0.5. The five study letters therefore run
    /// ~6.25-13.75 s rather than the ~5-11 s the thesis quotes, and the
    /// dry-run's "stuck past ~20 seconds is a defect" tripwire was MOVED to
    /// 20 s with this window — at the old ~15 s it had about a second of
    /// headroom where it had four. `docs/STUDY_DEVICE_DRYRUN.md` §4a records
    /// the move; this comment previously still cited the old 15 s. (Per-segment
    /// flooring at 1/240 s and a flat 1/60 s first segment drift the true ratio
    /// slightly above 1.25 for checkpoint-dense letters.)
    ///
    /// R17E (RULINGS 2026-11-06): the dot is unchanged from r16 (0.36
    /// units/s; R17D's slower 0.171 made every demonstration 2.1x longer).
    /// Under the coupling map M3 the demonstration plays at about rate 1.17
    /// along the study iPad's vertical strokes (derived: 0.36 x 875 pt =
    /// 315 pt/s, MEASURED in env3 PopCapture logs for I's stem; M3 gives
    /// 1.165 there).
    static let observeUnitsPerSecond: TimeInterval = 0.9 * AnimationSpeed.slow.multiplier

    /// Live speed for `start`, defaulting to the production value above.
    /// Exposed because a test that waits for a cycle has to budget its
    /// wall-clock window for whatever speed is in force, and at 0.4x that
    /// budget stops fitting on a loaded CI runner — `onCycleComplete_
    /// firesAtLeastOnce` observed zero cycles in its 3 s window on the
    /// first CI run after the slow speed landed. Tests that only care
    /// THAT a cycle fires set this; production never changes it.
    var unitsPerSecond: TimeInterval = AnimationGuideController.observeUnitsPerSecond

    func start(strokes: LetterStrokes) {
        stop()
        let guide = LetterAnimationGuide.build(from: strokes,
                                               unitsPerSecond: unitsPerSecond)
        guard !guide.steps.isEmpty else { return }
        armedStrokes = strokes

        task = Task { [weak self, sleeper, now] in
            // 60 Hz TICK, not a 60 Hz frame. The tick is how often we
            // sample the clock; how far the dot moves each time comes
            // from elapsed time (audit R-088), so a loaded device drops
            // frames instead of stretching the demonstration. The old
            // loop slept a fixed 1/60 s per frame, which made the
            // delivered stimulus a function of device load: measured
            // 12.6 s delivered against a 2.52 s nominal at 0.2 s/tick.
            // A skipped frame is not dropped silently: the next turn
            // emits the frames the clock says are due, interpolated at
            // their own guide times, so the demonstration keeps its
            // length AND the observe sound keeps its ~60 updates/s.
            let tick: TimeInterval = 1.0 / 60.0

            // One cycle laid out on the cycle clock. Every step lasts
            // exactly as long as the guide says; the first step of a
            // cycle (and the first step after a stroke change) is spent
            // parked at the new point, because a cross-stroke move is a
            // pen lift, not motion.
            struct Window {
                let step: AnimationStep
                let previous: AnimationStep?
                let start: TimeInterval
                let end: TimeInterval
                var isMove: Bool {
                    guard let previous else { return false }
                    return previous.strokeIndex == step.strokeIndex
                }
            }
            var windows: [Window] = []
            var offset: TimeInterval = 0
            var previous: AnimationStep?
            for step in guide.steps {
                let duration = guide.duration(for: step)
                windows.append(Window(step: step, previous: previous,
                                      start: offset, end: offset + duration))
                offset += duration
                previous = step
            }
            // The post-pass pause, in which the dot is already blank.
            let cycleDuration = offset + 0.5
            let firstPoint = guide.steps[0].point
            let lastPointInCycle = guide.steps[guide.steps.count - 1].point

            var heldFirst = false
            var cycleStart: TimeInterval = 0
            var nextFrameAt: TimeInterval = 0
            var lastStepIndex = -1
            var lastPoint = firstPoint
            var lastEventTime: TimeInterval = 0
            var tailEmitted = false

            /// Emit the frame that belongs at cycle time `t`. The dot's
            /// position comes from the clock, so the cycle keeps the
            /// guide's own length; `seconds` is the guide time since the
            /// previous frame, so the coupled rate stays the guide's
            /// velocity even when one frame stands for several ticks.
            @MainActor
            func emitFrame(at t: TimeInterval) {
                guard let self else { return }
                var index = windows.count - 1
                for (i, w) in windows.enumerated() where t < w.end {
                    index = i
                    break
                }
                if index > lastStepIndex {
                    // Emit the transition events for every window between
                    // the last sampled one and this one, so a dropped
                    // frame never swallows a stroke's pen lift.
                    for j in (lastStepIndex + 1)...index {
                        let w = windows[j]
                        guard !w.isMove else { continue }
                        self.guidePoint = w.step.point
                        if w.previous != nil { self.onFrame?(.jump(to: w.step.point)) }
                        self.onFrame?(.still(w.step.point))
                        lastPoint = w.step.point
                        lastEventTime = t
                    }
                    lastStepIndex = index
                }
                let window = windows[index]
                if window.isMove {
                    let span = window.end - window.start
                    let progress = CGFloat(min(1, max(0, (t - window.start)
                        / (span > 0 ? span : 1))))
                    let from = window.previous!.point
                    let to = CGPoint(
                        x: from.x + (window.step.point.x - from.x) * progress,
                        y: from.y + (window.step.point.y - from.y) * progress)
                    let seconds = t - lastEventTime
                    if seconds > 0 {
                        self.guidePoint = to
                        self.onFrame?(.move(from: lastPoint, to: to,
                                            seconds: seconds))
                        lastPoint = to
                        lastEventTime = t
                    }
                } else {
                    self.guidePoint = window.step.point
                }
            }

            while !Task.isCancelled {
                guard let self else { return }
                // Pre-attentive start cue: park the dot at the first step
                // for ~1 s on the first iteration so the child sees WHERE
                // the trace starts before motion begins (Mayer 2009).
                if !heldFirst {
                    self.guidePoint = firstPoint
                    self.onFrame?(.still(firstPoint))
                    let holdEnd = now() + 1.0
                    while !Task.isCancelled, now() < holdEnd {
                        try? await sleeper(.seconds(tick))
                    }
                    heldFirst = true
                    if Task.isCancelled { break }
                    cycleStart = now()
                    nextFrameAt = 0
                }

                let elapsed = now() - cycleStart

                // Emit every frame the clock says is due — one per 1/60 s
                // of STIMULUS, not one per tick. A loaded device therefore
                // renders fewer turns without thinning the coupling signal
                // the observe sound reads frame by frame (audit R-088: the
                // full-suite run at f8cb49f1 delivered 21 frames where the
                // guide owed 61, and P4's "calls.count > 20" went red).
                // Bounded at one second's worth per turn so a long stall
                // cannot flood the main actor.
                var emitted = 0
                while nextFrameAt <= elapsed, nextFrameAt < offset, emitted < 60 {
                    emitFrame(at: nextFrameAt)
                    nextFrameAt += tick
                    emitted += 1
                }
                // Still behind after that: one wide frame carries the
                // motion at the guide's own velocity rather than replaying
                // it — a genuine frame drop, not a silent one.
                if nextFrameAt <= elapsed, nextFrameAt < offset {
                    emitFrame(at: min(elapsed, offset))
                    nextFrameAt = elapsed + tick
                }

                if elapsed >= offset, !tailEmitted {
                    // Post-pass pause: blank dot, one still at the end.
                    self.guidePoint = nil
                    self.onFrame?(.still(lastPointInCycle))
                    tailEmitted = true
                }

                if elapsed >= cycleDuration {
                    // A stall long enough to skip the whole tail must still
                    // deliver the end-of-pass still the listener expects.
                    if !tailEmitted {
                        self.guidePoint = nil
                        self.onFrame?(.still(lastPointInCycle))
                        tailEmitted = true
                    }
                    if !Task.isCancelled { self.onCycleComplete?() }
                    cycleStart += cycleDuration
                    // If the process stalled for a whole cycle, resync
                    // rather than firing a burst of completions.
                    if cycleStart < now() - cycleDuration { cycleStart = now() }
                    nextFrameAt = 0
                    lastStepIndex = -1
                    lastPoint = firstPoint
                    lastEventTime = 0
                    tailEmitted = false
                    continue
                }
                try? await sleeper(.seconds(tick))
            }
            self?.guidePoint = nil
        }
    }

    /// Begin the animation after a delay so the dot doesn't race
    /// ahead of the letter ghost fade-in on a fresh letter load.
    func startAfterDelay(_ seconds: TimeInterval, strokes: LetterStrokes) {
        startTask?.cancel()
        armedStrokes = strokes
        startTask = Task { [weak self, sleeper] in
            try? await sleeper(.seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.start(strokes: strokes)
        }
    }

    /// Stop any running animation. Safe to call repeatedly.
    func stop() {
        startTask?.cancel()
        startTask = nil
        task?.cancel()
        task = nil
        guidePoint = nil
        armedStrokes = nil
    }
}
