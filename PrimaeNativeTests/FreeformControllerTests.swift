//  FreeformControllerTests.swift
//  PrimaeNativeTests
//
//  Coverage for FreeformController.clearBuffers — the buffer lifecycle is
//  load-bearing for the "Nochmal" button, mode switches, and letter loads,
//  and a future change that forgets one field would silently leak stale
//  state into the next recognition pass.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

private func sampleResult(_ letter: String = "A") -> RecognitionResult {
    RecognitionResult(
        predictedLetter: letter,
        confidence: 0.85,
        topThree: [.init(letter: letter, confidence: 0.85)],
        isCorrect: true
    )
}

@Suite @MainActor struct FreeformControllerTests {

    @Test func initialState_isClean() {
        let c = FreeformController()
        #expect(c.writingMode == .guided)
        #expect(c.freeformSubMode == .letter)
        #expect(c.freeformTargetWord == nil)
        #expect(c.freeformPoints.isEmpty)
        #expect(c.freeformStrokeSizes.isEmpty)
        #expect(c.freeformActivePath.isEmpty)
        #expect(c.freeformWordResults.isEmpty)
        #expect(c.freeformWordResultSlots.isEmpty)
        #expect(c.isRecognizing == false)
        #expect(c.isWaitingForRecognition == false)
        #expect(c.hasRecognitionCompleted == false)
        #expect(c.isRecognitionModelAvailable == nil)
        #expect(c.isProbingModel == false)
        #expect(c.lastFreeformFormScore == nil)
        #expect(c.pendingRecognitionTask == nil)
    }

    @Test func clearBuffers_emptiesAllDrawingState() {
        let c = FreeformController()
        c.freeformPoints = [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)]
        c.freeformStrokeSizes = [2]
        c.freeformActivePath = [CGPoint(x: 5, y: 6)]
        c.freeformWordResults = [sampleResult("M")]
        c.freeformWordResultSlots = [sampleResult("M"), nil]
        c.hasRecognitionCompleted = true
        c.lastFreeformFormScore = 0.8
        c.isWaitingForRecognition = true

        c.clearBuffers()

        #expect(c.freeformPoints.isEmpty)
        #expect(c.freeformStrokeSizes.isEmpty)
        #expect(c.freeformActivePath.isEmpty)
        #expect(c.freeformWordResults.isEmpty)
        #expect(c.freeformWordResultSlots.isEmpty)
        #expect(c.hasRecognitionCompleted == false)
        #expect(c.lastFreeformFormScore == nil)
        #expect(c.isWaitingForRecognition == false)
    }

    @Test func clearBuffers_cancelsPendingRecognitionTask() async {
        let c = FreeformController()
        // Hold on to a flag captured by reference so the test can prove
        // the task didn't run to completion.
        actor Sentinel { var ran = false; func mark() { ran = true } }
        let sentinel = Sentinel()
        c.pendingRecognitionTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s
            if Task.isCancelled { return }
            await sentinel.mark()
        }

        c.clearBuffers()
        #expect(c.pendingRecognitionTask == nil)
        try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
        let ran = await sentinel.ran
        #expect(ran == false) // cancelled before sleep ended
    }

    @Test func clearBuffers_preservesModeState() {
        // The doc-comment promises clearBuffers does NOT touch
        // writingMode / freeformSubMode / freeformTargetWord. Pin that
        // contract so a refactor doesn't accidentally reset mode-level
        // intent during a "Nochmal" tap.
        let c = FreeformController()
        c.writingMode = .freeform
        c.freeformSubMode = .word
        c.freeformTargetWord = FreeformWord(word: "MAUS", difficulty: 1)

        c.clearBuffers()

        #expect(c.writingMode == .freeform)
        #expect(c.freeformSubMode == .word)
        #expect(c.freeformTargetWord?.word == "MAUS")
    }

    @Test func clearBuffers_preservesModelAvailabilityProbeResult() {
        // The model probe is expensive — clearing should not invalidate
        // its result, otherwise every Nochmal would re-trigger a model
        // load. (The probe gate `isRecognitionModelAvailable` is value-
        // sticky on purpose.)
        let c = FreeformController()
        c.isRecognitionModelAvailable = true

        c.clearBuffers()

        #expect(c.isRecognitionModelAvailable == true)
    }

}
