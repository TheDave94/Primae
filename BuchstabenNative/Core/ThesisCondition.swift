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
        // T6 (ROADMAP_V5): manual researcher override for small cohorts
        // wins over the byte-modulo derivation. Lets a thesis with n < 30
        // achieve exact between-arms balance (e.g. 8/8/8) rather than
        // accepting the ~uniform-in-expectation imbalance produced by
        // byte%3. The override is settable from SettingsView's research
        // section and persists in UserDefaults + iCloud-KVS.
        if let manual = ParticipantStore.conditionOverride {
            return manual
        }
        return ParticipantStore.isEnrolled
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
    /// D-7: timestamp captured when `isEnrolled` flips from `false` to
    /// `true`. The CSV exporter filters phase-session rows older than
    /// this date so pilot / sandbox / pre-enrollment activity doesn't
    /// pollute the `.threePhase` arm at analysis time.
    private static let enrolledAtKey = "de.flamingistan.buchstaben.thesisEnrolledAt"
    private static let conditionOverrideKey = "de.flamingistan.buchstaben.thesisConditionOverride"

    /// Researcher-set thesis arm. When non-nil, `defaultForInstall`
    /// returns this value verbatim, ignoring the byte-modulo assignment.
    /// Used for stratified-block balancing in small-n thesis cohorts
    /// (T6 ROADMAP_V5). Mirrored to iCloud-KVS so a reinstall preserves
    /// the explicit assignment alongside the participant UUID.
    static var conditionOverride: ThesisCondition? {
        get {
            let icloud = NSUbiquitousKeyValueStore.default
            if let raw = icloud.string(forKey: conditionOverrideKey),
               let arm = ThesisCondition(rawValue: raw) {
                return arm
            }
            if let raw = UserDefaults.standard.string(forKey: conditionOverrideKey),
               let arm = ThesisCondition(rawValue: raw) {
                return arm
            }
            return nil
        }
        set {
            let icloud = NSUbiquitousKeyValueStore.default
            if let value = newValue {
                UserDefaults.standard.set(value.rawValue, forKey: conditionOverrideKey)
                icloud.set(value.rawValue, forKey: conditionOverrideKey)
            } else {
                UserDefaults.standard.removeObject(forKey: conditionOverrideKey)
                icloud.removeObject(forKey: conditionOverrideKey)
            }
            icloud.synchronize()
        }
    }

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
            let wasEnrolled = isEnrolled
            UserDefaults.standard.set(newValue, forKey: enrolledKey)
            let icloud = NSUbiquitousKeyValueStore.default
            icloud.set(newValue, forKey: enrolledKey)
            // D-7: stamp the enrolment timestamp the first time enrolment
            // flips on. Don't overwrite once it's set — a parent who
            // toggles the switch off and on again would otherwise lose
            // the original cohort start date and a portion of legitimate
            // study data would be incorrectly filtered as pre-enrollment.
            if newValue, !wasEnrolled, enrolledAt == nil {
                let now = Date()
                UserDefaults.standard.set(now, forKey: enrolledAtKey)
                icloud.set(now.timeIntervalSince1970, forKey: enrolledAtKey)
            }
            icloud.synchronize()
        }
    }

    /// Wall-clock time the install joined the thesis study. `nil` for
    /// installs that have never enrolled — those should never have any
    /// thesis-arm data because `defaultForInstall` returns `.threePhase`
    /// for `isEnrolled == false`. The CSV exporter discards phase-session
    /// rows older than this date (review item D-7).
    static var enrolledAt: Date? {
        let icloud = NSUbiquitousKeyValueStore.default
        let icloudTs = icloud.double(forKey: enrolledAtKey)
        if icloudTs > 0 {
            return Date(timeIntervalSince1970: icloudTs)
        }
        return UserDefaults.standard.object(forKey: enrolledAtKey) as? Date
    }
}
