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

    /// Produces a UTF-8 CSV with one row per letter containing:
    /// letter, sessionCount, averageAccuracy, trend
    /// Appended sections: session durations and thesis metrics.
    static func csvData(from snapshot: DashboardSnapshot) -> Data {
        var lines: [String] = ["letter,sessionCount,averageAccuracy,trend"]
        let sorted = snapshot.letterStats.values.sorted { $0.letter < $1.letter }
        for stat in sorted {
            let avg = String(format: "%.4f", stat.averageAccuracy)
            let tnd = String(format: "%.6f", stat.trend)
            let cnt = stat.accuracySamples.count
            lines.append("\(stat.letter),\(cnt),\(avg),\(tnd)")
        }
        lines.append("")
        lines.append("date,durationSeconds")
        for rec in snapshot.sessionDurations.sorted(by: { $0.dateString < $1.dateString }) {
            lines.append("\(rec.dateString),\(rec.durationSeconds)")
        }
        lines.append("")
        lines.append("metric,value")
        let rates = snapshot.phaseCompletionRates
        for phase in ["observe", "guided", "freeWrite"] {
            if let rate = rates[phase] {
                lines.append("phaseCompletionRate_\(phase),\(String(format: "%.4f", rate))")
            }
        }
        lines.append("averageFreeWriteScore,\(String(format: "%.4f", snapshot.averageFreeWriteScore))")
        lines.append("schedulerEffectivenessProxy,\(String(format: "%.4f", snapshot.schedulerEffectivenessProxy))")
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    // MARK: JSON

    /// Produces pretty-printed JSON of the full ``DashboardSnapshot`` plus thesis metrics.
    static func jsonData(from snapshot: DashboardSnapshot) throws(ExportError) -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting    = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let export = SnapshotWithMetrics(snapshot: snapshot)
            return try encoder.encode(export)
        } catch {
            throw ExportError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: Private types

    private struct SnapshotWithMetrics: Encodable {
        let letterStats: [String: LetterAccuracyStat]
        let sessionDurations: [SessionDurationRecord]
        let phaseSessionRecords: [PhaseSessionRecord]
        let thesisMetrics: ThesisMetrics

        init(snapshot: DashboardSnapshot) {
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
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) throws(ExportError) -> URL {
        let data: Data
        let filename: String
        let dateTag = Self.dateTag()
        switch format {
        case .csv:
            data     = csvData(from: snapshot)
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
