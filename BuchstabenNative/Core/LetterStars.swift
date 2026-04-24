// LetterStars.swift
// BuchstabenNative
//
// Shared quality-gated star calculator. Every UI surface that renders
// star counts (WorldSwitcherRail badge, FortschritteWorldView gallery,
// CompletionCelebrationOverlay, LetterWheelPicker chips) goes through
// this helper so the definitions of "one star earned" can never drift
// between views.

import CoreGraphics
import Foundation

enum LetterStars {

    /// Stars earned for a letter given its persisted per-phase scores
    /// (keyed by LearningPhase.rawName — the format ProgressStore uses).
    /// A score of nil means the phase was never attempted → 0 stars for
    /// that phase. A present score earns a star only when it meets
    /// `LearningPhaseController.starThreshold(for:)`.
    static func stars(for phaseScores: [String: Double]?) -> Int {
        guard let phaseScores else { return 0 }
        var count = 0
        for phase in LearningPhase.allCases {
            guard let score = phaseScores[phase.rawName] else { continue }
            if CGFloat(score) >= LearningPhaseController.starThreshold(for: phase) {
                count += 1
            }
        }
        return count
    }

    /// Maximum stars any single letter can earn. Pulled from
    /// `LearningPhase.allCases.count` so changes to the phase model
    /// (e.g. removing `direct` for a thesis condition) auto-propagate.
    static let maxStars: Int = LearningPhase.allCases.count
}
