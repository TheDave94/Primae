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

/// No test here writes a device key. The BEHAVIOUR tests receive their switches
/// through the deps seam with `stub` pinning the rest; the STORAGE tests
/// (`switchesAreReadOnceAtConstruction`, `resetRestoresDefaults`) run the real
/// default-argument and reset paths against a throwaway `UserDefaults` suite
/// (`ThrowawayDefaults`) handed over through `comparisonDefaults`. Swift
/// Testing runs suites in PARALLEL, so a write to the shared store lands inside
/// somebody else's read — which is what closes the class CONVENTIONS 140 names.
@MainActor
@Suite struct StudyComparisonSwitchesTests {

    private let canvas = CGSize(width: 400, height: 400)

    /// Build a study VM whose comparison switches come from the deps seam.
    ///
    /// A test that means to exercise a switch sets it through `configure`
    /// rather than writing a global key. That matters because swift-testing
    /// runs tests in PARALLEL: a key held inside one test's body is visible to
    /// every fixture constructed concurrently, in this suite or any other.
    /// MEASURED 2026-10-16: `observePassesTwoNeedsBothCycles` used to write
    /// `StudyComparisonSettings.observePasses = 2` while `AuditThirdPassTests`
    /// was building its fixture, which then needed TWO passes and failed its
    /// *"one full pass must end observe"* assertion. `TracingDependencies.stub`
    /// now pins the pass count, so the seam is the only way in.
    private func studyVM(configure: (inout TracingDependencies) -> Void = { _ in }) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        configure(&deps)
        return TracingViewModel(deps)
    }

    // MARK: - The ring is NOT a start dot

    /// The defect, pinned. With the dots switched off the ring must still
    /// render: it is the silent arm's only completion cue, because study
    /// mode removes the celebration overlay, the chime and the completion
    /// HUD for every arm.
    @Test("turning the start dots off does not remove the endpoint ring")
    func endpointRingSurvivesTheDotsSwitch() {
        // Driven through the deps seam, never the global key: see `studyVM`.
        let vm = studyVM { $0.guidedDotsVisible = false }
        vm.canvasSize = canvas

        #expect(vm.showCheckpoints == false,
                "precondition: the dots switch must actually suppress the start dots")
        #expect(vm.showEndpointRing,
                "the endpoint ring is gated on the DOTS switch — it must not be. It is the silent arm's only end-of-letter cue.")
    }

    /// And the converse: the ring stays a phase question, not a switch one.
    @Test("the endpoint ring is present in observe and guided, absent in freeWrite")
    func endpointRingIsPhaseDriven() {
        let vm = studyVM()
        vm.canvasSize = canvas

        #expect(vm.showEndpointRing, "observe should carry the endpoint ring")

        vm.phaseController.resume(at: .guided)
        #expect(vm.showEndpointRing, "guided should carry the endpoint ring")

        // The `.direct` leg that used to sit here is gone: the phase left
        // the session (2026-09-18), so `resume` refuses it and the
        // controller stays on `.guided`. Asserting `showEndpointRing ==
        // false` against `.guided` would have been asserting a false thing
        // about the wrong phase. What replaced it is the contract that made
        // it stale — the phase cannot be entered at all, from any seam.
        vm.phaseController.resume(at: .direct)
        #expect(vm.phaseController.currentPhase == .guided,
                "resume entered .direct — the tapping-the-points phase is not part of a session")
        #expect(vm.showEndpointRing,
                "a refused resume must leave the phase, and its ring, untouched")

        vm.phaseController.resume(at: .freeWrite)
        #expect(vm.showEndpointRing == false,
                "freeWrite must show nothing contingent on the hidden reference — the ring would leak the letter's end position")
    }

    @Test("the dots switch does suppress the start dots")
    func dotsSwitchSuppressesStartDots() {
        let vm = studyVM { $0.guidedDotsVisible = false }
        vm.canvasSize = canvas
        #expect(vm.showCheckpoints == false)

        let vm2 = studyVM { $0.guidedDotsVisible = true }
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
        let vm = studyVM { $0.guidedDotsVisible = false }
        vm.canvasSize = canvas
        let plan = vm.canvasDrawPlan

        #expect(plan.showsStartDots == false, "precondition: the dots switch must suppress the dots")
        #expect(plan.showsEndpointRing,
                "the draw plan drops the ring when the dots are off — the coupling defect, now visible without rendering")
    }

    @Test("the draw plan is phase-correct")
    func planIsPhaseCorrect() {
        let vm = studyVM()
        vm.canvasSize = canvas

        var plan = vm.canvasDrawPlan
        #expect(plan.showsEndpointRing && plan.showsStartDots, "observe shows both")

        vm.phaseController.resume(at: .guided)
        plan = vm.canvasDrawPlan
        #expect(plan.showsEndpointRing && plan.showsStartDots, "guided shows both")

        vm.phaseController.resume(at: .direct)
        plan = vm.canvasDrawPlan
        #expect(vm.phaseController.currentPhase == .guided,
                "resume entered .direct — the tapping-the-points phase is not part of a session")
        #expect(plan.showsEndpointRing && plan.showsStartDots,
                "a refused resume must leave the phase, and its draw plan, untouched")

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
    ///
    /// Driven through the deps seam, never the global key: see `studyVM`.
    @Test("observePasses = 2 restores a two-cycle observe")
    func observePassesTwoNeedsBothCycles() {
        let vm = studyVM { $0.observePasses = 2 }
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
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.letterRepeatCount = 3
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
            let injected = NullSpeechSynthesizer()   // a distinguishable instance
            var deps = TracingDependencies.stub
            deps.studyMode = studyMode
            deps.audioCondition = arm
            deps.speech = injected
            deps.spokenFeedbackInStudy = spokenOn

            let vm = TracingViewModel(deps)
            return (vm.speech as AnyObject) === injected
        }

        #expect(adoptsInjectedSpeech(studyMode: false, spokenOn: false, arm: .phoneme),
                "outside study mode the injected speech must be used — that is the casual path")

        #expect(adoptsInjectedSpeech(studyMode: true, spokenOn: false, arm: .phoneme) == false,
                "study mode with the switch OFF must substitute its own null synthesiser")

        #expect(adoptsInjectedSpeech(studyMode: true, spokenOn: true, arm: .phoneme),
                "the switch did not restore speech — it is inert")

        // The silent arm in a STUDY session gets the same voiceover as the
        // sound arms (P3, David 2026-10-04: spoken content identical in
        // every arm) — speech is not sonification. Its writing stays silent — that is
        // `SilentAudio` and `TouchDispatcher`, pinned in
        // `ProtocolMatrixTests` — and outside the study it still hears
        // nothing (C3-2, unchanged on the casual path).
        #expect(adoptsInjectedSpeech(studyMode: true, spokenOn: true, arm: .silent),
                "the study voiceover did not reach the silent arm — spoken content must be identical in every arm")
        #expect(adoptsInjectedSpeech(studyMode: false, spokenOn: true, arm: .silent) == false,
                "outside the study the silent arm adopted the injected speech — C3-2 holds on the casual path")
    }

    // MARK: - The switches are session properties, not live values

    /// A comparison switch must not be able to change the manipulation
    /// under a child mid-session, and the NEXT construction must pick up the
    /// current values — which is what makes the researcher screen's "takes
    /// effect at next app start" promise true rather than merely reassuring.
    ///
    /// This drives the PRODUCTION path: `omittingComparisonSwitches` leaves
    /// the nine switches out of the `TracingDependencies` call, so their real
    /// default arguments run, against a throwaway store standing in for the
    /// device's. (The test it replaces copied the global onto the seam by hand
    /// — exactly the read the default argument performs — so a wrong default
    /// argument still passed it.) The three the researcher screen exposes as
    /// presentation switches — dots, panning, axis demonstration — are
    /// asserted on observable view-model behaviour; the stamp, which is built
    /// from the resolved values of all nine, covers the rest.
    @Test("switches left to their default argument are read once, at construction")
    func switchesAreReadOnceAtConstruction() {
        let box = ThrowawayDefaults()
        box.write(.everySwitchNonDefault)

        let vm = TracingViewModel(.omittingComparisonSwitches(reading: box.defaults))
        vm.canvasSize = canvas

        // At construction: the stored values reach the session.
        #expect(vm.showCheckpoints == false,
                "guidedDotsVisible's default argument did not read the store — the start dots ignore the switch")
        #expect(vm.panningEnabled == false,
                "panningEnabled's default argument did not read the store — the pan axis ignores the switch")
        let stamp = vm.comparisonConfigurationStamp ?? ""
        let stamped = Set(stamp.split(separator: ";").map { String($0.split(separator: "=")[0]) })
        #expect(stamped == ["observePasses", "cycleAllConditions", "presentationSpacingSeconds",
                            "panningEnabled", "guidedDotsVisible", "spatialAxisDemonstration",
                            "soundGateRadiusFactor", "soundGateVelocityFloor", "oncePerCondition"],
                "the session did not resolve all nine omitted switches from the store: \(stamp)")
        #expect(stamp.contains("spatialAxisDemonstration=true"),
                "spatialAxisDemonstration's default argument did not read the store")

        // After construction: flipping the store must not move the session.
        StudyComparisonSettings.resetToDefaults(in: box.defaults)
        #expect(vm.panningEnabled == false,
                "panningEnabled moved after init — the pan axis could be switched on mid-session")
        #expect(vm.showCheckpoints == false,
                "the dots setting moved after init — the canvas could change under the child")
        #expect(vm.comparisonConfigurationStamp == stamp,
                "the stamp moved after init — rows would describe a configuration the session did not run")

        // The next construction picks the new values up.
        let vm2 = TracingViewModel(.omittingComparisonSwitches(reading: box.defaults))
        vm2.canvasSize = canvas
        #expect(vm2.panningEnabled, "a fresh view model did not pick up the reset pan setting")
        #expect(vm2.showCheckpoints, "a fresh view model did not pick up the reset dots setting")
        #expect(vm2.comparisonConfigurationStamp == nil,
                "a fresh view model over an all-default store still stamps a comparison run")
    }

    /// Turning the dots off must leave the ring (the silent arm's only
    /// end-of-letter cue) — here through the production default argument rather
    /// than the seam, since this is the switch the original defect lived in.
    @Test("dots off via the stored switch keeps the endpoint ring")
    func storedDotsSwitchKeepsTheRing() {
        let box = ThrowawayDefaults()
        box.defaults.set(false, forKey: StudyComparisonSettings.guidedDotsVisibleKey)

        let vm = TracingViewModel(.omittingComparisonSwitches(reading: box.defaults))
        vm.canvasSize = canvas
        #expect(vm.showCheckpoints == false)
        #expect(vm.showEndpointRing,
                "the ring must still be there with the dots off — see the first test in this file")
    }

    /// `resetToDefaults()` must actually return every key, or a comparison
    /// run leaks into the next session on that device.
    @Test("resetToDefaults restores every switch")
    func resetRestoresDefaults() {
        // Runs against a throwaway suite (`resetToDefaults(in:)`), never the
        // device store. The version of this test that wrote the global had to
        // snapshot and restore the WHOLE `dictionaryRepresentation()`, because
        // `resetToDefaults()` removes keys rather than writing values: the
        // global was left unset and every suite running in parallel then read
        // the CURRENT default (spokenFeedbackInStudy is `true` since
        // 2026-10-02), which flipped `silenceSpeech` in a concurrently
        // building VM and broke `OncePerConditionTests` — a failure in
        // someone else's test, caused here. A suite nobody else can see
        // cannot leak.
        let box = ThrowawayDefaults()
        box.write(.everySwitchNonDefault)
        #expect(StudyComparisonSettings.configuration(in: box.defaults) == .everySwitchNonDefault,
                "precondition: every switch must be away from its default before the reset")

        StudyComparisonSettings.resetToDefaults(in: box.defaults)

        let c = StudyComparisonSettings.configuration(in: box.defaults)
        #expect(c.observePasses == 1)
        #expect(c.spokenFeedbackInStudy == StudyComparisonSettings.spokenFeedbackInStudyDefault)
        #expect(c.allFiveLetters == false)
        #expect(c.letterRepeatCount == 1)
        #expect(c.cycleAllConditions == false)
        #expect(c.presentationSpacingSeconds == 0)
        #expect(c.panningEnabled)
        #expect(c.guidedDotsVisible)
        #expect(c.spatialAxisDemonstration == false)
        #expect(c.oncePerCondition == false)
        #expect(c.soundGateRadiusFactor == StudyComparisonSettings.soundGateRadiusFactorDefault)
        #expect(c.soundGateVelocityFloor == StudyComparisonSettings.soundGateVelocityFloorDefault)
        #expect(c == StudyComparisonConfiguration.defaults,
                "resetToDefaults left a switch away from the documented default")
    }
}
