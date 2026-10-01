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
