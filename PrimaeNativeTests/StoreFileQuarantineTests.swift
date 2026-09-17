// StoreFileQuarantineTests.swift
// PrimaeNativeTests
//
// 2026-09-17: `StoreFileQuarantine` and `LossyArray` had NO direct test
// coverage, despite being the only thing between a partly undecodable
// store file and the next atomic save. Five stores route through them —
// ProgressStore:403, ParentDashboardStore:415/424/896/905,
// RawTraceStore:142/153, ParticipantArchiveStore:141, StreakStore:240 —
// and the failure mode is silent: the study's phase records or raw
// traces replaced by an empty store, or every row after one malformed
// row dropped. The 2026-09-04 audit found the data-loss defect these
// helpers exist to prevent; nothing has pinned the helpers themselves
// since.
//
// StreakStoreTests already covers ONE end-to-end case (a corrupt
// StreakStore file ends up moved aside rather than overwritten). These
// tests pin the helper's own contract — byte preservation, no collision
// between two quarantines, and the element-wise decoder's
// advance/termination behaviour — which is where a regression would be
// invisible from the store level, because a store that drops rows and a
// store that never had them look identical from the outside.
//
// Everything runs in a per-test temporary directory created and removed
// here. No UserDefaults, no singleton, no shared path — Swift Testing
// runs suites in parallel and global state is not this suite's to move.

import Testing
import Foundation
@testable import PrimaeNative

/// A row shaped like the study records `LossyArray` is used on: two
/// required fields, so a missing key, a wrong type and a null each fail
/// through a different DecodingError path.
private struct QuarantineRow: Decodable, Equatable {
    let id: Int
    let letter: String
}

@Suite @MainActor struct StoreFileQuarantineTests {

    // MARK: - Scaffolding

    /// What an undecodable store file actually looks like: structurally
    /// broken JSON (trailing comma), carrying an umlaut — i.e. bytes that
    /// must survive the round trip unmangled, because a re-encode is
    /// exactly what the quarantine exists to avoid.
    private let undecodableProgress = #"{"schemaVersion":1,"letters":{"Ä":{"completionCount":3,}}}"#

    private func withTempDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreFileQuarantineTests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func contents(of url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    private func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func decode<Element: Decodable>(_ type: LossyArray<Element>.Type,
                                            from json: String) throws -> LossyArray<Element> {
        try JSONDecoder().decode(LossyArray<Element>.self, from: Data(json.utf8))
    }

    // MARK: - quarantine

    @Test("quarantine moves the undecodable file aside, byte for byte, and leaves nothing at the original path")
    func quarantineMovesAsideAndKeepsEveryByte() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("progress.json")
            try write(undecodableProgress, to: url)

            let dest = try #require(StoreFileQuarantine.quarantine(url),
                                    "an existing, writable store file must be quarantined, not dropped")

