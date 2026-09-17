// CalibrationSessionLoggerTests.swift
// PrimaeNativeTests
//
// 2026-09-17: `CalibrationSessionLogger` had NO test coverage. It is the
// only producer of the correction-pattern corpus (pre/post polyline pairs
// from every SKELETT/ANKER save), and every one of its failure paths is
// `try?`-and-swallow BY DESIGN: a broken path, a letter spelled the other
// way, or a save that collides with another save produces no corpus and
// no error the caller can see. The header documents the incident this is
// meant to prevent — an NFC/NFD split that put the same letter's captures
// in two sibling directories and hid ä/ö/ü sessions in the 2026-05-22
// batch-2 upload.
//
// The logger has no injection seam, so these tests drive the real
// `log(...)` against the app's own Documents directory and assert on what
// lands there. That is the same trade CalibrationStoreTests makes for
// Application Support. Cleanup removes ONLY the files and directories the
// test itself created — a device running these tests may already hold
// real calibration captures for the same letter, and a unit test must
// never be the thing that deletes the corpus.
//
// TWO SWIFT TRAPS this file had to be built around, both found by running
// it rather than by reading it (each one silently disabled an assertion):
//   1. String literals in source are NFC-normalised at compile time, so a
//      literal "A\u{0308}" IS "\u{00C4}" — a decomposed spelling only
//      exists if it is assembled from scalars while running.
//   2. `String ==` and `Set<String>` are canonical-equivalence based, so
//      any comparison written with `==` passes against the WRONG spelling
//      — the exact difference these tests exist to catch. Everything that
//      distinguishes the two spellings below compares Unicode scalars or
//      UTF-8 bytes.
//   3. A directory does not necessarily read back under the name it was
//      created with (measured: created from an NFC path, listed as
//      U+0041 U+0308), so the folder's spelling is not a sound thing to
//      assert — see the note in logPutsBothSpellingsInOneDirectory.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

/// The on-disk capture schema, mirrored here on purpose: this is the
/// contract the zip-extract / analysis path reads, so a field renamed or
/// dropped in the producer has to fail a test rather than a later
/// analysis.
private struct CapturedSession: Decodable {
    struct Point: Decodable {
        let x: Double
        let y: Double
    }
    let letter: String
    let schriftArt: String
    let timestamp_iso: String
    let pre_polyline: [[Point]]
    let post_polyline: [[Point]]
    let edit_count_in_session: Int
    let tool: String
}

@Suite(.serialized) @MainActor struct CalibrationSessionLoggerTests {

    // MARK: - Scaffolding

    /// One letter's session directory, plus what was already in it. The
    /// pre-existing set is the whole reason this exists: cleanup must be
    /// able to tell "mine" from "the device's".
    private struct LetterScratch {
        let dir: URL
        let preexisting: Set<String>
        /// Every entry in the CalibrationSessions root before the test ran —
        /// the only sound way to say "this test created ONE new letter
        /// directory", because the real device may already hold others.
        /// Byte keys, not strings: a Set<String> folds an NFC and an NFD
        /// spelling into ONE element, which is precisely the difference
        /// being looked for here.
        let rootEntries: Set<[UInt8]>
        let dirExisted: Bool
        let containerExisted: Bool
        let rootExisted: Bool
    }

    /// Built from scalars at RUNTIME, never from a literal: Swift
    /// normalises string literals to NFC at compile time, so a literal
    /// `"A\u{0308}"` in this file IS `"\u{00C4}"` — assembling the
    /// decomposed spelling is the only way to hand the logger a genuinely
    /// NFD letter, which is the whole point of the test below.
    private static let precomposedA = String(UnicodeScalar(0x00C4)!)
    private static let decomposedA = String(UnicodeScalar(0x0041)!) + String(UnicodeScalar(0x0308)!)

    /// The distinction these two tests exist to pin, expressed the only way
    /// Swift can express it. `String ==` is CANONICAL-EQUIVALENCE based, so
    /// `decomposedA == precomposedA` is TRUE and an assertion written with
    /// `==` passes even when the code under test stores the wrong spelling
    /// — a test that cannot fail. Scalar identity is the real question.
    private static func sameScalars(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    private func documents() throws -> URL {
        try #require(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
                     "the document directory is where the logger writes; without it the test proves nothing")
    }

