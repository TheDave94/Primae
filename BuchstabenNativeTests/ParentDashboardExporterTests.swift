//  ParentDashboardExporterTests.swift
//  BuchstabenNativeTests

import Testing
@testable import BuchstabenNative

@MainActor
struct ParentDashboardExporterTests {

    private func makeSnapshot() -> DashboardSnapshot {
        let store = JSONParentDashboardStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_dashboard_\(UUID().uuidString).json"))
        store.recordSession(letter: "A", accuracy: 0.9, durationSeconds: 60, date: date("2026-03-01"))
        store.recordSession(letter: "A", accuracy: 0.8, durationSeconds: 45, date: date("2026-03-02"))
        store.recordSession(letter: "B", accuracy: 0.5, durationSeconds: 30, date: date("2026-03-01"))
        return store.snapshot
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)!
    }

    // MARK: CSV

    @Test func csvContainsHeader() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        #expect(csv.hasPrefix("letter,sessionCount,averageAccuracy,trend"))
    }

    @Test func csvContainsLetterRows() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        #expect(csv.contains("A,2,"), "Expected A row with 2 sessions")
        #expect(csv.contains("B,1,"), "Expected B row with 1 session")
    }

    @Test func csvContainsDurationSection() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        #expect(csv.contains("date,durationSeconds"))
        #expect(csv.contains("2026-03-01"))
    }

    @Test func csvEmptySnapshotIsValid() {
        let csv = String(data: ParentDashboardExporter.csvData(from: DashboardSnapshot()), encoding: .utf8)!
        #expect(csv.hasPrefix("letter,sessionCount,averageAccuracy,trend"))
    }

    // MARK: JSON

    @Test func jsonDecodesBack() throws {
        let snap = makeSnapshot()
        let data = try ParentDashboardExporter.jsonData(from: snap)
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        #expect(decoded.letterStats.count == snap.letterStats.count)
    }

    @Test func jsonIsPrettyPrinted() throws {
        let data = try ParentDashboardExporter.jsonData(from: makeSnapshot())
        let str = String(data: data, encoding: .utf8)!
        #expect(str.contains("\n"), "Expected pretty-printed JSON with newlines")
    }

    // MARK: File export

    @Test func exportFileURLCSVWritesFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = try ParentDashboardExporter.exportFileURL(from: makeSnapshot(), format: .csv, tempDirectory: tmp)
        #expect(url.pathExtension == "csv")
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func exportFileURLJSONWritesFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = try ParentDashboardExporter.exportFileURL(from: makeSnapshot(), format: .json, tempDirectory: tmp)
        #expect(url.pathExtension == "json")
        #expect(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func exportFilenameContainsDate() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = try ParentDashboardExporter.exportFileURL(from: makeSnapshot(), format: .csv, tempDirectory: tmp)
        #expect(url.lastPathComponent.contains("buchstaben_progress_"))
        try? FileManager.default.removeItem(at: url)
    }
}
