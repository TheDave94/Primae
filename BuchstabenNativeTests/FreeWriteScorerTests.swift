// FreeWriteScorerTests.swift
// BuchstabenNativeTests

import XCTest
import CoreGraphics
@testable import BuchstabenNative

final class FreeWriteScorerTests: XCTestCase {

    // MARK: - Test fixtures

    /// Simple vertical line reference: 5 checkpoints from (0.5, 0.2) to (0.5, 0.8).
    private var verticalLineStrokes: LetterStrokes {
        LetterStrokes(
            letter: "I",
            checkpointRadius: 0.04,
            strokes: [
                StrokeDefinition(id: 1, checkpoints: [
                    Checkpoint(x: 0.5, y: 0.2),
                    Checkpoint(x: 0.5, y: 0.35),
                    Checkpoint(x: 0.5, y: 0.5),
                    Checkpoint(x: 0.5, y: 0.65),
                    Checkpoint(x: 0.5, y: 0.8),
                ])
            ]
        )
    }

    /// Two-stroke "L" reference.
    private var lStrokes: LetterStrokes {
        LetterStrokes(
            letter: "L",
            checkpointRadius: 0.04,
            strokes: [
                StrokeDefinition(id: 1, checkpoints: [
                    Checkpoint(x: 0.4, y: 0.2),
                    Checkpoint(x: 0.4, y: 0.5),
                    Checkpoint(x: 0.4, y: 0.8),
                ]),
                StrokeDefinition(id: 2, checkpoints: [
                    Checkpoint(x: 0.4, y: 0.8),
                    Checkpoint(x: 0.6, y: 0.8),
                    Checkpoint(x: 0.8, y: 0.8),
                ])
            ]
        )
    }

    // MARK: - Scoring tests

