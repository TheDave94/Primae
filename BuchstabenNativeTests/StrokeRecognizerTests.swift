//  StrokeRecognizerTests.swift
//  BuchstabenNativeTests

import Testing
import CoreGraphics
@testable import BuchstabenNative

private func makeStrokes(checkpointRadius: Double = 0.05, strokes: [[Checkpoint]]) -> LetterStrokes {
    LetterStrokes(letter: "T", checkpointRadius: checkpointRadius,
        strokes: strokes.enumerated().map { idx, cps in StrokeDefinition(id: idx + 1, checkpoints: cps) })
}
private func cp(_ x: Double, _ y: Double) -> Checkpoint { Checkpoint(x: x, y: y) }
private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y) }

@Suite @MainActor struct EuclideanStrokeRecognizerTests {
    let recognizer = EuclideanStrokeRecognizer()

    @Test func hit_atExactCenter() {
        #expect(recognizer.pointHitsCheckpoint(pt(0.5, 0.5), checkpoint: cp(0.5, 0.5), radius: 0.05))
    }
    @Test func hit_justInsideRadius() {
        let r = 0.05
        #expect(recognizer.pointHitsCheckpoint(pt(0.5 + r*(1-1e-6), 0.5), checkpoint: cp(0.5, 0.5), radius: r))
    }
    @Test func miss_justOutsideRadius() {
        let r = 0.05
        #expect(!recognizer.pointHitsCheckpoint(pt(0.5 + r*(1+1e-6), 0.5), checkpoint: cp(0.5, 0.5), radius: r))
    }
    @Test func hit_diagonalWithinRadius() {
        #expect(recognizer.pointHitsCheckpoint(pt(0.53, 0.54), checkpoint: cp(0.5, 0.5), radius: 0.0501))
    }
    @Test func miss_zeroRadius() {
        #expect(recognizer.pointHitsCheckpoint(pt(0.5, 0.5), checkpoint: cp(0.5, 0.5), radius: 0))
        #expect(!recognizer.pointHitsCheckpoint(pt(0.5001, 0.5), checkpoint: cp(0.5, 0.5), radius: 0))
    }
    @Test func evaluate_hit_advancesCheckpoint() {
        let stroke = StrokeDefinition(id: 1, checkpoints: [cp(0.3, 0.3), cp(0.7, 0.7)])
        let current = StrokeMatchResult(accuracy: 0, isComplete: false, nextCheckpointIndex: 0, checkpointCount: 2)
        let result = recognizer.evaluate(point: pt(0.3, 0.3), stroke: stroke, current: current, radius: 0.05)
        #expect(result != nil)
        #expect(result!.nextCheckpointIndex == 1)
        #expect(!result!.isComplete)
        #expect(abs(result!.accuracy - 0.5) < 1e-9)
    }
    @Test func evaluate_finalCheckpoint_marksComplete() {
        let stroke = StrokeDefinition(id: 1, checkpoints: [cp(0.5, 0.5)])
        let current = StrokeMatchResult(accuracy: 0, isComplete: false, nextCheckpointIndex: 0, checkpointCount: 1)
        let result = recognizer.evaluate(point: pt(0.5, 0.5), stroke: stroke, current: current, radius: 0.05)
        #expect(result != nil)
        #expect(result!.isComplete)
        #expect(abs(result!.accuracy - 1.0) < 1e-9)
    }
    @Test func evaluate_miss_returnsNil() {
        let stroke = StrokeDefinition(id: 1, checkpoints: [cp(0.5, 0.5)])
        let current = StrokeMatchResult(accuracy: 0, isComplete: false, nextCheckpointIndex: 0, checkpointCount: 1)
        #expect(recognizer.evaluate(point: pt(0.9, 0.9), stroke: stroke, current: current, radius: 0.05) == nil)
    }
    @Test func evaluate_alreadyComplete_returnsNil() {
        let stroke = StrokeDefinition(id: 1, checkpoints: [cp(0.5, 0.5)])
        let current = StrokeMatchResult(accuracy: 1, isComplete: true, nextCheckpointIndex: 1, checkpointCount: 1)
        #expect(recognizer.evaluate(point: pt(0.5, 0.5), stroke: stroke, current: current, radius: 0.05) == nil)
    }
}

