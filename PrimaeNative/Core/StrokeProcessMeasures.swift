// StrokeProcessMeasures.swift
// PrimaeNative
//
// THE PRIMARY accuracy outcome AND the process-level secondaries
// (stroke count, order, direction), from ONE computation (2026-09-04,
// superseding the 2026-09-03 Hausdorff-over-the-whole-trace design).
//
// REDEFINED 2026-10-05 (protocol revision 6, DECISIONS D8): the PRIMARY
// distance is now computed AFTER a translate + UNIFORM-scale fit of the
// drawn strokes' bounding box onto the reference's (aspect kept; rotation
// still NOT normalised), so a letter drawn anywhere on the canvas, at any
// size, is compared with the ideal letter. David: "it must be tracked
// wherever on the screen it is drawn and can it then be compared to an
// ideal letter drawing of the same letter for scoring". The unnormalised
// distance is kept as the secondary `spatialDeviationRaw`. The paragraph
// below records the 2026-09-04 reasoning this replaces, unchanged.
//
// WHY NOT SHAPE NORMALISATION (Procrustes rejected): scale and rotation
// are already controlled by this task's design — a fixed reference and
// a defined canvas — so normalising them buys nothing, and rotation-
// invariance is actively wrong: a letter drawn upside down is an
// error, not a nuisance parameter to fit away. The defect the
// 2026-09-03 redesign was chasing was never a shape-normalisation
// problem. Hausdorff over the whole trace was order-invariant at the
// POINT-CLOUD level, but it still let a spatially perfect letter with
// strokes in an unusual order score as well as the canonical order —
// no, wait, that's what it FIXED — the residual problem was subtler:
// neither Hausdorff-over-the-cloud nor Fréchet-over-the-concatenated-
// path ever asked "which of MY strokes corresponds to which of THE
// REFERENCE'S strokes" — one discarded stroke identity entirely, the
// other assumed trace-order == reference-order. Both are shape
// analyses; the actual invariance this study needs is stroke
// CORRESPONDENCE.
//
// THE APPROACH: match each traced stroke to its best-fitting reference
// stroke — order-invariant, because the matching decides pairing, not
// arrival order — then measure deviation WITHIN each matched pair.
// Fréchet distance (Eiter & Mannila 1994) is exactly right for that
// within-pair measurement (it stays a sequence-sensitive, single-curve
// distance); what changes is that it is never applied to a
// concatenation of strokes the reference and the child may have
// visited in different orders. The mean of the matched pairs' own
// Fréchet distances IS the order-invariant PRIMARY outcome
// (`spatialDeviation`). The recovered pairing IS the process
// secondaries: `matchedReferenceOrder` is the stroke-order measurement,
// and a stroke-COUNT mismatch (more or fewer traced strokes than the
// reference has) is the stroke-count measurement — nothing bolted on
// separately.
//
// DIRECTION REVERSAL is handled IN the pairing, not normalised away:
// for each candidate (traced stroke, reference stroke) pair, BOTH
// traversal directions are tried and the cheaper one wins — a reversed
// stroke is a process finding worth recording (`reversedStrokeCount`),
// not noise to erase from the distance.
//
// LITERATURE GROUNDING (searched 2026-09-04, per instruction: search
// handwriting-recognition / letter-formation-scoring, not morphometrics
// — Procrustes belongs to the latter and doesn't treat this problem):
// "stroke correspondence search" is the established term for exactly
// this — matching a stroke-order-free / stroke-number-free input
// against a reference character. Five representative correspondence-
// search methods are surveyed in the online-handwriting-recognition
// literature (cube search, bipartite weighted matching, individual
// correspondence decision, stable marriage, deviation-expansion) —
// Kaneko & Chen et al.'s stroke-order-free/stroke-number-free method
// (USPTO 5,796,867) and the comparative survey "Comparative performance
// analysis of stroke correspondence search methods for stroke-order
// free online multi-stroke character recognition" (Front. Comput. Sci.,
// Springer) name this exact problem. Bipartite weighted matching is the
// Hungarian (Kuhn–Munkres) assignment algorithm; unequal stroke counts
// are the linear sum assignment problem with error-correction (LSAPE)
// — insertions/deletions carry an explicit cost against a "do not
// match" option.
//
// SIMPLIFIED DELIBERATELY from that general framework, for this
// domain: bundled Latin letters have at most a handful of strokes, so
// (a) EXHAUSTIVE search over the small assignment space replaces the
// Hungarian algorithm — same optimum, no new dependency, and this runs
// once per phase completion, never per frame; (b) rather than LSAPE's
// tunable null-match cost (which would need calibration evidence this
// domain doesn't have), matching is FORCED to maximum cardinality —
// exactly `min(tracedCount, referenceCount)` pairs, always the
// cheapest such assignment. A traced stroke's "extra" or "missing"
// status therefore falls out of the COUNT difference alone (already
// exactly what `strokeCount` reports against the reference's own
// per-letter stroke count), not from a per-pair cost threshold this
// domain has no evidence to set correctly.
//
// Derived entirely from data already persisted (RawTrace's points +
// strokeStartIndices), so prior sessions remain re-derivable.

