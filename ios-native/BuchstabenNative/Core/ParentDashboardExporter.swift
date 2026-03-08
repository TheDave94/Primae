import Foundation

// MARK: - Export format

public enum DashboardExportFormat {
    case csv
    case json
}

// MARK: - Exporter

/// Converts a ``DashboardSnapshot`` to shareable file data.
/// No UIKit/SwiftUI dependency — kept in Core so it's testable on Linux CI.
public struct ParentDashboardExporter {

    // MARK: CSV

    /// Produces a UTF-8 CSV with one row per letter containing:
    /// letter, sessionCount, averageAccuracy, trend, bestAccuracy
    public static func csvData(from snapshot: DashboardSnapshot) -> Data {
        var lines: [String] = [
            "letter,sessionCount,averageAccuracy,trend"
        ]
        let sorted = snapshot.letterStats.values
            .sorted { $0.letter < $1.letter }
        for stat in sorted {
            let avg  = String(format: "%.4f", stat.averageAccuracy)
            let tnd  = String(format: "%.6f", stat.trend)
            let cnt  = stat.accuracySamples.count
            lines.append("\(stat.letter),\(cnt),\(avg),\(tnd)")
        }
        // Append session duration rows as a second section
        lines.append("")
        lines.append("date,durationSeconds")
        for rec in snapshot.sessionDurations.sorted(by: { $0.dateString < $1.dateString }) {
            lines.append("\(rec.dateString),\(rec.durationSeconds)")
        }
        return lines.joined(separator: "\n").data(using: .utf8) ?? Data()
    }

    // MARK: JSON

    /// Produces pretty-printed JSON of the full ``DashboardSnapshot``.
    public static func jsonData(from snapshot: DashboardSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    // MARK: File URL helpers

    /// Writes export data to a temp file and returns its URL for share-sheet use.
    /// - Parameters:
    ///   - snapshot: The dashboard data to export.
    ///   - format: `.csv` or `.json`
    ///   - tempDirectory: Override for testing; defaults to `FileManager.default.temporaryDirectory`.
    /// - Returns: URL of the written temp file.
    public static func exportFileURL(
        from snapshot: DashboardSnapshot,
        format: DashboardExportFormat,
        tempDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let data: Data
        let filename: String
        let dateTag = Self.dateTag()
        switch format {
        case .csv:
            data = csvData(from: snapshot)
            filename = "buchstaben_progress_\(dateTag).csv"
        case .json:
            data = try jsonData(from: snapshot)
            filename = "buchstaben_progress_\(dateTag).json"
        }
        let url = tempDirectory.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Private

    private static func dateTag() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
