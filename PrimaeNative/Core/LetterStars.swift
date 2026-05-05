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

    /// Maximum stars any single letter can earn. Pulled from
    /// `LearningPhase.allCases.count` so phase-model changes propagate.
    static let maxStars: Int = LearningPhase.allCases.count
}
