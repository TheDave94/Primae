//  StrokeRecognizerTests.swift
//  BuchstabenNativeTests
//
//  Unit tests for StrokeRecognizing protocol + EuclideanStrokeRecognizer
//  and StrokeRecognizerSession coordinator.

import XCTest
import CoreGraphics
@testable import BuchstabenNative

// MARK: - Helpers

private func makeStrokes(
    checkpointRadius: Double = 0.05,
    strokes: [[Checkpoint]]
) -> LetterStrokes {
    LetterStrokes(
        letter: "T",
        checkpointRadius: checkpointRadius,
        strokes: strokes.enumerated().map { idx, cps in
            StrokeDefinition(id: idx + 1, checkpoints: cps)
        }
    )
}

private func cp(_ x: Double, _ y: Double) -> Checkpoint { Checkpoint(x: x, y: y) }
private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

// MARK: - EuclideanStrokeRecognizer unit tests

@MainActor
final class EuclideanStrokeRecognizerTests: XCTestCase {

    let recognizer = EuclideanStrokeRecognizer()

    // pointHitsCheckpoint

    func testHit_atExactCenter() {
        XCTAssertTrue(recognizer.pointHitsCheckpoint(pt(0.5, 0.5), checkpoint: cp(0.5, 0.5), radius: 0.05))
    }

    func testHit_justInsideRadius() {
        let r = 0.05
        let offset = r * (1.0 - 1e-6)
        XCTAssertTrue(recognizer.pointHitsCheckpoint(pt(0.5 + offset, 0.5), checkpoint: cp(0.5, 0.5), radius: r))
    }

    func testMiss_justOutsideRadius() {
        let r = 0.05
        let offset = r * (1.0 + 1e-6)
        XCTAssertFalse(recognizer.pointHitsCheckpoint(pt(0.5 + offset, 0.5), checkpoint: cp(0.5, 0.5), radius: r))
    }

    func testHit_diagonalWithinRadius() {
        // dist = sqrt(0.03² + 0.04²) = 0.05 exactly
        XCTAssertTrue(recognizer.pointHitsCheckpoint(pt(0.53, 0.54), checkpoint: cp(0.5, 0.5), radius: 0.05))
    }

    func testMiss_zeroRadius() {
        // Only exact center hits with radius=0
        XCTAssertTrue(recognizer.pointHitsCheckpoint(pt(0.5, 0.5), checkpoint: cp(0.5, 0.5), radius: 0))
        XCTAssertFalse(recognizer.pointHitsCheckpoint(pt(0.5001, 0.5), checkpoint: cp(0.5, 0.5), radius: 0))
    }

    // evaluate

    func testEvaluate_hit_advancesCheckpoint() {
        let stroke = StrokeDefinition(id: 1, checkpoints: [cp(0.3, 0.3), cp(0.7, 0.7)])
        let current = StrokeMatchResult(accuracy: 0, isComplete: false, nextCheckpointIndex: 0, checkpointCount: 2)
        let result = recognizer.evaluate(point: pt(0.3, 0.3), stroke: stroke, current: current, radius: 0.05)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.nextCheckpointIndex, 1)
        XCTAssertFalse(result!.isComplete)
        XCTAssertEqual(result!.accuracy, 0.5, accuracy: 1e-9)
    }

    func testEvaluate_finalCheckpoint_marksComplete() {
        let stroke = StrokeDefinition(id: 1, checkpoints: [cp(0.5, 0.5)])
        let current = StrokeMatchResult(accuracy: 0, isComplete: false, nextCheckpointIndex: 0, checkpointCount: 1)
        let result = recognizer.evaluate(point: pt(0.5, 0.5), stroke: stroke, current: current, radius: 0.05)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.isComplete)
        XCTAssertEqual(result!.accuracy, 1.0, accuracy: 1e-9)
    }

    func testEvaluate_miss_returnsNil() {
        let stroke = StrokeDefinition(id: 1, checkpoints: [cp(0.5, 0.5)])
        let current = StrokeMatchResult(accuracy: 0, isComplete: false, nextCheckpointIndex: 0, checkpointCount: 1)
        let result = recognizer.evaluate(point: pt(0.9, 0.9), stroke: stroke, current: current, radius: 0.05)
        XCTAssertNil(result)
    }

    func testEvaluate_alreadyComplete_returnsNil() {
        let stroke = StrokeDefinition(id: 1, checkpoints: [cp(0.5, 0.5)])
        let current = StrokeMatchResult(accuracy: 1, isComplete: true, nextCheckpointIndex: 1, checkpointCount: 1)
        let result = recognizer.evaluate(point: pt(0.5, 0.5), stroke: stroke, current: current, radius: 0.05)
        XCTAssertNil(result)
    }
}

// MARK: - StrokeRecognizerSession tests

final class StrokeRecognizerSessionTests: XCTestCase {

    private func makeSession() -> StrokeRecognizerSession {
        StrokeRecognizerSession(recognizer: EuclideanStrokeRecognizer())
    }

