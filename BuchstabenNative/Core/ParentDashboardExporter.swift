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
                         progress: [String: LetterProgress] = [:]) -> Data {
        delimitedData(from: snapshot, participantId: participantId,
                       progress: progress, separator: ",")
    }

    /// Tab-separated variant of `csvData`. Same row layout, fewer
    /// import-time escaping headaches in SPSS / R for datasets that
    /// happen to contain commas.
    static func tsvData(from snapshot: DashboardSnapshot,
                         participantId: UUID = ParticipantStore.participantId,
                         progress: [String: LetterProgress] = [:]) -> Data {
        delimitedData(from: snapshot, participantId: participantId,
                       progress: progress, separator: "\t")
    }

    /// Shared row builder behind csvData / tsvData. Keeping a single
    /// implementation guarantees both formats stay in lock-step on
    /// columns and dimension precision.
    private static func delimitedData(
        from snapshot: DashboardSnapshot,
        participantId: UUID,
        progress: [String: LetterProgress],
        separator sep: String
    ) -> Data {
        var lines: [String] = []
        lines.append("# participantId=\(participantId.uuidString)")
        lines.append("")

        lines.append(["letter","sessionCount","averageAccuracy","trend","recognitionSamples","recognitionAvg"].joined(separator: sep))
        let sorted = snapshot.letterStats.values.sorted { $0.letter < $1.letter }
        for stat in sorted {
            let avg = String(format: "%.4f", stat.averageAccuracy)
            let tnd = String(format: "%.6f", stat.trend)
            let cnt = stat.accuracySamples.count
            let acc = progress[stat.letter]?.recognitionAccuracy ?? []
            let recCount = acc.count
            let recAvg = acc.isEmpty
                ? "" : String(format: "%.4f", acc.reduce(0, +) / Double(acc.count))
            lines.append([stat.letter, "\(cnt)", avg, tnd, "\(recCount)", recAvg].joined(separator: sep))
        }
        lines.append("")

        lines.append(["date","durationSeconds","condition"].joined(separator: sep))
        for rec in snapshot.sessionDurations.sorted(by: { $0.dateString < $1.dateString }) {
            lines.append([rec.dateString, "\(rec.durationSeconds)", rec.condition.rawValue].joined(separator: sep))
        }
        lines.append("")

        // Per-phase records gain four Schreibmotorik dimensions
        // (formAccuracy, tempoConsistency, pressureControl, rhythmScore)
        // alongside the recognition columns so SPSS / R / pandas imports
        // can analyse each motor-skill dimension independently. The
        // dimensions are non-null only on freeWrite rows — see
        // PhaseSessionRecord.init — so observe / direct / guided rows
        // emit empty strings for them.
        lines.append(["letter","phase","completed","score","schedulerPriority","condition","recognition_predicted","recognition_confidence","recognition_correct","formAccuracy","tempoConsistency","pressureControl","rhythmScore"].joined(separator: sep))
        // W-2: the per-letter `recognitionSamples` array is a rolling
        // latest-N window with no session timestamps, so attaching
        // `samples.last` to every per-phase row mis-correlates the most
        // recent recognition with phases that finished hours or days
        // earlier. The per-letter block above already surfaces the
        // recognition aggregate; per-session recognition correlation
        // requires session-time samples (see audit D-2), which the
        // schema can't reconstruct yet. Until then, leave these columns
        // blank so downstream tooling cannot accidentally read the
        // wrong reading as a session-aligned value.
        for rec in snapshot.phaseSessionRecords {
            let score = String(format: "%.4f", rec.score)
            let prio  = String(format: "%.4f", rec.schedulerPriority)
            let dimForm   = rec.formAccuracy.map     { String(format: "%.4f", $0) } ?? ""
            let dimTempo  = rec.tempoConsistency.map { String(format: "%.4f", $0) } ?? ""
            let dimPress  = rec.pressureControl.map  { String(format: "%.4f", $0) } ?? ""
            let dimRhythm = rec.rhythmScore.map      { String(format: "%.4f", $0) } ?? ""
            lines.append([
                rec.letter, rec.phase, "\(rec.completed)", score, prio,
                rec.condition.rawValue,
                "", "", "",
                dimForm, dimTempo, dimPress, dimRhythm
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
