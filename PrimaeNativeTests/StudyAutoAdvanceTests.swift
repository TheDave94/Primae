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

    /// Complete the letter through the REAL post-freeWrite entry point.
    ///
    /// Two earlier versions of this test drove `advance()` repeatedly to
    /// walk the phases, and both failed on their own precondition. The
    /// reason is worth recording: the freeWrite step hands off to the
    /// recognizer and RETURNS (`runRecognizerForFreeWrite`), so the letter
    /// completes on a later turn — and with the fixture's nil-result stub
    /// recognizer it never completed at all. Driving a whole session
    /// through the phase machinery was fighting the harness to reach a
    /// path that is directly callable.
    ///
    /// `completePostFreeWriteRecognition` IS that path: it is what the
    /// recognizer calls back into, it is internal, and in study mode it
    /// goes straight to `celebrateFreeWrite` → `recordSessionCompletion`
    /// (study sessions never retry — see its own branch).
    private func completeLetter(_ vm: TracingViewModel) async {
        for _ in 0..<4 { vm.phaseTransitions.advance() }        // walk to freeWrite
        vm.phaseTransitions.completePostFreeWriteRecognition(score: 1.0, result: nil)
        // The completion schedules the advance on a Task; give it a turn.
        try? await Task.sleep(for: .milliseconds(150))
    }

    @Test("a completed study letter advances to the next one by itself")
    func studyLetterAdvancesItself() async {
        let vm = studyVM()
        vm.startParkedLetter()
        let first = vm.currentLetterName

        await completeLetter(vm)
        #expect(vm.isPhaseSessionComplete,
                "precondition: the letter must actually complete, or this test proves nothing about what happens after")

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

        await completeLetter(vm)

        #expect(vm.currentLetterName == first,
                "a casual session advanced by itself — the celebration overlay is the casual advance path, and skipping it would swallow the reward the child is meant to dismiss")
    }
}