            #expect(!FileManager.default.fileExists(atPath: url.path),
                    "the undecodable file must no longer sit where the next atomic save writes — that overwrite is the data loss this helper prevents")
            #expect(dest.path != url.path)
            #expect(dest.deletingLastPathComponent().path == dir.path,
                    "the recovered copy belongs beside the original, where the device-extraction path looks for it")
            #expect(dest.pathExtension == "json",
                    "the recovered file must keep its extension or it cannot be opened as JSON on recovery")
            #expect(dest.lastPathComponent.hasPrefix("progress.undecodable-"),
                    "recovery naming is <stem>.undecodable-<stamp>.<ext>; got \(dest.lastPathComponent)")

            let preserved = try contents(of: dest)
            #expect(preserved == undecodableProgress,
                    "the quarantined file must hold the ORIGINAL bytes — re-encoding it would discard exactly what is being preserved")
        }
    }

    @Test("quarantine reports failure (nil) rather than throwing when there is nothing to move")
    func quarantineOfAMissingFileReturnsNil() throws {
        try withTempDirectory { dir in
            let missing = dir.appendingPathComponent("never-written.json")
            #expect(StoreFileQuarantine.quarantine(missing) == nil,
                    "a store file that does not exist is the ordinary first-launch case and must not crash the load path")
            let left = try names(in: dir)
            #expect(left.isEmpty, "a failed quarantine must not leave a stray file behind; got \(left)")
        }
    }

    @Test("two store files quarantined in the same second get their own copies — neither overwrites the other")
    func twoStoreFilesQuarantinedTogetherDoNotCollide() throws {
        try withTempDirectory { dir in
            // Five stores share this helper and any of them can fail its
            // load in the same instant; the whole point is that each
            // store's evidence survives.
            let progress = dir.appendingPathComponent("progress.json")
            let dashboard = dir.appendingPathComponent("dashboard.json")
            let traces = dir.appendingPathComponent("raw_traces.json")
            try write("progress payload", to: progress)
            try write("dashboard payload", to: dashboard)
            try write("trace payload", to: traces)

            let p = try #require(StoreFileQuarantine.quarantine(progress))
            let d = try #require(StoreFileQuarantine.quarantine(dashboard))
            let t = try #require(StoreFileQuarantine.quarantine(traces))

            #expect(Set([p, d, t]).count == 3, "each quarantined file needs its own destination")
            let kept = try names(in: dir).sorted()
            #expect(kept.count == 3, "nothing extra and nothing missing; got \(kept)")

            let keptProgress = try contents(of: p)
            let keptDashboard = try contents(of: d)
            let keptTraces = try contents(of: t)
            #expect(keptProgress == "progress payload")
            #expect(keptDashboard == "dashboard payload")
            #expect(keptTraces == "trace payload")
        }
    }

    // MARK: - preserveCopy

    @Test("preserveCopy leaves the live file running AND keeps a byte-identical copy beside it")
    func preserveCopyKeepsTheOriginalInPlace() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("dashboard.json")
            try write(undecodableProgress, to: url)

            let copy = try #require(StoreFileQuarantine.preserveCopy(url),
                                    "a partly undecodable file must be copied aside")

            #expect(FileManager.default.fileExists(atPath: url.path),
                    "preserveCopy is for a file that decoded well enough to keep running from — the live file must stay")
            let live = try contents(of: url)
            #expect(live == undecodableProgress, "the live file must be untouched")

            #expect(copy.path != url.path)
            #expect(copy.deletingLastPathComponent().path == dir.path)
            #expect(copy.pathExtension == "json")
            #expect(copy.lastPathComponent.hasPrefix("dashboard.undecodable-"),
                    "recovery naming is <stem>.undecodable-<stamp>.<ext>; got \(copy.lastPathComponent)")
            let preserved = try contents(of: copy)
            #expect(preserved == undecodableProgress,
                    "the copy must be the bytes that were on disk, not a re-encode of what the decoder could salvage")
            let after = try names(in: dir)
            #expect(after.count == 2,
                    "exactly one extra file: the live store file plus its preserved copy; got \(after)")
        }
    }

    @Test("preserveCopy reports failure (nil) rather than throwing when the source is missing")
    func preserveCopyOfAMissingFileReturnsNil() throws {
        try withTempDirectory { dir in
            let missing = dir.appendingPathComponent("never-written.json")
            #expect(StoreFileQuarantine.preserveCopy(missing) == nil)
            let left = try names(in: dir)
            #expect(left.isEmpty, "a failed preserveCopy must not leave a stray file behind; got \(left)")
        }
    }

    // MARK: - LossyArray

    @Test("all elements good: every row is kept, in order, and none is reported dropped")
    func lossyArrayKeepsEveryGoodRow() throws {
        let json = #"[{"id":1,"letter":"A"},{"id":2,"letter":"Ä"},{"id":3,"letter":"C"}]"#
        let lossy = try decode(LossyArray<QuarantineRow>.self, from: json)
        #expect(lossy.elements == [QuarantineRow(id: 1, letter: "A"),
                                   QuarantineRow(id: 2, letter: "Ä"),
                                   QuarantineRow(id: 3, letter: "C")],
                "element order is the study's chronological order — it must survive decoding")
        #expect(lossy.droppedCount == 0)
    }

    @Test("a malformed FIRST element does not spin the decode loop, and the rows behind it survive")
    func lossyArrayDoesNotSpinOnAMalformedFirstElement() throws {
        // This is the hang case, and it is a hang rather than a failure
        // because JSONDecoder does NOT advance an unkeyed container's
        // cursor when an element fails to decode: a loop that only
        // advances on success re-reads the same bad element forever.
        // Getting rows 2 and 3 out at all proves the bad element was
        // consumed; a loop that merely gave up would return [].
        let json = #"[{"id":"one","letter":"A"},{"id":2,"letter":"B"},{"id":3,"letter":"C"}]"#
        let lossy = try decode(LossyArray<QuarantineRow>.self, from: json)
        #expect(lossy.elements.map(\.id) == [2, 3],
                "the two good rows after a bad first row are the whole point of LossyArray; got \(lossy.elements.map(\.id))")
        #expect(lossy.droppedCount == 1)
    }

    @Test("a malformed LAST element costs only itself")
    func lossyArrayDropsOnlyTheLastBadRow() throws {
        let json = #"[{"id":1,"letter":"A"},{"id":2,"letter":"B"},{"id":3}]"#
        let lossy = try decode(LossyArray<QuarantineRow>.self, from: json)
        #expect(lossy.elements.map(\.id) == [1, 2])
        #expect(lossy.droppedCount == 1)
    }

    @Test("a malformed row in the MIDDLE costs only itself — the rows before and after both survive")
    func lossyArrayDropsOnlyTheBadRowInTheMiddle() throws {
        // The realistic corruption: a row whose nested payload is the
        // wrong shape (the case RawTraceStore's traces hit).
        let json = #"[{"id":1,"letter":"A"},{"id":2,"letter":{"nested":true}},{"id":3,"letter":"C"}]"#
        let lossy = try decode(LossyArray<QuarantineRow>.self, from: json)
        #expect(lossy.elements.map(\.id) == [1, 3],
                "a bad row in the middle must not truncate the array — that would silently cost every later study row")
        #expect(lossy.droppedCount == 1)
    }

    @Test("a wrong-typed element (type mismatch, not a missing key) is dropped and the rest survive")
    func lossyArrayDropsWrongTypedElement() throws {
        let json = #"[{"id":1,"letter":"A"},{"id":true,"letter":"B"},{"id":3,"letter":"C"}]"#
        let lossy = try decode(LossyArray<QuarantineRow>.self, from: json)
        #expect(lossy.elements.map(\.id) == [1, 3])
        #expect(lossy.droppedCount == 1)
    }

    @Test("a JSON null element is dropped and the rest survive")
    func lossyArrayDropsNullElement() throws {
        let json = #"[{"id":1,"letter":"A"},null,{"id":3,"letter":"C"}]"#
        let lossy = try decode(LossyArray<QuarantineRow>.self, from: json)
        #expect(lossy.elements.map(\.id) == [1, 3],
                "a null row is dropped like any other bad row; the rows around it are study data and must be kept")
        #expect(lossy.droppedCount == 1)
    }

    @Test("a nested ARRAY where a row was expected is dropped and the rest survive")
    func lossyArrayDropsNestedContainerElement() throws {
        // The failure at container level rather than field level: a
        // regression in the skip path would take every later row with it
        // here, so this is the case that would expose it.
        let json = #"[{"id":1,"letter":"A"},[1,2,3],{"id":3,"letter":"C"}]"#
        let lossy = try decode(LossyArray<QuarantineRow>.self, from: json)
        #expect(lossy.elements.map(\.id) == [1, 3])
        #expect(lossy.droppedCount == 1)
    }

    @Test("every element malformed: nothing is kept, everything is counted, and decoding terminates")
    func lossyArrayAllBadTerminates() throws {
        let json = #"[{"letter":"A"},{"letter":"B"},{"letter":"C"}]"#
        let lossy = try decode(LossyArray<QuarantineRow>.self, from: json)
        #expect(lossy.elements.isEmpty)
        #expect(lossy.droppedCount == 3,
                "the drop count is what the store logs to make the loss visible; got \(lossy.droppedCount)")
    }

    @Test("an empty array decodes to no elements and no drops")
    func lossyArrayEmptyArray() throws {
        let lossy = try decode(LossyArray<QuarantineRow>.self, from: "[]")
        #expect(lossy.elements.isEmpty)
        #expect(lossy.droppedCount == 0)
    }

    @Test("a typed, nested element: one bad inner array costs only that element")
    func lossyArrayOfNestedArraysDropsOnlyTheBadOne() throws {
        // Element is itself a collection — a failure part-way through an
        // inner array must not cost the elements around it.
        let json = #"[[1,2],[3,"x"],[4,5]]"#
        let lossy = try decode(LossyArray<[Int]>.self, from: json)
        #expect(lossy.elements == [[1, 2], [4, 5]])
        #expect(lossy.droppedCount == 1)
    }

    @Test("a file that is not an array at all THROWS — it must not read as a valid empty store")
    func lossyArrayNonArrayThrows() throws {
        // The stores branch on this: a throw is what routes the file to
        // quarantine. If a dict-shaped or truncated file decoded as an
        // empty array instead, the store would come up empty, log
        // nothing, and overwrite the evidence on its next save — the
        // exact 2026-09-04 defect.
        #expect(throws: (any Error).self) {
            _ = try decode(LossyArray<QuarantineRow>.self, from: #"{"rows":[]}"#)
        }
        #expect(throws: (any Error).self) {
            _ = try decode(LossyArray<QuarantineRow>.self, from: #"[{"id":1,"letter":"A"},"#)
        }
        #expect(throws: (any Error).self) {
            _ = try decode(LossyArray<QuarantineRow>.self, from: #"42"#)
        }
    }
}
