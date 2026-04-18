// ThesisCondition.swift
// BuchstabenNative
//
// A/B test infrastructure for thesis evaluation.
// Controls which pedagogical features are active so learning outcomes
// can be compared across conditions.

import Foundation

/// Pedagogical condition for thesis A/B evaluation.
enum ThesisCondition: String, Codable, CaseIterable, Sendable {
    /// Full three-phase model: observe → guided → freeWrite.
    case threePhase

    /// Guided tracing only — skips observe and freeWrite phases.
    case guidedOnly

    /// Guided tracing with fixed difficulty — no adaptive checkpoint radius.
    case control

    /// German display label for the parent dashboard and thesis reports.
    var displayName: String {
        switch self {
        case .threePhase: return "Drei Phasen"
        case .guidedOnly: return "Nur Nachspuren"
        case .control:    return "Kontrollgruppe"
        }
    }

    /// Deterministically assign a participant to a condition based on a stable UUID.
    /// Same UUID always returns the same condition, so assignment persists across
    /// launches and cannot drift mid-study.
    static func assign(participantId: UUID) -> ThesisCondition {
        // Use the first UUID byte, which is uniformly distributed for v4 UUIDs.
        let byte = participantId.uuid.0
        switch Int(byte) % ThesisCondition.allCases.count {
        case 0:  return .threePhase
        case 1:  return .guidedOnly
        default: return .control
        }
    }
}

/// Persists a per-install participant UUID for stable A/B cohort assignment.
enum ParticipantStore {
    private static let key = "de.flamingistan.buchstaben.participantId"

    /// The participant's UUID, generated on first call and persisted thereafter.
    static var participantId: UUID {
        if let raw = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: raw) {
            return uuid
        }
        let new = UUID()
        UserDefaults.standard.set(new.uuidString, forKey: key)
        return new
    }
}
