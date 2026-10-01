// TrainedLetterSubset.swift
// PrimaeNative
//
// Third assignment axis for the pilot: which 3 of the 5 study letters
// (A F I L M) a participant TRAINS. The post-test (H6) covers all 5
// regardless — the untrained 2 are the within-child baseline, so the
// subset filters only the practice pool (`visibleLetterNames` under
// `studyMode`), never the post-test.
//
// Mirrors the `ThesisCondition` / `PilotAudioCondition` machinery:
// deterministic UUID-byte assignment (its own decorrelated byte),
// researcher override in `ParticipantStore`, captured as `let` at VM
// init, stamped on every `PhaseSessionRecord`, exported per row.
//
// TWO SETS, ONE TYPE, AND WHY THEY DIVERGED (2026-09-17). This type
// used to carry exactly one meaning: "the 3 letters this participant
// trains". The `allFiveLetters` comparison switch
// (`StudyComparisonSettings`) broke that identity — under it the
// session practises all five while the ASSIGNMENT is still a 3-subset,
// and the row stamped the assignment as though it were the training
// record. Every exported row then asserted the child was untrained on
// two letters the child had in fact practised, and the post-test
// offered those same two letters as the "untrained" probe: the
// contrast the study rests on was fabricated by its own bookkeeping.
// The fix is the `allFive` case below, so the type can say "all five
// trained, no untrained complement" instead of asserting a 3-subset
// that is no longer what happened. `allFive` is deliberately NOT one
// of the ten assignment buckets — see `allSubsets`.

import Foundation

