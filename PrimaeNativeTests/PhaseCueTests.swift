// PhaseCueTests.swift
// PrimaeNativeTests
//
// The child-facing turn cue: 👁️ while the letter is demonstrated, 👆 while
// the child acts on it.
//
// WHY THIS FILE EXISTS. `SchuleWorldView` renders the cue, and it had ZERO
// references from either test target (audit 2026-09-17). That mattered
// because the cue was WRONG in a way no test could have caught: the pill
// showed the eye and the finger TOGETHER, always, and only in observe — so
// a child watching the demonstration was shown a finger telling them to
// write, and the phases where they actually write showed nothing at all.
// A supervisor reported it as "Auge und Finger"; David disambiguated it
// 2026-09-17: "Auge when the letter is shown and Finger when the child is
// supposed to write itself".
//
// A SwiftUI view's structure cannot be asserted, so the DECISION was moved
// onto the view model as `TracingViewModel.phaseCue` — the same move
// `CanvasDrawPlan` makes for the canvas. These tests pin the mapping; the
// view is now a switch over it and evaluates no phase condition of its own.
//
// WHAT THESE TESTS DO NOT COVER. That the view actually renders the cue the
// mapping names, and that `writingCueOverlay` is non-hit-testable. The
// second is load-bearing — an interactive overlay at that position would
// swallow every trace in guided, the phase that produces the scored data —
// and it is not reachable from a unit test. Stated rather than implied.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
@Suite struct PhaseCueTests {

    private let canvas = CGSize(width: 400, height: 400)

