import Foundation

// MARK: - Export format

enum DashboardExportFormat {
    case csv
    /// Tab-separated variant of `csv`. SPSS / R import TSV without the
    /// escape-quoting confusion CSVs hit on comma-bearing fields.
    case tsv
    case json
}

// MARK: - Typed export errors

enum ExportError: Error, Equatable {
    case encodingFailed(String)
    case writeFailed(String)
}

// MARK: - Multi-participant export source

/// One participant's complete export inputs — the live participant's, or
/// a sealed `ArchivedParticipant`'s, presented identically so the
/// combined-export functions below don't need to know which (2026-09-14).
struct ParticipantExportSource {
    let snapshot: DashboardSnapshot
    let participantId: UUID
    let progress: [String: LetterProgress]
    let rawTraces: [RawTrace]
    let enrolledAt: Date?
}

// MARK: - Exporter

/// Converts a ``DashboardSnapshot`` to shareable file data.
/// No UIKit/SwiftUI dependency — kept in Core so it's testable on Linux CI.
struct ParentDashboardExporter {

    // MARK: CSV / TSV

    /// Produces a UTF-8 CSV with a `# participantId=...` header, one
    /// row per letter, per-session durations, per-phase records, and
    /// aggregate thesis metrics. The participantId header lets A/B
    /// analysis align data across installs.
    static func csvData(from snapshot: DashboardSnapshot,
                         participantId: UUID = ParticipantStore.participantId,
                         progress: [String: LetterProgress] = [:],
                         enrolledAt: Date? = ParticipantStore.enrolledAt) -> Data {
        delimitedData(from: snapshot, participantId: participantId,
                       progress: progress, enrolledAt: enrolledAt, separator: ",")
    }

    /// Tab-separated variant of `csvData`. Same row layout.
    static func tsvData(from snapshot: DashboardSnapshot,
                         participantId: UUID = ParticipantStore.participantId,
                         progress: [String: LetterProgress] = [:],
                         enrolledAt: Date? = ParticipantStore.enrolledAt) -> Data {
        delimitedData(from: snapshot, participantId: participantId,
                       progress: progress, enrolledAt: enrolledAt, separator: "\t")
    }

