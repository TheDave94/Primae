// CalibrationStore.swift
// BuchstabenNative
//
// Owns the per-letter user-calibrated stroke JSON files in
// Application Support. Decoded results are cached in memory so the ghost /
// dot-render path doesn't hit disk on every frame.
//
// Extracted from TracingViewModel to isolate disk I/O + cache policy from
// the view model's touch / audio / phase logic.

import Foundation
import CoreGraphics

/// Reads and writes user-calibrated stroke definitions for a letter.
///
/// A user who re-calibrates a letter produces a JSON file in
/// `~/Application Support/BuchstabenNative/CalibratedStrokes/<letter>.json`.
/// On subsequent launches this file takes priority over the bundle
/// `strokes.json`, so each child's tuned dot positions survive restarts.
@MainActor
final class CalibrationStore {

    /// Decoded strokes keyed by letter, including negative (nil) results so
    /// the ghost-render path doesn't repeatedly hit `Data(contentsOf:)` for
    /// letters the user has never calibrated.
    private var cache: [String: LetterStrokes?] = [:]

    /// Returns the user-calibrated strokes for `letter`, or nil if none exist.
    /// First call for a letter performs disk I/O + JSON decode; subsequent
    /// calls return from the in-memory cache.
    func strokes(for letter: String) -> LetterStrokes? {
        if let cached = cache[letter] { return cached }
        guard let url = url(for: letter),
              let data = try? Data(contentsOf: url) else {
            // Memoize the negative result. updateValue is required because
            // `dict[k] = nil` removes the key on Optional-valued dictionaries.
            cache.updateValue(nil, forKey: letter)
            return nil
        }
        let decoded = try? JSONDecoder().decode(LetterStrokes.self, from: data)
        cache[letter] = decoded
        return decoded
    }

    /// Writes glyph-relative stroke checkpoints for `letter` to disk.
    /// Invalidates the in-memory cache so the next read picks up the new file.
    func persist(_ strokes: [[CGPoint]], for letter: String) {
        let defs = strokes.enumerated().compactMap { (i, pts) -> StrokeDefinition? in
            guard !pts.isEmpty else { return nil }
            return StrokeDefinition(id: i + 1, checkpoints: pts.map {
                // Round to 3 decimals so diffs between calibration runs are
                // visible but the files don't churn on imperceptible drift.
                Checkpoint(x: (($0.x * 1000).rounded() / 1000),
                           y: (($0.y * 1000).rounded() / 1000))
            })
        }
        let ls = LetterStrokes(letter: letter, checkpointRadius: 0.05, strokes: defs)
        guard let url = url(for: letter),
              let data = try? JSONEncoder().encode(ls) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        cache.removeValue(forKey: letter)
    }

    private func url(for letter: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BuchstabenNative/CalibratedStrokes/\(letter).json")
    }
}
