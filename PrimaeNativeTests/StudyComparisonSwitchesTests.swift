// StudyComparisonSwitchesTests.swift
// PrimaeNativeTests
//
// Coverage for the researcher comparison switches and for the ONE thing
// that must NOT be coupled to them.
//
// WHY THIS FILE EXISTS. The endpoint ring was first drawn inside the
// start-dot guard, so switching "Punkte rausschmeißen" off also deleted the
// silent arm's only end-of-letter acknowledgement. The fix for that was
// itself inert — the block was de-indented without moving its closing
// brace, leaving it nested — and it shipped through a full green run of
// `PrimaeNativeTests` (901 tests, 90 suites) because **nothing in the suite
// referenced the ring, any comparison key, or `StudyComparisonSettings`**.
// A green suite was no evidence at all for that diff. These tests make the
// coupling observable so the next attempt cannot pass by being inert.
//
// WHAT THE GATING TESTS DO AND DO NOT COVER. The first tests assert the
// view-model's own properties, which is necessary but NOT sufficient: the
// brace defect was in which guard ENCLOSES which draw, and those properties
// would have read the same either way. A property assertion cannot see
// nesting.
//
// `CanvasDrawPlan` is what closes that, and it closes it STRUCTURALLY
// rather than by assertion. The draw DECISIONS are computed in plain Swift
// and handed to the render closure as one value, so the closure evaluates
// no condition of its own for these elements and there is no brace whose
// position can be wrong. `graphicsContext` cannot be constructed, so the
// closure can never be invoked or spied on — this shape is the only way
// the decision becomes assertable at all.
//
// A render-based test was tried and DELETED; see the note where it was,
// below. It rendered a constant background rather than the canvas.

import Testing
import Foundation
import SwiftUI
import CoreGraphics
import UIKit
@testable import PrimaeNative

@MainActor
@Suite struct StudyComparisonSwitchesTests {

    private let canvas = CGSize(width: 400, height: 400)

