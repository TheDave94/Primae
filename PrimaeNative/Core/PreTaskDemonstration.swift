// PreTaskDemonstration.swift
// PrimaeNative
//
// Pre-task sound-arm demonstration, per the 2026-09-03 study-design
// instruction: both sound arms get a brief demonstration BEFORE the
// tracing task, structurally matched in duration and form, and neither
// coupled to the child's own trace.
//
// THE REASON FOR THE SYMMETRY: a demonstration can INSTALL a crossmodal
// mapping rather than reveal one already there. If only one arm got a
// pre-task demonstration, that arm's later tracing-task audio wouldn't
// just be "the arm's sound" — it would be "the arm's sound, already
// taught". That confounds the arm contrast with having been taught,
// not with what the sound itself is. So every arm gets a demonstration
// of the SAME shape; only its sound differs (or is absent) — the same
// "only audio varies" shape as pilot decision D1.
//
// Content per arm:
//   .phoneme  — a sound-letter exposure: the letter's own phoneme,
//               played once.
//   .spatial  — an axis demonstration: a scripted pitch/pan sweep
//               across the FULL canvas range, independent of any
//               specific letter's shape (a letter with a short stroke
//               would otherwise give a foreshortened, letter-dependent
//               sweep — see `axisSweep`). NOTE (2026-09-17): this is
//               what the spec above describes and no longer what a
//               default device does. The sweep is behind
//               `StudyComparisonSettings.spatialAxisDemonstration`,
//               OFF by default, so the live behaviour is a two-second
//               window with the carrier held steady — the same window
//               and the same match, minus the movement. See the
//               switch's doc comment for the protocol divergence that
//               OFF default represents.
//   .silent   — no audio is added. The unchanged ghost-letter animation
//               (LetterAnimationGuide / AnimationGuideController) that
//               already precedes tracing in every arm today IS the
//               silent arm's matched non-auditory equivalent: every
//               arm already gets the SAME visual demonstration of the
//               SAME duration; sound arms layer their own scripted
//               sound onto that same window, silent doesn't.
//
// NOT trace-coupled: `TracingViewModel.armPreTaskDemonstration` drives
// this from its OWN scripted timeline (`axisSweep`, or a single
// phoneme play), never from `TouchDispatcher`'s live-touch coupling —
// a structurally distinct mechanism from the tracing-task coupling
// §2.6 governs.

import CoreGraphics
import Foundation

enum PreTaskDemonstration {
    /// Total demo window, seconds. Fixed so the spatial axis sweep and
    /// the phoneme sound-letter exposure are matched in duration
    /// regardless of the phoneme clip's own natural length (phonemes
    /// are short sustained continuants / clean-burst stops — see
    /// docs/DECISIONS.md §2.6 — almost always shorter than this).
    static let duration: TimeInterval = 2.0

    /// Sample count for the scripted axis sweep, spread evenly across
    /// `duration`.
    static let sweepStepCount = 40

    /// One instant of the scripted, non-trace-coupled axis sweep: how
    /// far into the demo (seconds, monotonically increasing) and where
    /// the (silent, app-driven) sweep point sits in normalized canvas
    /// space at that instant.
    struct SweepSample: Equatable {
        let elapsed: TimeInterval
        let point: CGPoint
    }

    /// Pure — no Task, no audio, no clock, so it's directly unit-
    /// testable. One full top→bottom→top pass on Y (pitch: high → low
    /// → high) and on X (pan) a centre→right→centre→left→centre pass (x = 0.5 + 0.5·sin 2πt), a
    /// quarter-cycle out of phase so the two axes are audible moving
    /// independently rather than only together — a clearer axis
    /// demonstration than a straight diagonal would give.
    ///
    /// CALLED ONLY WHEN THE COMPARISON SWITCH IS ON (2026-09-17). The
    /// spatial arm's pre-task demonstration stopped driving this when the
    /// scripted sweep was removed on the supervisor's "Glissando weg"
    /// (6fb7233c), which held the carrier steady for the same two-second
    /// window instead. It has a call site again:
    /// `StudyComparisonSettings.spatialAxisDemonstration` selects between
    /// the two, so this runs whenever that switch is ON — off by default,
    /// and OFF is what the 6fb7233c commit established. See the `.spatial`
    /// branch of `TracingViewModel.armPreTaskDemonstration`, and the
    /// switch's own doc comment for why the OFF default is a divergence
    /// from `04-implementation.typ:17` rather than a neutral choice.
    static func axisSweep(steps: Int = Self.sweepStepCount,
                          duration: TimeInterval = Self.duration) -> [SweepSample] {
        guard steps > 1, duration > 0 else { return [] }
        return (0..<steps).map { i in
            let t = Double(i) / Double(steps - 1)
            let elapsed = t * duration
            let y = 0.5 - 0.5 * cos(2 * .pi * t)
            let x = 0.5 - 0.5 * cos(2 * .pi * t + .pi / 2)
            return SweepSample(elapsed: elapsed, point: CGPoint(x: x, y: y))
        }
    }
}
