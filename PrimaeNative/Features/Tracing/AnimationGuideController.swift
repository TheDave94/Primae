// AnimationGuideController.swift
// PrimaeNative
//
// Drives the "blue dot follows the stroke path" animation used during the
// observe phase and the onboarding trace-demo. Pure UI-side concern: owns
// the animation point + looping Task, with no audio, touch, or phase
// knowledge. Extracted from TracingViewModel to keep its God-object scope
// smaller.

import CoreGraphics
import Foundation

@MainActor
@Observable
final class AnimationGuideController {

    /// Current normalized (0–1) point of the animated guide dot.
    /// `nil` when no animation is running. Views render at screen scale
    /// using `PrimaeLetterRenderer.normalizedGlyphRect`.
    private(set) var guidePoint: CGPoint? = nil

    /// Fires after each full demonstration loop (all steps + the 0.5 s rest).
    /// The observe phase uses this to auto-advance after N cycles so a child
    /// who doesn't read the "Tippen" prompt isn't stuck forever.
    var onCycleComplete: (@MainActor () -> Void)? = nil

    /// The active animation loop. Cancelled on `stop()` or when replaced.
    private var task: Task<Void, Never>?

    /// Deferred-start task for `startAfterDelay(_:strokes:)`. Tracked
    /// separately so `stop()` can cancel either phase cleanly.
    private var startTask: Task<Void, Never>?

    /// Injected sleeper for per-step + inter-cycle waits. Defaults to
    /// `realSleeper` (Task.sleep) in production; tests substitute a
    /// deterministic fake so the cycle / step timing can be exercised
    /// without real wall-clock waits.
    private let sleeper: Sleeper

    init(sleeper: @escaping Sleeper = realSleeper) {
        self.sleeper = sleeper
    }

    /// Begin the looping animation immediately for the supplied strokes.
    /// Replaces any in-flight animation.
    func start(strokes: LetterStrokes) {
        stop()
        let guide = LetterAnimationGuide.build(from: strokes)
        guard !guide.steps.isEmpty else { return }

        task = Task { [weak self, sleeper] in
            // P4 (ROADMAP_V5): "Bob the dog" start cue. Park the guide
            // dot at the first step's position for ~1 s before the loop
            // begins so a 5-year-old has a chance to see WHERE the
            // trace starts before the dot starts moving (Mayer 2009
            // pre-attentive cueing). Skipped on subsequent loop
            // iterations — only the very first step gets the dwell.
            let firstHoldRequested = !Task.isCancelled
            var heldFirst = false
            // 60 Hz interpolation budget: each segment between two
            // consecutive checkpoints in the same stroke is split into
            // N frames so the dot glides instead of snapping. Across
            // stroke boundaries we teleport (no interpolation) so the
            // viewer doesn't see a phantom diagonal between e.g. the
            // top of the A's left leg and the top of the right leg.
            let frameInterval: TimeInterval = 1.0 / 60.0
            while !Task.isCancelled {
                guard let self else { return }
                if !heldFirst, firstHoldRequested, let firstStep = guide.steps.first {
                    self.guidePoint = firstStep.point
                    try? await sleeper(.seconds(1.0))
                    heldFirst = true
                    if Task.isCancelled { break }
                }
                var previousStep: AnimationStep? = nil
                for step in guide.steps {
                    guard !Task.isCancelled else { break }
                    let duration = guide.duration(for: step)
                    if let prev = previousStep, prev.strokeIndex == step.strokeIndex {
                        let frames = max(1, Int((duration / frameInterval).rounded()))
                        let dx = step.point.x - prev.point.x
                        let dy = step.point.y - prev.point.y
                        for f in 1...frames {
                            if Task.isCancelled { break }
                            let t = CGFloat(f) / CGFloat(frames)
                            self.guidePoint = CGPoint(x: prev.point.x + dx * t,
                                                      y: prev.point.y + dy * t)
                            try? await sleeper(.seconds(frameInterval))
                        }
                    } else {
                        // First step of the cycle or a new stroke —
                        // teleport and dwell for the segment duration
                        // so cross-stroke transitions read as discrete
                        // pen lifts rather than diagonal slides.
                        self.guidePoint = step.point
                        try? await sleeper(.seconds(duration))
                    }
                    previousStep = step
                }
                if !Task.isCancelled {
                    self.guidePoint = nil
                    try? await sleeper(.seconds(0.5))
                    // One full cycle completed — invite the observer to advance.
                    // The callback reads `self` again because the outer while
                    // continues until cancelled by the callback site via stop().
                    if !Task.isCancelled { self.onCycleComplete?() }
                }
            }
            self?.guidePoint = nil
        }
    }

    /// Begin the animation after a delay. Used when a new letter loads so
    /// the dot doesn't race ahead of the PBM fade-in.
    func startAfterDelay(_ seconds: TimeInterval, strokes: LetterStrokes) {
        startTask?.cancel()
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
    }
}
