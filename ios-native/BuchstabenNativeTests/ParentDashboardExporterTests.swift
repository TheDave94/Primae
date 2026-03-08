import XCTest
@testable import BuchstabenNative

final class ParentDashboardExporterTests: XCTestCase {

    // MARK: Helpers

    private func makeSnapshot() -> DashboardSnapshot {
        var snap = DashboardSnapshot()
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

    func testCSVContainsHeader() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        XCTAssertTrue(csv.hasPrefix("letter,sessionCount,averageAccuracy,trend"))
    }

    func testCSVContainsLetterRows() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        XCTAssertTrue(csv.contains("A,2,"), "Expected A row with 2 sessions")
        XCTAssertTrue(csv.contains("B,1,"), "Expected B row with 1 session")
    }

    func testCSVContainsDurationSection() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        XCTAssertTrue(csv.contains("date,durationSeconds"))
        XCTAssertTrue(csv.contains("2026-03-01"))
    }

    func testCSVEmptySnapshotIsValid() {
        let csv = String(data: ParentDashboardExporter.csvData(from: DashboardSnapshot()), encoding: .utf8)!
        XCTAssertTrue(csv.hasPrefix("letter,sessionCount,averageAccuracy,trend"))
    }

    // MARK: JSON

    func testJSONDecodesBack() throws {
        let snap = makeSnapshot()
        let data = try ParentDashboardExporter.jsonData(from: snap)
        let decoded = try JSONDecoder().decode(DashboardSnapshot.self, from: data)
        XCTAssertEqual(decoded.letterStats.count, snap.letterStats.count)
    }

    func testJSONIsPrettyPrinted() throws {
        let data = try ParentDashboardExporter.jsonData(from: makeSnapshot())
        let str = String(data: data, encoding: .utf8)!
        XCTAssertTrue(str.contains("\n"), "Expected pretty-printed JSON with newlines")
    }

    // MARK: File export

    func testExportFileURLCSVWritesFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = try ParentDashboardExporter.exportFileURL(from: makeSnapshot(), format: .csv, tempDirectory: tmp)
        XCTAssertTrue(url.pathExtension == "csv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    func testExportFileURLJSONWritesFile() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = try ParentDashboardExporter.exportFileURL(from: makeSnapshot(), format: .json, tempDirectory: tmp)
        XCTAssertTrue(url.pathExtension == "json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url)
    }

    func testExportFilenameContainsDate() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let url = try ParentDashboardExporter.exportFileURL(from: makeSnapshot(), format: .csv, tempDirectory: tmp)
        XCTAssertTrue(url.lastPathComponent.contains("buchstaben_progress_"))
        try? FileManager.default.removeItem(at: url)
    }
}
