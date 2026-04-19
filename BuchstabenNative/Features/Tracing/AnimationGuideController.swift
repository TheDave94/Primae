// AnimationGuideController.swift
// BuchstabenNative
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

    /// Begin the looping animation immediately for the supplied strokes.
    /// Replaces any in-flight animation.
    func start(strokes: LetterStrokes) {
        stop()
        let guide = LetterAnimationGuide.build(from: strokes)
        guard !guide.steps.isEmpty else { return }

        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for step in guide.steps {
                    guard !Task.isCancelled else { break }
                    self.guidePoint = step.point
                    try? await Task.sleep(for: .seconds(guide.duration(for: step)))
                }
                if !Task.isCancelled {
                    self.guidePoint = nil
                    try? await Task.sleep(for: .seconds(0.5))
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
        startTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
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