    func testPerfectTraceScoresHigh() {
        // Trace exactly along the reference points.
        let traced: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.2),
            CGPoint(x: 0.5, y: 0.35),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.5, y: 0.65),
            CGPoint(x: 0.5, y: 0.8),
        ]
        let score = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        XCTAssertGreaterThan(score, 0.9, "Perfect trace should score > 0.9")
    }

    func testNearPerfectTraceScoresHigh() {
        // Slightly offset trace — within checkpoint radius.
        let traced: [CGPoint] = [
            CGPoint(x: 0.51, y: 0.2),
            CGPoint(x: 0.49, y: 0.35),
            CGPoint(x: 0.52, y: 0.5),
            CGPoint(x: 0.48, y: 0.65),
            CGPoint(x: 0.51, y: 0.8),
        ]
        let score = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        XCTAssertGreaterThan(score, 0.8, "Near-perfect trace should score > 0.8")
    }

    func testCompletelyOffPathScoresLow() {
        // Trace in the wrong area entirely.
        let traced: [CGPoint] = [
            CGPoint(x: 0.1, y: 0.1),
            CGPoint(x: 0.15, y: 0.15),
            CGPoint(x: 0.2, y: 0.2),
            CGPoint(x: 0.1, y: 0.3),
            CGPoint(x: 0.05, y: 0.1),
        ]
        let score = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        XCTAssertLessThan(score, 0.3, "Off-path trace should score < 0.3")
    }

    func testPartialTraceScoresMidRange() {
        // Only trace the first half of the vertical line.
        let traced: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.2),
            CGPoint(x: 0.5, y: 0.3),
            CGPoint(x: 0.5, y: 0.4),
            CGPoint(x: 0.5, y: 0.5),
        ]
        let score = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        // Partial trace: Fréchet distance will be the max deviation, which is
        // the distance from (0.5, 0.5) to (0.5, 0.8) = 0.3.
        // This is beyond 3× radius (0.12), so score should be low-to-mid.
        XCTAssertLessThan(score, 0.8, "Partial trace should not score as highly as full trace")
    }

    func testReversedTraceStillScoresReasonably() {
        // Trace the line backwards — Fréchet distance handles this
        // by finding optimal matching, though reversed order increases it.
        let traced: [CGPoint] = [
            CGPoint(x: 0.5, y: 0.8),
            CGPoint(x: 0.5, y: 0.65),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.5, y: 0.35),
            CGPoint(x: 0.5, y: 0.2),
        ]
        let score = FreeWriteScorer.score(tracedPoints: traced, reference: verticalLineStrokes)
        // Reversed path: Fréchet distance will be high because the matching
        // is monotone — (0.8 vs 0.2) at start = 0.6 distance.
        // This is expected: stroke direction matters in handwriting!
        XCTAssertLessThan(score, 0.5, "Reversed trace should penalise (direction matters)")
    }

    func testMultiStrokeLetter() {
        // Trace an "L" shape matching the reference.
        let traced: [CGPoint] = [
            CGPoint(x: 0.4, y: 0.2),
            CGPoint(x: 0.4, y: 0.4),
            CGPoint(x: 0.4, y: 0.6),
            CGPoint(x: 0.4, y: 0.8),
            CGPoint(x: 0.5, y: 0.8),
            CGPoint(x: 0.6, y: 0.8),
            CGPoint(x: 0.7, y: 0.8),
            CGPoint(x: 0.8, y: 0.8),
        ]
        let score = FreeWriteScorer.score(tracedPoints: traced, reference: lStrokes)
        XCTAssertGreaterThan(score, 0.7, "L-shape trace should score well")
    }

    // MARK: - Edge cases

    func testEmptyTracedPathReturnsZero() {
        let score = FreeWriteScorer.score(tracedPoints: [], reference: verticalLineStrokes)
        XCTAssertEqual(score, 0)
    }

    func testSingleTracedPointReturnsZero() {
        let score = FreeWriteScorer.score(
            tracedPoints: [CGPoint(x: 0.5, y: 0.5)],
            reference: verticalLineStrokes
        )
        XCTAssertEqual(score, 0)
    }

    func testEmptyReferenceReturnsZero() {
        let emptyStrokes = LetterStrokes(letter: "X", checkpointRadius: 0.04, strokes: [])
        let traced = [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.5, y: 0.6)]
        let score = FreeWriteScorer.score(tracedPoints: traced, reference: emptyStrokes)
        XCTAssertEqual(score, 0)
    }

    func testZeroRadiusReturnsZero() {
        let strokes = LetterStrokes(
            letter: "I", checkpointRadius: 0,
            strokes: [StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0.5, y: 0.2), Checkpoint(x: 0.5, y: 0.8)
            ])]
        )
        let traced = [CGPoint(x: 0.5, y: 0.2), CGPoint(x: 0.5, y: 0.8)]
        let score = FreeWriteScorer.score(tracedPoints: traced, reference: strokes)
        XCTAssertEqual(score, 0)
    }

    // MARK: - Fréchet distance unit tests

    func testFrechetDistanceIdenticalCurves() {
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
        let d = FreeWriteScorer.discreteFrechetDistance(p, p)
        XCTAssertEqual(d, 0, accuracy: 1e-10)
    }

    func testFrechetDistanceParallelLines() {
        let p = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)]
        let q = [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
        let d = FreeWriteScorer.discreteFrechetDistance(p, q)
        // Parallel lines offset by 1 → Fréchet distance = 1.
        XCTAssertEqual(d, 1.0, accuracy: 1e-10)
    }

    func testFrechetDistanceSinglePoints() {
        let p = [CGPoint(x: 0, y: 0)]
        let q = [CGPoint(x: 3, y: 4)]
        let d = FreeWriteScorer.discreteFrechetDistance(p, q)
        XCTAssertEqual(d, 5.0, accuracy: 1e-10) // 3-4-5 triangle
    }

    // MARK: - Resampling tests

    func testResamplePreservesEndpoints() {
        let input = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 2, y: 0)]
        let resampled = FreeWriteScorer.resample(input, targetCount: 5)
        XCTAssertEqual(resampled.count, 5)
        XCTAssertEqual(resampled.first?.x ?? -1, 0, accuracy: 1e-10)
        XCTAssertEqual(resampled.last?.x ?? -1, 2, accuracy: 1e-10)
    }

    func testResampleMidpoint() {
        let input = [CGPoint(x: 0, y: 0), CGPoint(x: 4, y: 0)]
        let resampled = FreeWriteScorer.resample(input, targetCount: 3)
        XCTAssertEqual(resampled.count, 3)
        XCTAssertEqual(resampled[1].x, 2.0, accuracy: 1e-10)
    }

    func testResampleSinglePointReturnsInput() {
        let input = [CGPoint(x: 0.5, y: 0.5)]
        let resampled = FreeWriteScorer.resample(input, targetCount: 5)
        XCTAssertEqual(resampled.count, 1)
    }
}
