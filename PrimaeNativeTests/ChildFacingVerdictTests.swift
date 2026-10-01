// ChildFacingVerdictTests.swift
// PrimaeNativeTests
//
// Coverage for the two child-facing computations that had ZERO code
// references from either test target before this file (audit 2026-09-20):
//
//   1. the freeWrite score→verdict shown to the child
//      (`SchuleWorldView.feedbackCard`) — extracted to `FreeWriteFeedback`
//   2. the star TOTAL across letters, independently computed in
//      `SchuleWorldView.totalStars` and `WorldSwitcherRail.starTotal`,
//      each with a comment claiming it agreed with the other — extracted
//      to `LetterStars.total(for:)`
//
// WHY THE EXTRACTION. Both lived inside `View` bodies (`some View`, and
// `private` besides), which no unit test can reach — the same wall that
// forced `TracingViewModel.CanvasDrawPlan`. The DECISIONS are now plain
// Swift values; the views render them. Every threshold below is a LITERAL
// so it can fail: an expectation written as the implementation's own
// expression cannot.
//
// WHAT REMAINS UNCOVERED, named rather than faked: the rendered card (its
// layout, the `Color`s the bands resolve to, the star glyphs) and the two
// views' own bodies. Those stay untestable by construction. What is pinned
// is every threshold and every string — which is where a child-visible
// mistake would actually come from.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - 1. The freeWrite verdict

@Suite struct FreeWriteFeedbackTests {

    // MARK: stars — boundaries at 0.85 / 0.6 / 0.35

    @Test("three stars at and above 0.85, two just below")
    func threeStarBoundary() {
        #expect(FreeWriteFeedback(score: 1.0).starsEarned == 3)
        #expect(FreeWriteFeedback(score: 0.85).starsEarned == 3,
                "0.85 is the inclusive boundary")
        #expect(FreeWriteFeedback(score: 0.8499).starsEarned == 2,
                "just below 0.85 drops to two")
    }

    @Test("two stars at and above 0.6, one just below")
    func twoStarBoundary() {
        #expect(FreeWriteFeedback(score: 0.6).starsEarned == 2)
        #expect(FreeWriteFeedback(score: 0.5999).starsEarned == 1)
    }

    @Test("one star at and above 0.35, none just below")
    func oneStarBoundary() {
        #expect(FreeWriteFeedback(score: 0.35).starsEarned == 1)
        #expect(FreeWriteFeedback(score: 0.3499).starsEarned == 0)
        #expect(FreeWriteFeedback(score: 0).starsEarned == 0)
    }

    // MARK: praise — the exact German line per tier

    @Test("each star tier gets its own praise line")
    func praiseLines() {
        #expect(FreeWriteFeedback(score: 1.0).praise == "Super gemacht!")
        #expect(FreeWriteFeedback(score: 0.7).praise == "Gut gemacht!")
        #expect(FreeWriteFeedback(score: 0.4).praise == "Schon ganz gut.")
        #expect(FreeWriteFeedback(score: 0.1).praise == "Probier es nochmal.")
    }

    // MARK: the symbol cue, which switches at two stars

    @Test("two stars and above get the thumbs-up, below that sparkles")
    func symbolCue() {
        #expect(FreeWriteFeedback(score: 0.9).symbolName == "hand.thumbsup.fill")
        #expect(FreeWriteFeedback(score: 0.6).symbolName == "hand.thumbsup.fill",
                "two stars is the thumbs-up tier")
        #expect(FreeWriteFeedback(score: 0.5999).symbolName == "sparkles")
        #expect(FreeWriteFeedback(score: 0.0).symbolName == "sparkles")
    }

    // MARK: the colour band — a DIFFERENT ladder (0.7 / 0.5) from the stars

    @Test("the swatch band has its own thresholds, not the star ladder's")
    func tintBands() {
        #expect(FreeWriteFeedback(score: 1.0).tintBand == .green)
        #expect(FreeWriteFeedback(score: 0.7).tintBand == .green)
        #expect(FreeWriteFeedback(score: 0.6999).tintBand == .yellow)
        #expect(FreeWriteFeedback(score: 0.5).tintBand == .yellow)
        #expect(FreeWriteFeedback(score: 0.4999).tintBand == .orange)

        // The two ladders are deliberately independent: 0.65 is two stars
        // but only a yellow swatch, and 0.4 is one star and orange.
        #expect(FreeWriteFeedback(score: 0.65).starsEarned == 2)
        #expect(FreeWriteFeedback(score: 0.65).tintBand == .yellow)
        #expect(FreeWriteFeedback(score: 0.4).starsEarned == 1)
        #expect(FreeWriteFeedback(score: 0.4).tintBand == .orange)
    }

    @Test("the glyph row is three slots wide, and no score can exceed it")
    func neverExceedsGlyphSlots() {
        for step in 0...100 {
            let score = CGFloat(step) / 100
            let stars = FreeWriteFeedback(score: score).starsEarned
            #expect(stars >= 0 && stars <= FreeWriteFeedback.glyphSlots,
                    "score \(score) produced \(stars) stars, outside 0...\(FreeWriteFeedback.glyphSlots)")
        }
    }
}

