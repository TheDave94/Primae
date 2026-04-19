// AnimationGuideControllerTests.swift
// BuchstabenNativeTests

import Foundation
import CoreGraphics
import Testing
@testable import BuchstabenNative

@MainActor
@Suite struct AnimationGuideControllerTests {

    private func sampleStrokes() -> LetterStrokes {
        // Minimal 2-checkpoint stroke so the built guide has a non-empty step list.
        LetterStrokes(
            letter: "Z",
            checkpointRadius: 0.05,
            strokes: [
                StrokeDefinition(id: 1, checkpoints: [
                    Checkpoint(x: 0.1, y: 0.5),
                    Checkpoint(x: 0.9, y: 0.5),
                ])
            ]
        )
    }

    @Test func initialState_guidePointIsNil() {
        let c = AnimationGuideController()
        #expect(c.guidePoint == nil)
    }

    @Test func stop_withNoAnimation_doesNotCrash() {
        let c = AnimationGuideController()
        c.stop()
        c.stop()
        #expect(c.guidePoint == nil)
    }

    @Test func start_setsGuidePointWithinShortWindow() async {
        let c = AnimationGuideController()
        c.start(strokes: sampleStrokes())
        // The first step should assign guidePoint fairly quickly.
        for _ in 0..<20 {
            if c.guidePoint != nil { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(c.guidePoint != nil,
                "guidePoint should become non-nil within ~500 ms of start")
        c.stop()
    }

    @Test func stop_clearsGuidePoint() async {
        let c = AnimationGuideController()
        c.start(strokes: sampleStrokes())
        try? await Task.sleep(for: .milliseconds(80))
        c.stop()
        #expect(c.guidePoint == nil,
                "stop() must synchronously clear guidePoint")
    }

    @Test func startAfterDelay_doesNotFireEarly() async {
        let c = AnimationGuideController()
        c.startAfterDelay(0.2, strokes: sampleStrokes())
        try? await Task.sleep(for: .milliseconds(50))
        // Deferred start — guidePoint should still be nil.
        #expect(c.guidePoint == nil,
                "startAfterDelay must honor the delay before firing")
        c.stop()
    }

    @Test func onCycleComplete_firesAtLeastOnce() async {
        let c = AnimationGuideController()
        var cycles = 0
        c.onCycleComplete = { cycles += 1 }
        c.start(strokes: sampleStrokes())
        // Single checkpoint gets ~0.25s step + 0.5s pause ≈ 750ms/cycle.
        for _ in 0..<60 {
            if cycles >= 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(cycles >= 1,
                "onCycleComplete should fire within ~3 s; observed \(cycles) cycles")
        c.stop()
    }

    @Test func start_replacesInFlightAnimation() async {
        let c = AnimationGuideController()
        c.start(strokes: sampleStrokes())
        try? await Task.sleep(for: .milliseconds(40))
        // Restarting should cancel the previous loop without crashing.
        c.start(strokes: sampleStrokes())
        try? await Task.sleep(for: .milliseconds(40))
        c.stop()
    }
}