import CoreGraphics
import Foundation

/// One session's stroke-level measures against a reference: the
/// order-invariant PRIMARY spatial-deviation outcome, plus the process
/// secondaries recovered from the same stroke correspondence.
struct StrokeProcessMeasures: Equatable {
    /// PRIMARY, order-invariant accuracy outcome — since protocol r6
    /// (2026-10-05) measured AFTER the bounding-box fit
    /// (`StrokeProcessScorer.fitToReference`), so the paragraph's "same
    /// coordinate space" and "NOT normalised by letter size" below
    /// describe `spatialDeviationRaw` now: the mean, over the
    /// matched stroke pairs, of each pair's own (direction-minimised)
    /// discrete Fréchet distance — in the same reference-normalised
    /// coordinate space `PhaseSessionRecord.spatialDeviation` has always
    /// used. Unmatched (extra/missing) strokes do NOT enter this
    /// average — their signal is `strokeCount`, not a distance penalty;
    /// see the file header.
    /// UNIT (from protocol r16, audit B-3): a fraction of the study
    /// canvas HEIGHT, on both axes (`StrokeProcessScorer.heightNormalised`),
    /// so a horizontal and a vertical error of the same size in points
    /// count the same. Before r16 each axis was normalised separately
    /// (x by the width, y by the height), which weighted a vertical error
    /// by the canvas aspect ratio against a horizontal one: 1.45x on the
    /// study iPad (1270 x 874 pt in its exported traces), 1.73x on the
    /// 1084 x 626 pt A16 cell the tests use. The study letters
    /// share one glyph height, so this unit is a fixed multiple of the
    /// glyph height. Re-derive offline from `RawTrace` by dividing both
    /// point axes by `canvasSize.height` and multiplying the reference's x
    /// by `canvasSize.width / canvasSize.height`.
    let spatialDeviation: CGFloat
    /// SECONDARY (2026-10-05, protocol r6): the same stroke-correspondence
    /// distance WITHOUT the bounding-box fit — the pre-r6 primary, in the
    /// reference's own coordinate space, so position and size count. Its
    /// own assignment is solved independently (it is exactly what
    /// `spatialDeviation` was before r6); the process secondaries below
    /// come from the normalised pairing.
    let spatialDeviationRaw: CGFloat
    /// Number of strokes the child actually drew (pen-lift count + 1),
    /// one-sample taps included; `matchedReferenceOrder` has exactly this
    /// many entries, in trace order.
    /// The reference's own expected count is `reference.strokes.count`
    /// — a per-letter constant already in the bundle, not duplicated
    /// into every row.
    let strokeCount: Int
    /// For each traced stroke, IN TRACE ORDER, the index of its matched
    /// reference stroke, or `nil` when this traced stroke went unmatched
    /// (only possible when the child drew MORE strokes than the
    /// reference has — see the file header's "forced maximum
    /// cardinality" note). Recorded as the raw correspondence rather
    /// than a single order-conformance scalar deliberately: inversions,
    /// Kendall's tau, or exact-match can all be computed from this
    /// later, and pre-committing to one would discard information the
    /// thesis analysis might want differently.
    let matchedReferenceOrder: [Int?]
    /// Of the matched strokes, how many were traced in the reverse
    /// direction relative to the reference stroke's own checkpoint
    /// order — decided AS PART of the same cost search that chose the
    /// pairing (whichever direction gave the lower Fréchet distance for
    /// that specific matched pair), not a separate endpoint-distance
    /// heuristic pass.
    let reversedStrokeCount: Int