    /// Build a study VM and guarantee the comparison keys are cleared
    /// afterwards, so one test cannot leak configuration into the next.
    private func studyVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        return TracingViewModel(deps)
    }

    // MARK: - The ring is NOT a start dot

    /// The defect, pinned. With the dots switched off the ring must still
    /// render: it is the silent arm's only completion cue, because study
    /// mode removes the celebration overlay, the chime and the completion
    /// HUD for every arm.
    @Test("turning the start dots off does not remove the endpoint ring")
    func endpointRingSurvivesTheDotsSwitch() {
        StudyComparisonSettings.guidedDotsVisible = false
        defer { StudyComparisonSettings.resetToDefaults() }

        let vm = studyVM()
        vm.canvasSize = canvas

        #expect(vm.showCheckpoints == false,
                "precondition: the dots switch must actually suppress the start dots")
        #expect(vm.showEndpointRing,
                "the endpoint ring is gated on the DOTS switch — it must not be. It is the silent arm's only end-of-letter cue.")
    }

    /// And the converse: the ring stays a phase question, not a switch one.
    @Test("the endpoint ring is present in observe and guided, absent in direct and freeWrite")
    func endpointRingIsPhaseDriven() {
        StudyComparisonSettings.resetToDefaults()
        let vm = studyVM()
        vm.canvasSize = canvas

        #expect(vm.showEndpointRing, "observe should carry the endpoint ring")

        vm.phaseController.resume(at: .guided)
        #expect(vm.showEndpointRing, "guided should carry the endpoint ring")

        vm.phaseController.resume(at: .direct)
        #expect(vm.showEndpointRing == false,
                "direct draws its own numbered overlay; the ring would compete with it")

        vm.phaseController.resume(at: .freeWrite)
        #expect(vm.showEndpointRing == false,
                "freeWrite must show nothing contingent on the hidden reference — the ring would leak the letter's end position")
    }

    @Test("the dots switch does suppress the start dots")
    func dotsSwitchSuppressesStartDots() {
        StudyComparisonSettings.guidedDotsVisible = false
        defer { StudyComparisonSettings.resetToDefaults() }

        let vm = studyVM()
        vm.canvasSize = canvas
        #expect(vm.showCheckpoints == false)

        StudyComparisonSettings.guidedDotsVisible = true
        let vm2 = studyVM()
        vm2.canvasSize = canvas
        #expect(vm2.showCheckpoints, "the default keeps the start dots")
    }

    // THE RENDER TESTS THAT WERE HERE ARE GONE, and why is worth recording.
    //
    // Three tests rasterised `TracingCanvasView` with `ImageRenderer` and
    // counted the ring's red pixels. They were removed 2026-09-17 after
    // measuring what they actually rendered: observe and freeWrite came
    // back BYTE-IDENTICAL (51534 "red" pixels each), i.e. the raster was a
    // constant background, not the canvas. `ImageRenderer` does not run the
    // layout pass the view's `GeometryReader` needs, so the `Canvas` drew
    // nothing and the pixel counter was measuring the paper.
    //
    // That made the mutation check that "validated" them meaningless: a
    // deliberately re-nested ring made the test fail, but it would have
    // failed for ANY input, mutation or not. A test that cannot PASS is the
    // mirror of the test that cannot fail, and it is just as worthless —
    // it was caught only because the numbers were printed and compared.
    //
    // `CanvasDrawPlan` replaces them, and is the better instrument: the
    // decision is a value in ordinary Swift, so the coupling is asserted
    // directly instead of inferred from pixels. If a faithful render test
    // is ever wanted, the view needs a layout pass first (`UIHostingController`
    // in a window, or a fixed-size proposal that bypasses the GeometryReader).

    // MARK: - The draw plan — the coupling, in plain Swift

    /// `CanvasDrawPlan` exists so this assertion can be written at all.
    /// `GraphicsContext` has no public initialiser, so the draw closure
    /// cannot be invoked or spied on; the plan is the decision the closure
    /// is handed, which makes the coupling an ordinary value comparison.
    @Test("the draw plan keeps the ring when the start dots are switched off")
    func planKeepsRingWithDotsOff() {
        StudyComparisonSettings.guidedDotsVisible = false
        defer { StudyComparisonSettings.resetToDefaults() }

        let vm = studyVM()
        vm.canvasSize = canvas
        let plan = vm.canvasDrawPlan

        #expect(plan.showsStartDots == false, "precondition: the dots switch must suppress the dots")
        #expect(plan.showsEndpointRing,
                "the draw plan drops the ring when the dots are off — the coupling defect, now visible without rendering")
    }

    @Test("the draw plan is phase-correct")
    func planIsPhaseCorrect() {
        StudyComparisonSettings.resetToDefaults()
        let vm = studyVM()
        vm.canvasSize = canvas

        var plan = vm.canvasDrawPlan
        #expect(plan.showsEndpointRing && plan.showsStartDots, "observe shows both")

        vm.phaseController.resume(at: .guided)
        plan = vm.canvasDrawPlan
        #expect(plan.showsEndpointRing && plan.showsStartDots, "guided shows both")

        vm.phaseController.resume(at: .direct)
        plan = vm.canvasDrawPlan
        #expect(plan.showsEndpointRing == false && plan.showsStartDots == false,
                "direct draws its own numbered overlay and nothing of ours")

        vm.phaseController.resume(at: .freeWrite)
        plan = vm.canvasDrawPlan
        #expect(plan.showsEndpointRing == false,
                "freeWrite must show nothing contingent on the hidden reference")
        #expect(plan.showsGhost == false, "freeWrite withdraws all scaffolding")
    }

    // MARK: - The switches' SEMANTICS, not just their storage

    /// Each of these drives a production consumer. Before them the switches
    /// had only round-trip assertions on UserDefaults — a comparison run
    /// using any of them would have been unpinned.

    /// `observePasses` = 2: observe must need BOTH cycles before it advances.
    @Test("observePasses = 2 restores a two-cycle observe")
    func observePassesTwoNeedsBothCycles() {
        StudyComparisonSettings.observePasses = 2
        defer { StudyComparisonSettings.resetToDefaults() }

        let vm = studyVM()
        vm.canvasSize = canvas
        vm.startParkedLetter()
        #expect(vm.learningPhase == .observe, "precondition: a study launch starts in observe")

        vm.animation.onCycleComplete?()
        #expect(vm.learningPhase == .observe,
                "one cycle ended observe while observePasses is 2 — the switch is not reaching the exit test")

        vm.animation.onCycleComplete?()
        #expect(vm.learningPhase != .observe, "two cycles must end observe")
    }

    /// `letterRepeatCount` = 3: the same letter runs three times, and the
    /// third pass is the last.
    @Test("letterRepeatCount = 3 repeats the letter twice and then stops")
    func letterRepeatCountRepeatsThenStops() {
        StudyComparisonSettings.letterRepeatCount = 3
        defer { StudyComparisonSettings.resetToDefaults() }

        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.startParkedLetter()

        #expect(vm.repeatCurrentLetterIfConfigured(), "pass 2 of 3 must start")
        #expect(vm.repeatCurrentLetterIfConfigured(), "pass 3 of 3 must start")
        #expect(vm.repeatCurrentLetterIfConfigured() == false,
                "a fourth pass started — the repeat counter does not stop at the configured count")
    }

    @Test("letterRepeatCount = 1 never repeats")
    func letterRepeatCountOneIsInert() {
        StudyComparisonSettings.resetToDefaults()
        let vm = studyVM()
        vm.canvasSize = canvas
        vm.startParkedLetter()
        #expect(vm.repeatCurrentLetterIfConfigured() == false,
                "the repeat fired at the default count of 1")
    }

    /// `spokenFeedbackInStudy` = true: the null-object substitution must
    /// stand down, or the switch is inert. The silent ARM's silencing is
    /// separate and must survive it.
    ///
    /// Compared by IDENTITY, not by type. `TracingDependencies.stub` injects
    /// a null synthesiser AND a factory returning a null prompt player, so
    /// `vm.speech is NullSpeechSynthesizer` is true on BOTH branches and the
    /// first version of this test could not tell them apart — it failed for
    /// that reason, which is how the distinction was found. Passing a
    /// distinct instance and asking whether the view model ADOPTED it can.
    @Test("spokenFeedbackInStudy restores the injected speech, but never for the silent arm")
    func spokenFeedbackSwitchIsRealButArmAuthorityHolds() {
        func adoptsInjectedSpeech(studyMode: Bool, spokenOn: Bool,
                                  arm: PilotAudioCondition) -> Bool {
            StudyComparisonSettings.resetToDefaults()
            StudyComparisonSettings.spokenFeedbackInStudy = spokenOn
            defer { StudyComparisonSettings.resetToDefaults() }

            let injected = NullSpeechSynthesizer()   // a distinguishable instance
            var deps = TracingDependencies.stub
            deps.studyMode = studyMode
            deps.audioCondition = arm
            deps.speech = injected

            let vm = TracingViewModel(deps)
            return (vm.speech as AnyObject) === injected
        }

        #expect(adoptsInjectedSpeech(studyMode: false, spokenOn: false, arm: .phoneme),
                "outside study mode the injected speech must be used — that is the casual path")

        #expect(adoptsInjectedSpeech(studyMode: true, spokenOn: false, arm: .phoneme) == false,
                "study mode with the switch OFF must substitute its own null synthesiser")

        #expect(adoptsInjectedSpeech(studyMode: true, spokenOn: true, arm: .phoneme),
                "the switch did not restore speech — it is inert")

        #expect(adoptsInjectedSpeech(studyMode: true, spokenOn: true, arm: .silent) == false,
                "the silent arm adopted the injected speech — C3-2 says no audio path may fire for that arm, and no comparison switch may override it")
    }

    // MARK: - The switches are session properties, not live values

    /// A comparison switch must not be able to change the manipulation
    /// under a child mid-session. Every one is captured at view-model
    /// construction; writing the key afterwards must not move the VM.
    @Test("comparison switches are captured at init and do not move afterwards")
    func switchesAreCapturedAtInit() {
        StudyComparisonSettings.resetToDefaults()
        let vm = studyVM()

        #expect(vm.panningEnabled, "panning defaults on")

        // Flip every key AFTER construction.
        StudyComparisonSettings.panningEnabled = false
        StudyComparisonSettings.guidedDotsVisible = false
        StudyComparisonSettings.presentationSpacingSeconds = 5
        StudyComparisonSettings.observePasses = 2
        defer { StudyComparisonSettings.resetToDefaults() }

        #expect(vm.panningEnabled,
                "panningEnabled moved after init — the pan axis could be switched off mid-session")
        #expect(vm.showCheckpoints,
                "the dots setting moved after init — the canvas could change under the child")
    }

    /// The next construction DOES pick the new values up, which is what
    /// makes the researcher screen's "takes effect at next app start"
    /// promise true rather than merely reassuring.
    @Test("a fresh view model picks up the written values")
    func switchesApplyOnNextConstruction() {
        StudyComparisonSettings.panningEnabled = false
        StudyComparisonSettings.guidedDotsVisible = false
        defer { StudyComparisonSettings.resetToDefaults() }

        let vm = studyVM()
        vm.canvasSize = canvas
        #expect(vm.panningEnabled == false)
        #expect(vm.showCheckpoints == false)
        #expect(vm.showEndpointRing,
                "the ring must still be there with the dots off — see the first test in this file")
    }

    /// `resetToDefaults()` must actually return every key, or a comparison
    /// run leaks into the next session on that device.
    @Test("resetToDefaults restores every switch")
    func resetRestoresDefaults() {
        StudyComparisonSettings.observePasses = 2
        StudyComparisonSettings.spokenFeedbackInStudy = true
        StudyComparisonSettings.allFiveLetters = true
        StudyComparisonSettings.letterRepeatCount = 3
        StudyComparisonSettings.cycleAllConditions = true
        StudyComparisonSettings.presentationSpacingSeconds = 4
        StudyComparisonSettings.panningEnabled = false
        StudyComparisonSettings.guidedDotsVisible = false
        StudyComparisonSettings.spatialAxisDemonstration = true
        // The two trigger-boundary switches (2026-09-17). Their own file,
        // `TriggerBoundaryTests`, deliberately writes no key it then
        // asserts on — a parallel suite resetting mid-test would make that
        // flaky — so the reset coverage for these two lives here with the
        // other nine, where the assertions are all "equals the default"
        // and a concurrent reset can only reinforce them.
        StudyComparisonSettings.soundGateRadiusFactor = 6.0
        StudyComparisonSettings.soundGateVelocityFloor = 0

        StudyComparisonSettings.resetToDefaults()

        #expect(StudyComparisonSettings.observePasses == 1)
        #expect(StudyComparisonSettings.spokenFeedbackInStudy == false)
        #expect(StudyComparisonSettings.allFiveLetters == false)
        #expect(StudyComparisonSettings.letterRepeatCount == 1)
        #expect(StudyComparisonSettings.cycleAllConditions == false)
        #expect(StudyComparisonSettings.presentationSpacingSeconds == 0)
        #expect(StudyComparisonSettings.panningEnabled)
        #expect(StudyComparisonSettings.guidedDotsVisible)
        #expect(StudyComparisonSettings.soundGateRadiusFactor
                    == StudyComparisonSettings.soundGateRadiusFactorDefault)
        #expect(StudyComparisonSettings.soundGateVelocityFloor
                    == StudyComparisonSettings.soundGateVelocityFloorDefault)
    }
}
