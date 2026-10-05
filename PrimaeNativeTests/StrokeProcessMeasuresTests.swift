import Testing
import CoreGraphics
@testable import PrimaeNative

struct StrokeProcessMeasuresTests {

    // MARK: - Fixtures

    /// An L: vertical leg (stroke 0) then horizontal leg (stroke 1) —
    /// the canonical reference order and direction.
    private var lStrokes: LetterStrokes {
        LetterStrokes(
            letter: "L", checkpointRadius: 0.04,
            strokes: [
                StrokeDefinition(id: 1, checkpoints: [
                    Checkpoint(x: 0.4, y: 0.2), Checkpoint(x: 0.4, y: 0.5), Checkpoint(x: 0.4, y: 0.8),
                ]),
                StrokeDefinition(id: 2, checkpoints: [
                    Checkpoint(x: 0.4, y: 0.8), Checkpoint(x: 0.6, y: 0.8), Checkpoint(x: 0.8, y: 0.8),
                ]),
            ]
        )
    }

    private var verticalLineStrokes: LetterStrokes {
        LetterStrokes(
            letter: "I", checkpointRadius: 0.04,
            strokes: [StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8),
            ])]
        )
    }

    private func denseLine(from a: CGPoint, to b: CGPoint, count: Int = 65) -> [CGPoint] {
        (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    // MARK: - Single stroke

    @Test("single stroke, forward direction: matches, not reversed, near-zero deviation")
    func singleStrokeForward() throws {
        let trace = denseLine(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.5, y: 0.8))
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [], reference: verticalLineStrokes))
        #expect(m.strokeCount == 1)
        #expect(m.matchedReferenceOrder == [0])
        #expect(m.reversedStrokeCount == 0)
        #expect(m.spatialDeviation < 0.01,
                "a dense trace along the reference line should have ~zero deviation, got \(m.spatialDeviation)")
    }

    @Test("single stroke, reversed direction: matches, counted reversed, SAME deviation as forward")
    func singleStrokeReversed() throws {
        let forward = denseLine(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.5, y: 0.8))
        let reversed = denseLine(from: CGPoint(x: 0.5, y: 0.8), to: CGPoint(x: 0.5, y: 0.2))
        let mForward = try #require(StrokeProcessScorer.analyze(
            points: forward, strokeStartIndices: [], reference: verticalLineStrokes))
        let mReversed = try #require(StrokeProcessScorer.analyze(
            points: reversed, strokeStartIndices: [], reference: verticalLineStrokes))
        #expect(mReversed.strokeCount == 1)
        #expect(mReversed.matchedReferenceOrder == [0])
        #expect(mReversed.reversedStrokeCount == 1,
                "same points traversed start-to-end backwards must count as reversed")
        // Direction is handled IN the pairing (orientation minimises
        // cost), not left to inflate the distance — reversal is a
        // process finding (reversedStrokeCount), not a penalty on
        // spatialDeviation.
        #expect(abs(mForward.spatialDeviation - mReversed.spatialDeviation) < 1e-6,
                "reversal must not affect spatialDeviation: forward=\(mForward.spatialDeviation) reversed=\(mReversed.spatialDeviation)")
    }

    // MARK: - Off-path

    @Test("off-path trace has large spatial deviation")
    func offPathLargeDeviation() throws {
        let traced: [CGPoint] = [
            CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.15, y: 0.15),
            CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.1, y: 0.3),
            CGPoint(x: 0.05, y: 0.1),
        ]
        let m = try #require(StrokeProcessScorer.analyze(
            points: traced, strokeStartIndices: [], reference: verticalLineStrokes))
        #expect(m.spatialDeviation > 0.2,
                "a trace nowhere near the reference should have large deviation, got \(m.spatialDeviation)")
    }

    // MARK: - Multi-stroke order

    @Test("multi-stroke, reference order: matched order is [0, 1], near-zero deviation")
    func multiStrokeReferenceOrder() throws {
        let vert = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
        let horiz = denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 0.8, y: 0.8))
        let trace = vert + horiz
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [vert.count], reference: lStrokes))
        #expect(m.strokeCount == 2)
        #expect(m.matchedReferenceOrder == [0, 1],
                "traced vertical-then-horizontal must match reference strokes in the same order")
        #expect(m.reversedStrokeCount == 0)
        #expect(m.spatialDeviation < 0.01, "reference-order trace should have near-zero deviation, got \(m.spatialDeviation)")
    }

    @Test("multi-stroke, REVERSED stroke order: matched order is [1, 0], SAME deviation as reference order")
    func multiStrokeReversedOrder() throws {
        // Horizontal leg drawn FIRST, vertical leg SECOND — the reverse
        // of the reference's own stroke order. This is exactly the case
        // spatialDeviation (order-invariant via correspondence) must NOT
        // see, and matchedReferenceOrder exists to record instead.
        let horiz = denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 0.8, y: 0.8))
        let vert = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
        let trace = horiz + vert
        let referenceOrderTrace = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
            + denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 0.8, y: 0.8))
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [horiz.count], reference: lStrokes))
        let mReferenceOrder = try #require(StrokeProcessScorer.analyze(
            points: referenceOrderTrace, strokeStartIndices: [vert.count], reference: lStrokes))
        #expect(m.strokeCount == 2)
        #expect(m.matchedReferenceOrder == [1, 0],
                "traced horizontal-then-vertical must record the reference order as reversed")
        #expect(abs(m.spatialDeviation - mReferenceOrder.spatialDeviation) < 1e-6,
                "stroke order must not affect spatial deviation: reversed-order=\(m.spatialDeviation) reference-order=\(mReferenceOrder.spatialDeviation)")
    }

    @Test("matchedReferenceOrderField comma-joins the raw correspondence")
    func matchedReferenceOrderFieldFormat() throws {
        let horiz = denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 0.8, y: 0.8))
        let vert = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
        let trace = horiz + vert
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [horiz.count], reference: lStrokes))
        #expect(m.matchedReferenceOrderField == "1,0")
    }

    // MARK: - Stroke-count mismatch (extra / missing strokes)

    @Test("an extra traced stroke with no reference counterpart is unmatched, not force-paired")
    func extraTracedStrokeIsUnmatched() throws {
        // The correct two legs, PLUS a third, spurious stroke far from
        // both reference strokes.
        let vert = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
        let horiz = denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 0.8, y: 0.8))
        let stray = denseLine(from: CGPoint(x: 0.05, y: 0.05), to: CGPoint(x: 0.1, y: 0.1))
        let trace = vert + horiz + stray
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [vert.count, vert.count + horiz.count],
            reference: lStrokes))
        #expect(m.strokeCount == 3, "the child drew 3 strokes even though the reference has 2")
        #expect(m.matchedReferenceOrder == [0, 1, nil],
                "the stray third stroke has no reference counterpart and must be nil, not forced onto stroke 0 or 1")
        // The unmatched stray stroke must not enter the AVERAGE — only the
        // two genuinely matched pairs contribute. Pinned on the
        // unnormalised distance since protocol r6 (2026-10-05): the
        // primary is measured after fitting the bounding box of ALL drawn
        // strokes onto the reference's, and the stray stroke widens that
        // box, so it moves the primary through the fit (by design, as
        // ruled: "the drawn strokes' bounding box") — never through the
        // average.
        #expect(m.spatialDeviationRaw < 0.01,
                "an unmatched extra stroke must not inflate the matched-pair average, got \(m.spatialDeviationRaw)")
        #expect(m.spatialDeviation > m.spatialDeviationRaw,
                "r6: the stray stroke widens the drawn box, so the fitted legs no longer sit on the reference")
    }

    @Test("fewer traced strokes than the reference: the reference stroke with no match is simply absent from the pairing")
    func missingTracedStrokeLeavesOneRefStrokeUnpaired() throws {
        // Only the vertical leg — the L's horizontal leg was never drawn.
        let vert = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
        let m = try #require(StrokeProcessScorer.analyze(
            points: vert, strokeStartIndices: [], reference: lStrokes))
        #expect(m.strokeCount == 1, "the child drew only 1 stroke even though the reference has 2")
        #expect(m.matchedReferenceOrder == [0],
                "the single traced stroke matches its best reference counterpart (the vertical leg)")
        // On the unnormalised distance (r6): fitted, the lone leg is
        // centred on the WHOLE L's box, so it no longer sits on the leg.
        #expect(m.spatialDeviationRaw < 0.01)
    }

    // MARK: - Edge cases

    @Test("empty trace returns nil")
    func emptyTraceReturnsNil() {
        #expect(StrokeProcessScorer.analyze(
            points: [], strokeStartIndices: [], reference: verticalLineStrokes) == nil)
    }

    @Test("empty reference returns nil")
    func emptyReferenceReturnsNil() {
        let empty = LetterStrokes(letter: "X", checkpointRadius: 0.04, strokes: [])
        let trace = denseLine(from: CGPoint(x: 0.5, y: 0.2), to: CGPoint(x: 0.5, y: 0.8))
        #expect(StrokeProcessScorer.analyze(
            points: trace, strokeStartIndices: [], reference: empty) == nil)
    }

    @Test("a single stray point (no real stroke) returns nil")
    func singleStrayPointReturnsNil() {
        #expect(StrokeProcessScorer.analyze(
            points: [CGPoint(x: 0.5, y: 0.5)], strokeStartIndices: [],
            reference: verticalLineStrokes) == nil)
    }

    // MARK: - One-sample strokes (audit 2026-09-04)

    /// A tap that produced a single touch sample is a stroke the child
    /// made (pen-lift count + 1) even though it cannot be matched. It
    /// used to vanish from `strokeCount` silently.
    @Test("a one-sample tap counts as a stroke but is not matched")
    func oneSampleStrokeIsCountedNotMatched() throws {
        let vert = denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8))
        let horiz = denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 0.8, y: 0.8))
        let tap = [CGPoint(x: 0.9, y: 0.1)]
        let trace = vert + tap + horiz
        let m = try #require(StrokeProcessScorer.analyze(
            points: trace,
            strokeStartIndices: [vert.count, vert.count + tap.count],
            reference: lStrokes))
        #expect(m.strokeCount == 3, "vertical + tap + horizontal = 3 strokes drawn, got \(m.strokeCount)")
        #expect(m.matchedReferenceOrder.count == 3, "one entry per traced stroke, taps included (2026-09-05)")
        #expect(m.matchedReferenceOrder == [0, nil, 1],
                "the tap is the unmatched one, at ITS position: \(m.matchedReferenceOrder)")
    }

    // MARK: - r6 (2026-10-05): the bounding-box fit before the distance
    //
    // David: "it must be tracked wherever on the screen it is drawn and can
    // it then be compared to an ideal letter drawing of the same letter for
    // scoring". Translate + UNIFORM scale, aspect kept, no rotation; the
    // unnormalised distance stays as `spatialDeviationRaw`.

    private func analyzeL(_ strokes: [[CGPoint]]) throws -> StrokeProcessMeasures {
        var starts: [Int] = []
        var n = 0
        for s in strokes.dropLast() { n += s.count; starts.append(n) }
        return try #require(StrokeProcessScorer.analyze(
            points: Array(strokes.joined()), strokeStartIndices: starts, reference: lStrokes))
    }

    @Test("r6: the reference L drawn elsewhere on the canvas scores as the L; the raw secondary pays for the offset")
    func offsetLetterIsFitted() throws {
        let m = try analyzeL([denseLine(from: CGPoint(x: 0.55, y: 0.05), to: CGPoint(x: 0.55, y: 0.65)),
                              denseLine(from: CGPoint(x: 0.55, y: 0.65), to: CGPoint(x: 0.95, y: 0.65))])
        #expect(m.spatialDeviation < 0.01, "offset L, primary: \(m.spatialDeviation)")
        #expect(m.spatialDeviationRaw > 0.1, "offset L, raw: \(m.spatialDeviationRaw)")
        #expect(m.matchedReferenceOrder == [0, 1] && m.reversedStrokeCount == 0)
    }

    @Test("r6: a half-size L in a corner scores as the L; the raw secondary pays for size and place")
    func scaledLetterIsFitted() throws {
        let m = try analyzeL([denseLine(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.1, y: 0.4)),
                              denseLine(from: CGPoint(x: 0.1, y: 0.4), to: CGPoint(x: 0.3, y: 0.4))])
        #expect(m.spatialDeviation < 0.01, "half-size L, primary: \(m.spatialDeviation)")
        #expect(m.spatialDeviationRaw > 0.1, "half-size L, raw: \(m.spatialDeviationRaw)")
    }

    @Test("r6: the scale is UNIFORM — a stretched L is not fitted back into shape")
    func stretchedLetterKeepsItsError() throws {
        // Horizontal leg 0.6 long against the reference's 0.4: a per-axis
        // fit would erase that; the uniform fit (s = min ratio) cannot.
        let m = try analyzeL([denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8)),
                              denseLine(from: CGPoint(x: 0.4, y: 0.8), to: CGPoint(x: 1.0, y: 0.8))])
        #expect(m.spatialDeviation > 0.05, "a stretched L must still deviate: \(m.spatialDeviation)")
    }

    @Test("r6: rotation is NOT normalised — an upside-down L is an error")
    func upsideDownLetterIsAnError() throws {
        let m = try analyzeL([denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.4, y: 0.8)),
                              denseLine(from: CGPoint(x: 0.4, y: 0.2), to: CGPoint(x: 0.8, y: 0.2))])
        #expect(m.spatialDeviation > 0.2, "upside-down L, primary: \(m.spatialDeviation)")
    }

    @Test("r6: letter I (the bundle's slanted single stroke) drawn small and off-place scores as the I")
    func letterIIsFitted() throws {
        let a = CGPoint(x: 0.71, y: 0.04), b = CGPoint(x: 0.31, y: 0.96)
        let ref = LetterStrokes(letter: "I", checkpointRadius: 0.04, strokes: [
            StrokeDefinition(id: 1, checkpoints: denseLine(from: a, to: b, count: 40).map { Checkpoint(x: $0.x, y: $0.y) })])
        let small = denseLine(from: CGPoint(x: 0.05 + a.x * 0.3, y: 0.05 + a.y * 0.3),
                              to: CGPoint(x: 0.05 + b.x * 0.3, y: 0.05 + b.y * 0.3))
        let m = try #require(StrokeProcessScorer.analyze(points: small, strokeStartIndices: [], reference: ref))
        #expect(m.spatialDeviation < 0.01, "small I, primary: \(m.spatialDeviation)")
        #expect(m.spatialDeviationRaw > 0.2, "small I, raw: \(m.spatialDeviationRaw)")
    }

    @Test("r6 degenerate: a zero-width reference (vertical line) is fitted on its height alone, never NaN")
    func zeroWidthReferenceFitsOnHeight() throws {
        let drawn = denseLine(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.1, y: 0.4))
        let m = try #require(StrokeProcessScorer.analyze(points: drawn, strokeStartIndices: [], reference: verticalLineStrokes))
        #expect(m.spatialDeviation.isFinite && m.spatialDeviationRaw.isFinite)
        #expect(m.spatialDeviation < 0.01, "short vertical line, fitted on height: \(m.spatialDeviation)")
        // A slightly slanted line against the zero-width reference: the
        // drawn width cannot be fitted to 0, so the height decides.
        let slanted = denseLine(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.12, y: 0.4))
        let s = try #require(StrokeProcessScorer.analyze(points: slanted, strokeStartIndices: [], reference: verticalLineStrokes))
        #expect(s.spatialDeviation.isFinite && s.spatialDeviation < 0.05, "near-vertical: \(s.spatialDeviation)")
    }

    @Test("r6 degenerate: a tiny scribble (< 2% of the canvas) is moved, NOT scaled up into a letter")
    func tinyScribbleIsNotInflated() throws {
        // The reference L's own shape at 1% of the canvas: inflated, it
        // would score as a perfect L.
        let tiny = try analyzeL([denseLine(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.1, y: 0.115)),
                                 denseLine(from: CGPoint(x: 0.1, y: 0.115), to: CGPoint(x: 0.11, y: 0.115))])
        #expect(tiny.spatialDeviation.isFinite)
        #expect(tiny.spatialDeviation > 0.2, "a scribble was inflated to letter size: \(tiny.spatialDeviation)")
        // Control: the same shape just above the threshold IS fitted.
        let small = try analyzeL([denseLine(from: CGPoint(x: 0.1, y: 0.1), to: CGPoint(x: 0.1, y: 0.13)),
                                  denseLine(from: CGPoint(x: 0.1, y: 0.13), to: CGPoint(x: 0.12, y: 0.13))])
        #expect(small.spatialDeviation < 0.01, "a 3% L is a letter and is fitted: \(small.spatialDeviation)")
    }

    @Test("r6 degenerate: a zero-length stroke (two samples on one spot) is translated only, finite")
    func zeroLengthStrokeIsFinite() throws {
        let dot = [CGPoint(x: 0.3, y: 0.3), CGPoint(x: 0.3, y: 0.3)]
        let m = try #require(StrokeProcessScorer.analyze(points: dot, strokeStartIndices: [], reference: lStrokes))
        #expect(m.spatialDeviation.isFinite && m.spatialDeviationRaw.isFinite)
    }

    @Test("r6 degenerate: the fit has no fittable axis — identity scale, centres aligned")
    func fitWithoutAFittableAxisTranslatesOnly() {
        let fit = StrokeProcessScorer.fitToReference(
            drawn: [[CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.2, y: 0.6)]],     // zero width
            reference: [[CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.9, y: 0.5)]]) // zero height
        let p = fit(CGPoint(x: 0.2, y: 0.6))
        #expect(abs(p.x - 0.7) < 1e-9 && abs(p.y - 0.7) < 1e-9, "expected a pure translation, got \(p)")
    }
}
