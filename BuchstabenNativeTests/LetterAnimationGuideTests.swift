//  LetterAnimationGuideTests.swift
//  BuchstabenNativeTests

import Testing
import Foundation
import CoreGraphics
@testable import BuchstabenNative

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

@Suite @MainActor struct AnimationSpeedTests {
    @Test func normalMultiplier_isOne() { #expect(abs(AnimationSpeed.normal.multiplier - 1.0) < 1e-9) }
    @Test func slowMultiplier_lessThanOne() { #expect(AnimationSpeed.slow.multiplier < 1.0) }
    @Test func fastMultiplier_greaterThanOne() { #expect(AnimationSpeed.fast.multiplier > 1.0) }
    @Test func allCases_count() { #expect(AnimationSpeed.allCases.count == 3) }
}

@Suite struct LetterAnimationGuideTests {
    @Test func initialState_idle() { #expect(makeGuide().playbackState == .idle) }
    @Test func initialStepIndex_zero() { #expect(makeGuide().currentStepIndex == 0) }
    @Test func start_setsPlaying() {
        var g = makeGuide(); g.start()
        #expect(g.playbackState == .playing(stepIndex: 0))
    }
    @Test func pause_whilePlaying_setsPaused() {
        var g = makeGuide(); g.start(); g.pause()
        #expect(g.playbackState == .paused(stepIndex: 0))
    }
    @Test func pause_whenIdle_noChange() {
        var g = makeGuide(); g.pause()
        #expect(g.playbackState == .idle)
    }
    @Test func resume_whilePaused_setsPlaying() {
        var g = makeGuide(); g.start(); g.pause(); g.resume()
        #expect(g.playbackState == .playing(stepIndex: 0))
    }
    @Test func skip_setsSkipped() {
        var g = makeGuide(); g.start(); g.skip()
        #expect(g.playbackState == .skipped)
    }
    @Test func advanceStep_incrementsIndex() {
        var g = makeGuide(stepCount: 4); g.start(); g.advanceStep()
        #expect(g.currentStepIndex == 1)
    }
    @Test func advanceStep_updatesPlayingIndex() {
        var g = makeGuide(stepCount: 4); g.start(); g.advanceStep()
        #expect(g.playbackState == .playing(stepIndex: 1))
    }
    @Test func advanceStep_atLastStep_setsComplete() {
        var g = makeGuide(stepCount: 2); g.start(); g.advanceStep()
        let result = g.advanceStep()
        #expect(!result)
        #expect(g.playbackState == .complete)
    }
    @Test func advanceStep_returnsTrueWhenNotAtEnd() {
        var g = makeGuide(stepCount: 4); g.start()
        #expect(g.advanceStep())
    }
    @Test func hasNextStep_trueWhenNotAtLast() { #expect(makeGuide(stepCount: 4).hasNextStep) }
    @Test func hasNextStep_falseAtLastStep() {
        var g = makeGuide(stepCount: 1); g.start()
        #expect(!g.hasNextStep)
    }
    @Test func hasPreviousStep_falseAtFirst() { #expect(!makeGuide().hasPreviousStep) }
    @Test func hasPreviousStep_trueAfterAdvance() {
        var g = makeGuide(stepCount: 4); g.start(); g.advanceStep()
        #expect(g.hasPreviousStep)
    }
    @Test func currentStep_returnsFirstStep() { #expect(makeGuide().currentStep?.checkpointIndex == 0) }
    @Test func progress_zeroAtStart() { #expect(abs(makeGuide(stepCount: 4).progress) < 1e-9) }
    @Test func progress_afterAdvance() {
        var g = makeGuide(stepCount: 4); g.start(); g.advanceStep()
        #expect(abs(g.progress - 0.25) < 1e-9)
    }
    @Test func setSpeed_changesDuration() {
        var g = makeGuide(stepCount: 4, duration: 0.3)
        let normal = g.totalDuration; g.setSpeed(.fast)
        #expect(g.totalDuration < normal)
    }
    @Test func totalDuration_atNormalSpeed() {
        #expect(abs(makeGuide(stepCount: 4, duration: 0.3).totalDuration - 1.2) < 1e-9)
    }
    @Test func totalDuration_atHalfSpeed() {
        var g = makeGuide(stepCount: 4, duration: 0.3); g.setSpeed(.slow)
        #expect(abs(g.totalDuration - (0.3 / 0.4 * 4)) < 1e-6)
    }
    @Test func reset_restoresInitialState() {
        var g = makeGuide(stepCount: 4); g.start(); g.advanceStep(); g.setSpeed(.fast); g.reset()
        #expect(g.playbackState == .idle)
        #expect(g.currentStepIndex == 0)
        #expect(g.speed == .normal)
    }
    @Test func emptySteps_totalDurationZero() {
        #expect(abs(LetterAnimationGuide(steps: []).totalDuration) < 1e-9)
    }
    @Test func emptySteps_progressZero() {
        #expect(abs(LetterAnimationGuide(steps: []).progress) < 1e-9)
    }
}