@Suite struct StrokeRecognizerSessionTests {
    private func makeSession() -> StrokeRecognizerSession {
        StrokeRecognizerSession(recognizer: EuclideanStrokeRecognizer())
    }

    @Test func singleStroke_singleCheckpoint_completes() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.5, 0.5)]]))
        let result = session.update(normalizedPoint: pt(0.5, 0.5))
        #expect(result != nil)
        #expect(result!.isLetterComplete)
        #expect(abs(result!.overallAccuracy - 1.0) < 1e-9)
    }
    @Test func singleStroke_multiCheckpoint_partialProgress() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.1, 0.1), cp(0.5, 0.5), cp(0.9, 0.9)]]))
        _ = session.update(normalizedPoint: pt(0.1, 0.1))
        let r = session.update(normalizedPoint: pt(0.5, 0.5))
        #expect(!r!.isLetterComplete)
        #expect(abs(r!.overallAccuracy - 2.0/3.0) < 1e-9)
    }
    @Test func singleStroke_mustFollowOrder() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.1, 0.1), cp(0.5, 0.5)]]))
        _ = session.update(normalizedPoint: pt(0.5, 0.5))
        #expect(session.result!.strokeResults[0].nextCheckpointIndex == 0)
    }
    @Test func multiStroke_secondStrokeOnlyActiveAfterFirst() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.1, 0.1)], [cp(0.8, 0.8)]]))
        _ = session.update(normalizedPoint: pt(0.8, 0.8))
        #expect(session.result!.strokeResults[1].nextCheckpointIndex == 0)
        _ = session.update(normalizedPoint: pt(0.1, 0.1))
        #expect(session.result!.strokeResults[0].isComplete)
        _ = session.update(normalizedPoint: pt(0.8, 0.8))
        #expect(session.result!.isLetterComplete)
    }
    @Test func multiStroke_overallAccuracy_acrossStrokes() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.1, 0.1), cp(0.2, 0.2)], [cp(0.8, 0.8), cp(0.9, 0.9)]]))
        _ = session.update(normalizedPoint: pt(0.1, 0.1))
        #expect(abs(session.result!.overallAccuracy - 0.25) < 1e-9)
    }
    @Test func reset_clearsProgress() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.5, 0.5)]]))
        _ = session.update(normalizedPoint: pt(0.5, 0.5))
        session.reset()
        #expect(!session.result!.isLetterComplete)
        #expect(abs(session.result!.overallAccuracy) < 1e-9)
    }
    @Test func update_withoutLoad_returnsNil() {
        #expect(makeSession().update(normalizedPoint: pt(0.5, 0.5)) == nil)
    }
    @Test func result_withoutLoad_returnsNil() {
        #expect(makeSession().result == nil)
    }
    @Test func activeStrokeIndex_firstStrokeIncomplete() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.1, 0.1)], [cp(0.9, 0.9)]]))
        #expect(session.result!.activeStrokeIndex == 0)
    }
    @Test func activeStrokeIndex_allComplete_equalsCount() {
        let session = makeSession()
        session.load(makeStrokes(strokes: [[cp(0.5, 0.5)]]))
        _ = session.update(normalizedPoint: pt(0.5, 0.5))
        #expect(session.result!.activeStrokeIndex == 1)
    }
    @Test func customRecognizer_isUsed() {
        struct AlwaysHitRecognizer: StrokeRecognizing {
            func pointHitsCheckpoint(_ point: CGPoint, checkpoint: Checkpoint, radius: CGFloat) -> Bool { true }
            func evaluate(point: CGPoint, stroke: StrokeDefinition, current: StrokeMatchResult, radius: CGFloat) -> StrokeMatchResult? {
                let newNext = current.nextCheckpointIndex + 1
                return StrokeMatchResult(accuracy: CGFloat(newNext)/CGFloat(current.checkpointCount),
                    isComplete: newNext >= current.checkpointCount,
                    nextCheckpointIndex: newNext, checkpointCount: current.checkpointCount)
            }
        }
        let session = StrokeRecognizerSession(recognizer: AlwaysHitRecognizer())
        session.load(makeStrokes(strokes: [[cp(0.0, 0.0), cp(1.0, 1.0)]]))
        _ = session.update(normalizedPoint: pt(99, 99))
        #expect(session.result!.strokeResults[0].nextCheckpointIndex == 1)
    }
}
