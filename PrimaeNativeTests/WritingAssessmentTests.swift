// Unit coverage for the three non-form Schreibmotorik dimensions and the
// weighted overallScore on `WritingAssessment`. Form accuracy has its own
// coverage in FreeWriteScorerTests via Fréchet distance fixtures.
//
// The dimension implementations in FreeWriteScorer are file-private, so
// these tests exercise them through `FreeWriteScorer.score(...)` and
// assert on the resulting WritingAssessment fields. Form inputs are kept
// constant so any score variation comes from the dimension under test.

import Testing
import CoreGraphics
import Foundation
@testable import PrimaeNative

struct WritingAssessmentTests {

    // MARK: - Fixtures

    /// Reference polyline: a straight vertical line of 5 points at x=0.5,
    /// y ∈ [0.2, 0.8]. Large enough radius that formAccuracy never collapses
    /// the other dimensions through a weighted-sum dominance effect, though
    /// these tests assert on individual dimensions directly.
    private var verticalReference: LetterStrokes {
        LetterStrokes(
            letter: "I", checkpointRadius: 0.10,
            strokes: [StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.35),
                Checkpoint(x: 0.5, y: 0.5), Checkpoint(x: 0.5, y: 0.65),
                Checkpoint(x: 0.5, y: 0.8),
            ])]
        )
    }

    /// Matching perfect trace for the vertical reference.
    private var verticalTrace: [CGPoint] {
        [
            CGPoint(x: 0.5, y: 0.20), CGPoint(x: 0.5, y: 0.35),
            CGPoint(x: 0.5, y: 0.50), CGPoint(x: 0.5, y: 0.65),
            CGPoint(x: 0.5, y: 0.80),
        ]
    }

    // MARK: - tempoConsistency

    /// Fewer than three timestamps can't yield a meaningful variance, so the
    /// dimension returns the neutral baseline 1.0. Documents the guard.
    @Test("tempoConsistency with <3 timestamps returns neutral 1.0")
    func tempo_fewSamples_isNeutral() {
        let a = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            timestamps: [])
        let b = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            timestamps: [0.0, 0.05])
        #expect(a.tempoConsistency == 1.0)
        #expect(b.tempoConsistency == 1.0)
    }

    /// A vertical stroke of `count` samples, `step` apart in y, for the
    /// tempo tests (r16: tempo reads the points as well as the clock).
    private func verticalSamples(_ count: Int, step: CGFloat = 0.01) -> [CGPoint] {
        (0..<count).map { CGPoint(x: 0.5, y: 0.2 + CGFloat($0) * step) }
    }

    /// Constant speed → every windowed speed equal → variance 0 → 1.0.
    @Test("tempoConsistency at constant speed is 1.0")
    func tempo_uniform_isMax() {
        // 20 evenly-spaced samples, 50 ms each.
        let timestamps: [CFTimeInterval] = (0..<20).map { Double($0) * 0.05 }
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalSamples(20), reference: verticalReference,
            timestamps: timestamps)
        #expect(abs(assessment.tempoConsistency - 1.0) < 1e-9)
    }

    /// Alternating slow and fast stretches inside one stroke: the windowed
    /// speed varies and the score drops below 1 (r16: speed, not interval).
    @Test("tempoConsistency with a varying speed drops below 1.0")
    func tempo_varying_isBelowMax() {
        // Same distance per sample, alternating 0.1 s and 0.3 s per sample.
        var t: CFTimeInterval = 0
        var timestamps: [CFTimeInterval] = [t]
        for i in 0..<15 {
            t += (i % 2 == 0) ? 0.1 : 0.3
            timestamps.append(t)
        }
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalSamples(16), reference: verticalReference,
            timestamps: timestamps)
        #expect(assessment.tempoConsistency < 1.0)
        #expect(assessment.tempoConsistency >= 0.0)
    }

    /// A pen lift is the time across a `strokeStartIndices` boundary; it is
    /// excluded at ANY length (r16, audit B-8: before, only lifts of 0.5 s
    /// or more were, and a quick lift drove tempo to 0).
    @Test("tempoConsistency ignores pen lifts of any length")
    func tempo_liftsExcluded() {
        for lift in [0.2, 2.0] {
            var timestamps: [CFTimeInterval] = []
            var t: CFTimeInterval = 0
            for _ in 0..<10 { timestamps.append(t); t += 0.05 }
            t += lift - 0.05
            for _ in 0..<10 { timestamps.append(t); t += 0.05 }
            let assessment = FreeWriteScorer.score(
                tracedPoints: verticalSamples(20), strokeStartIndices: [10],
                reference: verticalReference, timestamps: timestamps)
            #expect(abs(assessment.tempoConsistency - 1.0) < 1e-9, "lift \(lift) s")
        }
    }

    // MARK: - pressureControl

    /// Empty forces array is the default in `score(forces:)` — returns 1.0
    /// so traces without digitizer data don't get penalised.
    @Test("pressureControl with no forces returns 1.0")
    func pressure_empty_isNeutral() {
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference)
        #expect(assessment.pressureControl == 1.0)
    }

    /// Finger input reports force = 0; treated as "no pressure data".
    @Test("pressureControl with all-zero forces (finger) returns 1.0")
    func pressure_allZero_isNeutral() {
        let forces: [CGFloat] = Array(repeating: 0, count: 10)
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            forces: forces)
        #expect(assessment.pressureControl == 1.0)
    }

    /// Fewer than two non-zero samples can't yield variance — neutral 1.0.
    @Test("pressureControl with <2 active samples returns 1.0")
    func pressure_sparseActive_isNeutral() {
        let forces: [CGFloat] = [0, 0, 0.5, 0, 0]
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            forces: forces)
        #expect(assessment.pressureControl == 1.0)
    }

    /// Constant non-zero force → variance = 0 → score = 1.0.
    @Test("pressureControl with constant force is 1.0")
    func pressure_constant_isMax() {
        let forces: [CGFloat] = Array(repeating: 0.6, count: 10)
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            forces: forces)
        #expect(abs(assessment.pressureControl - 1.0) < 1e-9)
    }

    /// Wildly-varying force drops the score below 1.
    @Test("pressureControl with alternating force drops below 1.0")
    func pressure_varying_isBelowMax() {
        // Alternating heavy/light press — high CV.
        let forces: [CGFloat] = (0..<10).map { $0 % 2 == 0 ? 0.1 : 0.9 }
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            forces: forces)
        #expect(assessment.pressureControl < 1.0)
        #expect(assessment.pressureControl >= 0.0)
    }

    // MARK: - rhythmScore

    /// Zero-length session (start == end) returns 0 per the guard clause.
    @Test("rhythmScore with zero session duration returns 0")
    func rhythm_zeroDuration_isZero() {
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            timestamps: [0, 0.05, 0.1],
            sessionStart: 10.0, sessionEnd: 10.0)
        #expect(assessment.rhythmScore == 0)
    }

    /// Empty timestamps returns 0 (nothing to count as active).
    @Test("rhythmScore with no timestamps returns 0")
    func rhythm_noTimestamps_isZero() {
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            timestamps: [], sessionStart: 0, sessionEnd: 1.0)
        #expect(assessment.rhythmScore == 0)
    }

    /// Continuous drawing where every dt < 0.5 s → active ≈ total → ≈ 1.0.
    @Test("rhythmScore for fully continuous trace approaches 1.0")
    func rhythm_continuous_nearMax() {
        // 20 samples evenly across a 1 s session.
        let timestamps: [CFTimeInterval] = (0..<20).map { Double($0) * 0.05 }
        let sessionEnd = timestamps.last ?? 0
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            timestamps: timestamps,
            sessionStart: 0, sessionEnd: sessionEnd)
        // activeTime == sum of 19 × 0.05 s == 0.95, sessionEnd == 0.95 → 1.0.
        #expect(abs(assessment.rhythmScore - 1.0) < 1e-9)
    }

    /// Long pauses (>= 0.5 s) are excluded from active time, dropping the
    /// ratio below 1.0.
    @Test("rhythmScore drops when long pauses dominate the session")
    func rhythm_longPause_dropsRatio() {
        // Two short bursts (~0.25 s each) separated by a 3 s idle gap.
        let burst1: [CFTimeInterval] = [0.00, 0.05, 0.10, 0.15, 0.20, 0.25]
        let gap: CFTimeInterval = 3.0
        let burst2: [CFTimeInterval] = burst1.map { $0 + 0.25 + gap }
        let timestamps = burst1 + burst2
        let sessionEnd = timestamps.last ?? 0
        let assessment = FreeWriteScorer.score(
            tracedPoints: verticalTrace, reference: verticalReference,
            timestamps: timestamps,
            sessionStart: 0, sessionEnd: sessionEnd)
        // Active ≈ 2 × (5 × 0.05) == 0.50; total ≈ 3.50 → ratio ≈ 0.14.
        #expect(assessment.rhythmScore < 0.3)
        #expect(assessment.rhythmScore > 0.0)
    }

    // MARK: - overallScore weighting

    /// All-zero dimensions → overallScore 0.
    @Test("overallScore is 0 when every dimension is 0")
    func overall_zero() {
        let a = WritingAssessment(formAccuracy: 0, tempoConsistency: 0,
                                  pressureControl: 0, rhythmScore: 0)
        #expect(a.overallScore == 0)
    }

    /// All-one dimensions → overallScore 1.0 (weights must sum to 1).
    @Test("overallScore is 1.0 when every dimension is 1.0")
    func overall_one() {
        let a = WritingAssessment(formAccuracy: 1, tempoConsistency: 1,
                                  pressureControl: 1, rhythmScore: 1)
        #expect(abs(a.overallScore - 1.0) < 1e-9)
    }

    /// Each dimension drives the overall score by its documented weight.
    /// Form = 40 %, Tempo = 25 %, Druck = 15 %, Rhythmus = 20 %.
    @Test("overallScore respects per-dimension weights",
          arguments: [
            (CGFloat(1), CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(0.40)),
            (CGFloat(0), CGFloat(1), CGFloat(0), CGFloat(0), CGFloat(0.25)),
            (CGFloat(0), CGFloat(0), CGFloat(1), CGFloat(0), CGFloat(0.15)),
            (CGFloat(0), CGFloat(0), CGFloat(0), CGFloat(1), CGFloat(0.20)),
          ])
    func overall_weights(form: CGFloat, tempo: CGFloat, pressure: CGFloat,
                         rhythm: CGFloat, expected: CGFloat) {
        let a = WritingAssessment(formAccuracy: form, tempoConsistency: tempo,
                                  pressureControl: pressure, rhythmScore: rhythm)
        #expect(abs(a.overallScore - expected) < 1e-9)
    }

    /// Mixed dimensions sum correctly: catches any future regression where
    /// someone re-orders weights or drops a dimension from the sum.
    @Test("overallScore sums a known mix correctly")
    func overall_knownMix() {
        let a = WritingAssessment(formAccuracy: 0.5, tempoConsistency: 0.8,
                                  pressureControl: 0.0, rhythmScore: 1.0)
        // 0.5·0.40 + 0.8·0.25 + 0.0·0.15 + 1.0·0.20 = 0.20 + 0.20 + 0 + 0.20 = 0.60
        #expect(abs(a.overallScore - 0.60) < 1e-9)
    }
}
