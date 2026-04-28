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
///
/// Storage layering (review item W-22):
///   1. **iCloud Key-Value** (`NSUbiquitousKeyValueStore`) — primary,
///      survives app reinstall on the same iCloud account so a parent
///      who deletes + reinstalls mid-study doesn't accidentally reroll
///      the child's A/B condition assignment.
///   2. **UserDefaults** — local fallback for offline / no-iCloud
///      installs, and for the test target which doesn't have iCloud
///      entitlements.
///
/// On first access we read both sources, prefer whichever has a valid
/// UUID, and reconcile by writing the chosen value back to whichever
/// source was empty. Subsequent writes hit both stores so a future
/// device-replacement read finds the same UUID.
enum ParticipantStore {
    private static let key = "de.flamingistan.buchstaben.participantId"
    private static let enrolledKey = "de.flamingistan.buchstaben.thesisEnrolled"

    /// The participant's UUID, generated on first call and persisted thereafter.
    /// Reads from iCloud-KVS first, then UserDefaults, so a reinstall on the
    /// same iCloud account preserves the original cohort assignment.
    static var participantId: UUID {
        let icloud = NSUbiquitousKeyValueStore.default
        // Pre-existing values take precedence over any new generation.
        if let raw = icloud.string(forKey: key),
           let uuid = UUID(uuidString: raw) {
            // Backfill local UserDefaults if missing so offline reads
            // still hit a value when iCloud isn't reachable.
            if UserDefaults.standard.string(forKey: key) != raw {
                UserDefaults.standard.set(raw, forKey: key)
            }
            return uuid
        }
        if let raw = UserDefaults.standard.string(forKey: key),
           let uuid = UUID(uuidString: raw) {
            // Promote local-only UUID to iCloud so a future reinstall
            // sees the same cohort assignment.
            icloud.set(raw, forKey: key)
            icloud.synchronize()
            return uuid
        }
        // First-ever launch on this install + iCloud account combination.
        let new = UUID()
        let raw = new.uuidString
        UserDefaults.standard.set(raw, forKey: key)
        icloud.set(raw, forKey: key)
        icloud.synchronize()
        return new
    }

    /// Whether this install participates in the thesis A/B study.
    ///
    /// When `false` (the default for any install that hasn't explicitly opted
    /// in via the Forschung settings toggle), `TracingDependencies.live`
    /// pins `thesisCondition` to `.threePhase` so every child gets the full
    /// four-phase flow. When `true`, the stable UUID-derived condition from
    /// `ThesisCondition.assign(participantId:)` takes over.
    ///
    /// Mirrored to iCloud-KVS so an enrolled child who reinstalls keeps
    /// the same condition (review item W-22).
    static var isEnrolled: Bool {
        get {
            // Prefer iCloud if it has a value; otherwise fall back to local.
            let icloud = NSUbiquitousKeyValueStore.default
            if icloud.object(forKey: enrolledKey) != nil {
                return icloud.bool(forKey: enrolledKey)
            }
            return UserDefaults.standard.bool(forKey: enrolledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enrolledKey)
            let icloud = NSUbiquitousKeyValueStore.default
            icloud.set(newValue, forKey: enrolledKey)
            icloud.synchronize()
        }
    }
}
