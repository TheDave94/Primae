// FinalTestTransitionTests.swift
// PrimaeNativeTests
//
// The two edges of the final test (protocol r27), as David saw them in a
// screen recording of a session on main 28136d3c (2026-11-23):
//
//   END. After the check on the last test letter, `finishFinalTest()` set the
//   stage back to `.inactive` BEFORE the end screen covered the canvas. Every
//   rule keyed on "the test is running" let go at once: the practice chrome
//   (letter badge, phase dots, chevrons, hand button) came back and was
//   tappable, and the last test letter's ink stood under the end screen while
//   it faded in (`SessionEndScreenView.lead` + its fade, about 2 s).
//
//   START. The last TRAINING letter's free-write ink stays in the buffers until
//   the first test letter loads, and nothing stopped the canvas drawing it, so
//   it showed after the bubble pause, through the intro (about 3 s).
//
// Both are DECISIONS, pinned as values: the stage (`.ended`) and the rules it
// feeds (`FinalTestRules.hidesChrome`/`acceptsTouch`/`showsInk`), and what the
// canvas is handed (`TracingViewModel.CanvasDrawPlan.showsInk`) — the closure
// only replays it (CLAUDE.md, Test Infrastructure 3). The flow runs through
// `FinalTestRig` (FinalTestFlowTests.swift): hermetic, manual clock.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
@Suite struct FinalTestTransitionTests {

    // MARK: The rules, as values

    @Test("the ended stage keeps the practice screen away: no chrome, no touch, no scaffolding, no check")
    func endedRules() {
        #expect(FinalTestRules.hidesChrome(.ended), "the practice chrome came back under the end screen")
        #expect(!FinalTestRules.acceptsTouch(.ended), "the canvas took a touch once the test was over")
        #expect(!FinalTestRules.showsScaffolding(.ended))
        #expect(!FinalTestRules.showsPause(.ended))
        #expect(!FinalTestRules.showsGlimpseGlyph(.ended))
        #expect(!FinalTestRules.showsCheckButton(stage: .ended, hasInk: true))
    }

    @Test("ink is drawn in training, the glimpse and the writing; never in the pause, the intro or the end")
    func inkRule() {
        for stage in [FinalTestStage.inactive, .glimpse, .writing] {
            #expect(FinalTestRules.showsInk(stage), "\(stage) hid the child's ink")
        }
        for stage in [FinalTestStage.pause, .intro, .ended] {
            #expect(!FinalTestRules.showsInk(stage), "\(stage) drew ink")
        }
    }

    // MARK: Bug 2 — the start: no training ink in the pause or the intro

    @Test("the last training letter's ink is not drawn in the pause or the intro, and ink is drawn again once the child writes")
    func noTrainingInkInPauseOrIntro() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        let pool = rig.vm.visibleLetterNames
        for name in pool.dropLast() { await rig.finishTraining(name) }
        // The last training letter, WRITTEN: ink in the free-write buffer.
        rig.vm.loadLetter(name: pool[pool.count - 1])
        rig.vm.advanceLearningPhase()
        rig.vm.advanceLearningPhase()
        #expect(rig.vm.learningPhase == .freeWrite)
        // A straight stroke is not an A/F/I: the r25 attempt check sends it
        // back (at most `maxRetries` times, clearing the buffer), and the
        // attempt after that is accepted, so write until the pause.
        for attempt in 0...(FreeWriteAttemptCheck.maxRetries + 1) where rig.vm.finalTestStage != .pause {
            rig.writeOneStroke(t0: 1000 + Double(attempt) * 10)
            rig.vm.advanceLearningPhase()
            await rig.waitUntil { rig.vm.finalTestStage == .pause || rig.vm.freeWritePoints.isEmpty }
        }

        #expect(rig.vm.finalTestStage == .pause)
        // The cause, not just the symptom: the buffers still hold the ink.
        #expect(!rig.vm.freeWritePoints.isEmpty, "fixture: the training ink is gone before the pause")
        #expect(!rig.vm.canvasDrawPlan.showsInk, "the training ink is drawn during the pause")