    private func beginScratch(letter: String) throws -> LetterScratch {
        let fm = FileManager.default
        let container = try documents().appendingPathComponent("PrimaeNative")
        let root = container.appendingPathComponent("CalibrationSessions")
        let dir = root.appendingPathComponent(letter)
        let preexisting = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        let rootEntries = Set(((try? fm.contentsOfDirectory(atPath: root.path)) ?? [])
            .map { Array($0.utf8) })
        return LetterScratch(dir: dir,
                             preexisting: preexisting,
                             rootEntries: rootEntries,
                             dirExisted: fm.fileExists(atPath: dir.path),
                             containerExisted: fm.fileExists(atPath: container.path),
                             rootExisted: fm.fileExists(atPath: root.path))
    }

    private func endScratch(_ scratch: LetterScratch) {
        let fm = FileManager.default
        let now = Set((try? fm.contentsOfDirectory(atPath: scratch.dir.path)) ?? [])
        for name in now.subtracting(scratch.preexisting) {
            try? fm.removeItem(at: scratch.dir.appendingPathComponent(name))
        }
        let root = scratch.dir.deletingLastPathComponent()
        let container = root.deletingLastPathComponent()
        // Only directories the test created, and only once empty.
        for (url, existed) in [(scratch.dir, scratch.dirExisted),
                               (root, scratch.rootExisted),
                               (container, scratch.containerExisted)] where !existed {
            let left = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            if left.isEmpty { try? fm.removeItem(at: url) }
        }
    }

