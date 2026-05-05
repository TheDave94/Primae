// LearningPhase.swift
// PrimaeNative
//
// Four-step Gradual Release of Responsibility flow (Fisher & Frey 2013):
// observe → direct → guided → freeWrite ("I do" / "Start" / "We do" / "You do").

import Foundation

/// Represents one of the four phases in the letter-learning sequence.
/// The phase determines canvas scaffolding and how input is scored.
enum LearningPhase: Int, Codable, CaseIterable, Comparable, Equatable, Sendable {
    /// Watch the animated letter formation. Touch disabled; tap replays.
    case observe   = 0

    /// Tap the numbered stroke-start dots in order to learn directionality.
    /// Pass/fail scoring (1.0 on completion). Thibon, Gerber & Kandel 2018.
    case direct    = 1

    /// Trace the letter with checkpoint rails. Scored by checkpoint
    /// progress (0–1).
    case guided    = 2

    /// Write the letter from memory without visual checkpoints. Scored
    /// by discrete Fréchet distance against the reference.
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

    /// Stable string key for serialization (Codable dictionary keys).
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
