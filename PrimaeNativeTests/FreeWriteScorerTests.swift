import Testing
import CoreGraphics
@testable import PrimaeNative

struct FreeWriteScorerTests {

    // MARK: - Fixtures

    private var verticalLineStrokes: LetterStrokes {
        LetterStrokes(
            letter: "I", checkpointRadius: 0.04,
            strokes: [StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2),  Checkpoint(x: 0.5, y: 0.35),
                Checkpoint(x: 0.5, y: 0.5),  Checkpoint(x: 0.5, y: 0.65),
                Checkpoint(x: 0.5, y: 0.8),
            ])]
        )
    }

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

    // MARK: - Scoring

    @Test("Perfect trace scores above 0.9")
    func perfectTrace() {
        let traced: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.5, y: 0.35),
            CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.65),
            CGPoint(x: 0.5, y: 0.8),
        ]
        let assessment = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        #expect(assessment.formAccuracy > 0.9)
    }

    @Test("Near-perfect trace scores above 0.8")
    func nearPerfectTrace() {
        let traced: [CGPoint] = [
            CGPoint(x: 0.51, y: 0.2), CGPoint(x: 0.49, y: 0.35),
            CGPoint(x: 0.52, y: 0.5), CGPoint(x: 0.48, y: 0.65),
            CGPoint(x: 0.51, y: 0.8),
        ]
        let assessment = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        #expect(assessment.formAccuracy > 0.8)
    }

    @Test("Completely off-path scores below 0.3")
    func offPath() {
        let traced: [CGPoint] = [
            CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.15, y: 0.15),
            CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.1, y: 0.3),
            CGPoint(x: 0.05, y: 0.1),
        ]
        let assessment = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        #expect(assessment.formAccuracy < 0.3)
    }

    @Test("Reversed trace penalises direction")
    func reversedTrace() {
        let traced: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.5, y: 0.65),
            CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.35),
            CGPoint(x: 0.5, y: 0.2),
        ]
        let assessment = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        #expect(assessment.formAccuracy < 0.5)
    }

    @Test("Multi-stroke L-shape scores well")
    func multiStroke() {
        let traced: [CGPoint] = [
            CGPoint(x: 0.4, y: 0.2), CGPoint(x: 0.4, y: 0.4),
            CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.4, y: 0.8),
            CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.6, y: 0.8),
            CGPoint(x: 0.7, y: 0.8), CGPoint(x: 0.8, y: 0.8),
        ]
        let assessment = FreeWriteScorer.score(tracedPoints: traced, reference: lStrokes)
        #expect(assessment.formAccuracy > 0.7)
    }

    // MARK: - Edge cases

    @Test("Empty input returns zero",
          arguments: [
            ([] as [CGPoint], true),
            ([CGPoint(x: 0.5, y: 0.5)], true),
          ])
    func emptyOrSingleInput(points: [CGPoint], expectZero: Bool) {
        let assessment = FreeWriteScorer.score(tracedPoints: points, reference: verticalLineStrokes)
        if expectZero { #expect(assessment.formAccuracy == 0) }
    }

    @Test("Empty reference returns zero")
    func emptyReference() {
        let empty = LetterStrokes(letter: "X", checkpointRadius: 0.04, strokes: [])
        let traced = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.6)]
        #expect(FreeWriteScorer.score(tracedPoints: traced, reference: empty).formAccuracy == 0)
    }

    @Test("Zero radius returns zero")
    func zeroRadius() {
        let strokes = LetterStrokes(
            letter: "I", checkpointRadius: 0,
            strokes: [StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8),
            ])]
        )
        let traced = [CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.5, y: 0.8)]
        #expect(FreeWriteScorer.score(tracedPoints: traced, reference: strokes).formAccuracy == 0)
    }

    // MARK: - formAccuracyShape

    /// `formAccuracyShape` is the freeform-mode scorer (blank canvas:
    /// stroke order, pen-lift count, absolute position all irrelevant).
    /// The order-free Hausdorff guarantee is the meaningful contract.
    @Test("formAccuracyShape: identical trace and reference scores high")
    func formAccuracyShapeIdentical() {
        let strokes = LetterStrokes(letter: "I", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8)
            ])
        ])
        let traced = (0...20).map { CGPoint(x: 0.5, y: 0.2 + 0.6 * Double($0) / 20) }
        #expect(FreeWriteScorer.formAccuracyShape(tracedPoints: traced, reference: strokes) > 0.85)
    }

    @Test("formAccuracyShape: scribble far from reference scores near zero")
    func formAccuracyShapeScribble() {
        let strokes = LetterStrokes(letter: "I", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8)
            ])
        ])
        // Random clump in upper-left corner with no relation to the I.
        let traced = (0...20).map { i -> CGPoint in
            let t = Double(i) / 20
            return CGPoint(x: 0.05 + 0.05 * t, y: 0.05 + 0.05 * sin(t * 6))
        }
        #expect(FreeWriteScorer.formAccuracyShape(tracedPoints: traced, reference: strokes) < 0.5)
    }

    @Test("formAccuracyShape: order-free — reversed trace scores the same")
    func formAccuracyShapeOrderFree() {
        let strokes = LetterStrokes(letter: "I", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8)
            ])
        ])
        let forward = (0...20).map { CGPoint(x: 0.5, y: 0.2 + 0.6 * Double($0) / 20) }
        let reversed = forward.reversed().map { $0 }
        let s1 = FreeWriteScorer.formAccuracyShape(tracedPoints: forward, reference: strokes)
        let s2 = FreeWriteScorer.formAccuracyShape(tracedPoints: reversed, reference: strokes)
        #expect(abs(s1 - s2) < 1e-6, "Hausdorff is order-free; reversed trace must score identically")
    }

    @Test("formAccuracyShape: empty inputs return zero")
    func formAccuracyShapeEmpty() {
        let strokes = LetterStrokes(letter: "I", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8)
            ])
        ])
        #expect(FreeWriteScorer.formAccuracyShape(tracedPoints: [], reference: strokes) == 0)
        let emptyRef = LetterStrokes(letter: "X", checkpointRadius: 0.04, strokes: [])
        let traced = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.6)]
        #expect(FreeWriteScorer.formAccuracyShape(tracedPoints: traced, reference: emptyRef) == 0)
    }

    // MARK: - Fréchet distance

    @Test("Identical curves have zero Fréchet distance")
    func frechetIdentical() {
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
        #expect(FreeWriteScorer.discreteFrechetDistance(p, p) < 1e-10)
    }

    @Test("Parallel lines have distance equal to offset")
    func frechetParallel() {
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]
        let q = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
        #expect(abs(FreeWriteScorer.discreteFrechetDistance(p, q) - 1.0) < 1e-10)
    }

    @Test("Single points: distance is Euclidean")
    func frechetSinglePoints() {
        let p = [CGPoint(x: 0, y: 0)]
        let q = [CGPoint(x: 3, y: 4)]
        #expect(abs(FreeWriteScorer.discreteFrechetDistance(p, q) - 5.0) < 1e-10)
    }

    // MARK: - Resampling

    @Test("Resample preserves endpoints")
    func resampleEndpoints() {
        let input = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
        let resampled = FreeWriteScorer.resample(input, targetCount: 5)
        #expect(resampled.count == 5)
        #expect(abs(resampled.first!.x) < 1e-10)
        #expect(abs(resampled.last!.x - 2.0) < 1e-10)
    }

    @Test("Resample midpoint is correct")
    func resampleMidpoint() {
        let input = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0)]
        let resampled = FreeWriteScorer.resample(input, targetCount: 3)
        #expect(resampled.count == 3)
        #expect(abs(resampled[1].x - 2.0) < 1e-10)
    }

    // MARK: - Symmetry (Eiter & Mannila 1994 — discrete Fréchet is symmetric)

    @Test("Discrete Fréchet distance is symmetric")
    func frechetSymmetric() {
        let p: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 0)]
        let q: [CGPoint] = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 0),
                            CGPoint(x: 2, y: 1), CGPoint(x: 3, y: 0)]
        let d1 = FreeWriteScorer.discreteFrechetDistance(p, q)
        let d2 = FreeWriteScorer.discreteFrechetDistance(q, p)
        #expect(abs(d1 - d2) < 1e-10,
                "discreteFrechetDistance(p,q) = \(d1) but (q,p) = \(d2) — must be symmetric")
    }

    @Test("Identical curves produce zero distance")
    func frechetZeroForIdentical() {
        let p: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
        #expect(FreeWriteScorer.discreteFrechetDistance(p, p) == 0)
    }

    @Test("Single-point curves produce Euclidean distance")
    func frechetSinglePoint() {
        let a: [CGPoint] = [CGPoint(x: 0, y: 0)]
        let b: [CGPoint] = [CGPoint(x: 3, y: 4)]
        let d = FreeWriteScorer.discreteFrechetDistance(a, b)
        #expect(abs(d - 5.0) < 1e-10,
                "Single-point discrete Fréchet should equal Euclidean (3-4-5), got \(d)")
    }
}
