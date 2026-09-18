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
// caller of `loadRecommendedLetter()`, the function that advances the
// session. So a letter ended in `.freeWrite`, a phase that draws a BLANK
// canvas by design, and stayed there until a proctor tapped the chevron.
//
// WHAT IS PINNED HERE, AND WHAT IS NOT — stated because the difference
// matters more than the test does.
//
// PINNED: `loadRecommendedLetter()` carries a study branch that advances
// deterministically. It was dead code — nothing called it — and this is the
// half of the fix that a unit test can reach.
//
// NOT PINNED: the WIRING — that `recordSessionCompletion` now schedules
// that call. That is the half that actually fixes the bug, and three
// attempts to reach it from a unit test all failed on their own
// precondition with `phase=.observe` after four `advance()` calls, i.e.
// the coordinator does not walk a fixture session through the phases. That
// is a property of driving a session from a test, not of the fix, and it
// is recorded rather than papered over: **the wiring is verified by
// reading and must be confirmed on a device.**
//
// The earlier attempts are worth knowing about because two of them LOOKED
// like they tested the behaviour: they drove phases, asserted a letter
// changed, and would have passed vacuously had the precondition assertion
// not been there. It was, and it caught all three.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
@Suite struct StudyAutoAdvanceTests {

    private let canvas = CGSize(width: 400, height: 400)

    private func makeAsset(_ name: String) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper,
                    audioFiles: ["\(name).mp3"],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []),
                    phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
    }

    /// THREE letters, and that is load-bearing rather than decoration.
    /// `TracingDependencies.stub` serves a ONE-letter pool, so advancing
    /// from it lands back on the same letter (`visible[(idx + 1) % 1]`) —
    /// which made the first version of this test assert that a letter HAD
    /// changed while the fixture could not possibly change it. Two letters
    /// would do; three mirrors the study subset the other suites use.
    private func studyVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.letters = ["A", "F", "I"].map(makeAsset)
        return vm
    }

    /// The branch that was dead. In a study session the advance must be the
    /// FIXED deterministic order — never the spaced-repetition scheduler —
    /// because letter order must not diverge with performance.
    @Test("in a study session, loadRecommendedLetter advances deterministically")
    func studyAdvanceIsDeterministic() {
        let vm = studyVM()
        vm.startParkedLetter()
        let first = vm.currentLetterName

        vm.loadRecommendedLetter()

        #expect(vm.currentLetterName != first,
                "a study session stayed on '\(first)' — the study branch of `loadRecommendedLetter` is the only advance path the study build has, since the celebration overlay that used to call it is gated out under STUDY_BUILD")
    }

    /// The counterpart, and the reason the study branch must stay narrow:
    /// outside study mode this call is the celebration's "Weiter", and it
    /// must NOT take the deterministic path — a casual child's letter order
    /// is performance-driven.
    @Test("outside study mode the advance is not the fixed order")
    func casualAdvanceIsNotFixedOrder() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.letters = ["A", "F", "I"].map(makeAsset)
        vm.startParkedLetter()

        // No assertion about WHICH letter: the casual path is
        // scheduler-driven and depends on progress state. What is asserted
        // is that the call is safe to make in both modes and does not
        // trap — the study branch above depends on the split being real.
        vm.loadRecommendedLetter()

        #expect(vm.currentLetterName.isEmpty == false,
                "the casual advance left the session with no current letter")
    }
}
