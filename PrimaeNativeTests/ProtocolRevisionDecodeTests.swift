// ProtocolRevisionDecodeTests.swift
// PrimaeNativeTests
//
// B-20 (audit 2026-11-01, B-tracing.md:35). `PhaseSessionRecord.init(from:)`
// decoded `protocolRevision` with `try?`, so a value that was PRESENT but
// undecodable became nil — the same nil an r1-r3 row carries because the
// field did not exist yet. The exporter reads nil as revision 0
// (`(rec.protocolRevision ?? 0) <= derivedPostTestLastRevision`), so a
// post-r12 row with a damaged revision was tagged as a derived post-test.
//
// The fix: ABSENT (or null) stays the legitimate pre-r4 nil; PRESENT but
// undecodable throws, so the row is dropped by `LossyArray`, counted in the
// `StoreDecodeTally`, the original file is preserved and the proctor sees
// the notice — the path every other undecodable study row already takes.
//
// Every test works on its own temporary directory and a private failure
// center; none touches UserDefaults.
//
// MUTATION CHECKS (run with a SUITE-level `-only-testing:` filter and read
// "Test run with N tests" every time — a function-level filter reports
// success having run nothing):
//   PrimaeNative/Core/ParentDashboardStore.swift, PhaseSessionRecord
//   `init(from:)`: replace
//     `try c.decodeIfPresent(Int.self, forKey: .protocolRevision)`
//   with
//     `try? c.decode(Int.self, forKey: .protocolRevision)`
//   → `presentButUndecodableRevisionIsNotAnAbsentOne`,
//     `aDamagedRevisionRowIsDroppedAndListedNotKeptAsPreR12` and
//     `aDamagedRevisionNeverEarnsADerivedPostTestTag` go RED.
//   (`absentOrNullRevisionStaysNil` stays green: it pins the other side.)

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct ProtocolRevisionDecodeTests {

    /// The five required keys of a phase row.
    private static let base = #""letter":"A","phase":"freeWrite","completed":true,"score":0.5,"schedulerPriority":0"#

    private func decodeRow(extra: String) throws -> PhaseSessionRecord {
        let json = "{\(Self.base)\(extra.isEmpty ? "" : "," + extra)}"
        return try StoreCoding.decoder().decode(PhaseSessionRecord.self, from: Data(json.utf8))
    }

    @Test("an absent or null revision is the legitimate pre-r4 nil")
    func absentOrNullRevisionStaysNil() throws {
        #expect(try decodeRow(extra: "").protocolRevision == nil)
        #expect(try decodeRow(extra: #""protocolRevision":null"#).protocolRevision == nil)
        #expect(try decodeRow(extra: #""protocolRevision":12"#).protocolRevision == 12)
    }

    @Test("a PRESENT but undecodable revision is not turned into the absent one")
    func presentButUndecodableRevisionIsNotAnAbsentOne() {
        for damaged in [#""protocolRevision":"12""#, #""protocolRevision":12.5"#,
                        #""protocolRevision":true"#, #""protocolRevision":{}"#] {
            #expect(throws: (any Error).self, "\(damaged) must not decode to a row") {
                try decodeRow(extra: damaged)
            }
        }
    }

    // MARK: Through the store, on disk

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("B20-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A snapshot file with one row per entry of `rows` (each the extra
    /// members of a phase row; letter, phase and the rest are fixed).
    private func writeSnapshot(rows: [(letter: String, extra: String)], to url: URL) throws {
        let encoded = rows.map { row in
            #"{"letter":"\#(row.letter)","phase":"freeWrite","completed":true,"score":0.5,"schedulerPriority":0,"trainedSubset":"AFI"\#(row.extra.isEmpty ? "" : "," + row.extra)}"#
        }.joined(separator: ",")
        let text = #"{"letterStats":{},"sessionDurations":[],"phaseSessionRecords":[\#(encoded)],"schemaVersion":1}"#
        try Data(text.utf8).write(to: url)
    }

    @Test("a row with a damaged revision is dropped and listed, not kept as pre-r12")
    func aDamagedRevisionRowIsDroppedAndListedNotKeptAsPreR12() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dashboard.json")
        try writeSnapshot(rows: [("A", ""),                                // r1-r3: no field
                                 ("F", #""protocolRevision":"12""#),       // damaged
                                 ("I", #""protocolRevision":12"#)], to: url)

        let center = PersistenceFailureCenter()
        let store = JSONParentDashboardStore(fileURL: url, failureCenter: center)

        #expect(store.snapshot.phaseSessionRecords.map(\.letter) == ["A", "I"],
                "the damaged row must not survive as a row of unknown revision")
        #expect(store.snapshot.phaseSessionRecords.first { $0.letter == "A" }?.protocolRevision == nil,
                "an absent field stays nil — it is not back-filled")
        #expect(store.snapshot.phaseSessionRecords.first { $0.letter == "I" }?.protocolRevision == 12)
        #expect(center.notices.count == 1 && center.notices[0].contains("1 × phaseSessionRecords"),
                "the dropped row must be counted and listed for the proctor: \(center.notices)")
        #expect(center.notices.first?.contains("original copied to") == true
                    && center.notices.first?.contains("copy FAILED") == false,
                "the original bytes must be preserved: \(center.notices)")
    }

    /// The consequence the audit named: with the damaged value read as
    /// nil, the exporter treated a post-r12 final freeWrite as pre-r12 and
    /// tagged it as a derived post-test.
    @Test("a damaged revision never earns a derived post-test tag in the export")
    func aDamagedRevisionNeverEarnsADerivedPostTestTag() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dashboard.json")
        try writeSnapshot(rows: [("A", ""),                                // legit pre-r12: still derived
                                 ("F", #""protocolRevision":"12""#),       // damaged: must NOT be tagged
                                 ("I", #""protocolRevision":12"#)], to: url)
        let store = JSONParentDashboardStore(fileURL: url, failureCenter: PersistenceFailureCenter())

        let text = String(data: ParentDashboardExporter.csvData(
            from: store.snapshot, participantId: UUID(), progress: [:], enrolledAt: nil), encoding: .utf8)!
        let block = try #require(DelimitedExport.block(in: text, headerPrefix: "letter,phase,completed"))
        let letters = block.rows.indices.compactMap { block.value("letter", row: $0) }
        let probes = Dictionary(uniqueKeysWithValues: block.rows.indices.map {
            (block.value("letter", row: $0) ?? "?", block.value("probe", row: $0) ?? "?") })

        #expect(letters.sorted() == ["A", "I"], "the damaged row is not exported as a study row: \(letters)")
        #expect(probes["A"] == "posttest", "an absent revision keeps the r1-r11 derived tag: \(probes)")
        #expect(probes["I"] == "", "an r12 row is never tagged: \(probes)")
        #expect(probes["F"] == nil, "the damaged row must not be exported (let alone tagged): \(probes)")
    }
}
