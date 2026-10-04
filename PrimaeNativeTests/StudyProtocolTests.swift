// StudyProtocolTests.swift
// PrimaeNativeTests
//
// Pins `StudyProtocol` (2026-10-04): the hand-bumped revision of the
// child-facing protocol, stamped on every phase row at creation and
// exported as the LAST column. Nothing here writes a global.
//
// Mutation checks (flip, confirm RED, restore — and read the test count
// out of the log, CLAUDE.md "Test Infrastructure" 5):
//   - historyIsContiguousAndEndsAtRevision: set `StudyProtocol.revision`
//     to 5 without appending a history row.
//   - storeStampsCurrentRevisionAtCreation: delete
//     `self.protocolRevision = protocolRevision` in
//     `PhaseSessionRecord.init`.
//   - exportCarriesRevisionAsLastColumn: drop `"protocolRevision"` from
//     the exporter's header array.
//   - legacyRowDecodesRevisionAsNil: change the decode to
//     `(try? c.decode(Int.self, forKey: .protocolRevision)) ?? StudyProtocol.revision`.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct StudyProtocolTests {

    @Test("history revisions are contiguous from 1 and the last one is `revision`")
    func historyIsContiguousAndEndsAtRevision() {
        let revisions = StudyProtocol.history.map(\.revision)
        #expect(revisions == Array(1...revisions.count),
                "history must number its revisions 1, 2, 3, … with no gap or repeat: \(revisions)")
        #expect(StudyProtocol.history.last?.revision == StudyProtocol.revision,
                "`revision` was bumped without a history row, or a row was added without bumping it")
    }

    @Test("every merged revision names its PR and its merge time")
    func mergedRevisionsAreDated() {
        // Only the newest revision may still be unmerged.
        for entry in StudyProtocol.history.dropLast() {
            #expect(entry.mergedAtUTC != nil && entry.pullRequest != nil,
                    "revision \(entry.revision) is not the newest but has no merge date or PR")
        }
    }

    @Test("a phase row written through the store carries the current revision")
    func storeStampsCurrentRevisionAtCreation() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudyProtocol-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONParentDashboardStore(fileURL: url)
        store.recordPhaseSession(letter: "A", phase: "freeWrite", completed: true,
                                 score: 0.5, schedulerPriority: 0,
                                 condition: .threePhase, audioCondition: .silent)
        let row = try #require(store.snapshot.phaseSessionRecords.last)
        #expect(row.protocolRevision == StudyProtocol.revision,
                "the row was not stamped with the revision that wrote it")

        // And it survives the store's own round trip to disk. `persist()`
        // writes in a detached task, so the store's own contract is to
        // `flush()` before another instance reads the file
        // (`ParentDashboardStore.flush`). Without the await this raced the
        // disk write, the reload found NO file, and the missing ROW
        // surfaced as "protocolRevision nil" through the optional chain.
        // The #require below keeps "row missing" and "field missing"
        // apart, so the conflation cannot come back with it.
        await store.flush()
        let reloaded = JSONParentDashboardStore(fileURL: url)
        let reread = try #require(reloaded.snapshot.phaseSessionRecords.last,
                                   "the reloaded store lost the row entirely — the disk write never landed")
        #expect(reread.protocolRevision == StudyProtocol.revision)
    }

    @Test("the export carries protocolRevision as the LAST column, from the record")
    func exportCarriesRevisionAsLastColumn() throws {
        var snap = DashboardSnapshot()
        // A current row, and a row as a pre-revision build wrote it.
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_000)))
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "F", phase: "freeWrite", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_001),
            protocolRevision: nil))

        let csv = String(data: ParentDashboardExporter.csvData(
            from: snap, progress: [:], enrolledAt: nil), encoding: .utf8)!
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = try #require(lines.first { $0.hasPrefix("letter,phase,completed") })
        let names = header.components(separatedBy: ",")
        #expect(names.last == "protocolRevision", "Header: \(header)")
        #expect(names.dropLast().last == "comparisonConfiguration",
                "protocolRevision must be appended after the previous last column, not inserted")

        func lastField(_ prefix: String) throws -> String {
            let row = try #require(lines.first { $0.hasPrefix(prefix) })
            let fields = row.components(separatedBy: ",")
            #expect(fields.count == names.count, "row and header out of alignment:\n\(row)")
            return fields.last ?? "<none>"
        }
        #expect(try lastField("A,freeWrite") == String(StudyProtocol.revision))
        #expect(try lastField("F,freeWrite") == "",
                "a pre-revision row must export EMPTY, never the current revision")
    }

    @Test("a legacy row decodes protocolRevision as nil, not the current revision")
    func legacyRowDecodesRevisionAsNil() throws {
        let legacy = """
        {"letter":"A","phase":"freeWrite","completed":true,"score":0.5,
         "schedulerPriority":0.1,"condition":"threePhase"}
        """.data(using: .utf8)!
        let rec = try JSONDecoder().decode(PhaseSessionRecord.self, from: legacy)
        #expect(rec.protocolRevision == nil,
                "a row written before the field existed was re-stamped on decode")
    }
}
