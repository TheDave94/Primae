//  LetterAnimationGuideTests.swift
//  BuchstabenNativeTests

import XCTest
import CoreGraphics
@testable import BuchstabenNative

// MARK: - Helpers

private func makeSteps(count: Int, duration: TimeInterval = 0.3) -> [AnimationStep] {
    (0..<count).map {
        AnimationStep(strokeIndex: 0, checkpointIndex: $0,
                      point: CGPoint(x: Double($0) * 0.1, y: 0.5),
                      segmentDuration: duration)
    }
}

private func makeGuide(stepCount: Int = 4, duration: TimeInterval = 0.3) -> LetterAnimationGuide {
    LetterAnimationGuide(steps: makeSteps(count: stepCount, duration: duration))
}

// MARK: - AnimationSpeed tests

@MainActor
final class AnimationSpeedTests: XCTestCase {

    func testNormalMultiplier_isOne() async {
        XCTAssertEqual(AnimationSpeed.normal.multiplier, 1.0, accuracy: 1e-9)
    }

    func testSlowMultiplier_lessThanOne() async {
        XCTAssertLessThan(AnimationSpeed.slow.multiplier, 1.0)
    }

    func testFastMultiplier_greaterThanOne() async {
        XCTAssertGreaterThan(AnimationSpeed.fast.multiplier, 1.0)
    }

    func testAllCases_count() async {
        XCTAssertEqual(AnimationSpeed.allCases.count, 3)
    }
}

// MARK: - LetterAnimationGuide state tests

final class LetterAnimationGuideTests: XCTestCase {

    func testInitialState_idle() async {
        let guide = makeGuide()
        XCTAssertEqual(guide.playbackState, .idle)
    }

    func testInitialStepIndex_zero() async {
        let guide = makeGuide()
        XCTAssertEqual(guide.currentStepIndex, 0)
    }

    func testStart_setsPlaying() async {
        var guide = makeGuide()
        guide.start()
        XCTAssertEqual(guide.playbackState, .playing(stepIndex: 0))
    }

    func testPause_whilePlaying_setsPaused() async {
        var guide = makeGuide()
        guide.start()
        guide.pause()
        XCTAssertEqual(guide.playbackState, .paused(stepIndex: 0))
    }

    func testPause_whenIdle_noChange() async {
        var guide = makeGuide()
        guide.pause()
        XCTAssertEqual(guide.playbackState, .idle)
    }

    func testResume_whilePaused_setsPlaying() async {
        var guide = makeGuide()
        guide.start()
        guide.pause()
        guide.resume()
        XCTAssertEqual(guide.playbackState, .playing(stepIndex: 0))
    }

    func testSkip_setsSkipped() async {
        var guide = makeGuide()
        guide.start()
        guide.skip()
        XCTAssertEqual(guide.playbackState, .skipped)
    }

    func testAdvanceStep_incrementsIndex() async {
        var guide = makeGuide(stepCount: 4)
        guide.start()
        guide.advanceStep()
        XCTAssertEqual(guide.currentStepIndex, 1)
    }

    func testAdvanceStep_updatesPlayingIndex() async {
        var guide = makeGuide(stepCount: 4)
        guide.start()
        guide.advanceStep()
        XCTAssertEqual(guide.playbackState, .playing(stepIndex: 1))
    }

    func testAdvanceStep_atLastStep_setsComplete() async {
        var guide = makeGuide(stepCount: 2)
        guide.start()
        guide.advanceStep() // move to index 1
        let result = guide.advanceStep() // at last step
        XCTAssertFalse(result)
        XCTAssertEqual(guide.playbackState, .complete)
    }

    func testAdvanceStep_returnsTrueWhenNotAtEnd() async {
        var guide = makeGuide(stepCount: 4)
        guide.start()
        XCTAssertTrue(guide.advanceStep())
    }

    func testHasNextStep_trueWhenNotAtLast() async {
        let guide = makeGuide(stepCount: 4)
        XCTAssertTrue(guide.hasNextStep)
    }

    func testHasNextStep_falseAtLastStep() async {
        var guide = makeGuide(stepCount: 1)
        guide.start()
        XCTAssertFalse(guide.hasNextStep)
    }

    func testHasPreviousStep_falseAtFirst() async {
        let guide = makeGuide()
        XCTAssertFalse(guide.hasPreviousStep)
    }

    func testHasPreviousStep_trueAfterAdvance() async {
        var guide = makeGuide(stepCount: 4)
        guide.start()
        guide.advanceStep()
        XCTAssertTrue(guide.hasPreviousStep)
    }

    func testCurrentStep_returnsFirstStep() async {
        let guide = makeGuide()
        XCTAssertEqual(guide.currentStep?.checkpointIndex, 0)
    }

    func testProgress_zeroAtStart() async {
        let guide = makeGuide(stepCount: 4)
        XCTAssertEqual(guide.progress, 0.0, accuracy: 1e-9)
    }

    func testProgress_afterAdvance() async {
        var guide = makeGuide(stepCount: 4)
        guide.start()
        guide.advanceStep()
        XCTAssertEqual(guide.progress, 0.25, accuracy: 1e-9)
    }

    func testSetSpeed_changesDuration() async {
        var guide = makeGuide(stepCount: 4, duration: 0.3)
        let normalDuration = guide.totalDuration
        guide.setSpeed(.fast)
        XCTAssertLessThan(guide.totalDuration, normalDuration)
    }

    func testTotalDuration_atNormalSpeed() async {
        let guide = makeGuide(stepCount: 4, duration: 0.3)
        XCTAssertEqual(guide.totalDuration, 1.2, accuracy: 1e-9)
    }

    func testTotalDuration_atHalfSpeed() async {
        var guide = makeGuide(stepCount: 4, duration: 0.3)
        guide.setSpeed(.slow)
        // 0.3 / 0.4 * 4 = 3.0
        XCTAssertEqual(guide.totalDuration, 0.3 / 0.4 * 4, accuracy: 1e-6)
    }

    func testReset_restoresInitialState() async {
        var guide = makeGuide(stepCount: 4)
        guide.start()
        guide.advanceStep()
        guide.setSpeed(.fast)
        guide.reset()
        XCTAssertEqual(guide.playbackState, .idle)
        XCTAssertEqual(guide.currentStepIndex, 0)
        XCTAssertEqual(guide.speed, .normal)
    }

    func testEmptySteps_totalDurationZero() async {
        let guide = LetterAnimationGuide(steps: [])
        XCTAssertEqual(guide.totalDuration, 0, accuracy: 1e-9)
    }

    func testEmptySteps_progressZero() async {
        let guide = LetterAnimationGuide(steps: [])
        XCTAssertEqual(guide.progress, 0, accuracy: 1e-9)
    }
}
