// CalibrationStoreTests.swift
// PrimaeNativeTests
//
// Direct tests for CalibrationStore's cache + disk I/O semantics. The
// negative-result memoization relies on `Dictionary.updateValue(_:forKey:)`
// because `dict[key] = nil` removes the key for Optional-valued dicts —
// easy to regress.

import Foundation
import CoreGraphics
import Testing
@testable import PrimaeNative

@MainActor
@Suite struct CalibrationStoreTests {

    // Helper: absolute URL for a given (schriftArt, letter) pair. Matches the
    // store's internal layout so tests can clean up after themselves without
    // needing a private accessor.
    private func fontSpecificURL(letter: String, schriftArt: SchriftArt) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PrimaeNative/CalibratedStrokes/\(schriftArt.rawValue)/\(letter).json")
    }

    private func legacyURL(letter: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PrimaeNative/CalibratedStrokes/\(letter).json")
    }

    @Test func strokes_withNoFile_returnsNil() {
        let store = CalibrationStore()
        #expect(store.strokes(for: "NonexistentLetter\(UUID().uuidString)",
                              schriftArt: .druckschrift) == nil)
    }

    @Test func persist_writesFile_thenReadsBack() {
        let letter = "T_\(UUID().uuidString.prefix(6))"
        let points: [[CGPoint]] = [[
            CGPoint(x: 0.1, y: 0.2),
            CGPoint(x: 0.3, y: 0.4),
            CGPoint(x: 0.5, y: 0.6),
        ]]
        let store = CalibrationStore()
        store.persist(points, for: letter, schriftArt: .druckschrift)

        // A fresh store instance should read the same file back
        let other = CalibrationStore()
        let loaded = other.strokes(for: letter, schriftArt: .druckschrift)
        #expect(loaded != nil)
        #expect(loaded?.strokes.count == 1)
        #expect(loaded?.strokes.first?.checkpoints.count == 3)

        if let url = fontSpecificURL(letter: letter, schriftArt: .druckschrift) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func persist_roundsToThreeDecimals() {
        let letter = "R_\(UUID().uuidString.prefix(6))"
        let store = CalibrationStore()
        store.persist([[CGPoint(x: 0.123456789, y: 0.987654321)]],
                      for: letter, schriftArt: .druckschrift)
        let loaded = CalibrationStore().strokes(for: letter, schriftArt: .druckschrift)
        #expect(loaded != nil)
        let cp = loaded?.strokes.first?.checkpoints.first
        #expect(abs((cp?.x ?? 0) - 0.123) < 1e-9, "x should be rounded to 3 decimals")
        #expect(abs((cp?.y ?? 0) - 0.988) < 1e-9, "y should be rounded to 3 decimals")

        if let url = fontSpecificURL(letter: letter, schriftArt: .druckschrift) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func persist_skipsEmptyStrokes() {
        let letter = "E_\(UUID().uuidString.prefix(6))"
        let store = CalibrationStore()
        store.persist([[], [CGPoint(x: 0.1, y: 0.1)], []],
                      for: letter, schriftArt: .druckschrift)
        let loaded = CalibrationStore().strokes(for: letter, schriftArt: .druckschrift)
        #expect(loaded?.strokes.count == 1,
                "Empty stroke arrays should be filtered out, leaving 1 of 3")

        if let url = fontSpecificURL(letter: letter, schriftArt: .druckschrift) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func persist_invalidatesCache() {
        let letter = "C_\(UUID().uuidString.prefix(6))"
        let store = CalibrationStore()

        // Seed a first version.
        store.persist([[CGPoint(x: 0.1, y: 0.1)]],
                      for: letter, schriftArt: .druckschrift)
        _ = store.strokes(for: letter, schriftArt: .druckschrift) // prime cache

        // Overwrite with a different shape.
        store.persist([
            [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.3)],
        ], for: letter, schriftArt: .druckschrift)

        let reloaded = store.strokes(for: letter, schriftArt: .druckschrift)
        #expect(reloaded?.strokes.first?.checkpoints.count == 2,
                "After persist, cache must invalidate so next read picks up new file")

        if let url = fontSpecificURL(letter: letter, schriftArt: .druckschrift) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func strokes_negativeResult_isMemoized() {
        // The tricky bit: dict[k] = nil removes the key on Optional-valued
        // dicts, so the store uses updateValue(_:forKey:). Without this
        // pattern, the disk-miss path would re-hit FileManager every frame.
        // We can't introspect the cache, but we can verify the public
        // contract: repeat calls return nil consistently, no crash.
        let letter = "Missing_\(UUID().uuidString)"
        let store = CalibrationStore()
        for _ in 0..<5 {
            #expect(store.strokes(for: letter, schriftArt: .druckschrift) == nil)
        }
    }

    @Test func persist_keepsScriptsIndependent() {
        // Calibrating the same letter under Druckschrift and Schreibschrift
        // must not collide — each script needs its own saved checkpoint set.
        let letter = "S_\(UUID().uuidString.prefix(6))"
        let store = CalibrationStore()

        store.persist(
            [[CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2)]],
            for: letter, schriftArt: .druckschrift)
        store.persist(
            [[CGPoint(x: 0.8, y: 0.8),
              CGPoint(x: 0.9, y: 0.9),
              CGPoint(x: 0.95, y: 0.95)]],
            for: letter, schriftArt: .schreibschrift)

        let druck = CalibrationStore().strokes(for: letter, schriftArt: .druckschrift)
        let schreib = CalibrationStore().strokes(for: letter, schriftArt: .schreibschrift)

        #expect(druck?.strokes.first?.checkpoints.count == 2)
        #expect(schreib?.strokes.first?.checkpoints.count == 3)

        for font in [SchriftArt.druckschrift, .schreibschrift] {
            if let url = fontSpecificURL(letter: letter, schriftArt: font) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    @Test func strokes_fallsBackToLegacyPath() {
        // Calibrations saved before per-font storage existed live at the old
        // flat path. Reads must still find them when a font-specific file is
        // absent so the schema change doesn't orphan a parent's tuning.
        let letter = "L_\(UUID().uuidString.prefix(6))"
        guard let url = legacyURL(letter: letter) else {
            Issue.record("legacy URL unavailable")
            return
        }

        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let legacy = LetterStrokes(
            letter: letter,
            checkpointRadius: 0.05,
            strokes: [StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.1, y: 0.2),
                Checkpoint(x: 0.3, y: 0.4),
            ])]
        )
        guard let data = try? JSONEncoder().encode(legacy) else {
            Issue.record("could not encode legacy payload")
            return
        }
        try? data.write(to: url, options: .atomic)

        let loaded = CalibrationStore().strokes(for: letter, schriftArt: .druckschrift)
        #expect(loaded?.strokes.first?.checkpoints.count == 2,
                "Legacy flat-path file should be found when no font-specific file exists")

        try? FileManager.default.removeItem(at: url)
    }
}
