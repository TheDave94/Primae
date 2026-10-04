// EnrolmentLogTests.swift
// PrimaeNativeTests
//
// T4 (2026-10-04): the enrolment log's store and its export block. The
// "logged at enrolment, never sealed as a participant" half lives in
// `NewParticipantResetTests.enrolmentIsLoggedApartFromTheArchive`, beside
// the phantom-guard tests it must not undo. Nothing here writes a global.
//
// Mutation checks (flip, confirm RED, restore — read the test count):
//   - enrolmentBlockFollowsTheParticipants: in `combinedDelimitedData`,
//     drop the `if !enrolments.isEmpty { … }` append.
//   - enrolmentsNeverCountAsParticipants: build the filename tag from
//     `participants.count + enrolments.count`.
//   - jsonLogSurvivesARelaunch: skip the `data.write` in
//     `JSONEnrolmentLog.append`.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct EnrolmentLogTests {

    private func record(_ arm: PilotAudioCondition, at seconds: TimeInterval) -> EnrolmentRecord {
        EnrolmentRecord(participantId: UUID(),
                        enrolledAt: Date(timeIntervalSince1970: seconds),
                        audioCondition: arm, trainedSubset: "AFI",
                        protocolRevision: StudyProtocol.revision)
    }

    private func participant() -> ParticipantExportSource {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_100)))
        return ParticipantExportSource(snapshot: snap, participantId: UUID(), progress: [:],
                                       rawTraces: [], enrolledAt: nil)
    }

    @Test("the combined CSV carries the enrolment block after the last participant block")
    func enrolmentBlockFollowsTheParticipants() throws {
        let child = record(.phoneme, at: 1_770_000_000)
        let dropout = record(.silent, at: 1_770_000_050)
        let csv = String(data: ParentDashboardExporter.combinedDelimitedData(
            participants: [participant()], enrolments: [child, dropout], separator: ","),
                         encoding: .utf8)!
        let lines = csv.components(separatedBy: "\n")
        let header = try #require(lines.firstIndex { $0.hasPrefix("enrolment_participantId,") },
                                  "no enrolment block in the combined export")
        #expect(lines[header] == "enrolment_participantId,enrolledAt,audioCondition,trainedSubset,protocolRevision")
        let rows = Array(lines[(header + 1)...]).filter { !$0.isEmpty }
        #expect(rows.count == 2, "one row per enrolment: \(rows)")
        #expect(rows.last?.hasPrefix(dropout.participantId.uuidString) == true)
        #expect(rows.last?.hasSuffix(",silent,AFI,\(StudyProtocol.revision)") == true,
                "the dropout's arm, subset and revision must be on its row: \(rows.last ?? "")")
        // The participant blocks come first and are not renamed.
        let firstPhaseHeader = try #require(lines.firstIndex { $0.hasPrefix("letter,phase,completed") })
        #expect(firstPhaseHeader < header)
        #expect(!csv.contains("next participant ====") ,
                "one participant must stay one block — the enrolment separator is not a participant separator")
    }

    @Test("no enrolments, no block: the combined export is byte-identical to before")
    func noEnrolmentsLeavesTheExportUnchanged() {
        let p = participant()
        let without = ParentDashboardExporter.combinedDelimitedData(participants: [p], separator: ",")
        let withEmpty = ParentDashboardExporter.combinedDelimitedData(participants: [p], enrolments: [],
                                                                      separator: ",")
        #expect(without == withEmpty)
    }

    @Test("enrolments never count as participants in the file's N")
    func enrolmentsNeverCountAsParticipants() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrolment-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ParentDashboardExporter.combinedExportFileURL(
            participants: [participant()],
            enrolments: [record(.phoneme, at: 1), record(.spatial, at: 2), record(.silent, at: 3)],
            format: .csv, tempDirectory: dir)
        #expect(url.lastPathComponent.hasSuffix("_all1.csv"),
                "three enrolments, one participant with data — N is 1: \(url.lastPathComponent)")
    }

    @Test("the on-disk log survives a relaunch, oldest enrolment first")
    func jsonLogSurvivesARelaunch() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("enrolments-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let later = record(.spatial, at: 200)
        let earlier = record(.phoneme, at: 100)
        let log = JSONEnrolmentLog(directoryURL: dir)
        log.append(later)
        log.append(earlier)
        await log.flush()

        let reloaded = JSONEnrolmentLog(directoryURL: dir)
        #expect(reloaded.enrolments == [earlier, later])
    }
}