    /// Comma-joined `matchedReferenceOrder` for CSV/JSON export — "-"
    /// for an unmatched (extra) traced stroke, same convention
    /// `TrainedLetterSubset`'s CSV column uses for a small ordered set.
    var matchedReferenceOrderField: String {
        matchedReferenceOrder.map { $0.map(String.init) ?? "-" }.joined(separator: ",")
    }
}

enum StrokeProcessScorer {
    /// Splits `points` into per-stroke segments, finds the minimum-cost
    /// stroke correspondence against the reference's own strokes (both
    /// traversal directions considered per candidate pair), and reports
    /// the order-invariant primary distance plus count/order/direction.
    /// `points` must already be normalised into the reference's
    /// coordinate space — the same convention the rest of this scoring
    /// path uses. Since r6 the primary fits position and scale away
    /// (`fitToReference`); they still count in `spatialDeviationRaw`.
    /// `nil` when there's nothing comparable.
    static func analyze(
        points: [CGPoint],
        strokeStartIndices: [Int],
        reference: LetterStrokes
    ) -> StrokeProcessMeasures? {
        // A non-finite sample (NaN / infinity) poisons every distance and
        // the bounding-box fit (A18, round-1 B-13): drop such points, with
        // the stroke starts remapped onto the kept points, and score what
        // is left. Fewer than 2 finite points is not a production.
        // Unreachable from UIKit today; a seam against a future input path.
        if !points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
            var kept: [CGPoint] = []
            var keptBefore: [Int] = []          // keptBefore[i] = kept points among points[0..<i]
            keptBefore.reserveCapacity(points.count + 1)
            for p in points {
                keptBefore.append(kept.count)
                if p.x.isFinite && p.y.isFinite { kept.append(p) }
            }
            keptBefore.append(kept.count)
            guard kept.count >= 2 else { return nil }
            let starts = strokeStartIndices.filter { $0 >= 0 && $0 < points.count }.map { keptBefore[$0] }
            return analyze(points: kept, strokeStartIndices: starts, reference: reference)
        }
        guard !points.isEmpty, !reference.strokes.isEmpty else { return nil }

        // Positional, without matching what cannot be matched (2026-09-05):
        // every traced stroke has an entry in `matchedReferenceOrder` (a
        // one-sample tap gets nil at ITS position) and every reference
        // index is into `reference.strokes` as authored; the assignment
        // itself runs over the strokes with >= 2 points on both sides. A
        // trace with no such stroke is not a production and returns nil.
        // Known limit: a one-checkpoint reference dot (i, j, umlauts) is
        // never matched, so a dot's placement does not enter the distance.
        let allTraceStrokes = splitStrokes(points: points, strokeStartIndices: strokeStartIndices)
        let allRefStrokes = FreeWriteScorer.densifyReferenceStrokesPerStroke(reference)
        let eligibleTrace = allTraceStrokes.indices.filter { allTraceStrokes[$0].count >= 2 }
        let eligibleRef = allRefStrokes.indices.filter { allRefStrokes[$0].count >= 2 }
        guard !eligibleTrace.isEmpty, !eligibleRef.isEmpty else { return nil }
        let traceStrokes = eligibleTrace.map { allTraceStrokes[$0] }
        let refStrokes = eligibleRef.map { allRefStrokes[$0] }

        // Every trace stroke is resampled to ONE fixed arc-length spacing
        // before any Fréchet comparison (r16, audit B-11), so the distance
        // no longer depends on how densely the digitiser sampled the same
        // path. The spacing is a fixed fraction of the reference's height
        // (`traceSpacing`); the primary resamples AFTER the fit, in the
        // reference's frame, so the r6 size invariance stays exact.
        let spacing = traceSpacing(reference: refStrokes)
        func spaced(_ strokes: [[CGPoint]]) -> [[CGPoint]] {
            strokes.map { resampleBySpacing($0, spacing: spacing) }
        }

        // SECONDARY (r6): no fit, position and size count.
        guard let raw = correspondence(trace: spaced(traceStrokes), reference: refStrokes) else { return nil }

