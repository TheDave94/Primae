// LearningPhase.swift
// BuchstabenNative
//
// Three-step pedagogical model based on the Gradual Release of
// Responsibility framework (Fisher & Frey, 2013; LetterSchool's
// "tap → trace → write" pattern).
//
// Phase progression:
//   observe  →  guided  →  freeWrite
//   "I do"      "We do"     "You do"

import Foundation

/// Represents one of the three phases in the letter-learning sequence.
///
/// Each letter is practised through all three phases in order before
/// the session is considered complete. The phase determines what
/// scaffolding the canvas provides and how the child's input is scored.
enum LearningPhase: Int, Codable, CaseIterable, Comparable, Equatable, Sendable {
    /// Watch the animated letter formation. Touch is disabled.
    /// The child sees numbered stroke-start dots and the animation guide
    /// tracing the correct path. Tap replays the animation.
    case observe   = 0

    /// Trace the letter with checkpoint rails (current production behaviour).
    /// Checkpoints are visible, haptic feedback fires on hit, audio plays
    /// when near a stroke. Scored by checkpoint progress (0–1).
    case guided    = 1

    /// Write the letter from memory without visual checkpoints.
    /// Touch is tracked as a freehand polyline. Scoring uses discrete
    /// Fréchet distance against the reference stroke definition.
    case freeWrite = 2

    static func < (lhs: LearningPhase, rhs: LearningPhase) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The next phase in the sequence, or `nil` if this is the final phase.
    var next: LearningPhase? {
        LearningPhase(rawValue: rawValue + 1)
    }

    /// German display label for UI.
    var displayName: String {
        switch self {
        case .observe:   return "Anschauen"
        case .guided:    return "Nachspuren"
        case .freeWrite: return "Selbst schreiben"
        }
    }

    /// Short icon for compact UI.
    var icon: String {
        switch self {
        case .observe:   return "👁️"
        case .guided:    return "✏️"
        case .freeWrite: return "🖊️"
        }
    }
}

// MARK: - Thesis evaluation condition

/// Allows comparing learning outcomes across different pedagogical modes.
/// The thesis can evaluate three-phase vs. guided-only vs. no-adaptation.
enum ThesisCondition: String, Codable, CaseIterable, Sendable {
    /// Full three-phase model: observe → guided → freeWrite.
    case threePhase

    /// Guided tracing only (current behaviour, no observe/freeWrite phases).
    case guidedOnly

    /// Control: guided tracing with fixed difficulty (no adaptive policy).
    case control
}