/// Either one of the C(5,3) = 10 possible trained 3-subsets of the
/// study set, or the all-five case that the `allFiveLetters` comparison
/// switch produces. `rawValue` is the canonical sorted concatenation —
/// "AFI" (3, one of the ten assignment buckets) or "AFILM" (5, the
/// comparison configuration, never assigned) — and the CSV export keys
/// on it, so it must stay stable.
struct TrainedLetterSubset: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    /// The 5-letter pilot stimulus set, sorted. THE single owner of
    /// this list: `TracingViewModel.studyBaseLetters` and
    /// `LetterPickerBar.demoLetters` both read it from here, and
    /// `allSubsets` below derives the ten assignment buckets from it.
    static let studyLetters = ["A", "F", "I", "L", "M"]

    /// All 10 subsets in deterministic lexicographic order — index i of
    /// this array is what the UUID-modulo assignment selects, so the
    /// order is load-bearing for reproducibility. Do not reorder.
    ///
    /// EXACTLY TEN, ALWAYS. `assign` indexes this array by
    /// `byte % count`, so an eleventh entry would not merely add a
    /// bucket — it would change which subset EVERY participant is
    /// assigned. The all-five comparison case is therefore a separate
    /// static (`allFive`), never an element here.
    static let allSubsets: [TrainedLetterSubset] = {
        var result: [TrainedLetterSubset] = []
        let l = studyLetters
        for i in 0..<l.count {
            for j in (i + 1)..<l.count {
                for k in (j + 1)..<l.count {
                    result.append(TrainedLetterSubset(validated: l[i] + l[j] + l[k]))
                }
            }
        }
        return result
    }()

    /// "AFILM" — every study letter trained. The `allFiveLetters`
    /// comparison configuration's trained set, and the value stamped on
    /// every row of a session run under that switch.
    ///
    /// Its purpose is to be DISTINGUISHABLE in the export from a real
    /// 3-subset run. It is: every assigned value is exactly 3 characters
    /// drawn from the ten above, this one is 5 and is in no assignment
    /// bucket, and `untrainedLetters` on it is EMPTY — so an analysis
    /// that partitions trained from untrained reads "no untrained
    /// letter" rather than a fabricated pair. A run under the switch is
    /// a comparison run, not pilot data, and the row now says so in the
    /// same column the pilot rows use.
    static let allFive = TrainedLetterSubset(validated: studyLetters.joined())

    /// Internal non-validating init for the canonical enumeration.
    private init(validated: String) { self.rawValue = validated }

    /// Failable public init — accepts one of the 10 canonical 3-subsets
    /// or the all-five case. A stored override or record carrying
    /// anything else decodes to nil and falls back to derivation, same
    /// shape as the arm enums.
    ///
    /// `allFive` is accepted so an exported "AFILM" round-trips through
    /// this type rather than decoding to nil — the exporter's
    /// derived-post-test pass (`ParentDashboardExporter
    /// .derivedTrainedPostTestIndices`) re-reads the column through this
    /// initialiser, and a nil there would silently drop the post-test
    /// tag from every letter of an all-five run. A researcher override
    /// of "AFILM" is likewise meaningful rather than inert.
    init?(rawValue: String) {
        guard Self.allSubsets.contains(where: { $0.rawValue == rawValue })
                || rawValue == Self.allFive.rawValue else { return nil }
        self.rawValue = rawValue
    }

    /// The trained letters as base-letter keys (uppercase), for
    /// filtering against `LetterAsset.baseLetter`.
    var letters: Set<String> { Set(rawValue.map(String.init)) }

    /// The study letters this participant does NOT train — the
    /// within-child post-test baseline.
    ///
    /// EMPTY under `allFive`: there is no untrained letter to be the
    /// baseline, and this property says so rather than inventing the two
    /// the assignment axis happens to name. This is the single point the
    /// post-test gate and the researcher UI both read, so neither can
    /// offer an "untrained" letter that was trained.
    var untrainedLetters: Set<String> { Set(Self.studyLetters).subtracting(letters) }

    /// Whether this is the all-five comparison case rather than one of
    /// the ten assignment buckets. Callers that must refuse a
    /// within-child contrast (the post-test gate, the researcher UI)
    /// branch on `untrainedLetters.isEmpty` instead — the state, not the
    /// label — but this is what makes the case legible in the record.
    var isAllFive: Bool { self == .allFive }

    /// Proctor-facing label, e.g. "A · F · I", or all five.
    var displayName: String { rawValue.map(String.init).joined(separator: " · ") }

    /// Deterministically assign a participant to a trained subset from
    /// the stable UUID. Keys on byte 9 — decorrelated from byte 0
    /// (`ThesisCondition`) and byte 15 (`PilotAudioCondition`) so the
    /// three axes stay independent.
    ///
    /// NOT byte 8 (2026-09-04): `ParticipantStore.participantId` is a
    /// Foundation `UUID()`, i.e. RFC 4122 version 4, whose byte 6 carries
    /// the version nibble and whose byte 8 carries the two VARIANT bits
    /// (`10xxxxxx`) — byte 8 only ever takes the 64 values 128…191, so
    /// `byte % 10` gave subsets 0, 1, 8, 9 seven of those 64 values and
    /// the other six subsets six each (~10.9 % vs ~9.4 %; measured over
    /// 200 000 v4 UUIDs). The earlier claim of a "~4‰ residual bias from
    /// 256 % 10" assumed a uniform byte. Byte 9 is fully random; the
    /// residual is the genuine 256 % 10 (subsets 0–5 get 26/256, 6–9 get
    /// 25/256). The researcher override exists for exact small-cohort
    /// counterbalancing regardless.
    static func assign(participantId: UUID) -> TrainedLetterSubset {
        let byte = participantId.uuid.9
        return allSubsets[Int(byte) % allSubsets.count]
    }

    /// The trained subset for this install. Researcher override wins;
    /// enrolled installs derive from the participant UUID; non-enrolled
    /// installs get the first canonical subset ("AFI") — inert, since
    /// the subset only takes effect under `studyMode`.
    static var defaultForInstall: TrainedLetterSubset {
        if let manual = ParticipantStore.trainedSubsetOverride {
            return manual
        }
        return ParticipantStore.isEnrolled
            ? .assign(participantId: ParticipantStore.participantId)
            : allSubsets[0]
    }
}