    /// Files in this letter's directory that the test put there.
    private func newFiles(_ scratch: LetterScratch) -> [String] {
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: scratch.dir.path)) ?? [])
        return now.subtracting(scratch.preexisting).sorted()
    }

    private func readCapture(at url: URL) throws -> CapturedSession {
        try JSONDecoder().decode(CapturedSession.self, from: Data(contentsOf: url))
    }

    private let prePair: [[CGPoint]] = [[CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.5, y: 0.75)]]
    private let postPair: [[CGPoint]] = [[CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.5, y: 0.75),
                                          CGPoint(x: 0.75, y: 0.25)]]

    // MARK: - Round trip

    @Test("a save writes exactly one capture under <letter>/ and it round-trips the pair and metadata it was given")
    func logWritesOneRoundTrippableCapture() throws {
        let letter = "T\(UUID().uuidString.prefix(8))"
        let scratch = try beginScratch(letter: letter)
        defer { endScratch(scratch) }

        CalibrationSessionLogger.log(pre: prePair, post: postPair, letter: letter,
                                     schriftArt: .druckschrift, editCount: 2, tool: .anker)

        let written = newFiles(scratch)
        #expect(written.count == 1, "one save must produce exactly one capture; got \(written)")
        let name = try #require(written.first)
        #expect(name.hasSuffix(".json"), "the corpus is JSON per session; got \(name)")
        #expect(!name.contains(":"), "the filename must be filesystem-safe — colons are stripped for that reason")

        let capture = try readCapture(at: scratch.dir.appendingPathComponent(name))
        #expect(capture.letter == letter)
        #expect(capture.schriftArt == SchriftArt.druckschrift.rawValue,
                "the script is what the corpus is stratified by; got \(capture.schriftArt)")
        #expect(capture.tool == CalibrationSessionLogger.Tool.anker.rawValue,
                "the tool that made the edit is what the corpus is analysed by; got \(capture.tool)")
        #expect(capture.edit_count_in_session == 2)

        let before = try #require(capture.pre_polyline.first)
        #expect(capture.pre_polyline.count == 1)
        #expect(before.count == 2)
        #expect(abs((before.first?.x ?? -1) - 0.25) < 1e-9)
        #expect(abs((before.last?.y ?? -1) - 0.75) < 1e-9)

        let after = try #require(capture.post_polyline.first)
        #expect(capture.post_polyline.count == 1)
        #expect(after.count == 3, "the saved edit must be in the payload, not just the pre state")
        #expect(abs((after.last?.x ?? -1) - 0.75) < 1e-9)
        #expect(abs((after.last?.y ?? -1) - 0.25) < 1e-9)

        // The timestamp is what orders the corpus; unparseable means a
        // capture that cannot be placed in time.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        #expect(iso.date(from: capture.timestamp_iso) != nil,
                "timestamp_iso must be ISO-8601; got \(capture.timestamp_iso)")
    }

    @Test("a save that changed nothing writes no capture — not even the directory")
    func logWritesNothingWhenPreEqualsPost() throws {
        let letter = "T\(UUID().uuidString.prefix(8))"
        let scratch = try beginScratch(letter: letter)
        defer { endScratch(scratch) }

        CalibrationSessionLogger.log(pre: prePair, post: prePair, letter: letter,
                                     schriftArt: .druckschrift, editCount: 0, tool: .skelett)

        let written = newFiles(scratch)
        #expect(written.isEmpty,
                "an auto-save with no edit must not add a capture — otherwise the corpus fills with empty pairs; got \(written)")
        #expect(!FileManager.default.fileExists(atPath: scratch.dir.path),
                "a no-op save should not even create the directory")
    }

    @Test("the no-op guard is exactly the 4-decimal capture precision: below it nothing is written, above it a capture lands")
    func logNoOpGuardMatchesTheStoredPrecision() throws {
        let letter = "T\(UUID().uuidString.prefix(8))"
        let scratch = try beginScratch(letter: letter)
        defer { endScratch(scratch) }

        // 0.1234561 vs 0.1234564 — a difference four orders of magnitude
        // below the recorded precision, i.e. identical once written.
        let belowPrecision: [[CGPoint]] = [[CGPoint(x: 0.1234561, y: 0.5)]]
        let alsoBelow: [[CGPoint]] = [[CGPoint(x: 0.1234564, y: 0.5)]]
        CalibrationSessionLogger.log(pre: belowPrecision, post: alsoBelow, letter: letter,
                                     schriftArt: .druckschrift, editCount: 0, tool: .skelett)
        #expect(newFiles(scratch).isEmpty,
                "a difference that rounds away is not an edit: the guard compares the rounded values, so no capture should land")

        // ...and the guard must not be degenerate: a difference ABOVE the
        // precision is a real edit and must be captured.
        let abovePrecision: [[CGPoint]] = [[CGPoint(x: 0.1234561, y: 0.5)]]
        let clearlyDifferent: [[CGPoint]] = [[CGPoint(x: 0.1235561, y: 0.5)]]
        CalibrationSessionLogger.log(pre: abovePrecision, post: clearlyDifferent, letter: letter,
                                     schriftArt: .druckschrift, editCount: 1, tool: .skelett)
        let written = newFiles(scratch)
        #expect(written.count == 1,
                "an edit above the capture precision is exactly what this module exists to record; got \(written)")
    }

    // MARK: - Letter normalisation (the documented NFC/NFD incident)

    @Test("a letter passed in NFD is recorded as NFC — the payload the corpus is analysed from")
    func logNormalisesTheLetterInThePayload() throws {
        let nfd = Self.decomposedA
        let nfc = Self.precomposedA
        #expect(nfd.unicodeScalars.count == 2, "precondition: A + combining diaeresis")
        #expect(nfc.unicodeScalars.count == 1, "precondition: the precomposed scalar")
        #expect(!Self.sameScalars(nfd, nfc), "precondition: two genuinely different spellings")

        let scratch = try beginScratch(letter: nfc)
        defer { endScratch(scratch) }

        CalibrationSessionLogger.log(pre: prePair, post: postPair, letter: nfd,
                                     schriftArt: .druckschrift, editCount: 1, tool: .skelett)

        let written = newFiles(scratch)
        #expect(written.count == 1, "the capture must land in the NFC directory; got \(written)")
        let name = try #require(written.first)
        let capture = try readCapture(at: scratch.dir.appendingPathComponent(name))
        #expect(Self.sameScalars(capture.letter, nfc),
                "a capture whose payload says A+combining-diaeresis is a different letter to every consumer downstream; got \(capture.letter.unicodeScalars.map { String(format: "U+%04X", $0.value) })")
    }

    @Test("the NFC and NFD spellings of one letter share ONE directory — not two siblings")
    func logPutsBothSpellingsInOneDirectory() async throws {
        // The documented incident: sibling directories for one letter hid
        // ä/ö/ü captures from the upload path. Asserted at the ROOT of the
        // tree (the entry the filesystem actually created) rather than by
        // probing the NFD path, so the result means the same thing whether
        // or not the volume folds the two spellings together. The two
        // saves are a second apart so their filenames cannot collide (see
        // the known-issue test below for what happens when they do).
        let nfd = Self.decomposedA
        let nfc = Self.precomposedA
        let scratch = try beginScratch(letter: nfc)
        defer { endScratch(scratch) }
        let root = scratch.dir.deletingLastPathComponent()

        CalibrationSessionLogger.log(pre: prePair, post: postPair, letter: nfc,
                                     schriftArt: .druckschrift, editCount: 1, tool: .skelett)
        try await Task.sleep(nanoseconds: 1_050_000_000)
        CalibrationSessionLogger.log(pre: prePair, post: postPair, letter: nfd,
                                     schriftArt: .druckschrift, editCount: 2, tool: .anker)

        let written = newFiles(scratch)
        #expect(written.count == 2,
                "both saves — one spelled NFC, one NFD — belong to this one letter directory; got \(written)")

        let entriesNow = Set(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .map { Array($0.utf8) })
        let newDirs = entriesNow.subtracting(scratch.rootEntries)
        #expect(newDirs.count == 1,
                "the two spellings must not produce two sibling directories — that is the split that hid the ä/ö/ü captures in the 2026-05-22 batch; new entries were \(newDirs.count) of \(entriesNow.count)")

        // Deliberately NOT asserted: the spelling of the directory that
        // came back. Measured on the device this suite runs against, the
        // name read back for a directory the code created from an NFC path
        // is the DECOMPOSED spelling (U+0041 U+0308) — so this listing is
        // reporting the volume's/Foundation's choice, not the logger's, and
        // asserting it would pin an OS behaviour. That measurement is also
        // why the payload check above is the load-bearing one: the `letter`
        // field is the only place the spelling survives to the analysis
        // side intact.
    }

    // MARK: - Known gap (reported, not fixed — this suite documents it)

    @Test("KNOWN GAP: two saves in the same wall-clock second collide on one filename, and the first capture is lost")
    func twoSavesInTheSameSecondCollide() throws {
        // `timestampFilename()` has one-second resolution, and the second
        // write is atomic — so the second save replaces the first with no
        // error and no log line. In a module whose entire purpose is that
        // a calibration capture is never silently lost, this is silent
        // loss. Reported to the maintainers rather than fixed here; when
        // it is fixed (a unique suffix, or fractional seconds), the
        // expectation below passes and Swift Testing fails this test as a
        // known issue that no longer reproduces — delete the marker then.
        let letter = "T\(UUID().uuidString.prefix(8))"
        let scratch = try beginScratch(letter: letter)
        defer { endScratch(scratch) }

        // Land both saves inside one second on purpose; a clock tick
        // between them would make the premise false, so retry if it does.
        var captured: [String] = []
        for _ in 0..<5 {
            let before = Int(Date().timeIntervalSince1970)
            CalibrationSessionLogger.log(pre: prePair, post: postPair, letter: letter,
                                         schriftArt: .druckschrift, editCount: 1, tool: .skelett)
            CalibrationSessionLogger.log(pre: prePair,
                                         post: self.postPair + [[CGPoint(x: 0.9, y: 0.1)]],
                                         letter: letter,
                                         schriftArt: .druckschrift, editCount: 2, tool: .skelett)
            captured = newFiles(scratch)
            if Int(Date().timeIntervalSince1970) == before { break }
            for name in captured {
                try? FileManager.default.removeItem(at: scratch.dir.appendingPathComponent(name))
            }
        }

        withKnownIssue("timestampFilename() has one-second resolution, so two calibration saves in the same second write to the same path and the second atomically replaces the first — a capture lost with no error and no log line.") {
            #expect(captured.count == 2,
                    "two saves are two captures; one filename means the first edit's pair is gone. Got \(captured)")
            if captured.count == 1, let only = captured.first,
               let survivor = try? readCapture(at: scratch.dir.appendingPathComponent(only)) {
                #expect(survivor.edit_count_in_session == 2,
                        "the surviving file is the SECOND save's — the first was replaced, not merged")
            }
        }
    }
}
