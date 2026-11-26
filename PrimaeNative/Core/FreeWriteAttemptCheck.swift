// FreeWriteAttemptCheck.swift
// PrimaeNative
//
// Protocol r25 (David's ruling 2026-11-15): the free-writing ATTEMPT
// CHECK. A training free-writing production the child finishes is
// accepted unless it is a NON-ATTEMPT — an empty canvas, a scribble, a
// single line or other shape nowhere near the letter, or a clearly wrong
// letter. Wobbly but real letters always pass. Geometry only: no
// recognizer veto, stroke order and direction are not checked (those are
// enforced in observe / direct / guided). Same rule in every arm.
//
// It is a gate on PROGRESSION, not a measure: the continuous outcome
// scores (`spatialDeviation`, `formAccuracy`, …) are untouched and the
// check's own numbers are recorded on every free-writing row as passive
// data. The decision what to do with a rejection (retry, at most
// `maxRetries` times, then move on) lives in `PhaseTransitionCoordinator`.
//
// THE RULE. In the frame-height units the scorer uses
// (`StrokeProcessScorer.heightNormalised`), the drawn ink is aligned to
// the reference strokes: rotated by one of -15…+15 degrees (5 degree
// steps), then its bounding box fitted onto the reference's, with x and y
// scale allowed to differ by at most `maxAspectDistortion`. The box is
// taken over the matched strokes or over all ink, whichever aligns
// better (a stray mark far away must not shrink the letter; a broken
// stroke must not lose half of it). Over ALL the aligned ink:
//   - coverage  = share of reference points with ink within k·r,
//   - precision = share of ink points within k·r of the reference,
// with r the letter's checkpoint radius and k = `toleranceRadii`. The
// attempt passes when, for some alignment whose ink length is within
// `inkLengthRange` of the reference's, min(coverage, precision) >=
// `minShapeScore`, AND the ink has at most `maxExtraReversals` more sharp
// direction reversals than the reference itself (a scribble is mostly
// reversals; a wobble at up to 10 % of the glyph height is not).
//
// CALIBRATION (MEASURED 2026-11-15, Mac swiftc driver over this file's
// algorithm; wt-primae-audit-notes/attempt-check-2026-11-15/v4, out6.txt,
// grid5.py): 9 real adult traces + 122 distorted correct letters (wobble
// up to 10 % of glyph height, aspect 0.6-1.5, slant ±15°, any size and
// position, strokes moved up to 15 %, overshoot, one continuous stroke,
// broken strokes, traced twice, tremor, stray marks up to 0.2 of the
// height) all pass — the weakest at 0.83 (I plus a 0.2-height stray
// mark). 76 of 79 non-attempts are rejected (all scribbles, circles,
// boxes but M's, dots, lines but a slanted line for I, which is close to
// an I); 31 of 40 wrong letters are rejected. A wrong letter that
// CONTAINS the target (L drawn for I) passes: the known leniency limit.

import CoreGraphics
import Foundation

