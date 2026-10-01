// FreeWriteFeedback.swift
// PrimaeNative
//
// The child-facing verdict shown after a freeWrite attempt: how many stars,
// which praise line, which symbol cue, and which colour band.
//
// WHY THIS TYPE EXISTS. It used to be four inline expressions inside
// `SchuleWorldView.feedbackCard(title:score:subtitle:)` — the score→stars
// ladder, the praise switch, the symbol ternary and the tint ternary — in a
// function returning `some View`. A view's body is not reachable from a unit
// test (and `GraphicsContext` cannot even be constructed), so the mapping
// that decides what a five-year-old is shown had no coverage at all (audit
// 2026-09-20). The DECISIONS are plain Swift and live here; the view now
// only renders this value. Same structural answer as
// `TracingViewModel.CanvasDrawPlan`: compute what to draw in plain Swift,
// hand the closure a value.
//
// WHAT THIS STILL DOES NOT COVER, named rather than faked: the rendered
// result — `feedbackCard`'s layout, the `Color`s the bands resolve to, and
// the star glyphs — remains untestable by construction. What is pinned here
// is every threshold and every string, which is where a child-visible
// mistake would actually come from.

import CoreGraphics

/// The verdict shown to the child after a freeWrite attempt.
struct FreeWriteFeedback: Equatable {

    /// The number of stars `feedbackCard` renders glyphs for. Not
    /// `LetterStars.maxStars`: this is a three-glyph row keyed on the
    /// attempt's own score, not the per-letter persisted total.
    static let glyphSlots = 3

    /// Which colour family the mood swatch uses. A plain band rather than a
    /// `Color` so the value is comparable in a test and independent of the
    /// trait collection.
    enum TintBand: Equatable {
        case green, yellow, orange
    }

    let starsEarned: Int
    let praise: String
    let symbolName: String
    let tintBand: TintBand

    /// Thresholds in descending order: 0.85 / 0.6 / 0.35 for stars, and
    /// 0.7 / 0.5 for the swatch. Both ladders are asserted at their exact
    /// boundaries in `FreeWriteFeedbackTests`.
    init(score: CGFloat) {
        let stars: Int
        if score >= 0.85 {
            stars = 3
        } else if score >= 0.6 {
            stars = 2
        } else if score >= 0.35 {
            stars = 1
        } else {
            stars = 0
        }
        self.starsEarned = stars

        switch stars {
        case 3: praise = "Super gemacht!"
        case 2: praise = "Gut gemacht!"
        case 1: praise = "Schon ganz gut."
        default: praise = "Probier es nochmal."
        }

        // Two or more stars is the "thumbs up" tier; below that the card
        // shows sparkles rather than a judgement.
        symbolName = stars >= 2 ? "hand.thumbsup.fill" : "sparkles"

        tintBand = score >= 0.7 ? .green : (score >= 0.5 ? .yellow : .orange)
    }
}
