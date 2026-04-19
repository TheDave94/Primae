// CalibrationStoreTests.swift
// BuchstabenNativeTests
//
// Direct tests for CalibrationStore's cache + disk I/O semantics. The
// negative-result memoization relies on `Dictionary.updateValue(_:forKey:)`
// because `dict[key] = nil` removes the key for Optional-valued dicts —
// easy to regress.

import Foundation
import CoreGraphics
import Testing
@testable import BuchstabenNative

@MainActor
@Suite struct CalibrationStoreTests {

    @Test func strokes_withNoFile_returnsNil() {
        let store = CalibrationStore()
        #expect(store.strokes(for: "NonexistentLetter\(UUID().uuidString)") == nil)
    }

    @Test func persist_writesFile_thenReadsBack() {
        let letter = "T_\(UUID().uuidString.prefix(6))"
        let points: [[CGPoint]] = [[
            CGPoint(x: 0.1, y: 0.2),
            CGPoint(x: 0.3, y: 0.4),
            CGPoint(x: 0.5, y: 0.6),
        ]]
        let store = CalibrationStore()
        store.persist(points, for: letter)

        // A fresh store instance should read the same file back
        let other = CalibrationStore()
        let loaded = other.strokes(for: letter)
        #expect(loaded != nil)
        #expect(loaded?.strokes.count == 1)
        #expect(loaded?.strokes.first?.checkpoints.count == 3)

        // Cleanup
        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BuchstabenNative/CalibratedStrokes/\(letter).json") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func persist_roundsToThreeDecimals() {
        let letter = "R_\(UUID().uuidString.prefix(6))"
        let store = CalibrationStore()
        store.persist([[CGPoint(x: 0.123456789, y: 0.987654321)]], for: letter)
        let loaded = CalibrationStore().strokes(for: letter)
        #expect(loaded != nil)
        let cp = loaded?.strokes.first?.checkpoints.first
        #expect(abs((cp?.x ?? 0) - 0.123) < 1e-9, "x should be rounded to 3 decimals")
        #expect(abs((cp?.y ?? 0) - 0.988) < 1e-9, "y should be rounded to 3 decimals")

        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BuchstabenNative/CalibratedStrokes/\(letter).json") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func persist_skipsEmptyStrokes() {
        let letter = "E_\(UUID().uuidString.prefix(6))"
        let store = CalibrationStore()
        store.persist([[], [CGPoint(x: 0.1, y: 0.1)], []], for: letter)
        let loaded = CalibrationStore().strokes(for: letter)
        #expect(loaded?.strokes.count == 1,
                "Empty stroke arrays should be filtered out, leaving 1 of 3")

        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BuchstabenNative/CalibratedStrokes/\(letter).json") {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test func persist_invalidatesCache() {
        let letter = "C_\(UUID().uuidString.prefix(6))"
        let store = CalibrationStore()

        // Seed a first version.
        store.persist([[CGPoint(x: 0.1, y: 0.1)]], for: letter)
        _ = store.strokes(for: letter) // prime cache

        // Overwrite with a different shape.
        store.persist([
            [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.3)],
        ], for: letter)

        let reloaded = store.strokes(for: letter)
        #expect(reloaded?.strokes.first?.checkpoints.count == 2,
                "After persist, cache must invalidate so next read picks up new file")

        if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BuchstabenNative/CalibratedStrokes/\(letter).json") {
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
            #expect(store.strokes(for: letter) == nil)
        }
    }
}
