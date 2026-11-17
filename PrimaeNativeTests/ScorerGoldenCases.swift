// ScorerGoldenCases.swift
// PrimaeNativeTests
//
// The fixed literal traces `ScorerExactGoldenTests` scores (audit R-105).
// Pure geometry on a `LetterStrokes` reference: no scorer call, no
// Testing import, no global state, so the traces are a function of the
// bundled reference alone. Every trace is in the reference's own
// glyph-bbox space (the JSON frame, checkpointRadius 0.1), i.e. what
// `FreeWriteScorer.score` / `StrokeProcessScorer.analyze` receive when
// the reference is passed unmapped.

import CoreGraphics
@testable import PrimaeNative

/// A trace as the scorer receives it: flat points plus stroke starts.
@MainActor
struct ScorerGoldenTrace {
    let points: [CGPoint]
    let strokeStartIndices: [Int]

    /// Flatten per-stroke point lists; every stroke after the first
    /// starts a new stroke (the recorder's `beginStroke` convention).
    init(strokes: [[CGPoint]]) {
        var pts: [CGPoint] = []
        var starts: [Int] = []
        for (i, s) in strokes.enumerated() {
            if i > 0 { starts.append(pts.count) }
            pts.append(contentsOf: s)
        }
        points = pts
        strokeStartIndices = starts
    }
}

@MainActor
enum ScorerGoldenCases {
    /// The reference's own checkpoints, one traced stroke per reference
    /// stroke, in reference order and direction.
    static func strokes(_ ref: LetterStrokes) -> [[CGPoint]] {
        ref.strokes.map { $0.checkpoints.map { CGPoint(x: $0.x, y: $0.y) } }
    }

    /// Case 1: the reference traced exactly.
    static func identity(_ ref: LetterStrokes) -> ScorerGoldenTrace {
        ScorerGoldenTrace(strokes: strokes(ref))
    }

    /// Case 2: the reference moved by a uniform offset.
    static func offset(_ ref: LetterStrokes, dx: CGFloat = 0.2, dy: CGFloat = -0.1) -> ScorerGoldenTrace {
        ScorerGoldenTrace(strokes: strokes(ref).map { $0.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } })
    }

    /// Case 3: the reference scaled uniformly about the origin.
    static func scaled(_ ref: LetterStrokes, by s: CGFloat = 0.5) -> ScorerGoldenTrace {
        ScorerGoldenTrace(strokes: strokes(ref).map { $0.map { CGPoint(x: $0.x * s, y: $0.y * s) } })
    }

    /// Case 4: one reference stroke left out.
    static func missing(_ ref: LetterStrokes, stroke index: Int) -> ScorerGoldenTrace {
        var s = strokes(ref)
        s.remove(at: index)
        return ScorerGoldenTrace(strokes: s)
    }

    /// F1-01 (segmentation): reference strokes `first...last` drawn as ONE
    /// stroke (their points concatenated), the rest as authored.
    static func merged(_ ref: LetterStrokes, _ first: Int, _ last: Int) -> ScorerGoldenTrace {
        let s = strokes(ref)
        var out: [[CGPoint]] = []
        for i in 0..<first { out.append(s[i]) }
        out.append(Array(s[first...last].joined()))
        for i in (last + 1)..<s.count { out.append(s[i]) }
        return ScorerGoldenTrace(strokes: out)
    }

    /// F1-01 (segmentation): a single-stroke reference split into several
    /// strokes at the given checkpoint indices (each split point ends one
    /// stroke and starts the next, as a pen lift at a vertex would).
    static func split(_ ref: LetterStrokes, at indices: [Int]) -> ScorerGoldenTrace {
        let pts = strokes(ref)[0]
        var out: [[CGPoint]] = []
        var start = 0
        for i in indices {
            out.append(Array(pts[start...i]))
            start = i
        }
        out.append(Array(pts[start...]))
        return ScorerGoldenTrace(strokes: out)
    }

    /// F1-02 (fit): every point rotated by `degrees` about the centre of
    /// the reference's checkpoint bounding box (extra slant).
    static func rotated(_ ref: LetterStrokes, degrees: CGFloat) -> ScorerGoldenTrace {
        let all = strokes(ref).joined()
        let xs = all.map(\.x), ys = all.map(\.y)
        let cx = (xs.min()! + xs.max()!) / 2, cy = (ys.min()! + ys.max()!) / 2
        let a = degrees * .pi / 180
        let c = cos(a), s = sin(a)
        return ScorerGoldenTrace(strokes: strokes(ref).map { $0.map {
            CGPoint(x: cx + ($0.x - cx) * c - ($0.y - cy) * s,
                    y: cy + ($0.x - cx) * s + ($0.y - cy) * c)
        } })
    }

    /// F1-02 (fit): the reference traced exactly plus one 2-sample stray
    /// contact far from the letter.
    static func withStray(_ ref: LetterStrokes) -> ScorerGoldenTrace {
        ScorerGoldenTrace(strokes: strokes(ref) + [[CGPoint(x: 1.6, y: 1.6), CGPoint(x: 1.61, y: 1.6)]])
    }
}
