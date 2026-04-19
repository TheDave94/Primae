// ThesisCondition.swift
// BuchstabenNative
//
// A/B test infrastructure for thesis evaluation.
// Controls which pedagogical features are active so learning outcomes
// can be compared across conditions.

import Foundation

/// Pedagogical condition for thesis A/B evaluation.
///
/// The default for non-enrolled installs is `.threePhase` (full pedagogical
/// flow). `.assign(participantId:)` is only invoked for installs that have
/// opted into the research study via `ParticipantStore.isEnrolled`. The case
/// name predates the `direct` phase added in v3-004 — rawValues are preserved
/// for backward-compatible decode of historical dashboard JSON.
enum ThesisCondition: String, Codable, CaseIterable, Sendable {
    /// Full four-phase pedagogical flow: observe → direct → guided → freeWrite.
    /// Case is still named `threePhase` to keep the Codable rawValue stable for
    /// existing `PhaseSessionRecord` / `SessionDurationRecord` entries.
    case threePhase

    /// Guided tracing only — skips observe, direct, and freeWrite phases.
    case guidedOnly

    /// Guided tracing with fixed difficulty — no adaptive checkpoint radius.
    case control

    /// German display label for the parent dashboard and thesis reports.
    var displayName: String {
        switch self {
        case .threePhase: return "Vier Phasen"
        case .guidedOnly: return "Nur Nachspuren"
        case .control:    return "Kontrollgruppe"
        }
    }

    /// The default condition for this install.
    ///
    /// Non-enrolled installs (`ParticipantStore.isEnrolled == false`, the
    /// default) always get `.threePhase` so every child gets the full
    /// four-phase flow. Enrolled installs get the stable UUID-derived arm
    /// from `assign(participantId:)`. Exposed as a standalone computed
    /// property so it's testable without instantiating the full
    /// `TracingDependencies` graph (AudioEngine, JSONProgressStore, etc.).
    static var defaultForInstall: ThesisCondition {
        ParticipantStore.isEnrolled
            ? .assign(participantId: ParticipantStore.participantId)
            : .threePhase
    }

    /// Deterministically assign a participant to a condition based on a stable UUID.
    /// Same UUID always returns the same condition, so assignment persists across
    /// launches and cannot drift mid-study.
    ///
    /// Invoked only when `ParticipantStore.isEnrolled == true`. Non-enrolled
    /// installs use `.threePhase` unconditionally so Anschauen and Richtung
    /// lernen are never silently skipped for casual users.
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
    private static let enrolledKey = "de.flamingistan.buchstaben.thesisEnrolled"

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

    /// Whether this install participates in the thesis A/B study.
    ///
    /// When `false` (the default for any install that hasn't explicitly opted
    /// in via the Forschung settings toggle), `TracingDependencies.live`
    /// pins `thesisCondition` to `.threePhase` so every child gets the full
    /// four-phase flow. When `true`, the stable UUID-derived condition from
    /// `ThesisCondition.assign(participantId:)` takes over.
    static var isEnrolled: Bool {
        get { UserDefaults.standard.bool(forKey: enrolledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enrolledKey) }
    }
}