        await rig.clock.waitForRequests(1)
        rig.clock.release(0)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        #expect(rig.vm.finalTestStage == .intro)
        #expect(!rig.vm.freeWritePoints.isEmpty, "fixture: the training ink is gone before the intro")
        #expect(!rig.vm.canvasDrawPlan.showsInk, "the training ink is drawn during the intro")

        await rig.clock.waitForRequests(2)
        rig.clock.release(1)
        await rig.waitUntil { rig.vm.finalTestStage == .glimpse }
        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        #expect(rig.vm.canvasDrawPlan.showsInk, "the child's own test ink is not drawn while writing")
    }

    // MARK: Bug 1 — the end: nothing of the practice screen comes back

    @Test("after the last check the end screen comes up over a test screen: stage ended, chrome hidden, no ink, no scaffolding, no touch")
    func theEndKeepsThePracticeScreenAway() async {
        let rig = FinalTestRig(pauseSeconds: 30, glimpseSeconds: 1.5)
        defer { rig.close() }
        await finishWholeTest(rig)

        #expect(rig.vm.sessionEndScreenPresented, "fixture: the end screen did not come")
        #expect(rig.vm.finalTestStage == .ended, "the stage fell back to \(rig.vm.finalTestStage) before the end screen covered")
        #expect(FinalTestRules.hidesChrome(rig.vm.finalTestStage), "the badge, dots, chevrons and hand came back")
        #expect(!FinalTestRules.acceptsTouch(rig.vm.finalTestStage), "the canvas took a touch under the end screen")
        let plan = rig.vm.canvasDrawPlan
        #expect(!plan.showsInk, "the last test letter's ink is drawn under the end screen")
        #expect(!plan.showsGhost && !plan.showsStartDots && !plan.showsEndpointRing,
                "scaffolding came back under the end screen")
        #expect(rig.vm.phaseCue == nil, "the hand came back under the end screen")
        #expect(rig.vm.studyNavigationHeld, "a chevron could walk the child out of the end")
    }

    @Test("a letter load after the end (a cold probe) returns to training: chrome, ink and touch are back")
    func aLoadAfterTheEndLeavesTheEndedStage() async {
        let rig = FinalTestRig(pauseSeconds: 30, glimpseSeconds: 1.5)
        defer { rig.close() }
        await finishWholeTest(rig)
        #expect(rig.vm.finalTestStage == .ended)

        rig.vm.loadLetter(name: rig.vm.visibleLetterNames[0])
        #expect(rig.vm.finalTestStage == .inactive, "a probe after the end opened under the ended stage")
        #expect(!rig.vm.sessionEndScreenPresented)
        #expect(FinalTestRules.acceptsTouch(rig.vm.finalTestStage))
        #expect(rig.vm.canvasDrawPlan.showsInk)
    }

    @Test("'Nächstes Kind' after the end returns to training")
    func nextChildAfterTheEnd() async {
        let rig = FinalTestRig(pauseSeconds: 30, glimpseSeconds: 1.5)
        defer { rig.close() }
        await finishWholeTest(rig)
        _ = rig.vm.resetForNewParticipant()
        #expect(rig.vm.finalTestStage == .inactive)
    }

    // MARK: Helper

    /// Training, pause, intro and every test letter, up to the last check.
    private func finishWholeTest(_ rig: FinalTestRig) async {
        let count = rig.vm.visibleLetterNames.count
        await rig.finishTrainingOfEveryLetter()
        await rig.passPauseAndIntro()
        for n in 0..<count {
            await rig.clock.waitForRequests(3 + n)
            rig.clock.release(2 + n)
            await rig.waitUntil { rig.vm.finalTestStage == .writing }
            rig.writeOneStroke(t0: 1000 + Double(n) * 10)
            rig.vm.finishFinalTestLetterTapped()
            await rig.waitUntil { rig.vm.isPhaseSessionComplete }
            rig.vm.advanceAfterCompletedStudyLetter()
        }
    }
}