        // PRIMARY (r6, refined r16 / audit B-5): the drawn strokes fitted
        // onto the reference's box, the box taken over the MATCHED strokes
        // only (match -> fit -> re-match). Fitting over every stroke let one
        // stray contact far from the letter inflate the drawn box and
        // shrink the real letter 5-13x before the comparison.
        func primaryCorrespondence(fitOn subset: [Int])
            -> (deviation: CGFloat, matched: [Int?], reversed: Int)? {
            let fit = fitToReference(drawn: fitBasis(subset.map { traceStrokes[$0] }), reference: refStrokes)
            return correspondence(trace: spaced(traceStrokes.map { $0.map(fit) }), reference: refStrokes)
        }
        let allIndices = Array(traceStrokes.indices)
        let primary: (deviation: CGFloat, matched: [Int?], reversed: Int)
        if traceStrokes.count <= refStrokes.count {
            // Every drawn stroke is matched (forced maximum cardinality), so
            // the matched set IS the whole drawing: the r6 fit, unchanged.
            guard let p = primaryCorrespondence(fitOn: allIndices) else { return nil }
            primary = p
        } else {
            // More drawn strokes than reference strokes: some stay
            // unmatched, and they must not move the fit. Two seeds for the
            // first match — the fit over every stroke that is not itself a
            // tap or scribble, and the unfitted (raw) pairing — each iterated
            // to a fixed point (the fit is over exactly the strokes it
            // matches). The cheaper fixed point wins, the same
            // minimum-cost rule the assignment itself uses.
            let substantial = allIndices.filter {
                guard let box = boundingBox([traceStrokes[$0]]) else { return false }
                return max(box.width, box.height) >= scribbleExtent
            }
            let rawMatched = allIndices.filter { raw.matched[$0] != nil }
            var seeds: [[Int]] = [substantial.isEmpty ? allIndices : substantial]
            if !rawMatched.isEmpty && rawMatched != seeds[0] { seeds.append(rawMatched) }
            var best: (deviation: CGFloat, matched: [Int?], reversed: Int)?
            for seed in seeds {
                var fitSet = seed
                var candidate: (deviation: CGFloat, matched: [Int?], reversed: Int)?
                for _ in 0..<Self.refitIterations {
                    guard let p = primaryCorrespondence(fitOn: fitSet) else { break }
                    candidate = p
                    let matchedSet = allIndices.filter { p.matched[$0] != nil }
                    if matchedSet == fitSet || matchedSet.isEmpty { break }
                    fitSet = matchedSet
                }
                if let c = candidate, best == nil || c.deviation < best!.deviation { best = c }
            }
            guard let b = best else { return nil }
            primary = b
        }

        // Expand back to the ORIGINAL positions on both sides.
        var matchedAll: [Int?] = Array(repeating: nil, count: allTraceStrokes.count)
        for (i, j) in primary.matched.enumerated() {
            guard let j else { continue }
            matchedAll[eligibleTrace[i]] = eligibleRef[j]
        }

