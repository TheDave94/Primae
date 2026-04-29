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

    // MARK: - D-2 / D-3: phase-row recognition + recordedAt are session-aligned

    /// D-2: when the VM passes a `RecognitionSample` to `recordPhaseSession`,
    /// the per-phase row emits the actual session-aligned values. This
    /// supersedes W-2's blank-column workaround now that `PhaseSessionRecord`
    /// carries the recognition fields directly.
    @Test func csvPhaseRowEmitsSessionAlignedRecognition() {
        let recordedAt = Date(timeIntervalSince1970: 1_770_000_000)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true,
            score: 0.7, schedulerPriority: 0, condition: .threePhase,
            recordedAt: recordedAt,
            recognition: RecognitionSample(
                predictedLetter: "O", confidence: 0.62, isCorrect: false
            )
        ))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        let isoTs = ISO8601DateFormatter().string(from: recordedAt)
        // Phase row format: letter,phase,completed,score,prio,condition,
        // recordedAt,recognition_predicted,recognition_confidence,
        // recognition_correct,formAccuracy,tempoConsistency,pressureControl,rhythmScore
        #expect(csv.contains("A,freeWrite,true,0.7000,0.0000,threePhase,\(isoTs),O,0.6200,false,,,,"),
                "Expected session-aligned recognition + timestamp — found:\n\(csv)")
    }

    /// Phase rows without a recognition sample (guided / observe / direct,
    /// or freeWrite that fired before the recogniser returned) still emit
    /// blanks for the recognition columns — but `recordedAt` is always
    /// populated for new records.
    @Test func csvPhaseRowBlankRecognitionWhenNoneRecorded() {
        let recordedAt = Date(timeIntervalSince1970: 1_770_000_000)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "C", phase: "guided", completed: true,
            score: 0.5, schedulerPriority: 0, condition: .threePhase,
            recordedAt: recordedAt
        ))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        let isoTs = ISO8601DateFormatter().string(from: recordedAt)
        #expect(csv.contains("C,guided,true,0.5000,0.0000,threePhase,\(isoTs),,,,,,,"),
                "Expected blank recognition columns + populated recordedAt — found:\n\(csv)")
    }

    // MARK: - D-7: pre-enrolment records are filtered

    /// D-7: any phase-session row recorded before `ParticipantStore.enrolledAt`
    /// is dropped at export time so pilot / sandbox activity doesn't get
    /// silently attributed to the assigned thesis arm.
    @Test func csvFiltersPreEnrolmentRows() {
        let enrolledAt = Date(timeIntervalSince1970: 1_770_000_000)
        let earlier   = enrolledAt.addingTimeInterval(-86_400)
        let later     = enrolledAt.addingTimeInterval( 86_400)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "P", phase: "guided", completed: true,
            score: 0.5, schedulerPriority: 0, condition: .threePhase,
            recordedAt: earlier
        ))
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "Q", phase: "guided", completed: true,
            score: 0.5, schedulerPriority: 0, condition: .threePhase,
            recordedAt: later
        ))
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: enrolledAt), encoding: .utf8)!
        #expect(csv.contains("# enrolledAt="))
        #expect(!csv.contains("P,guided,true"),
                "Pre-enrolment row must be discarded — found:\n\(csv)")
        #expect(csv.contains("Q,guided,true"),
                "Post-enrolment row must survive — found:\n\(csv)")
    }

    /// Legacy rows missing `recordedAt` (pre-D-3) survive the filter so
    /// historical thesis data isn't accidentally erased when an export
    /// runs after the upgrade.
    @Test func csvKeepsLegacyRowsWithoutRecordedAt() {
        let enrolledAt = Date(timeIntervalSince1970: 1_770_000_000)
        var snap = DashboardSnapshot()
        // Decoding a record from a JSON file without `recordedAt`
        // produces nil there. Construct one manually via JSON to mirror
        // the pre-D-3 wire format.
        let legacyJSON = """
        {
          "letter": "L", "phase": "guided", "completed": true,
          "score": 0.5, "schedulerPriority": 0.0, "condition": "threePhase"
        }
        """.data(using: .utf8)!
        let legacy = try! JSONDecoder().decode(PhaseSessionRecord.self, from: legacyJSON)
        snap.phaseSessionRecords.append(legacy)
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: enrolledAt), encoding: .utf8)!
        #expect(csv.contains("L,guided,true"),
                "Legacy row without recordedAt must survive — found:\n\(csv)")
    }

    // MARK: - D-6: speedTrend column on letter-aggregate rows

    @Test func csvLetterAggregateContainsSpeedTrend() {
        var snap = DashboardSnapshot()
        snap.letterStats["A"] = LetterAccuracyStat(letter: "A", accuracySamples: [0.8])
        var prog = LetterProgress()
        prog.speedTrend = [1.2, 1.5, 1.8]
        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: ["A": prog], enrolledAt: nil), encoding: .utf8)!
        #expect(csv.contains("speedTrend"),
                "Expected speedTrend column header")
        #expect(csv.contains("1.2000;1.5000;1.8000"),
                "Expected semicolon-joined speedTrend values — found:\n\(csv)")
    }
}
