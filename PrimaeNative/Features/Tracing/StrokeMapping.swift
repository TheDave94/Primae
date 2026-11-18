// StrokeMapping.swift
// PrimaeNative
//
// Audit R-081 (PERF). The bbox-relative → cell-fraction stroke mapping used
// to live in three copies inside `TracingViewModel`, and `TracingCanvasView`
// re-ran `gridCellStrokes(at:)` three to four times per cell per frame and
// re-smoothed the ghost's Bezier paths every frame. The arithmetic is now
// one pure function (`StrokeMapping`) and the per-frame results are memoised
// (`StrokeMappingCache`).

import CoreGraphics
import SwiftUI

/// The pure mapping. No state, no renderer, no cache.
enum StrokeMapping {

    /// JSON strokes are bbox-relative (0..1 of the glyph's bounding box).
    /// Map them through the glyph rect into cell-fraction coordinates, and
    /// scale the checkpoint radius by the rect's geometric-mean side.
    static func map(_ source: LetterStrokes, into gr: CGRect) -> LetterStrokes {
        let mapped = source.strokes.map { def in
            StrokeDefinition(
                id: def.id,
                checkpoints: def.checkpoints.map { cp in
                    Checkpoint(x: gr.minX + cp.x * gr.width,
                               y: gr.minY + cp.y * gr.height)
                }
            )
        }
        return LetterStrokes(letter: source.letter,
                             checkpointRadius: source.checkpointRadius
                                 * (gr.width * gr.height).squareRoot(),
                             strokes: mapped)
    }

    /// Catmull-Rom-to-Bezier smoothing. Replaces a polyline through the
    /// supplied points with a `Path` whose segments are cubic Beziers,
    /// so corners between adjacent samples round off instead of forming
    /// visible kinks.
    static func smoothedPath(through pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count >= 2 else { return path }
        if pts.count == 2 {
            path.addLine(to: pts[1])
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = i == 0 ? pts[0] : pts[i - 1]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = i + 2 < pts.count ? pts[i + 2] : pts[i + 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0,
                             y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0,
                             y: p2.y - (p3.y - p1.y) / 6.0)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

/// Memoises `StrokeMapping.map` and the ghost's smoothed paths.
///
/// The mapping is keyed on everything that changes the glyph rect (letter,
/// cell size, script, OpenType features, padding) AND checked against the
/// SOURCE strokes on every hit: a font-weight change swaps the source
/// under an unchanged key, and must not be served the old weight's mapping.
final class StrokeMappingCache {

    struct Key: Hashable {
        var letter: String
        var schriftArt: SchriftArt
        var features: [String]
        var pad: CGFloat
        var cellSize: CGSize
    }

    private struct Entry {
        var source: LetterStrokes
        var mapped: LetterStrokes
    }

    private struct GhostEntry {
        var strokes: LetterStrokes
        var frame: CGRect
        var paths: [Path]
    }

    /// Letters × cell sizes × scripts is small; this only stops a long
    /// session of window resizes from growing without bound.
    private static let capacity = 64

    /// Sources kept per key: Light/Regular weights and the variant form
    /// share a key and differ only in their source strokes.
    private static let sourcesPerKey = 4

    private var entries: [Key: [Entry]] = [:]
    private var ghosts: [Int: GhostEntry] = [:]

    private(set) var mappingHits = 0
    private(set) var mappingMisses = 0
    private(set) var ghostHits = 0
    private(set) var ghostMisses = 0

    /// The mapped strokes, or `source` unchanged when no glyph rect exists
    /// (nothing is cached then, so the next call asks again).
    /// `rect` is only evaluated on a miss.
    func strokes(for source: LetterStrokes, key: Key,
                 rect: () -> CGRect?) -> LetterStrokes {
        if let e = entries[key]?.first(where: { $0.source == source }) {
            mappingHits += 1
            return e.mapped
        }
        guard let gr = rect() else { return source }
        mappingMisses += 1
        let mapped = StrokeMapping.map(source, into: gr)
        if entries.count >= Self.capacity, entries[key] == nil { entries.removeAll() }
        var slot = entries[key] ?? []
        if slot.count >= Self.sourcesPerKey { slot.removeFirst() }
        slot.append(Entry(source: source, mapped: mapped))
        entries[key] = slot
        return mapped
    }

    /// The ghost's smoothed paths for one cell, in canvas points. Rebuilt
    /// only when the mapped strokes or the frame they are drawn into change.
    /// Strokes with fewer than two checkpoints are skipped, as the canvas
    /// always did.
    func ghostPaths(cell: Int, strokes: LetterStrokes, frame: CGRect) -> [Path] {
        if let g = ghosts[cell], g.frame == frame, g.strokes == strokes {
            ghostHits += 1
            return g.paths
        }
        ghostMisses += 1
        let paths: [Path] = strokes.strokes.compactMap { stroke in
            guard stroke.checkpoints.count >= 2 else { return nil }
            let pts = stroke.checkpoints.map { cp in
                CGPoint(x: frame.minX + cp.x * frame.width,
                        y: frame.minY + cp.y * frame.height)
            }
            return StrokeMapping.smoothedPath(through: pts)
        }
        ghosts[cell] = GhostEntry(strokes: strokes, frame: frame, paths: paths)
        return paths
    }
}
