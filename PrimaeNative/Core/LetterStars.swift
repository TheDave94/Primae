// LetterStars.swift
// PrimaeNative
//
// Shared quality-gated star calculator. Every UI surface rendering
// star counts goes through here so "one star earned" stays consistent.

import CoreGraphics
import Foundation

enum LetterStars {

    /// Stars earned given persisted per-phase scores keyed by
    /// `LearningPhase.rawName`. A phase earns its star only when its
    /// score meets `LearningPhaseController.starThreshold(for:)`.
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

    /// Maximum stars any single letter can earn.
    ///
    /// **It used to say this was "pulled from `LearningPhase.allCases.count`
    /// so phase-model changes propagate", and that claim stopped being true
    /// on 2026-09-18.** `allCases` is FOUR while no session runs more than
    /// THREE phases (`direct` left the flow — see `LearningPhase`'s header),
    /// so this is a cap over every phase that has ever existed, not over the
    /// ones a session runs. It does not change any star a child can earn —
    /// `stars(for:)` counts scored rows, and there are now three — but it IS
    /// the wrong denominator for anything that treats it as "the total".
    ///
    /// A static cannot be right here without knowing the condition: the
    /// session's own total is `LearningPhaseController.maxStars`
    /// (`activePhases.count`), which is what the Schule surface uses. This
    /// one is retained for the Fortschritte surface, which is compiled out
    /// of the study build. See HANDOFF: the "mastered" tint keyed on it is
    /// unreachable, which was already true under the study condition and is
    /// now true for the casual one too.
    static let maxStars: Int = LearningPhase.allCases.count
}
