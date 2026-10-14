// RowIdentityExportTests.swift
// R-123 (audit 2026-10-13, D1-14/15/16), additive half only: every phase
// row and every duration row names its participant and carries a row id
// minted by the store, the duration rows carry the phase rows' stamps
// (trained set, comparison stamp, protocol revision), and every field of
// every block goes through RFC 4180 quoting. The `strokeOrder` separator
// change is D4 and is NOT here.
//
// Round trip: row written → store file → reloaded store → exported CSV /
// JSON carries the value; a file written before the fields existed still
// decodes, and its rows export with empty cells in the same columns.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct RowIdentityExportTests {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("rowid-\(UUID().uuidString).json")
    }

    private func recordRow(_ store: ParentDashboardStoring, phase: String, letter: String = "A") {
        store.recordPhaseSession(
            letter: letter, phase: phase, completed: true, score: 0.5, schedulerPriority: 0,
            condition: .threePhase, audioCondition: .phoneme, assessment: nil, recognition: nil,
            inputDevice: "finger", rawTraceID: nil, trainedSubset: "AFI", phaseDurationSeconds: nil,
            frechetDistance: nil, checkpointCoverage: nil, spatialDeviation: nil, strokeCount: nil,
            strokeOrder: nil, reversedStrokeCount: nil, studyMode: true, probe: nil,
            comparisonConfiguration: nil, spatialDeviationRaw: nil, context: PhaseRowContext())
    }

    private func csv(_ snapshot: DashboardSnapshot, _ pid: UUID) -> String {
        String(data: ParentDashboardExporter.csvData(from: snapshot, participantId: pid,
                                                     progress: [:], enrolledAt: nil),
               encoding: .utf8)!
    }

    @Test("R-123: every phase row names its participant and carries a store-minted row id, across the disk")
    func phaseRowsCarryParticipantAndRowId() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONParentDashboardStore(fileURL: url)
        recordRow(store, phase: "guided")
        recordRow(store, phase: "freeWrite")
        await store.flush()

        let reloaded = JSONParentDashboardStore(fileURL: url)
        let records = reloaded.snapshot.phaseSessionRecords
        try #require(records.count == 2)
        let ids = records.compactMap(\.rowId)
        #expect(ids.count == 2, "a row without an id: \(records.map(\.rowId))")
        #expect(Set(ids).count == 2, "two rows share an id")

        let pid = UUID()
        let block = try #require(DelimitedExport.block(in: csv(reloaded.snapshot, pid), headerPrefix: "letter,phase,completed"))
        try #require(block.rows.count == 2)
        for (i, rec) in records.enumerated() {
            #expect(block.value("participantId", row: i) == pid.uuidString,
                    "row \(i) does not name its participant: \(block.header.suffix(4))")
            #expect(block.value("rowId", row: i) == rec.rowId?.uuidString)
        }
        // Appended LAST: the legacy columns keep their positions.
        let legacyEnd = try #require(block.header.firstIndex(of: "spatialDeviationRaw"))
        #expect(Array(block.header.dropFirst(legacyEnd + 1).prefix(2)) == ["participantId", "rowId"])

        let json = String(data: try ParentDashboardExporter.jsonData(
            from: reloaded.snapshot, participantId: pid, progress: [:], enrolledAt: nil), encoding: .utf8)!
        for id in ids { #expect(json.contains(id.uuidString), "JSON lost row id \(id)") }
    }

    @Test("R-123: a duration row carries participant, row id, trained set, comparison stamp and revision")
    func durationRowsCarryTheStamps() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONParentDashboardStore(fileURL: url)
        store.recordSession(letter: "A", accuracy: 0.5, durationSeconds: 12, wallClockSeconds: 15,
                            date: Date(), condition: .threePhase, inputDevice: "finger",
                            audioCondition: .spatial, studyMode: true, probe: nil,
                            trainedSubset: "AFI", comparisonConfiguration: "allFiveLetters")
        await store.flush()
        let reloaded = JSONParentDashboardStore(fileURL: url)
        let rec = try #require(reloaded.snapshot.sessionDurations.first)
        let rowId = try #require(rec.rowId, "the store minted no row id")

        let pid = UUID()
        let block = try #require(DelimitedExport.block(in: csv(reloaded.snapshot, pid), headerPrefix: "date,recordedAt,durationSeconds"))
        #expect(block.value("participantId") == pid.uuidString)
        #expect(block.value("rowId") == rowId.uuidString)
        #expect(block.value("trainedSubset") == "AFI")
        #expect(block.value("comparisonConfiguration") == "allFiveLetters")
        #expect(block.value("protocolRevision") == String(StudyProtocol.revision))
        #expect(block.header.firstIndex(of: "probe").flatMap { block.header.dropFirst($0 + 1).first } == "participantId",
                "the new duration columns must follow the legacy ones")
    }

    @Test("R-123: the letter session's duration row is stamped by the view model")
    func completionStampsTheDurationRow() async throws {
        let store = DeliveryRowStore()
        var deps = TracingDependencies.stub
        deps.thesisCondition = .threePhase
        deps.dashboardStore = store
        deps.letterRecognizer = StubLetterRecognizer.alwaysReturn(predicted: "A", confidence: 0.9, isCorrect: true)
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 400, height: 400)
        vm.phaseController.advance(score: 1.0)
        vm.phaseController.advance(score: 0.8)
        vm.freeWriteRecorder.startSession(now: 100.0)
        for i in 0...18 {
            vm.freeWriteRecorder.record(point: CGPoint(x: 20 + Double(i) * 20, y: 200),
                                        timestamp: 100.0 + Double(i) * 0.1, force: 0.5,
                                        canvasSize: vm.canvasSize)
        }
        vm.advanceLearningPhase()
        for _ in 0..<200 where store.durations.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        let d = try #require(store.durations.first, "no duration row")
        #expect(d.trainedSubset == vm.effectiveTrainedSubset.rawValue,
                "the duration row lost the trained set: \(String(describing: d.trainedSubset))")
    }

    @Test("R-123: a store file written before the fields existed decodes, and exports empty cells in the same columns")
    func oldFileDecodesWithEmptyCells() throws {
        let old = """
        {"letterStats":{},"sessionDurations":[{"dateString":"2026-10-01","durationSeconds":12.5,"condition":"threePhase","recordedAt":781000000,"letter":"A","audioCondition":"phoneme","studyMode":true}],
         "phaseSessionRecords":[{"letter":"A","phase":"freeWrite","completed":true,"score":0.5,"schedulerPriority":0,"condition":"threePhase","audioCondition":"phoneme","recordedAt":781000000,"protocolRevision":6}]}
        """
        let snap = try StoreCoding.decoder().decode(DashboardSnapshot.self, from: Data(old.utf8))
        let rec = try #require(snap.phaseSessionRecords.first)
        #expect(rec.rowId == nil && rec.finalizedBy == nil && rec.delivery == nil && rec.probeAttempt == nil)
        let dur = try #require(snap.sessionDurations.first)
        #expect(dur.rowId == nil && dur.trainedSubset == nil && dur.comparisonConfiguration == nil)
        #expect(dur.protocolRevision == nil, "an old duration row must not be back-filled with this build's revision")

        let text = csv(snap, UUID())
        let phase = try #require(DelimitedExport.block(in: text, headerPrefix: "letter,phase,completed"))
        #expect(phase.rows.first?.count == phase.header.count, "row and header disagree on the column count")
        #expect(phase.value("rowId") == "")
        let durations = try #require(DelimitedExport.block(in: text, headerPrefix: "date,recordedAt,durationSeconds"))
        #expect(durations.rows.first?.count == durations.header.count)
        #expect(durations.value("protocolRevision") == "")
    }

    @Test("R-123: duration and letter fields are RFC 4180 quoted like the phase rows")
    func everyBlockIsQuoted() throws {
        var snap = DashboardSnapshot()
        snap.sessionDurations.append(SessionDurationRecord(
            dateString: "2026-10-01", durationSeconds: 3, recordedAt: Date(), inputDevice: "fin,ger",
            letter: "A,B"))
        let text = csv(snap, UUID())
        let durations = try #require(DelimitedExport.block(in: text, headerPrefix: "date,recordedAt,durationSeconds"))
        #expect(durations.rows.first?.count == durations.header.count,
                "an unquoted comma split a duration field: \(durations.rows.first ?? [])")
        #expect(durations.value("letter") == "A,B")
        #expect(durations.value("inputDevice") == "fin,ger")
    }
}
