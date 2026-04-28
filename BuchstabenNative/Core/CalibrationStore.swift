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

/// Reads and writes user-calibrated stroke definitions for a letter under a
/// specific `SchriftArt`.
///
/// A user who re-calibrates a letter produces a JSON file in
/// `~/Application Support/BuchstabenNative/CalibratedStrokes/<schriftArt>/<letter>.json`.
/// On subsequent launches this file takes priority over the bundle
/// `strokes.json`, so each child's tuned dot positions survive restarts and
/// Druckschrift / Schreibschrift calibrations stay independent.
///
/// Legacy calibrations written before per-script storage existed live at
/// `CalibratedStrokes/<letter>.json` without a font folder. Reads fall back
/// to that path when a font-specific file is absent so nothing on disk is
/// orphaned by the schema change; the next save promotes that data into the
/// current font's folder.
@MainActor
final class CalibrationStore {

    /// Decoded strokes keyed by `schriftArt.rawValue + "/" + letter`, including
    /// negative (nil) results so the ghost-render path doesn't repeatedly hit
    /// `Data(contentsOf:)` for letters the user has never calibrated.
    private var cache: [String: LetterStrokes?] = [:]

    /// Returns the user-calibrated strokes for `letter` in `schriftArt`, or nil
    /// if none exist. First call for a (font, letter) pair performs disk I/O +
    /// JSON decode; subsequent calls return from the in-memory cache.
    /// Falls back to the pre-per-font file path if the font-specific file is
    /// missing, so calibrations saved before the schema split still apply.
    func strokes(for letter: String, schriftArt: SchriftArt) -> LetterStrokes? {
        let key = cacheKey(letter: letter, schriftArt: schriftArt)
        if let cached = cache[key] { return cached }

        if let url = fontSpecificURL(letter: letter, schriftArt: schriftArt),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(LetterStrokes.self, from: data) {
            cache[key] = decoded
            return decoded
        }

        if let url = legacyURL(letter: letter),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(LetterStrokes.self, from: data) {
            cache[key] = decoded
            return decoded
        }

        // Memoize the negative result. updateValue is required because
        // `dict[k] = nil` removes the key on Optional-valued dictionaries.
        cache.updateValue(nil, forKey: key)
        return nil
    }

    /// Writes glyph-relative stroke checkpoints for `letter` in `schriftArt` to
    /// disk. Invalidates the in-memory cache so the next read picks up the new
    /// file.
    func persist(_ strokes: [[CGPoint]], for letter: String, schriftArt: SchriftArt) {
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
        guard let url = fontSpecificURL(letter: letter, schriftArt: schriftArt),
              let data = try? JSONEncoder().encode(ls) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            storePersistenceLogger.warning(
                "CalibrationStore disk write failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        cache.removeValue(forKey: cacheKey(letter: letter, schriftArt: schriftArt))
    }

    private func cacheKey(letter: String, schriftArt: SchriftArt) -> String {
        "\(schriftArt.rawValue)/\(letter)"
    }

    private func fontSpecificURL(letter: String, schriftArt: SchriftArt) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BuchstabenNative/CalibratedStrokes/\(schriftArt.rawValue)/\(letter).json")
    }

    private func legacyURL(letter: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BuchstabenNative/CalibratedStrokes/\(letter).json")
    }
}
