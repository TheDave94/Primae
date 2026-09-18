// StudyAutoAdvanceTests.swift
// PrimaeNativeTests
//
// A study letter advances ITSELF when it completes.
//
// WHY THIS FILE EXISTS. Reported from the device 2026-09-18 as two separate
// complaints: "the canvas gets blank and gets stuck there" and "the letters
// don't auto advance". They are one defect. The study build gates out the
// celebration overlay — correctly, it is reward-class UI and every arm must
// end a trial identically (audit C1/C2) — but that overlay was ALSO the only
// thing that advanced the session. So a letter ended in `.freeWrite`, a
// phase that draws a BLANK canvas by design, and stayed there until a
// proctor tapped the chevron.
//
// The fix calls `loadRecommendedLetter()`, which already carried a study
// branch written for exactly this (`nextLetter()`, fixed deterministic
// order) — dead code, because the only caller was the gated-out overlay.
//
// WHAT THIS TEST DOES AND DOES NOT COVER. It drives the real coordinator
// through the real phases and asserts the letter changed, with the delay
// set to zero so nothing sleeps. It does NOT cover the pacing (that the
// delay is a sensible length) nor that the transition looks right on a
// device — neither is assertable here, and neither is claimed.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
@Suite struct StudyAutoAdvanceTests {

    private let canvas = CGSize(width: 400, height: 400)

    private func studyVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.phaseTransitions.studyAutoAdvanceDelay = 0   // no sleeping in tests
        return vm
    }

    /// Drive the coordinator until it stops advancing. `advance()` returns
    /// early once the letter session is complete, so this is safe to
    /// over-call and cannot loop forever.
    private func completeLetter(_ vm: TracingViewModel) {
        for _ in 0..<8 { vm.phaseTransitions.advance() }
    }

    @Test("a completed study letter advances to the next one by itself")
    func studyLetterAdvancesItself() async {
        let vm = studyVM()
        vm.startParkedLetter()
        let first = vm.currentLetterName

        completeLetter(vm)
        #expect(vm.isPhaseSessionComplete,
                "precondition: driving the phases must complete the letter, or this test proves nothing about what happens after")

        // The advance is scheduled, not synchronous — give the Task a turn.
        try? await Task.sleep(for: .milliseconds(120))

        #expect(vm.currentLetterName != first,
                "the study session stayed on '\(first)' after the letter completed. The celebration overlay is gated out under STUDY_BUILD and was the only caller of `loadRecommendedLetter()`, so nothing advanced — a child at the end of a letter sees a blank canvas and the session stops.")
    }

    /// The other half: a NON-study session is driven by the child dismissing
    /// the celebration, so the auto-advance must not fire there and steal
    /// the overlay's moment.
    @Test("a non-study letter does not auto-advance")
    func casualLetterDoesNotAutoAdvance() async {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.phaseTransitions.studyAutoAdvanceDelay = 0
        vm.startParkedLetter()
        let first = vm.currentLetterName

        completeLetter(vm)
        try? await Task.sleep(for: .milliseconds(120))

        #expect(vm.currentLetterName == first,
                "a casual session advanced by itself — the celebration overlay is the casual advance path, and skipping it would swallow the reward the child is meant to dismiss")
    }
}