nonisolated enum FreeWriteAttemptCheck {

    /// What the check found. `shapeScore` is the best min(coverage,
    /// precision) over the alignments whose ink length was in range
    /// (0 when none was); `lengthRatio` the aligned ink length over the
    /// reference's, for the alignment that scored best (nil when nothing
    /// was comparable); `extraReversals` the sharp reversals beyond the
    /// reference's own.
    struct Result: Equatable {
        var passed: Bool
        var shapeScore: CGFloat
        var lengthRatio: CGFloat?
        var extraReversals: Int
    }

    /// Retries a training free-writing gets before the session moves on
    /// regardless (r25): at most three attempts in all.
    static let maxRetries = 2
    /// Tolerance band around the reference, in checkpoint radii.
    static let toleranceRadii: CGFloat = 1.5
    /// min(coverage, precision) an attempt must reach.
    static let minShapeScore: CGFloat = 0.80
    /// Aligned ink length over the reference's length.
    static let inkLengthRange: ClosedRange<CGFloat> = 0.5...3.5
    /// Sharp direction reversals allowed beyond the reference's own.
    static let maxExtraReversals = 9
    /// Rotations tried, degrees.
    static let rotationsDegrees: [CGFloat] = [-15, -10, -5, 0, 5, 10, 15]
    /// Largest ratio between the x and y scale of the alignment.
    static let maxAspectDistortion: CGFloat = 1.6

    /// Evaluate one free-writing production. `points` are canvas points
    /// in `frame`'s coordinates, `strokeStartIndices` the recorder's
    /// stroke starts, `reference` the letter as the tracker holds it.
    static func evaluate(points: [CGPoint],
                         strokeStartIndices: [Int],
                         reference: LetterStrokes,
                         frame: CGRect) -> Result {
        let rejected = Result(passed: false, shapeScore: 0, lengthRatio: nil, extraReversals: 0)
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              StrokeProcessScorer.isProduction(points: points, canvasSize: frame.size) else { return rejected }
        let iso = StrokeProcessScorer.heightNormalised(points: points, reference: reference, frame: frame)
        guard let measures = StrokeProcessScorer.analyze(points: iso.points,
                                                         strokeStartIndices: strokeStartIndices,
                                                         reference: iso.reference) else { return rejected }
        let split = StrokeProcessScorer.splitStrokes(points: iso.points, strokeStartIndices: strokeStartIndices)
        let ink = split.filter { $0.count >= 2 }
        let matched = split.indices.filter {
            $0 < measures.matchedReferenceOrder.count && measures.matchedReferenceOrder[$0] != nil && split[$0].count >= 2
        }.map { split[$0] }
        let ref = FreeWriteScorer.densifyReferenceStrokesPerStroke(iso.reference).filter { $0.count >= 2 }
        guard !ink.isEmpty, !ref.isEmpty, let refBox = box(ref) else { return rejected }

        let extra = reversals(ink) - reversals(ref)
        let spacing = StrokeProcessScorer.traceSpacing(reference: ref) / 2
        let refPoints = ref.flatMap { StrokeProcessScorer.resampleBySpacing($0, spacing: spacing) }
        let refLength = ref.reduce(0) { $0 + length($1) }
        let tolerance = toleranceRadii * iso.reference.checkpointRadius
        guard refLength > 0, tolerance > 0 else { return rejected }

        var best: CGFloat = 0
        var bestLength: CGFloat?
        for basis in [matched, ink] where !basis.isEmpty {
            for degrees in rotationsDegrees {
                guard let align = alignment(basis: basis, onto: refBox, degrees: degrees) else { continue }
                let aligned = ink.map { $0.map(align) }
                let ratio = aligned.reduce(0) { $0 + length($1) } / refLength
                if bestLength == nil { bestLength = ratio }
                guard inkLengthRange.contains(ratio) else { continue }
                let inkPoints = aligned.flatMap { StrokeProcessScorer.resampleBySpacing($0, spacing: spacing) }
                let precision = share(inkPoints, within: tolerance, of: refPoints)
                let coverage = share(refPoints, within: tolerance, of: inkPoints)
                let score = min(precision, coverage)
                if score > best { best = score; bestLength = ratio }
            }
        }
        let passed = best >= minShapeScore && extra <= maxExtraReversals
        return Result(passed: passed, shapeScore: best, lengthRatio: bestLength, extraReversals: max(extra, 0))
    }

    // MARK: - Pieces

    /// Rotate about the basis's box centre, then fit that box onto the
    /// reference's, x and y scaled separately within
    /// `maxAspectDistortion`. An axis the reference barely spans (I's
    /// width) or the drawing does not span takes the other axis's scale,
    /// as in `StrokeProcessScorer.fitToReference`; a scribble-sized
    /// drawing is moved, not inflated.
    static func alignment(basis: [[CGPoint]], onto r: CGRect, degrees: CGFloat) -> ((CGPoint) -> CGPoint)? {
        guard let b0 = box(basis) else { return nil }
        let t = degrees * .pi / 180
        let c0 = CGPoint(x: b0.midX, y: b0.midY)
        let cosT = cos(t), sinT = sin(t)
        let rotate: (CGPoint) -> CGPoint = { p in
            CGPoint(x: c0.x + cosT * (p.x - c0.x) - sinT * (p.y - c0.y),
                    y: c0.y + sinT * (p.x - c0.x) + cosT * (p.y - c0.y))
        }
        guard let b = box(basis.map { $0.map(rotate) }) else { return nil }
        let rMax = max(r.width, r.height)
        let degenerate = StrokeProcessScorer.degenerateExtent
        let minShare = StrokeProcessScorer.fitAxisMinShare
        var sx: CGFloat? = (b.width > degenerate && r.width >= minShare * rMax) ? r.width / b.width : nil
        var sy: CGFloat? = (b.height > degenerate && r.height >= minShare * rMax) ? r.height / b.height : nil
        if sx == nil { sx = sy }
        if sy == nil { sy = sx }
        guard var fx = sx, var fy = sy else { return nil }
        if max(b.width, b.height) < StrokeProcessScorer.scribbleExtent { fx = 1; fy = 1 }
        let k = maxAspectDistortion
        if fx / fy > k { let g = (fx * fy).squareRoot(); fx = g * k.squareRoot(); fy = g / k.squareRoot() }
        if fy / fx > k { let g = (fx * fy).squareRoot(); fy = g * k.squareRoot(); fx = g / k.squareRoot() }
        let bc = CGPoint(x: b.midX, y: b.midY), rc = CGPoint(x: r.midX, y: r.midY)
        return { p in
            let q = rotate(p)
            return CGPoint(x: rc.x + fx * (q.x - bc.x), y: rc.y + fy * (q.y - bc.y))
        }
    }

    /// Sharp direction reversals (a turn of more than 120 degrees between
    /// the chords two samples either side), with each stroke resampled at
    /// 1/30 of the drawing's larger extent. One reversal is counted once.
    static func reversals(_ strokes: [[CGPoint]]) -> Int {
        guard let b = box(strokes) else { return 0 }
        let spacing = max(b.width, b.height) / 30
        guard spacing > 0 else { return 0 }
        var count = 0
        for stroke in strokes where stroke.count >= 2 {
            let q = StrokeProcessScorer.resampleBySpacing(stroke, spacing: spacing)
            var i = 2
            while i + 2 < q.count {
                let u = CGPoint(x: q[i].x - q[i - 2].x, y: q[i].y - q[i - 2].y)
                let w = CGPoint(x: q[i + 2].x - q[i].x, y: q[i + 2].y - q[i].y)
                let nu = hypot(u.x, u.y), nw = hypot(w.x, w.y)
                if nu > 0, nw > 0, (u.x * w.x + u.y * w.y) / (nu * nw) < -0.5 {
                    count += 1
                    i += 3
                } else {
                    i += 1
                }
            }
        }
        return count
    }

    /// Share of `points` with a `target` point within `tolerance`. The
    /// targets are bucketed in a grid of `tolerance`-sized cells, so each
    /// point compares only against the 3x3 cells around it: a target within
    /// `tolerance` can lie in no other cell. The comparison itself is the
    /// brute-force one (`shareBruteForce`), so the result is identical; the
    /// scan was O(points x targets) and ran 28 times per evaluation on the
    /// main actor (T1R, 2026-11-24).
    static func share(_ points: [CGPoint], within tolerance: CGFloat, of target: [CGPoint]) -> CGFloat {
        guard !points.isEmpty, !target.isEmpty else { return 0 }
        guard tolerance > 0, tolerance.isFinite,
              (points + target).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return shareBruteForce(points, within: tolerance, of: target)
        }
        let t2 = tolerance * tolerance
        struct Cell: Hashable { let x: Int; let y: Int }
        func cell(_ p: CGPoint) -> Cell {
            Cell(x: Int((p.x / tolerance).rounded(.down)), y: Int((p.y / tolerance).rounded(.down)))
        }
        var grid: [Cell: [CGPoint]] = [:]
        for q in target { grid[cell(q), default: []].append(q) }
        var hits = 0
        for p in points {
            let c = cell(p)
            search: for dx in -1...1 {
                for dy in -1...1 {
                    guard let bucket = grid[Cell(x: c.x + dx, y: c.y + dy)] else { continue }
                    if bucket.contains(where: { ($0.x - p.x) * ($0.x - p.x) + ($0.y - p.y) * ($0.y - p.y) <= t2 }) {
                        hits += 1
                        break search
                    }
                }
            }
        }
        return CGFloat(hits) / CGFloat(points.count)
    }

    /// The reference implementation `share` must equal: every point against
    /// every target.
    static func shareBruteForce(_ points: [CGPoint], within tolerance: CGFloat, of target: [CGPoint]) -> CGFloat {
        guard !points.isEmpty, !target.isEmpty else { return 0 }
        let t2 = tolerance * tolerance
        var hits = 0
        for p in points where target.contains(where: { ($0.x - p.x) * ($0.x - p.x) + ($0.y - p.y) * ($0.y - p.y) <= t2 }) {
            hits += 1
        }
        return CGFloat(hits) / CGFloat(points.count)
    }

    static func length(_ s: [CGPoint]) -> CGFloat {
        var l: CGFloat = 0
        for i in s.indices.dropFirst() { l += hypot(s[i].x - s[i - 1].x, s[i].y - s[i - 1].y) }
        return l
    }

    static func box(_ strokes: [[CGPoint]]) -> CGRect? {
        let pts = strokes.joined()
        guard let first = pts.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
