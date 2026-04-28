//  ParentDashboardExporterTests.swift
//  BuchstabenNativeTests

import Testing
import Foundation
@testable import BuchstabenNative

@MainActor
struct ParentDashboardExporterTests {

    private func makeSnapshot() -> DashboardSnapshot {
        let store = JSONParentDashboardStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_dashboard_\(UUID().uuidString).json"))
        store.recordSession(letter: "A", accuracy: 0.9, durationSeconds: 60, date: date("2026-03-01"), condition: .threePhase)
        store.recordSession(letter: "A", accuracy: 0.8, durationSeconds: 45, date: date("2026-03-02"), condition: .threePhase)
        store.recordSession(letter: "B", accuracy: 0.5, durationSeconds: 30, date: date("2026-03-01"), condition: .threePhase)
        return store.snapshot
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: s)!
    }

    // MARK: CSV

    @Test func csvContainsHeader() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        // The CSV now starts with a participantId comment line followed by the
        // letter table header. Both must be present for A/B analysis consumers.
        #expect(csv.hasPrefix("# participantId="))
        #expect(csv.contains("letter,sessionCount,averageAccuracy,trend"))
    }

    @Test func csvContainsLetterRows() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        #expect(csv.contains("A,2,"), "Expected A row with 2 sessions")
        #expect(csv.contains("B,1,"), "Expected B row with 1 session")
    }

    @Test func csvContainsDurationSection() {
        let csv = String(data: ParentDashboardExporter.csvData(from: makeSnapshot()), encoding: .utf8)!
        #expect(csv.contains("date,durationSeconds,condition"))
        #expect(csv.contains("2026-03-01"))
    }

    @Test func csvEmptySnapshotIsValid() {
        let csv = String(data: ParentDashboardExporter.csvData(from: DashboardSnapshot()), encoding: .utf8)!
        #expect(csv.hasPrefix("# participantId="))
        #expect(csv.contains("letter,sessionCount,averageAccuracy,trend"))
    }

    @Test func csvIncludesParticipantIdAndConditionColumns() {
        let csv = String(data: ParentDashboardExporter.csvData(
            from: makeSnapshot(),
            participantId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
        ), encoding: .utf8)!
        #expect(csv.contains("# participantId=00000000-0000-0000-0000-0000000000AB"))
        #expect(csv.contains("date,durationSeconds,condition"))
        #expect(csv.contains("letter,phase,completed,score,schedulerPriority,condition"))
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

    // MARK: - F1: recognition columns are populated from RecognitionSample

    /// Build a snapshot with a phase-session record for a letter and pair it
    /// with a LetterProgress that carries a wrong-letter, low-confidence
    /// recognition sample. The exporter must emit those values verbatim
    /// instead of the prior bug's hardcoded `<expected>,<conf>,true`.
    @Test func csvRecognitionColumnsReflectStoredSample() {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true,
            score: 0.7, schedulerPriority: 0, condition: .threePhase
        ))
        var prog = LetterProgress()
        prog.recognitionSamples = [RecognitionSample(
            predictedLetter: "O",  // model picked a different letter
            confidence: 0.62,
            isCorrect: false       // mismatch with expected "A"
        )]
        prog.recognitionAccuracy = [0.62]
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: ["A": prog]), encoding: .utf8)!
        // Phase row format: letter,phase,completed,score,prio,condition,
        // recognition_predicted,recognition_confidence,recognition_correct
        #expect(csv.contains("A,freeWrite,true,0.7000,0.0000,threePhase,O,0.6200,false"),
                "Expected the exporter to emit the actual predicted letter (O) and isCorrect (false) — found:\n\(csv)")
    }

    /// Pre-RecognitionSample installs only stored a confidence list. Make
    /// sure the exporter still surfaces that legacy confidence (so the
    /// column isn't suddenly blank) and leaves predicted/correct empty
    /// because we never persisted them under the old schema.
    @Test func csvRecognitionColumnsFallBackToLegacyAccuracy() {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "B", phase: "guided", completed: true,
            score: 0.8, schedulerPriority: 0, condition: .control
        ))
        var prog = LetterProgress()
        prog.recognitionAccuracy = [0.42]   // legacy: confidence only
        prog.recognitionSamples  = nil      // never written under old schema
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: ["B": prog]), encoding: .utf8)!
        // Predicted + correct columns blank because the legacy schema didn't
        // capture them; confidence still surfaces from recognitionAccuracy.
        #expect(csv.contains("B,guided,true,0.8000,0.0000,control,,0.4200,"),
                "Expected legacy-confidence fallback row — found:\n\(csv)")
    }

    @Test func csvRecognitionColumnsBlankWhenNoData() {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "C", phase: "guided", completed: true,
            score: 0.5, schedulerPriority: 0, condition: .threePhase
        ))
        // No progress entry for "C" → all three recognition columns blank.
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:]), encoding: .utf8)!
        #expect(csv.contains("C,guided,true,0.5000,0.0000,threePhase,,,"),
                "Expected all recognition columns blank — found:\n\(csv)")
    }
}