        return StrokeProcessMeasures(
            spatialDeviation: primary.deviation,
            spatialDeviationRaw: raw.deviation,
            strokeCount: allTraceStrokes.count,
            matchedReferenceOrder: matchedAll,
            reversedStrokeCount: primary.reversed
        )
    }

    /// Below this extent (canvas-normalised units, the larger of width and
    /// height) a drawing is a TAP OR SCRIBBLE, not a letter: it is moved
    /// onto the reference but NOT scaled up, so a dot cannot be inflated
    /// into a letter-sized shape that scores as letter-like. 2% of the
    /// canvas. Ruled 2026-10-05. From r16 the unit is the canvas HEIGHT on
    /// both axes (≈17.5 pt on the study iPad's 1270 x 874 pt canvas, ≈12.5 pt
    /// on the 1084 x 626 pt A16 test cell; before r16 a horizontal
    /// extent was measured in canvas widths, ≈25.4 pt and ≈21.7 pt).
    static let scribbleExtent: CGFloat = 0.02
    /// Upper bound on match -> fit -> re-match rounds per seed (r16). Two
    /// rounds reach the fixed point in every case measured; the bound only
    /// stops a pathological drawing from oscillating.
    static let refitIterations = 4
    /// The fixed arc-length spacing every trace stroke is resampled to
    /// before Fréchet (r16, audit B-11), as a fraction of the reference
    /// strokes' height: 1/40, about 7 pt on the A16 study canvas.
    static let traceSpacingFraction: CGFloat = 1.0 / 40.0

    /// `traceSpacingFraction` of the reference's height (its width when the
    /// reference is flat), never zero.
    static func traceSpacing(reference: [[CGPoint]]) -> CGFloat {
        guard let box = boundingBox(reference) else { return 1 }
        let extent = box.height > degenerateExtent ? box.height : max(box.width, degenerateExtent)
        return extent * traceSpacingFraction
    }

    /// The stroke resampled at one fixed arc-length spacing: as many points
    /// as its length holds at `spacing` (at least two), evenly spread along
    /// the polyline, endpoints kept. The point count follows the path's
    /// length, not the number of digitiser samples on it.
    static func resampleBySpacing(_ stroke: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard stroke.count >= 2, spacing > 0 else { return stroke }
        var length: CGFloat = 0
        for i in 1..<stroke.count { length += FreeWriteScorer.dist(stroke[i - 1], stroke[i]) }
        guard length > 0, length.isFinite else { return stroke }
        let count = max(2, Int((length / spacing).rounded()) + 1)
        return FreeWriteScorer.resample(stroke, targetCount: count)
    }

    /// The arc-length spacing of `fitBasis`, as a fraction of the drawn
    /// strokes' height: 1/120, about 2.5 pt. Finer than `traceSpacingFraction`
    /// because the box's top and bottom often sit on a sharp apex (A, M),
    /// which a coarse resample would cut by up to half a spacing.
    static let fitBasisSpacingFraction: CGFloat = 1.0 / 120.0

    /// The strokes the fit's bounding box is read from: the drawn strokes
    /// resampled at a fixed arc-length spacing, taken relative to
    /// THEIR OWN height (so the r6 size invariance stays exact). A box over
    /// the raw samples grows with the number of noisy samples at its edge,
    /// which made the fit, and through it the primary, follow the sample
    /// rate (r16, audit B-11; narrow letters such as I most).
    static func fitBasis(_ drawn: [[CGPoint]]) -> [[CGPoint]] {
        guard let box = boundingBox(drawn) else { return drawn }
        let extent = box.height > degenerateExtent ? box.height : max(box.width, degenerateExtent)
        return drawn.map { resampleBySpacing($0, spacing: extent * fitBasisSpacingFraction) }
    }

    /// The frame-normalised points and the reference, both in units of the
    /// frame's HEIGHT on both axes (r16, audit B-3), so one point of error
    /// weighs the same horizontally and vertically. `points` are in the
    /// frame's own coordinates (canvas points); the reference is in the
    /// frame's per-axis 0–1 fractions, as the tracker and `RawTrace` keep
    /// it, and only its x is rescaled by the frame's aspect (width/height).
    /// The radius is left as it is: in the tracker's own cell-height units
    /// (`StrokeTracker.cellDefinition`), which is this frame's unit too.
    /// A zero frame passes the points through with aspect 1, as before.
    static func heightNormalised(points: [CGPoint], reference: LetterStrokes,
                                 frame: CGRect) -> (points: [CGPoint], reference: LetterStrokes) {
        let w = max(frame.width, 1)
        let h = max(frame.height, 1)
        let aspect = w / h
        let pts = points.map { CGPoint(x: ($0.x - frame.minX) / h, y: ($0.y - frame.minY) / h) }
        let ref = LetterStrokes(
            letter: reference.letter,
            checkpointRadius: reference.checkpointRadius,
            strokes: reference.strokes.map { s in
                StrokeDefinition(id: s.id, checkpoints: s.checkpoints.map {
                    Checkpoint(x: $0.x * aspect, y: $0.y)
                })
            })
        return (pts, ref)
    }

    /// Whether a free-write contact is a PRODUCTION — something the lift's
    /// 2.0 s quiet window advances on and the unload path scores and
    /// records as a completed trial (protocol r7). At least two recorded
    /// points AND a bounding box whose larger side, canvas-normalised as
    /// `FreeWritePhaseRecorder.assess` normalises, is at least
    /// `scribbleExtent` — the constant the r6 fit already uses to call a
    /// drawing a scribble, so the two cannot disagree. Under the r7
    /// kept-point filter a palm or finger creeping a few points across the
    /// glass records several points; two points alone no longer tell a
    /// contact from a mark.
    /// From r16 both sides are measured in canvas HEIGHTS, the unit the fit
    /// now sees (`heightNormalised`), so the two still cannot disagree.
    static func isProduction(points: [CGPoint], canvasSize: CGSize) -> Bool {
        guard points.count >= 2, let box = boundingBox([points]) else { return false }
        let width = box.width / max(canvasSize.height, 1)
        let height = box.height / max(canvasSize.height, 1)
        return max(width, height) >= scribbleExtent
    }
    /// An extent at or below this is zero (a straight vertical or
    /// horizontal line, or a single point) — that axis cannot be fitted.
    static let degenerateExtent: CGFloat = 1e-6

    /// The share of the reference's larger extent an axis must span to set
    /// the fit scale (r16). 0.25: every study letter's narrow axis but I's
    /// (about 0.07) clears it.
    static let fitAxisMinShare: CGFloat = 0.25

    /// The translate + UNIFORM scale (aspect kept, no rotation) that fits
    /// the drawn strokes' bounding box onto the reference strokes' box
    /// (protocol r6, 2026-10-05): centres aligned, one scale factor
    /// `s = min(ref.w / drawn.w, ref.h / drawn.h)` over the axes where
    /// BOTH extents are non-degenerate.
    ///   - one axis degenerate on either side (a drawn straight stroke, or
    ///     a straight-line reference): fitted on the other axis alone;
    ///   - no fittable axis (a point, or two lines at right angles): s = 1;
    ///   - a scribble (`scribbleExtent`): s = 1 — moved, not inflated.
    /// Never divides by a degenerate extent, so it cannot produce NaN.
    static func fitToReference(drawn: [[CGPoint]], reference: [[CGPoint]]) -> (CGPoint) -> CGPoint {
        guard let d = boundingBox(drawn), let r = boundingBox(reference) else { return { $0 } }
        var ratios: [CGFloat] = []
        // An axis votes only when the reference spans at least
        // `fitAxisMinShare` of its larger extent on it (r16): the narrow
        // axis of a near-1D glyph (I's 18 pt slant over 274 pt) is a few
        // points wide, so pen jitter alone moved its ratio, and with it the
        // whole fit, by tens of percent, and more at a higher sample rate.
        let rMax = max(r.width, r.height)
        if d.width > degenerateExtent && r.width > degenerateExtent
            && r.width >= fitAxisMinShare * rMax { ratios.append(r.width / d.width) }
        if d.height > degenerateExtent && r.height > degenerateExtent
            && r.height >= fitAxisMinShare * rMax { ratios.append(r.height / d.height) }
        let isScribble = max(d.width, d.height) < scribbleExtent
        let scale = (isScribble ? nil : ratios.min()) ?? 1
        let dc = CGPoint(x: d.midX, y: d.midY)
        let rc = CGPoint(x: r.midX, y: r.midY)
        return { p in CGPoint(x: rc.x + scale * (p.x - dc.x), y: rc.y + scale * (p.y - dc.y)) }
    }

    private static func boundingBox(_ strokes: [[CGPoint]]) -> CGRect? {
        let pts = strokes.joined()
        guard let first = pts.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The stroke-correspondence search itself: per (traced, reference)
    /// pair the cheaper of forward/reversed discrete Fréchet distance,
    /// the minimum-cost assignment, and the mean over the matched pairs.
    /// `matched` is indexed like `trace` (eligible strokes only).
    private static func correspondence(trace traceStrokes: [[CGPoint]],
                                       reference refStrokes: [[CGPoint]])
        -> (deviation: CGFloat, matched: [Int?], reversed: Int)? {
        let traceCount = traceStrokes.count
        let refCount = refStrokes.count

        // Cost[i][j]: the cheaper of forward/reversed discrete Fréchet
        // distance between traced stroke i and reference stroke j, with
        // the traced stroke resampled to that reference stroke's own
        // (densified) point count first — Fréchet, unlike Hausdorff,
        // has no proven bound on cross-density inflation, so both sides
        // are matched to a common density here, the same discipline the
        // historical whole-path Fréchet computation always applied.
        var cost = Array(repeating: Array(repeating: CGFloat.greatestFiniteMagnitude, count: refCount),
                         count: traceCount)
        var reversedWins = Array(repeating: Array(repeating: false, count: refCount), count: traceCount)

        for i in 0..<traceCount {
            for j in 0..<refCount {
                let refStroke = refStrokes[j]
                let targetCount = refStroke.count   // >= 64 after densify; the old max(…, 8) was dead
                let forward = FreeWriteScorer.resample(traceStrokes[i], targetCount: targetCount)
                let reversed = Array(forward.reversed())
                let forwardCost = FreeWriteScorer.discreteFrechetDistance(forward, refStroke)
                let reversedCost = FreeWriteScorer.discreteFrechetDistance(reversed, refStroke)
                if reversedCost < forwardCost {
                    cost[i][j] = reversedCost
                    reversedWins[i][j] = true
                } else {
                    cost[i][j] = forwardCost
                }
            }
        }

        let matched = bestAssignment(cost: cost, traceCount: traceCount, refCount: refCount)

        var totalDeviation: CGFloat = 0
        var matchedCount = 0
        var reversedCount = 0
        for i in 0..<traceCount {
            guard let j = matched[i] else { continue }
            totalDeviation += cost[i][j]
            matchedCount += 1
            if reversedWins[i][j] { reversedCount += 1 }
        }
        // Unreachable when both traceCount and refCount are > 0 (the
        // smaller side is always fully matched by construction — see
        // `bestAssignment`), guarded anyway rather than assumed.
        guard matchedCount > 0 else { return nil }
        return (totalDeviation / CGFloat(matchedCount), matched, reversedCount)
    }

    /// Minimum-total-cost assignment between traced-stroke indices
    /// `0..<traceCount` and reference-stroke indices `0..<refCount`,
    /// FORCED to `min(traceCount, refCount)` pairs (the smaller side is
    /// always fully matched — see the file header's "forced maximum
    /// cardinality" note). Exhaustive search: correct and fast at this
    /// domain's scale (a handful of strokes per letter), and the
    /// literature's general solution to this exact assignment problem —
    /// bipartite weighted matching / the Hungarian algorithm — would be
    /// unnecessary machinery here. Returns, for each traced-stroke index
    /// in trace order, its matched reference index or `nil`.
    private static func bestAssignment(
        cost: [[CGFloat]], traceCount: Int, refCount: Int
    ) -> [Int?] {
        guard traceCount > 0, refCount > 0 else { return Array(repeating: nil, count: traceCount) }

        if traceCount <= refCount {
            // Every traced stroke matches some distinct reference stroke.
            var usedRef = Array(repeating: false, count: refCount)
            var current = Array(repeating: Optional<Int>.none, count: traceCount)
            var best = current
            var bestTotal = CGFloat.greatestFiniteMagnitude
            func search(_ i: Int, _ total: CGFloat) {
                if total >= bestTotal { return }
                if i == traceCount { bestTotal = total; best = current; return }
                for j in 0..<refCount where !usedRef[j] {
                    usedRef[j] = true
                    current[i] = j
                    search(i + 1, total + cost[i][j])
                    usedRef[j] = false
                }
            }
            search(0, 0)
            return best
        } else {
            // Every reference stroke matches some distinct traced
            // stroke; the extra traced strokes stay unmatched.
            var usedTrace = Array(repeating: false, count: traceCount)
            var current = Array(repeating: Optional<Int>.none, count: refCount) // ref -> trace
            var best = current
            var bestTotal = CGFloat.greatestFiniteMagnitude
            func search(_ j: Int, _ total: CGFloat) {
                if total >= bestTotal { return }
                if j == refCount { bestTotal = total; best = current; return }
                for i in 0..<traceCount where !usedTrace[i] {
                    usedTrace[i] = true
                    current[j] = i
                    search(j + 1, total + cost[i][j])
                    usedTrace[i] = false
                }
            }
            search(0, 0)
            var result: [Int?] = Array(repeating: nil, count: traceCount)
            for (refIdx, traceIdx) in best.enumerated() {
                if let traceIdx { result[traceIdx] = refIdx }
            }
            return result
        }
    }

    /// Split a flat point array into per-stroke segments. Same
    /// `strokeStartIndices` convention `LetterRecognizer`'s rasteriser
    /// already uses (`[0] + strokeStartIndices.filter { $0 > 0 && $0 <
    /// points.count }`, sorted) — matched deliberately rather than
    /// re-derived, so a change to one doesn't silently diverge from the
    /// other.
    private static func splitStrokes(points: [CGPoint], strokeStartIndices: [Int]) -> [[CGPoint]] {
        guard !points.isEmpty else { return [] }
        let breaks = ([0] + strokeStartIndices.filter { $0 > 0 && $0 < points.count }).sorted()
        var result: [[CGPoint]] = []
        for (b, breakIdx) in breaks.enumerated() {
            let endIdx = (b + 1 < breaks.count) ? breaks[b + 1] : points.count
            guard breakIdx < endIdx else { continue }
            result.append(Array(points[breakIdx..<endIdx]))
        }
        return result
    }
}