    // MARK: Single-stroke

    func testSingleStroke_singleCheckpoint_completes() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.5, 0.5)]]))
        let result = session.update(normalizedPoint: pt(0.5, 0.5))
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.isLetterComplete)
        XCTAssertEqual(result!.overallAccuracy, 1.0, accuracy: 1e-9)
    }

    func testSingleStroke_multiCheckpoint_partialProgress() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.1, 0.1), cp(0.5, 0.5), cp(0.9, 0.9)]]))
        _ = session.update(normalizedPoint: pt(0.1, 0.1))  // hit cp 0
        let r = session.update(normalizedPoint: pt(0.5, 0.5))  // hit cp 1
        XCTAssertFalse(r!.isLetterComplete)
        XCTAssertEqual(r!.overallAccuracy, 2.0/3.0, accuracy: 1e-9)
    }

    func testSingleStroke_mustFollowOrder() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.1, 0.1), cp(0.5, 0.5)]]))
        // Try to hit cp1 before cp0 — should not register
        _ = session.update(normalizedPoint: pt(0.5, 0.5))
        let r = session.result
        XCTAssertEqual(r!.strokeResults[0].nextCheckpointIndex, 0)
    }

    // MARK: Multi-stroke

    func testMultiStroke_secondStrokeOnlyActiveAfterFirst() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [
            [cp(0.1, 0.1)],
            [cp(0.8, 0.8)]
        ]))
        // Try second stroke first — should not register
        _ = session.update(normalizedPoint: pt(0.8, 0.8))
        XCTAssertEqual(session.result!.strokeResults[1].nextCheckpointIndex, 0)

        // Complete first stroke
        _ = session.update(normalizedPoint: pt(0.1, 0.1))
        XCTAssertTrue(session.result!.strokeResults[0].isComplete)

        // Now second stroke registers
        _ = session.update(normalizedPoint: pt(0.8, 0.8))
        XCTAssertTrue(session.result!.isLetterComplete)
    }

    func testMultiStroke_overallAccuracy_acrossStrokes() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [
            [cp(0.1, 0.1), cp(0.2, 0.2)],  // 2 checkpoints
            [cp(0.8, 0.8), cp(0.9, 0.9)]   // 2 checkpoints
        ]))
        _ = session.update(normalizedPoint: pt(0.1, 0.1))  // 1/4
        let r = session.result!
        XCTAssertEqual(r.overallAccuracy, 0.25, accuracy: 1e-9)
    }

    // MARK: Reset

    func testReset_clearsProgress() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.5, 0.5)]]))
        _ = session.update(normalizedPoint: pt(0.5, 0.5))
        session.reset()
        XCTAssertFalse(session.result!.isLetterComplete)
        XCTAssertEqual(session.result!.overallAccuracy, 0, accuracy: 1e-9)
    }

    // MARK: Not loaded

    func testUpdate_withoutLoad_returnsNil() {
        let session = makeSession()
        let result = session.update(normalizedPoint: pt(0.5, 0.5))
        XCTAssertNil(result)
    }

    func testResult_withoutLoad_returnsNil() {
        let session = makeSession()
        XCTAssertNil(session.result)
    }

    // MARK: activeStrokeIndex

    func testActiveStrokeIndex_firstStrokeIncomplete() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.1, 0.1)], [cp(0.9, 0.9)]]))
        XCTAssertEqual(session.result!.activeStrokeIndex, 0)
    }

    func testActiveStrokeIndex_allComplete_equalsCount() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.5, 0.5)]]))
        _ = session.update(normalizedPoint: pt(0.5, 0.5))
        XCTAssertEqual(session.result!.activeStrokeIndex, 1)
    }

    // MARK: Custom recognizer injection

    func testCustomRecognizer_isUsed() {
        // Recognizer that always hits everything
        struct AlwaysHitRecognizer: StrokeRecognizing {
            func pointHitsCheckpoint(_ point: CGPoint, checkpoint: Checkpoint, radius: CGFloat) -> Bool { true }
            func evaluate(point: CGPoint, stroke: StrokeDefinition, current: StrokeMatchResult, radius: CGFloat) -> StrokeMatchResult? {
                let newNext = current.nextCheckpointIndex + 1
                let complete = newNext >= current.checkpointCount
                return StrokeMatchResult(accuracy: CGFloat(newNext)/CGFloat(current.checkpointCount),
                                         isComplete: complete,
                                         nextCheckpointIndex: newNext,
                                         checkpointCount: current.checkpointCount)
            }
        }
        let session = StrokeRecognizerSession(recognizer: AlwaysHitRecognizer())
        session.load(makeStrokes(strokes: [[cp(0.0, 0.0), cp(1.0, 1.0)]]))
        _ = session.update(normalizedPoint: pt(99, 99))  // should hit via AlwaysHit
        let r = session.result!
        XCTAssertEqual(r.strokeResults[0].nextCheckpointIndex, 1)
    }
}