// MARK: - 2. The star total

@MainActor
@Suite struct StarTotalTests {

    private func progress(_ scores: [String: Double]?) -> LetterProgress {
        LetterProgress(phaseScores: scores)
    }

    @Test("no letters at all is zero, not a crash")
    func emptyIsZero() {
        #expect(LetterStars.total(for: [:]) == 0)
    }

    @Test("a single perfect letter contributes three, not four")
    func perfectSessionLetterContributesThree() {
        // The session runs three phases since the 2026-09-18 cut, so a
        // perfect letter is three stars. `LetterStars.maxStars` (4) is the
        // cross-surface cap over every phase key that has ever existed and
        // is NOT what this total adds up.
        let row = ["observe": 1.0, "guided": 1.0, "freeWrite": 1.0]
        #expect(LetterStars.total(for: ["A": progress(row)]) == 3,
                "a perfect three-phase letter is three stars")
    }

    @Test("a zero-scored session earns its one free phase and no more")
    func zeroSessionEarnsOne() {
        let row = ["observe": 0.0, "guided": 0.0, "freeWrite": 0.0]
        #expect(LetterStars.total(for: ["A": progress(row)]) == 1,
                "observe is a pass/fail completion marker at a 0 threshold; guided and freeWrite are not")
    }

    @Test("the total sums across letters, and a letter with no row adds nothing")
    func sumsAcrossLetters() {
        let perfect = ["observe": 1.0, "guided": 1.0, "freeWrite": 1.0]
        let zero = ["observe": 0.0, "guided": 0.0, "freeWrite": 0.0]
        let total = LetterStars.total(for: [
            "A": progress(perfect),
            "F": progress(perfect),      // 3
            "I": progress(zero),         // 1
            "L": progress(nil),          // 0 — legacy row, no phase scores
            "M": progress([:]),          // 0 — empty row
        ])
        #expect(total == 7, "3 + 3 + 1 + 0 + 0 = 7, got \(total)")
    }

    @Test("the total is exactly the sum of the per-letter stars it delegates to")
    func totalIsTheSumOfItsParts() {
        let rows: [String: [String: Double]] = [
            "A": ["observe": 1.0, "guided": 0.9, "freeWrite": 0.5],
            "F": ["observe": 1.0, "guided": 0.5, "freeWrite": 0.4],
            "I": ["observe": 1.0],
        ]
        let byHand = rows.values.reduce(0) { $0 + LetterStars.stars(for: $1) }
        let viaTotal = LetterStars.total(for: rows.mapValues { progress($0) })
        #expect(viaTotal == byHand,
                "LetterStars.total must be the sum of LetterStars.stars — the property both view badges now share by construction")
        // A: observe 1.0>=0.0, guided 0.9>=0.5, freeWrite 0.5>=0.4  -> 3
        // F: observe 1.0>=0.0, guided 0.5>=0.5, freeWrite 0.4>=0.4  -> 3
        // I: observe 1.0>=0.0                                        -> 1
        #expect(viaTotal == 7, "3 + 3 + 1 = 7, got \(viaTotal)")
    }
}
