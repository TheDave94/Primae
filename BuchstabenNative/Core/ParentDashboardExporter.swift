import Foundation

// MARK: - Export format

enum DashboardExportFormat {
    case csv
    /// Tab-separated variant of `csv`. SPSS, R, and most stat tools
    /// import TSV without escape-quoting confusion when the dataset
    /// happens to contain commas, so a TSV export is offered alongside
    /// the canonical CSV.
    case tsv
    case json
}

// MARK: - Typed export errors

enum ExportError: Error, Equatable {
    case encodingFailed(String)
    case writeFailed(String)
}

// MARK: - Exporter

/// Converts a ``DashboardSnapshot`` to shareable file data.
/// No UIKit/SwiftUI dependency — kept in Core so it's testable on Linux CI.
struct ParentDashboardExporter {

    // MARK: CSV / TSV

    /// Produces a UTF-8 CSV with a `# participantId=...` header, one row per
    /// letter, per-session durations (with condition), per-phase records
    /// (with condition), and the aggregate thesis metrics.
    /// Consumers doing A/B analysis need the participantId header to align
    /// data across installs and the condition column on every session row.
    static func csvData(from snapshot: DashboardSnapshot,
                         participantId: UUID = ParticipantStore.participantId,
                         progress: [String: LetterProgress] = [:],
                         enrolledAt: Date? = ParticipantStore.enrolledAt) -> Data {
        delimitedData(from: snapshot, participantId: participantId,
                       progress: progress, enrolledAt: enrolledAt, separator: ",")
    }

    /// Tab-separated variant of `csvData`. Same row layout, fewer
    /// import-time escaping headaches in SPSS / R for datasets that
    /// happen to contain commas.
    static func tsvData(from snapshot: DashboardSnapshot,
                         participantId: UUID = ParticipantStore.participantId,
                         progress: [String: LetterProgress] = [:],
                         enrolledAt: Date? = ParticipantStore.enrolledAt) -> Data {
        delimitedData(from: snapshot, participantId: participantId,
                       progress: progress, enrolledAt: enrolledAt, separator: "\t")
    }