    /// Shared row builder behind csvData / tsvData. Single
    /// implementation keeps both formats in lock-step on columns.
    /// RFC 4180 quoting for one field of a delimited row: a field that
    /// contains the separator, a double quote, or a line break is wrapped
    /// in double quotes with inner quotes doubled; every other field is
    /// emitted verbatim, so rows without such fields are byte-identical
    /// to before. Needed because `strokeOrder` is comma-joined
    /// (`StrokeProcessMeasures.matchedReferenceOrderField`, e.g. "0,2,1"
    /// for a crossbar-first A): unquoted, a multi-stroke letter's CSV row
    /// split into extra columns and shifted `reversedStrokeCount`,
    /// `studyMode` and `probe` right (audit 2026-09-04, class one).
    static func delimitedField(_ field: String, separator sep: String) -> String {
        guard field.contains(sep) || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func delimitedData(
        from snapshot: DashboardSnapshot,
        participantId: UUID,
        progress: [String: LetterProgress],
        enrolledAt: Date?,
        separator sep: String
    ) -> Data {
        var lines: [String] = []
        lines.append("# participantId=\(participantId.uuidString)")
        // Enrolment timestamp lets consumers reproduce the
        // pre-enrollment filtering rule and audit skipped records.
        if let enrolledAt {
            lines.append("# enrolledAt=\(ISO8601DateFormatter().string(from: enrolledAt))")
        }
        // Timezone label for cross-timezone / DST-aware interpretation.
        lines.append("# timezone=\(TimeZone.current.identifier)")
        let isoFormatter = ISO8601DateFormatter()
        lines.append("")

        // Letter-aggregate columns:
        //   speedTrend — semicolon-joined per-letter writing-speed
        //                series feeding the automatisation bonus.
        //   freeformCompletionCount — blank-canvas completions tracked
        //                separately from guided mastery.
        //   retrievalAccuracy — rolling mean of retrievalAttempts (cap 10).
        // `averageAccuracy` REMOVED 2026-09-16 (supervisor ruling): it
        // mixed arms (`accuracySamples` carries no condition tag) AND
        // mixed phases (fed by `overallScore`, which under the kept
        // four-phase flow has a mathematical floor of 0.5 — D12), while
        // being none of the outcomes Ch.6 defines. It could only mislead
        // an exploratory read of the export. See docs/APP_DOCUMENTATION.md
        // export-schema appendix for the removal note.
        lines.append(["letter","sessionCount","trend","recognitionSamples","recognitionAvg","speedTrend","freeformCompletionCount","retrievalAccuracy"].joined(separator: sep))
        let sorted = snapshot.letterStats.values.sorted { $0.letter < $1.letter }
        for stat in sorted {
            let tnd = String(format: "%.6f", stat.trend)
            let cnt = stat.accuracySamples.count
            let prog = progress[stat.letter]
            let acc = prog?.recognitionAccuracy ?? []
            let recCount = acc.count
            let recAvg = acc.isEmpty
                ? "" : String(format: "%.4f", acc.reduce(0, +) / Double(acc.count))
            let speedField = (prog?.speedTrend ?? [])
                .map { String(format: "%.4f", $0) }
                .joined(separator: ";")
            let freeformField = prog?.freeformCompletionCount.map { String($0) } ?? ""
            let retrievalField: String = {
                guard let attempts = prog?.retrievalAttempts, !attempts.isEmpty else { return "" }
                let acc = Double(attempts.filter { $0 }.count) / Double(attempts.count)
                return String(format: "%.4f", acc)
            }()
            lines.append([stat.letter, "\(cnt)", tnd, "\(recCount)", recAvg, speedField, freeformField, retrievalField].joined(separator: sep))
        }
        lines.append("")

        // Full ISO-8601 timestamp alongside day-level dateString lets
        // analysis recover time-of-day signal. wallClockSeconds covers
        // backgrounded intervals so engagement-vs-practice is
        // recoverable. Legacy rows emit empty strings for new columns.
        // `letter` (appended last for legacy column order) ties the
        // duration to the practised letter directly — the pilot's
        // per-letter time-to-complete no longer needs a `recordedAt`
        // join against the per-phase rows. Empty for legacy records.
        // Filtered on enrolment like the phase rows (review 2026-09-05: the
        // D11#1 filter never reached this block); stamped with the arm /
        // study flag / probe so a duration attributes without a join.
        let enrolledDurations: [SessionDurationRecord] = {
            guard let enrolledAt else { return snapshot.sessionDurations }
            return snapshot.sessionDurations.filter { rec in
                guard let ts = rec.recordedAt else { return false }
                return ts >= enrolledAt
            }
        }()
        lines.append(["date","recordedAt","durationSeconds","wallClockSeconds","condition","inputDevice","letter","audioCondition","studyMode","probe"].joined(separator: sep))
        for rec in enrolledDurations.sorted(by: { $0.dateString < $1.dateString }) {
            let recordedAtField = rec.recordedAt.map { isoFormatter.string(from: $0) } ?? ""
            let wallField = rec.wallClockSeconds.map { String(format: "%.3f", $0) } ?? ""
            lines.append([rec.dateString, recordedAtField,
                          String(format: "%.3f", rec.durationSeconds),
                          wallField, rec.condition.rawValue,
                          rec.inputDevice ?? "",
                          rec.letter ?? "",
                          rec.audioCondition?.rawValue ?? "",
                          rec.studyMode.map(String.init) ?? "",
                          rec.probe ?? ""].joined(separator: sep))
        }
        lines.append("")

        // Per-phase rows carry the four Schreibmotorik dimensions
        // (formAccuracy / tempoConsistency / pressureControl /
        // rhythmScore) — non-null only for freeWrite rows. Legacy
        // rows decode the new fields as nil and emit empty strings.
        // `inputDevice` ("finger" / "pencil") distinguishes a true
        // finger session from a low-variance pencil session.
        // `recognition_confidence_raw` is the pre-calibration softmax
        // probability, used to quantify the calibrator's effect.
        // `audioCondition` (pilot audio arm), `trainedSubset` (the
        // letters trained in that row's session — a 3-of-5 value like
        // "AFI" for a pilot run, or "AFILM" for an all-five comparison
        // run, in which case there is no untrained complement to
        // partition against; see `PhaseSessionRecord.trainedSubset`),
        // and `phaseDurationSeconds`
        // (freeWrite measured-phase time: first-to-last raw sample,
        // excluding the trailing 2.0 s quiet-window auto-advance) are
        // appended last, newest-last, so the legacy column order is
        // preserved for existing consumers.
        // `spatialDeviation` is the study's PRIMARY accuracy outcome
        // (2026-09-04: order-invariant via stroke correspondence, raw,
        // unclamped, lower = better — see StrokeProcessMeasures).
        // `frechetDistance` is RETIRED (2026-09-04): the column stays,
        // for CSV-schema stability, but every row now writes it empty —
        // see PhaseSessionRecord.frechetDistance for why (Fréchet itself
        // isn't gone, it moved to the WITHIN-PAIR computation behind
        // `spatialDeviation`; the sequence signal it used to approximate
        // is `strokeOrder`/`reversedStrokeCount` now, directly).
        // `checkpointCoverage` is a SECONDARY outcome (bounded 0–1,
        // saturates at ceiling). All three are freeWrite-only.
        // `spatialDeviation` rides at the very end, after
        // `checkpointCoverage`, for the same newest-last column-order
        // reason the others do — it is the newest field, not because it
        // is least important.
        // `strokeCount`/`strokeOrder`/`reversedStrokeCount` are the
        // process-measure secondaries, appended after spatialDeviation
        // for the same newest-last reason, in that order.
        // Column name, not just doc comment (2026-09-16): the RETIRED
        // field used to export under the bare name "frechetDistance" —
        // the name a cold reader searching for the thesis's primary
        // Fréchet-distance outcome would reach for first — while the
        // live primary outcome exports as "spatialDeviation", which
        // doesn't say "Fréchet" anywhere. That reader gets an always-
        // empty column and no signal they picked the wrong one. See
        // `retiredFrechetColumnName` for why this is fixed by renaming
        // the OUTPUT column only, not the Swift property or its Codable
        // key (`PhaseSessionRecord.frechetDistance` is untouched — this
        // is a header-string change here plus a JSON post-process below,
        // nothing that could affect decoding any file already on disk).
        // `comparisonConfiguration` appended LAST (2026-09-18): the
        // non-default researcher switches this row's session ran under,
        // or EMPTY for a pilot row. Without it a comparison run's rows
        // and a pilot run's rows were the same 27 columns, same order,
        // same names, and could not be told apart once merged across
        // sessions — eleven of the twelve switches left no trace at all
        // (the twelfth, `allFiveLetters`, only indirectly, through
        // `trainedSubset == "AFILM"`). Newest-last for the same reason
        // every other recent column is: existing parsers index the
        // legacy order. The value rides on the record and is never
        // recomputed here — see `PhaseSessionRecord
        // .comparisonConfiguration`.
        lines.append(["letter","phase","completed","score","schedulerPriority","condition","recordedAt","recognition_predicted","recognition_confidence","recognition_confidence_raw","recognition_correct","formAccuracy","tempoConsistency","pressureControl","rhythmScore","inputDevice","audioCondition","trainedSubset","phaseDurationSeconds",Self.retiredFrechetColumnName,"checkpointCoverage","spatialDeviation","strokeCount","strokeOrder","reversedStrokeCount","studyMode","probe","comparisonConfiguration"].joined(separator: sep))
        // D11#1: filtered ONCE, here, and every aggregate below —
        // including the arm-split ones — reads `enrolledRecords`, never
        // `snapshot.phaseSessionRecords` directly. The raw-row loop and
        // the arm aggregates used to apply this filter independently;
        // the aggregates' copy was missing, so a pre-enrolment row
        // (proctor test-taps, sandbox activity) was excluded from the
        // per-row export but still counted into the between-arm
        // comparison — the exact attribution this filter exists to
        // prevent.
        let enrolledRecords: [PhaseSessionRecord] = {
            let filtered: [PhaseSessionRecord] = {
                guard let enrolledAt else { return snapshot.phaseSessionRecords }
                // Also discard rows lacking `recordedAt` when an `enrolledAt`
                // exists — they default to `.threePhase` and would silently
                // inflate that arm.
                return snapshot.phaseSessionRecords.filter { rec in
                    guard let ts = rec.recordedAt else { return false }
                    return ts >= enrolledAt
                }
            }()
            // Tags the derived trained-letter post-test row (see
            // `withDerivedPostTestTags`) so `probe == "posttest"` finds
            // all five study letters' post-test rows in THIS export, not
            // just the two untrained ones the live app tags itself.
            return withDerivedPostTestTags(filtered)
        }()
        // D11#1, second half (2026-09-04): the four HEADLINE aggregates
        // further down (`phaseCompletionRate_*`, `averageFreeWriteScore`,
        // `schedulerEffectivenessProxy`, `averageForm/Tempo/Pressure/
        // Rhythm`) are computed properties of the snapshot and ran over
        // every record on disk — the filter above never reached them,
        // even after the ticket was marked closed. One filtered view,
        // built once, so they read exactly the rows the per-row block
        // and the arm aggregates read.
        let enrolledSnapshot = DashboardSnapshot(
            letterStats: snapshot.letterStats,   // aggregates: not filterable by time
            sessionDurations: enrolledDurations,
            phaseSessionRecords: enrolledRecords
        )
        for rec in enrolledRecords {
            let score = String(format: "%.4f", rec.score)
            let prio  = String(format: "%.4f", rec.schedulerPriority)
            let recordedAtField = rec.recordedAt.map { isoFormatter.string(from: $0) } ?? ""
            let recLabel = rec.recognitionPredicted ?? ""
            let recConf  = rec.recognitionConfidence.map { String(format: "%.4f", $0) } ?? ""
            let recConfRaw = rec.recognitionConfidenceRaw.map { String(format: "%.4f", $0) } ?? ""
            let recRight = rec.recognitionCorrect.map { String($0) } ?? ""
            let dimForm   = rec.formAccuracy.map     { String(format: "%.4f", $0) } ?? ""
            let dimTempo  = rec.tempoConsistency.map { String(format: "%.4f", $0) } ?? ""
            let dimPress  = rec.pressureControl.map  { String(format: "%.4f", $0) } ?? ""
            let dimRhythm = rec.rhythmScore.map      { String(format: "%.4f", $0) } ?? ""
            // Explicitly typed as [String] and split from `.joined` —
            // the combined array-literal-plus-chained-method-call
            // expression stopped type-checking in reasonable time once
            // this grew past ~19 heterogeneous-looking elements (all
            // are String, but the compiler re-derives that per element
            // across the whole chain unless the literal's target type
            // is pinned up front). Found by CI, 2026-09-03.
            let row: [String] = [
                rec.letter, rec.phase, "\(rec.completed)", score, prio,
                rec.condition.rawValue, recordedAtField,
                recLabel, recConf, recConfRaw, recRight,
                dimForm, dimTempo, dimPress, dimRhythm,
                rec.inputDevice ?? "",
                rec.audioCondition.rawValue,
                rec.trainedSubset ?? "",
                rec.phaseDurationSeconds.map { String(format: "%.3f", $0) } ?? "",
                // 6 dp: the distance lives in normalised 0–1 letter
                // space, where meaningful between-child differences show
                // up in the 3rd–4th decimal.
                rec.frechetDistance.map { String(format: "%.6f", $0) } ?? "",
                rec.checkpointCoverage.map { String(format: "%.4f", $0) } ?? "",
                // Same 6 dp precision as frechetDistance, same space.
                rec.spatialDeviation.map { String(format: "%.6f", $0) } ?? "",
                rec.strokeCount.map(String.init) ?? "",
                rec.strokeOrder ?? "",
                rec.reversedStrokeCount.map(String.init) ?? "",
                // Whether the study configuration was on for this row
                // (C3-2, 2026-09-04); empty for legacy rows.
                rec.studyMode.map(String.init) ?? "",
                // Cold-probe kind: pretest / posttest / delayed; empty for
                // a training pass (2026-09-04).
                rec.probe ?? "",
                // The session's comparison stamp, read off the RECORD
                // (2026-09-18). Deliberately not read from
                // `StudyComparisonSettings`: that would stamp every row
                // in the file with the configuration of the device the
                // export ran on, which for a session run yesterday is
                // simply wrong. Empty for a pilot row.
                rec.comparisonConfiguration ?? ""
            ]
            lines.append(row.map { delimitedField($0, separator: sep) }.joined(separator: sep))
        }
        lines.append("")

        lines.append(["metric","value"].joined(separator: sep))
        let rates = enrolledSnapshot.phaseCompletionRates
        // Iterate LearningPhase.allCases so every phase, including
        // `direct`, lands in the export.
        for phase in LearningPhase.allCases.map(\.rawName) {
            if let rate = rates[phase] {
                lines.append(["phaseCompletionRate_\(phase)", String(format: "%.4f", rate)].joined(separator: sep))
            }
        }
        lines.append(["averageFreeWriteScore", String(format: "%.4f", enrolledSnapshot.averageFreeWriteScore)].joined(separator: sep))
        lines.append(["schedulerEffectivenessProxy",
                      enrolledSnapshot.schedulerEffectivenessProxyIfDefined.map { String(format: "%.4f", $0) } ?? ""].joined(separator: sep))
        // Per-condition aggregates so between-arm comparisons don't
        // have to back out cross-arm contamination. The proxy is
        // meaningful only inside an arm — `.control` uses a different
        // priority scale, so the cross-arm proxy is invalid.
        for arm in ThesisCondition.allCases {
            let armRecords = enrolledRecords.filter { $0.condition == arm }
            let freeWrite = armRecords.filter { $0.phase == LearningPhase.freeWrite.rawName && $0.completed }.map(\.score)
            if !freeWrite.isEmpty {
                let avg = freeWrite.reduce(0, +) / Double(freeWrite.count)
                lines.append(["averageFreeWriteScore_\(arm.rawValue)", String(format: "%.4f", avg)].joined(separator: sep))
            }
            // Per-arm proxy: same Pearson as `schedulerEffectivenessProxy`,
            // restricted to one condition. Skipped under 2 pairs.
            var pairs: [(priority: Double, delta: Double)] = []
            let lettersInArm = Set(armRecords.map(\.letter))
            for letter in lettersInArm {
                // D11#2: actually sorted, not just named `chrono` — see
                // the identical fix + rationale in
                // `ParentDashboardStore.schedulerEffectivenessProxy`.
                // freeWrite rows only: consecutive rows of ONE pass are
                // observe → direct → guided → freeWrite, three different
                // instruments, so cross-phase deltas are not learning gains
                // (audit 2026-09-04).
                let chrono = armRecords
                    .filter { $0.letter == letter && $0.completed && $0.phase == LearningPhase.freeWrite.rawName }
                    .sorted { ($0.recordedAt ?? .distantPast) < ($1.recordedAt ?? .distantPast) }
                guard chrono.count >= 2 else { continue }
                for i in 0..<(chrono.count - 1) {
                    pairs.append((priority: chrono[i].schedulerPriority,
                                  delta: chrono[i + 1].score - chrono[i].score))
                }
            }
            if pairs.count >= 2 {
                let n = Double(pairs.count)
                let xs = pairs.map(\.priority)
                let ys = pairs.map(\.delta)
                let xMean = xs.reduce(0, +) / n
                let yMean = ys.reduce(0, +) / n
                let num = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) }
                let xVar = xs.reduce(0.0) { $0 + ($1 - xMean) * ($1 - xMean) }
                let yVar = ys.reduce(0.0) { $0 + ($1 - yMean) * ($1 - yMean) }
                if xVar > 0, yVar > 0 {
                    let r = num / (xVar * yVar).squareRoot()
                    lines.append(["schedulerEffectivenessProxy_\(arm.rawValue)", String(format: "%.4f", r)].joined(separator: sep))
                }
            }
        }
        // Per-letter accuracy aggregates split by thesis arm.
        // `letterStats.accuracySamples` (the source the removed
        // letter-row `averageAccuracy` used) carries no condition tag;
        // `phaseSessionRecords` does, so it gives a clean per-arm
        // letter-level source. Format:
        // `letterByArm,letter,arm,sampleCount,averageScore`.
        lines.append(["letterByArm","letter","arm","sampleCount","averageScore"].joined(separator: sep))
        // freeWrite rows only (audit 2026-09-04, class one): observe/direct
        // rows carry a constant score of 1.0 and guided carries coverage,
        // so averaging every phase floored the per-arm accuracy near 0.5
        // and compared the arms on a completion counter. Same phase
        // filter as `averageFreeWriteScore_<arm>` above.
        let phaseByArm = Dictionary(grouping: enrolledRecords.filter { $0.completed && $0.phase == LearningPhase.freeWrite.rawName }, by: { $0.condition })
        for arm in ThesisCondition.allCases {
            guard let records = phaseByArm[arm] else { continue }
            let byLetter = Dictionary(grouping: records, by: { $0.letter })
            for (letter, group) in byLetter.sorted(by: { $0.key < $1.key }) {
                let n = group.count
                let avg = group.map(\.score).reduce(0, +) / Double(n)
                lines.append(["letterByArm", letter, arm.rawValue, "\(n)", String(format: "%.4f", avg)].joined(separator: sep))
            }
        }
        // Pilot audio axis — the PRIMARY between-subjects IV (the
        // pedagogical axis above is held constant across pilot arms, D1).
        // Stratified ALONGSIDE the pedagogical axis, not instead of it, so
        // both the pilot's audio contrast and the larger study's
        // pedagogical contrast stay exportable from one file.
        for arm in PilotAudioCondition.allCases {
            let armRecords = enrolledRecords.filter { $0.audioCondition == arm }
            let freeWrite = armRecords.filter { $0.phase == LearningPhase.freeWrite.rawName && $0.completed }.map(\.score)
            if !freeWrite.isEmpty {
                let avg = freeWrite.reduce(0, +) / Double(freeWrite.count)
                lines.append(["averageFreeWriteScore_audio_\(arm.rawValue)", String(format: "%.4f", avg)].joined(separator: sep))
            }
        }
        // Per-letter accuracy split by audio arm — the audio-axis twin of
        // `letterByArm`. Format:
        // `letterByAudioArm,letter,audioArm,sampleCount,averageScore`.
        lines.append(["letterByAudioArm","letter","audioArm","sampleCount","averageScore"].joined(separator: sep))
        let phaseByAudioArm = Dictionary(grouping: enrolledRecords.filter { $0.completed && $0.phase == LearningPhase.freeWrite.rawName }, by: { $0.audioCondition })
        for arm in PilotAudioCondition.allCases {
            guard let records = phaseByAudioArm[arm] else { continue }
            let byLetter = Dictionary(grouping: records, by: { $0.letter })
            for (letter, group) in byLetter.sorted(by: { $0.key < $1.key }) {
                let n = group.count
                let avg = group.map(\.score).reduce(0, +) / Double(n)
                lines.append(["letterByAudioArm", letter, arm.rawValue, "\(n)", String(format: "%.4f", avg)].joined(separator: sep))
            }
        }
        // Aggregate Schreibmotorik dimensions across all completed
        // freeWrite sessions. Emitted only when at least one session
        // contributed.
        if let dims = enrolledSnapshot.averageWritingDimensions {
            lines.append(["averageFormAccuracy", String(format: "%.4f", dims.form)].joined(separator: sep))
            lines.append(["averageTempoConsistency", String(format: "%.4f", dims.tempo)].joined(separator: sep))
            lines.append(["averagePressureControl", String(format: "%.4f", dims.pressure)].joined(separator: sep))
            lines.append(["averageRhythmScore", String(format: "%.4f", dims.rhythm)].joined(separator: sep))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    /// A visually unambiguous separator between one participant's CSV/TSV
    /// block and the next in a combined export — `#`-prefixed so it reads
    /// as a comment line to any consumer that already skips the `#
    /// participantId=...` header lines, rather than as a data row.
    private static let participantBlockSeparator =
        "\n\n# ==================== next participant ====================\n\n"

    /// Every participant's CSV/TSV block, one after another in a single
    /// file (2026-09-14) — the "export once at the end covering everyone"
    /// a multi-child session needs, instead of one export per child.
    /// Reuses `delimitedData` unchanged per participant, so the existing,
    /// already-thesis-documented per-row column schema (EXPORT_SCHEMA
    /// appendix) is byte-identical inside each block; only the
    /// concatenation is new.
    static func combinedDelimitedData(
        participants: [ParticipantExportSource],
        separator sep: String
    ) -> Data {
        let blocks = participants.map { p in
            String(data: delimitedData(from: p.snapshot, participantId: p.participantId,
                                       progress: p.progress, enrolledAt: p.enrolledAt, separator: sep),
                   encoding: .utf8) ?? ""
        }
        return blocks.joined(separator: Self.participantBlockSeparator).data(using: .utf8) ?? Data()
    }

    // MARK: JSON

    /// Pretty-printed JSON of the full snapshot plus thesis metrics,
    /// `participantId`, and per-letter progress entries.
    static func jsonData(from snapshot: DashboardSnapshot,
                          participantId: UUID = ParticipantStore.participantId,
                          progress: [String: LetterProgress] = [:],
                          rawTraces: [RawTrace] = [],
                          enrolledAt: Date? = ParticipantStore.enrolledAt) throws(ExportError) -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let export = snapshotWithMetrics(from: snapshot, participantId: participantId,
                                             progress: progress, rawTraces: rawTraces,
                                             enrolledAt: enrolledAt)
            return renamingRetiredFrechetKey(in: try encoder.encode(export))
        } catch {
            throw ExportError.encodingFailed(error.localizedDescription)
        }
    }

    /// Every participant's JSON export object, as one top-level array
    /// (2026-09-14) — the JSON counterpart of `combinedDelimitedData`.
    static func combinedJSONData(participants: [ParticipantExportSource]) throws(ExportError) -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let exports = participants.map {
                snapshotWithMetrics(from: $0.snapshot, participantId: $0.participantId,
                                    progress: $0.progress, rawTraces: $0.rawTraces,
                                    enrolledAt: $0.enrolledAt)
            }
            return renamingRetiredFrechetKey(in: try encoder.encode(exports))
        } catch {
            throw ExportError.encodingFailed(error.localizedDescription)
        }
    }

    /// Shared single-participant JSON export builder behind both
    /// `jsonData` and `combinedJSONData`, so the pre-enrolment filtering
    /// rule (Ch.3) lives in exactly one place.
    private static func snapshotWithMetrics(
        from snapshot: DashboardSnapshot,
        participantId: UUID,
        progress: [String: LetterProgress],
        rawTraces: [RawTrace],
        enrolledAt: Date?
    ) -> SnapshotWithMetrics {
        // Same pre-enrolment rule as the CSV (2026-09-04): the JSON
        // archive used to dump every phase row unfiltered and carried
        // no `enrolledAt`, so its consumer could not even reproduce
        // the rule the thesis states the exporter applies (Ch.3).
        // Raw traces follow the SAME rule (2026-09-06): a trace
        // recorded before this enrolment can link to no exported row
        // (those rows are filtered), and after "Teilnehmer
        // wiederherstellen" with a different id — the delayed test on
        // an iPad whose last child was never wiped — it is that other
        // child's ink under this participantId. Same-id restores keep
        // the original `enrolledAt`, so the archive stays complete.
        let filteredTraces = enrolledAt.map { at in
            rawTraces.filter { $0.recordedAt >= at }
        } ?? rawTraces
        let filtered: DashboardSnapshot = {
            guard let enrolledAt else {
                var s = snapshot
                s.phaseSessionRecords = withDerivedPostTestTags(s.phaseSessionRecords)
                return s
            }
            var s = snapshot
            s.phaseSessionRecords = withDerivedPostTestTags(snapshot.phaseSessionRecords.filter { rec in
                guard let ts = rec.recordedAt else { return false }
                return ts >= enrolledAt
            })
            s.sessionDurations = snapshot.sessionDurations.filter { rec in
                guard let ts = rec.recordedAt else { return false }
                return ts >= enrolledAt
            }
            return s
        }()
        return SnapshotWithMetrics(
            snapshot: filtered,
            participantId: participantId,
            progress: progress,
            rawTraces: filteredTraces,
            enrolledAt: enrolledAt
        )
    }

    // MARK: Private types

    private struct SnapshotWithMetrics: Encodable {
        let participantId: String
        /// Enrolment instant the row filter was applied against; nil when
        /// the install was never enrolled (then nothing was filtered).
        let enrolledAt: Date?
        let letterStats: [String: LetterAccuracyStat]
        let sessionDurations: [SessionDurationRecord]
        let phaseSessionRecords: [PhaseSessionRecord]
        let letterProgress: [String: LetterProgress]
        /// Lossless per-trial raw freeWrite traces, linked to their
        /// records by `PhaseSessionRecord.rawTraceID`. The JSON archive is
        /// the ONLY export that carries them (the CSV stays derived-only).
        let rawTraces: [RawTrace]
        let thesisMetrics: ThesisMetrics

        init(snapshot: DashboardSnapshot,
             participantId: UUID,
             progress: [String: LetterProgress],
             rawTraces: [RawTrace],
             enrolledAt: Date?) {
            self.participantId = participantId.uuidString
            self.enrolledAt = enrolledAt
            letterStats = snapshot.letterStats
            sessionDurations = snapshot.sessionDurations
            phaseSessionRecords = snapshot.phaseSessionRecords
            letterProgress = progress
            self.rawTraces = rawTraces
            let dims = snapshot.averageWritingDimensions
            thesisMetrics = ThesisMetrics(
                phaseCompletionRates: snapshot.phaseCompletionRates,
                averageFreeWriteScore: snapshot.averageFreeWriteScore,
                schedulerEffectivenessProxy: snapshot.schedulerEffectivenessProxy,
                averageFormAccuracy: dims?.form,
                averageTempoConsistency: dims?.tempo,
                averagePressureControl: dims?.pressure,
                averageRhythmScore: dims?.rhythm
            )
        }

        struct ThesisMetrics: Encodable {
            let phaseCompletionRates: [String: Double]
            let averageFreeWriteScore: Double
            let schedulerEffectivenessProxy: Double
            /// Schreibmotorik dimensions averaged across all completed
            /// freeWrite sessions. nil when no freeWrite data exists yet.
            let averageFormAccuracy: Double?
            let averageTempoConsistency: Double?
            let averagePressureControl: Double?
            let averageRhythmScore: Double?
        }
    }

    // MARK: File URL helpers

    /// Writes export data to a temp file and returns its URL for share-sheet use.
    static func exportFileURL(
        from snapshot: DashboardSnapshot,
        format: DashboardExportFormat,
        tempDirectory: URL = FileManager.default.temporaryDirectory,
        progress: [String: LetterProgress] = [:],
        rawTraces: [RawTrace] = []
    ) throws(ExportError) -> URL {
        let data: Data
        let filename: String
        // Date + time + participant prefix: several children on one iPad
        // on one pilot day used to produce identically named files that
        // overwrote each other in the temp dir and in any save folder
        // (audit 2026-09-04).
        let tag = "\(Self.dateTag())_\(Self.timeTag())_\(ParticipantStore.participantId.uuidString.prefix(8))"
        switch format {
        case .csv:
            // CSV stays derived-scalars only — raw traces are too large
            // and the wrong shape for a flat row; they ride the JSON.
            data     = csvData(from: snapshot, progress: progress)
            filename = "primae_progress_\(tag).csv"
        case .tsv:
            data     = tsvData(from: snapshot, progress: progress)
            filename = "primae_progress_\(tag).tsv"
        case .json:
            data     = try jsonData(from: snapshot, progress: progress, rawTraces: rawTraces)
            filename = "primae_progress_\(tag).json"
        }
        let url = tempDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return url
    }

    /// Writes a COMBINED export — every participant recorded on this
    /// device, current plus archived — to one temp file (2026-09-14).
    /// The proctor-facing "export once at the end" action; see
    /// `TracingViewModel.allParticipantExportSources`.
    static func combinedExportFileURL(
        participants: [ParticipantExportSource],
        format: DashboardExportFormat,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) throws(ExportError) -> URL {
        let data: Data
        let filename: String
        let tag = "\(Self.dateTag())_\(Self.timeTag())_all\(participants.count)"
        switch format {
        case .csv:
            data     = combinedDelimitedData(participants: participants, separator: ",")
            filename = "primae_progress_ALL_\(tag).csv"
        case .tsv:
            data     = combinedDelimitedData(participants: participants, separator: "\t")
            filename = "primae_progress_ALL_\(tag).tsv"
        case .json:
            data     = try combinedJSONData(participants: participants)
            filename = "primae_progress_ALL_\(tag).json"
        }
        let url = tempDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return url
    }

    // MARK: Private

    private static func timeTag() -> String {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: Date())
        return String(format: "%02d%02d%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private static func dateTag() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Export-time-only corrections (2026-09-16)
    //
    // Two fixes, both applied to COPIES built for export, never to
    // anything persisted: PhaseSessionRecord's own Codable keys and
    // on-disk format are untouched by either, so nothing already on a
    // device is affected by landing this mid-pilot.

    /// The CSV/TSV header name for the retired whole-path Fréchet field.
    /// Not "frechetDistance" (2026-09-16) — that name is what a reader
    /// hunting for the thesis's primary Fréchet-distance outcome reaches
    /// for first, and this column is always empty; the real primary
    /// outcome exports as "spatialDeviation". Kept in the same column
    /// position for the schema-stability reason the field is kept at
    /// all (`PhaseSessionRecord.frechetDistance`'s own doc comment).
    static let retiredFrechetColumnName = "frechetDistance_RETIRED_alwaysEmpty"

    /// Rewrites the JSON output's `frechetDistance` key to
    /// `retiredFrechetColumnName`, wherever it appears in the
    /// `phaseSessionRecords` array of an already-encoded export. Runs
    /// AFTER `JSONEncoder` — not a change to `PhaseSessionRecord`'s own
    /// Codable — specifically so nothing about how the struct decodes
    /// (including any file already on a device from earlier today) can
    /// be affected by this. A pure `Data` -> `Data` transform; falls
    /// back to the untouched input on any parse failure rather than
    /// producing empty or malformed output.
    private static func renamingRetiredFrechetKey(in data: Data) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return data }
        func rewrite(_ value: Any) -> Any {
            if let dict = value as? [String: Any] {
                var out: [String: Any] = [:]
                for (key, v) in dict {
                    let newKey = key == "frechetDistance" ? retiredFrechetColumnName : key
                    out[newKey] = rewrite(v)
                }
                return out
            }
            if let array = value as? [Any] { return array.map(rewrite) }
            return value
        }
        let rewritten = rewrite(root)
        guard JSONSerialization.isValidJSONObject(rewritten),
              let out = try? JSONSerialization.data(
                withJSONObject: rewritten, options: [.prettyPrinted, .sortedKeys])
        else { return data }
        return out
    }

    /// Indices in `records` that are the derived post-test measurement
    /// for a TRAINED letter — the freeWrite phase of that letter's final
    /// training pass (thesis Ch.6, content/06-evaluation.typ §"Outcome
    /// measures"). `StudyProbe.posttest.permits` deliberately refuses a
    /// trained letter at record time (`StudyProbe.swift`'s own header:
    /// "The trained letters' post-test is the freeWrite phase of their
    /// final training pass... so this kind refuses a trained letter"),
    /// so nothing in the live app ever tags this row — leaving the
    /// export schema silent on which trained-letter row IS the
    /// post-test measurement, discoverable only by timestamp ordering.
    /// `records` must be chronological (both callers filter from the
    /// append-ordered on-disk array without re-sorting) — "last" here
    /// means latest in that order, which `enumerated()` preserves.
    ///
    /// Reads the `trainedSubset` column, which is the SESSION's trained
    /// set (`TracingViewModel.effectiveTrainedSubset`), not the
    /// participant's assignment. Under the `allFiveLetters` comparison
    /// switch that column is "AFILM" — the all-five case of
    /// `TrainedLetterSubset` — so this derivation tags all five letters'
    /// final training pass, which is correct there: with no untrained
    /// letter, every letter's post-test IS its own last training
    /// freeWrite. `TrainedLetterSubset.init?(rawValue:)` accepts that
    /// value for this reason; a nil here would have dropped the tag from
    /// every letter of an all-five run.
    private static func derivedTrainedPostTestIndices(in records: [PhaseSessionRecord]) -> Set<Int> {
        var lastIndexPerLetter: [String: Int] = [:]
        for (i, rec) in records.enumerated() {
            guard rec.phase == LearningPhase.freeWrite.rawName,
                  rec.completed,
                  rec.probe == nil,   // not already a pretest/delayed cold probe
                  let subsetRaw = rec.trainedSubset,
                  let subset = TrainedLetterSubset(rawValue: subsetRaw),
                  subset.letters.contains(rec.letter)
            else { continue }
            lastIndexPerLetter[rec.letter] = i
        }
        return Set(lastIndexPerLetter.values)
    }

    /// Applies `derivedTrainedPostTestIndices`, returning export-only
    /// copies with `probe` set to `StudyProbe.posttest.rawValue` where
    /// derived — so `probe == "posttest"` finds all five study letters'
    /// post-test rows (two tagged live, three tagged here), not just the
    /// two untrained ones. Mutates copies only: `records` was already
    /// read from disk/memory before this runs, and nothing here writes
    /// back to any store.
    private static func withDerivedPostTestTags(_ records: [PhaseSessionRecord]) -> [PhaseSessionRecord] {
        let derived = derivedTrainedPostTestIndices(in: records)
        guard !derived.isEmpty else { return records }
        return records.enumerated().map { i, rec in
            guard derived.contains(i) else { return rec }
            var tagged = rec
            tagged.probe = StudyProbe.posttest.rawValue
            return tagged
        }
    }
}