    private func studyVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        return vm
    }

    /// The rule David stated, phase by phase. `guided` is "Nachspuren" and
    /// `freeWrite` is "Selbst schreiben" — both are the CHILD acting;
    /// `observe` is the letter being shown.
    ///
    /// `direct` ("Richtung lernen", numbered-dot tapping) is NOT walked any
    /// more: it left the session on 2026-09-18 ("the whole tapping the
    /// points part should go"), and `resume(at:)` refuses an inactive
    /// phase, so attempting it here would silently leave the phase
    /// unchanged and assert against the wrong state. The enum case and
    /// `phaseCue`'s branch for it both remain — the case is `Codable` and
    /// reachable from stored rows.
    @Test("the eye marks the demonstration and the finger marks the child's turn")
    func cueFollowsThePhase() {
        let vm = studyVM()

        vm.phaseController.resume(at: .observe)
        #expect(vm.phaseCue == .watch,
                "observe shows the letter being demonstrated — the child watches, so this is the EYE")

        vm.phaseController.resume(at: .guided)
        #expect(vm.phaseCue == .act,
                "guided is 'Nachspuren' — the child traces, so this is the FINGER")

        vm.phaseController.resume(at: .freeWrite)
        #expect(vm.phaseCue == .act,
                "freeWrite is 'Selbst schreiben' — the most literal instance of the child writing itself, so it carries the finger. The no-scaffolding rule bars signals contingent on the HIDDEN REFERENCE, and a turn cue carries no information about the letter")
    }

    /// No cue at ANY stage of the r27 final test — writing included. David
    /// ruled 2026-11-23 that the 👆 pill shown while the child writes the
    /// test from memory was NOT intended. The session is walked for real
    /// (`FinalTestRig`), stage by stage, so the stage each assertion reads
    /// is the one the app is in, not one a test set by hand.
    @Test("the final test shows no turn cue at any stage: pause, intro, glimpse, writing (before and after ink)")
    func finalTestShowsNoCue() async {
        let rig = FinalTestRig()
        defer { rig.close() }
        var visited: [FinalTestStage] = []
        func expectNoCue(_ note: String) {
            visited.append(rig.vm.finalTestStage)
            #expect(rig.vm.phaseCue == nil,
                    "\(rig.vm.finalTestStage) (\(note)) shows the \(String(describing: rig.vm.phaseCue)) cue")
        }

        // Control: before the test, this same rig shows a cue, so a nil below
        // is the final test's doing, not a rig that never shows one.
        #expect(rig.vm.finalTestStage == .inactive)
        #expect(rig.vm.phaseCue != nil, "control: the rig shows no cue even in training")

        await rig.finishTrainingOfEveryLetter()
        await rig.clock.waitForRequests(1)
        #expect(rig.vm.finalTestStage == .pause, "precondition")
        expectNoCue("pause")

        rig.clock.release(0)
        await rig.waitUntil { rig.vm.finalTestStage == .intro }
        #expect(rig.vm.finalTestStage == .intro, "precondition")
        expectNoCue("intro")

        await rig.clock.waitForRequests(2)
        rig.clock.release(1)
        await rig.waitUntil { rig.vm.finalTestStage == .glimpse }
        #expect(rig.vm.finalTestStage == .glimpse, "precondition")
        expectNoCue("glimpse")

        await rig.clock.waitForRequests(3)
        rig.clock.release(2)
        await rig.waitUntil { rig.vm.finalTestStage == .writing }
        #expect(rig.vm.finalTestStage == .writing, "precondition")
        expectNoCue("writing, no ink yet")
        rig.writeOneStroke()
        #expect(rig.vm.showsFinalTestCheck, "precondition: the stroke landed")
        expectNoCue("writing, after the first stroke")

        // On through every remaining test letter to the end screen (`.ended`).
        let count = rig.vm.visibleLetterNames.count
        for n in 0..<count {
            if n > 0 {
                await rig.clock.waitForRequests(3 + n)
                rig.clock.release(2 + n)
                await rig.waitUntil { rig.vm.finalTestStage == .writing }
                rig.writeOneStroke(t0: 1000 + Double(n) * 10)
            }
            rig.vm.finishFinalTestLetterTapped()
            await rig.waitUntil { rig.vm.isPhaseSessionComplete }
            rig.vm.advanceAfterCompletedStudyLetter()
        }
        #expect(rig.vm.finalTestStage == .ended, "precondition")
        expectNoCue("ended, the session end screen")

        // Every non-inactive stage was walked. `FinalTestStage` is not
        // CaseIterable; this exhaustive switch makes a NEW stage a compile
        // error here until it is added to the walk and to `walked`.
        func compileGuard(_ stage: FinalTestStage) {
            switch stage { case .inactive, .pause, .intro, .glimpse, .writing, .ended: break }
        }
        let walked: [FinalTestStage] = [.pause, .intro, .glimpse, .writing, .ended]
        for stage in walked {
            #expect(visited.contains(stage), "\(stage) was never reached, so its cue was never read")
        }
    }

    // NO "both cues" TEST EXISTS, deliberately. The defect was the pill
    // rendering eye AND finger at once; `phaseCue` is a single optional
    // value, so "both" is unrepresentable by construction. A test asserting
    // `cue == nil || cue == .watch || cue == .act` would be a tautology the
    // compiler already guarantees — a test that cannot fail, which is worse
    // than none because it reads as evidence. The shape is the guard here,
    // and `cueFollowsThePhase` walks every phase, so a regression that made
    // a phase yield the wrong cue is caught there.

    /// THE CALIBRATION GUARD HAS NO TEST, AND CANNOT HAVE ONE HERE.
    ///
    /// `phaseCue` carries `guard !isCalibrating else { return nil }`, and
    /// `canvasDrawPlan` carries the same guard on its own two flags. Neither
    /// is pinnable from this target, for a reason worth recording rather
    /// than rediscovering:
    ///
    /// `isCalibrating` is a COMPUTED, READ-ONLY property, and under
    /// `STUDY_BUILD` — which is unconditional in `Package.swift` — its body
    /// is `#if STUDY_BUILD return false`. So in every build this repo can
    /// produce, the property is a constant `false`, the guard is inert, and
    /// a test asserting "the cue stands down while calibrating" could not
    /// fail. Writing one would inflate the count, not the evidence.
    ///
    /// The guard is kept because it is the correct expression of the
    /// intent and matches the canvas's existing shape — if the calibrator
    /// ever returns to a build, the guard is already right. Recorded here so
    /// a later seat does not read the absence as an oversight.
}
