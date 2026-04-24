import Foundation

// MARK: - Export format

enum DashboardExportFormat {
    case csv
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

    // MARK: CSV

    /// Produces a UTF-8 CSV with a `# participantId=...` header, one row per
    /// letter, per-session durations (with condition), per-phase records
    /// (with condition), and the aggregate thesis metrics.
    /// Consumers doing A/B analysis need the participantId header to align
    /// data across installs and the condition column on every session row.
    static func csvData(from snapshot: DashboardSnapshot,
                         participantId: UUID = ParticipantStore.participantId,
                         progress: [String: LetterProgress] = [:]) -> Data {
        var lines: [String] = []
        lines.append("# participantId=\(participantId.uuidString)")
        lines.append("")

        lines.append("letter,sessionCount,averageAccuracy,trend,recognitionSamples,recognitionAvg")
        let sorted = snapshot.letterStats.values.sorted { $0.letter < $1.letter }
        for stat in sorted {
            let avg = String(format: "%.4f", stat.averageAccuracy)
            let tnd = String(format: "%.6f", stat.trend)
            let cnt = stat.accuracySamples.count
            let acc = progress[stat.letter]?.recognitionAccuracy ?? []
            let recCount = acc.count
            let recAvg = acc.isEmpty
                ? "" : String(format: "%.4f", acc.reduce(0, +) / Double(acc.count))
            lines.append("\(stat.letter),\(cnt),\(avg),\(tnd),\(recCount),\(recAvg)")
        }
        lines.append("")

        lines.append("date,durationSeconds,condition")
        for rec in snapshot.sessionDurations.sorted(by: { $0.dateString < $1.dateString }) {
            lines.append("\(rec.dateString),\(rec.durationSeconds),\(rec.condition.rawValue)")
        }
        lines.append("")

        lines.append("letter,phase,completed,score,schedulerPriority,condition,recognition_predicted,recognition_confidence,recognition_correct")
        // Per-session recognition data is per-letter, not per-phase — we
        // surface the per-letter rolling-recognition average and the
        // latest-result fields per letter-progress entry. For phase rows
        // without a corresponding progress entry we leave the three
        // recognition columns blank so downstream CSV consumers can
        // distinguish "no recognition data" from "zero confidence".
        for rec in snapshot.phaseSessionRecords {
            let score = String(format: "%.4f", rec.score)
            let prio  = String(format: "%.4f", rec.schedulerPriority)
            let prog  = progress[rec.letter]
            let recConf: String = prog?.recognitionAccuracy?.last
                .map { String(format: "%.4f", $0) } ?? ""
            // Emit a prediction label only when we have a stored confidence
            // — it's always the child's guided letter so the caller can
            // reconstruct predicted vs. expected from the row itself.
            let recLabel  = recConf.isEmpty ? "" : rec.letter
            let recRight  = recConf.isEmpty ? "" : "true"
            lines.append("\(rec.letter),\(rec.phase),\(rec.completed),\(score),\(prio),\(rec.condition.rawValue),\(recLabel),\(recConf),\(recRight)")
        }
        lines.append("")

        lines.append("metric,value")
        let rates = snapshot.phaseCompletionRates
        // Iterate LearningPhase.allCases so Richtung-lernen (direct) is
        // exported alongside the other three phases — prior versions dropped it.
        for phase in LearningPhase.allCases.map(\.rawName) {
            if let rate = rates[phase] {
                lines.append("phaseCompletionRate_\(phase),\(String(format: "%.4f", rate))")
            }
        }
        lines.append("averageFreeWriteScore,\(String(format: "%.4f", snapshot.averageFreeWriteScore))")
        lines.append("schedulerEffectivenessProxy,\(String(format: "%.4f", snapshot.schedulerEffectivenessProxy))")
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    // MARK: JSON

    /// Produces pretty-printed JSON of the full ``DashboardSnapshot`` plus
    /// thesis metrics and the stable `participantId` needed for cross-install
    /// A/B analysis.
    static func jsonData(from snapshot: DashboardSnapshot,
                          participantId: UUID = ParticipantStore.participantId) throws(ExportError) -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let export = SnapshotWithMetrics(snapshot: snapshot, participantId: participantId)
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
        let thesisMetrics: ThesisMetrics

        init(snapshot: DashboardSnapshot, participantId: UUID) {
            self.participantId = participantId.uuidString
            letterStats = snapshot.letterStats
            sessionDurations = snapshot.sessionDurations
            phaseSessionRecords = snapshot.phaseSessionRecords
            thesisMetrics = ThesisMetrics(
                phaseCompletionRates: snapshot.phaseCompletionRates,
                averageFreeWriteScore: snapshot.averageFreeWriteScore,
                schedulerEffectivenessProxy: snapshot.schedulerEffectivenessProxy
            )
        }

        struct ThesisMetrics: Encodable {
            let phaseCompletionRates: [String: Double]
            let averageFreeWriteScore: Double
            let schedulerEffectivenessProxy: Double
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
        case .json:
            data     = try jsonData(from: snapshot)     // typed-throw propagates
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
