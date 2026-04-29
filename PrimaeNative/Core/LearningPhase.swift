// LearningPhase.swift
// PrimaeNative
//
// Four-step pedagogical model based on the Gradual Release of
// Responsibility framework (Fisher & Frey, 2013; LetterSchool's
// "tap → trace → write" pattern extended with directionality teaching).
//
// Phase progression:
//   observe  →  direct  →  guided  →  freeWrite
//   "I do"      "Start"    "We do"     "You do"

import Foundation

/// Represents one of the four phases in the letter-learning sequence.
///
/// Each letter is practised through all four phases in order before
/// the session is considered complete. The phase determines what
/// scaffolding the canvas provides and how the child's input is scored.
enum LearningPhase: Int, Codable, CaseIterable, Comparable, Equatable, Sendable {
    /// Watch the animated letter formation. Touch is disabled.
    /// The child sees numbered stroke-start dots and the animation guide
    /// tracing the correct path. Tap replays the animation.
    case observe   = 0

    /// Tap the numbered stroke-start dots in order to learn directionality.
    /// Research (Thibon, Gerber & Kandel, 2018) shows children under 8
    /// store motor programs for individual segments; explicitly teaching
    /// start positions aids segment-by-segment motor program formation.
    /// Scored pass/fail (1.0 on completion).
    case direct    = 1

    /// Trace the letter with checkpoint rails.
    /// Checkpoints are visible, haptic feedback fires on hit, audio plays
    /// when near a stroke. Scored by checkpoint progress (0–1).
    case guided    = 2

    /// Write the letter from memory without visual checkpoints.
    /// Touch is tracked as a freehand polyline. Scoring uses discrete
    /// Fréchet distance against the reference stroke definition.
    case freeWrite = 3

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
        case .direct:    return "Richtung lernen"
        case .guided:    return "Nachspuren"
        case .freeWrite: return "Selbst schreiben"
        }
    }

    /// Stable string key for serialization (matches Codable dictionary keys in ProgressStore).
    var rawName: String {
        switch self {
        case .observe:   return "observe"
        case .direct:    return "direct"
        case .guided:    return "guided"
        case .freeWrite: return "freeWrite"
        }
    }

    /// Short icon for compact UI.
    var icon: String {
        switch self {
        case .observe:   return "👁️"
        case .direct:    return "☝️"
        case .guided:    return "✏️"
        case .freeWrite: return "🖊️"
        }
    }
}