    /// Shared row builder behind csvData / tsvData. Keeping a single
    /// implementation guarantees both formats stay in lock-step on
    /// columns and dimension precision.
    private static func delimitedData(
        from snapshot: DashboardSnapshot,
        participantId: UUID,
        progress: [String: LetterProgress],
        enrolledAt: Date?,
        separator sep: String
    ) -> Data {
        var lines: [String] = []
        lines.append("# participantId=\(participantId.uuidString)")
        // D-7: surface the enrolment timestamp in the export header so
        // downstream consumers can reproduce the exporter's pre-
        // enrollment filtering rule and audit which records were
        // skipped at export time.
        if let enrolledAt {
            lines.append("# enrolledAt=\(ISO8601DateFormatter().string(from: enrolledAt))")
        }
        // T3 (ROADMAP_V5): timezone metadata so downstream analytics can
        // interpret `recordedAt` columns correctly across devices that
        // travel timezones or run in DST. ISO-8601 timestamps already
        // carry an offset, but the timezone identifier is a more useful
        // analyst-facing label.
        lines.append("# timezone=\(TimeZone.current.identifier)")
        let isoFormatter = ISO8601DateFormatter()
        lines.append("")

        // D-6: speedTrend (the rolling per-letter writing-speed series
        // used by the scheduler's automatisation bonus) was previously
        // JSON-only. Surface it as a semicolon-joined list in the
        // letter-aggregate row so SPSS / R imports can reconstruct the
        // automatisation analysis without the JSON sidecar.
        // `freeformCompletionCount` (HIDDEN_FEATURES_AUDIT C.2): blank-canvas
        // letter-recognition completions are counted separately from guided
        // mastery so the analysis can distinguish exploration from
        // gradual-release learning. nil for letters never written in
        // freeform mode; emitted as empty string.
        // P1 (ROADMAP): `retrievalAccuracy` is the rolling mean of
        // `LetterProgress.retrievalAttempts` (cap 10). Empty when the
        // parent hasn't enabled the Erinnerungstest, or for letters
        // never tested.
        lines.append(["letter","sessionCount","averageAccuracy","trend","recognitionSamples","recognitionAvg","speedTrend","freeformCompletionCount","retrievalAccuracy"].joined(separator: sep))
        let sorted = snapshot.letterStats.values.sorted { $0.letter < $1.letter }
        for stat in sorted {
            let avg = String(format: "%.4f", stat.averageAccuracy)
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
            lines.append([stat.letter, "\(cnt)", avg, tnd, "\(recCount)", recAvg, speedField, freeformField, retrievalField].joined(separator: sep))
        }
        lines.append("")

        // D-9: emit the full ISO-8601 timestamp alongside the day-level
        // dateString so the analysis can recover time-of-day signal
        // (morning vs evening practice). T4 adds wallClockSeconds (total
        // wall-clock time including backgrounded intervals) so the
        // engagement-vs-practice split is recoverable. T7 adds
        // inputDevice. Legacy rows emit empty strings for new columns.
        lines.append(["date","recordedAt","durationSeconds","wallClockSeconds","condition","inputDevice"].joined(separator: sep))
        for rec in snapshot.sessionDurations.sorted(by: { $0.dateString < $1.dateString }) {
            let recordedAtField = rec.recordedAt.map { isoFormatter.string(from: $0) } ?? ""
            let wallField = rec.wallClockSeconds.map { String(format: "%.3f", $0) } ?? ""
            lines.append([rec.dateString, recordedAtField,
                          String(format: "%.3f", rec.durationSeconds),
                          wallField, rec.condition.rawValue,
                          rec.inputDevice ?? ""].joined(separator: sep))
        }
        lines.append("")

        // Per-phase records gain four Schreibmotorik dimensions
        // (formAccuracy, tempoConsistency, pressureControl, rhythmScore)
        // alongside the recognition columns so SPSS / R / pandas imports
        // can analyse each motor-skill dimension independently. The
        // dimensions are non-null only on freeWrite rows — see
        // PhaseSessionRecord.init — so observe / direct / guided rows
        // emit empty strings for them.
        // D-3 adds `recordedAt`; D-2 reverses W-2's blank-column workaround
        // because `PhaseSessionRecord` now carries session-aligned
        // recognition fields. Legacy rows (pre-D-2/D-3) decode the new
        // fields as nil and emit empty strings, which is what
        // downstream tooling already handles.
        // D-6: `inputDevice` ("finger"/"pencil") so a `pressureControl == 1.0`
        // row is distinguishable from a real low-variance pencil session.
        // T5: `recognition_confidence_raw` is the pre-calibration softmax
        // probability so the thesis can quantify the calibrator's effect
        // on classification decisions.
        lines.append(["letter","phase","completed","score","schedulerPriority","condition","recordedAt","recognition_predicted","recognition_confidence","recognition_confidence_raw","recognition_correct","formAccuracy","tempoConsistency","pressureControl","rhythmScore","inputDevice"].joined(separator: sep))
        for rec in snapshot.phaseSessionRecords {
            // D-7: discard rows recorded before this install joined the
            // study so pilot / sandbox / pre-enrolment activity isn't
            // silently attributed to the assigned thesis arm.
            // D-8: also discard rows that pre-date `recordedAt` itself
            // when an `enrolledAt` exists — we can't prove they were
            // post-enrolment, and the decoder defaulted their condition
            // to `.threePhase`, which would silently inflate that arm.
            if let enrolledAt {
                if let ts = rec.recordedAt {
                    if ts < enrolledAt { continue }
                } else {
                    continue
                }
            }
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
            lines.append([
                rec.letter, rec.phase, "\(rec.completed)", score, prio,
                rec.condition.rawValue, recordedAtField,
                recLabel, recConf, recConfRaw, recRight,
                dimForm, dimTempo, dimPress, dimRhythm,
                rec.inputDevice ?? ""
            ].joined(separator: sep))
        }
        lines.append("")

        lines.append(["metric","value"].joined(separator: sep))
        let rates = snapshot.phaseCompletionRates
        // Iterate LearningPhase.allCases so Richtung-lernen (direct) is
        // exported alongside the other three phases — prior versions dropped it.
        for phase in LearningPhase.allCases.map(\.rawName) {
            if let rate = rates[phase] {
                lines.append(["phaseCompletionRate_\(phase)", String(format: "%.4f", rate)].joined(separator: sep))
            }
        }
        lines.append(["averageFreeWriteScore", String(format: "%.4f", snapshot.averageFreeWriteScore)].joined(separator: sep))
        lines.append(["schedulerEffectivenessProxy", String(format: "%.4f", snapshot.schedulerEffectivenessProxy)].joined(separator: sep))
        // D-7 / D-10: per-condition aggregates so a between-arm comparison
        // doesn't have to back out the mixed-condition contamination from
        // the overall figures above. The proxy is meaningful only inside
        // an arm — `.control` uses `-completionCount` priorities, which
        // share no scale with the Ebbinghaus priorities the other arms
        // emit, so the cross-arm proxy is invalid by construction.
        for arm in ThesisCondition.allCases {
            let armRecords = snapshot.phaseSessionRecords.filter { $0.condition == arm }
            let freeWrite = armRecords.filter { $0.phase == "freeWrite" && $0.completed }.map(\.score)
            if !freeWrite.isEmpty {
                let avg = freeWrite.reduce(0, +) / Double(freeWrite.count)
                lines.append(["averageFreeWriteScore_\(arm.rawValue)", String(format: "%.4f", avg)].joined(separator: sep))
            }
            // Per-arm proxy: same Pearson formula as `schedulerEffectivenessProxy`,
            // restricted to one condition. Skipped when the arm has fewer
            // than 2 letter pairs to correlate.
            var pairs: [(priority: Double, delta: Double)] = []
            let lettersInArm = Set(armRecords.map(\.letter))
            for letter in lettersInArm {
                let chrono = armRecords.filter { $0.letter == letter && $0.completed }
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
        // D-5: per-letter accuracy aggregates split by thesis arm.
        // `letterStats.accuracySamples` is a flat array with no
        // condition tag, so the per-letter `averageAccuracy` row above
        // mixes arms. Recompute the same aggregate from
        // `phaseSessionRecords` (which DO carry condition) so a
        // between-arm letter-level analysis has a clean source.
        // Format: `letterByArm,letter,arm,sampleCount,averageScore`.
        lines.append(["letterByArm","letter","arm","sampleCount","averageScore"].joined(separator: sep))
        let phaseByArm = Dictionary(grouping: snapshot.phaseSessionRecords.filter(\.completed), by: { $0.condition })
        for arm in ThesisCondition.allCases {
            guard let records = phaseByArm[arm] else { continue }
            let byLetter = Dictionary(grouping: records, by: { $0.letter })
            for (letter, group) in byLetter.sorted(by: { $0.key < $1.key }) {
                let n = group.count
                let avg = group.map(\.score).reduce(0, +) / Double(n)
                lines.append(["letterByArm", letter, arm.rawValue, "\(n)", String(format: "%.4f", avg)].joined(separator: sep))
            }
        }
        // Aggregate Schreibmotorik dimensions across all completed
        // freeWrite sessions. Only emitted when at least one session
        // contributed — pre-V3 installs never see these rows.
        if let dims = snapshot.averageWritingDimensions {
            lines.append(["averageFormAccuracy", String(format: "%.4f", dims.form)].joined(separator: sep))
            lines.append(["averageTempoConsistency", String(format: "%.4f", dims.tempo)].joined(separator: sep))
            lines.append(["averagePressureControl", String(format: "%.4f", dims.pressure)].joined(separator: sep))
            lines.append(["averageRhythmScore", String(format: "%.4f", dims.rhythm)].joined(separator: sep))
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    // MARK: JSON

    /// Produces pretty-printed JSON of the full ``DashboardSnapshot`` plus
    /// thesis metrics, the stable `participantId` needed for cross-install
    /// A/B analysis, and the per-letter progress entries (recognition
    /// samples, speed trend, paper-transfer assessments).
    static func jsonData(from snapshot: DashboardSnapshot,
                          participantId: UUID = ParticipantStore.participantId,
                          progress: [String: LetterProgress] = [:]) throws(ExportError) -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let export = SnapshotWithMetrics(
                snapshot: snapshot,
                participantId: participantId,
                progress: progress
            )
            return try encoder.encode(export)
        } catch {
            throw ExportError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: Private types

    private struct SnapshotWithMetrics: Encodable {
        let participantId: String
        let letterStats: [String: LetterAccuracyStat]
        let sessionDurations: [SessionDurationRecord]
        let phaseSessionRecords: [PhaseSessionRecord]
        let letterProgress: [String: LetterProgress]
        let thesisMetrics: ThesisMetrics

        init(snapshot: DashboardSnapshot,
             participantId: UUID,
             progress: [String: LetterProgress]) {
            self.participantId = participantId.uuidString
            letterStats = snapshot.letterStats
            sessionDurations = snapshot.sessionDurations
            phaseSessionRecords = snapshot.phaseSessionRecords
            letterProgress = progress
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
        progress: [String: LetterProgress] = [:]
    ) throws(ExportError) -> URL {
        let data: Data
        let filename: String
        let dateTag = Self.dateTag()
        switch format {
        case .csv:
            data     = csvData(from: snapshot, progress: progress)
            filename = "buchstaben_progress_\(dateTag).csv"
        case .tsv:
            data     = tsvData(from: snapshot, progress: progress)
            filename = "buchstaben_progress_\(dateTag).tsv"
        case .json:
            data     = try jsonData(from: snapshot, progress: progress)
            filename = "buchstaben_progress_\(dateTag).json"
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

    private static func dateTag() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
