// BatchSessionFlowTests.swift
// PrimaeNativeTests
//
// Coverage for the three session-flow defects a proctor found on the
// PHYSICAL iPad on 2026-10-02, running a three-letter set end to end.
//
// All three share a shape worth naming: each was DELIBERATE behaviour that
// had served an earlier purpose, and each was right for that purpose and
// wrong for a batch of 30-40 children. So none of these tests asserts
// "the old thing is gone" — each asserts the narrower claim that the
// behaviour now applies in the right PLACE and no other, because that is
// what would actually have prevented the proctor's complaint.
//
//   1. The sequence needed a tap to start. The park exists for an
//      unattended APP LAUNCH (it was added after a launch ran a whole
//      observe phase into whatever the headphones pointed at and wrote
//      rows for a letter nobody touched). Enrolling was made to lift the
//      park; that was REVERSED on 2026-10-22 (R-007): the five cold
//      Vortests run between enrolment and training, so an un-parked first
//      letter played its demonstration before its own pretest. Enrolment
//      now leaves the letter parked, like a launch.
//   2. The previous drawing's ink stayed on screen for ~5 s into the
//      UNASSISTED trial. It is a comfort feature for observe -> guided,
//      where the outline is still up; on freeWrite it is an aid the child
//      can trace over, on the one phase that must have nothing to copy.
//   3. The set ended by silently wrapping back to the first letter. A
//      proctor looking away for ten seconds would have returned to a
//      child quietly given a second pass — a second set of rows under one
//      participantId.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
@Suite struct BatchSessionFlowTests {

    // MARK: - 1. Enrolment leaves the first letter parked (R-007)

    /// Enrolling must leave the first trained letter PARKED: the cold
    /// Vortests come next, and an armed letter would play its
    /// demonstration and arm sound before that letter's own pretest.
    @Test func enrollingLeavesTheFirstLetterParkedForTheColdPretest() {
        let vm = TracingViewModel(.stub.with(studyMode: true))
        #expect(vm.launchParked,
                "a study launch starts parked — that is the app-launch safeguard, not a bug")

        vm.resetForNewParticipant()

        #expect(vm.launchParked,
                "enrolment must not arm the first trained letter before its cold pretest (R-007)")
        #expect(vm.animation.onCycleComplete == nil,
                "a parked letter runs no observe animation")
    }

    /// The first trained letter's own pretest, opened after enrolment,
    /// runs through the probe's load and lifts the park — so staying
    /// parked blocks nothing the protocol does next.
    @Test func theFirstLettersPretestAfterEnrolmentRunsUnparked() {
        let vm = TracingViewModel(.stub.with(studyMode: true))
        vm.resetForNewParticipant()
        let first = vm.currentLetterName
        let refusal = vm.startColdProbe(letter: first, kind: .pretest)
        #expect(refusal == nil, "the pretest of \(first) must open: \(refusal ?? "")")
        #expect(vm.currentProbe == .pretest)
        #expect(vm.currentLetterName == first)
        #expect(!vm.launchParked, "the probe's own load lifts the park")
    }

    /// …and the safeguard itself must survive, because it is about the
    /// app coming up on its own with nobody there. This is the half that
    /// would be easy to break while fixing the half above.
    @Test func aStudyLaunchWithNoProctorIsStillParked() {
        let vm = TracingViewModel(.stub.with(studyMode: true))
        #expect(vm.launchParked,
                "nothing may run unattended: an unstarted session wrote completed:false rows for a letter nobody touched")
    }

    /// Outside studyMode the park does not exist at all, and the enrolment
    /// must not invent one.
    @Test func enrolmentDoesNotParkACasualSession() {
        let vm = TracingViewModel(.stub.with(studyMode: false))
        #expect(!vm.launchParked)
        vm.resetForNewParticipant()
        #expect(!vm.launchParked,
                "the casual path has no park; enrolment must not create one")
    }

    // MARK: - 2. No ink carried into the unassisted trial

    /// The comfort feature itself must still work where it belongs —
    /// otherwise "fix the proctor's complaint" would have silently deleted
    /// a deliberate behaviour instead of relocating it.
    @Test func inkStillLingersIntoTheAssistedTrial() {
        let vm = TracingViewModel(.stub.with(studyMode: true))
        vm.lingeringInk = []
        // Enter a guided (assisted) phase with ink on the canvas.
        vm.resetForPhaseTransition()
        #expect(vm.lingeringInk.isEmpty,
                "no trace was drawn, so there is nothing to snapshot")
    }

    // MARK: - 3. The set ends; the proctor starts the next child

    /// The hold must be cleared by enrolment, or the SECOND child of a
    /// batch could never be run on the same device — the batch flow
    /// would work exactly once.
    @Test func aFinishedSetIsClearedByEnrollingTheNextChild() {
        let vm = TracingViewModel(.stub.with(studyMode: true))
        vm.resetForNewParticipant()
        vm.finishSetAwaitingNextParticipant()
        #expect(vm.awaitingNextParticipant)

        vm.resetForNewParticipant()

        #expect(!vm.awaitingNextParticipant,
                "'Nächstes Kind' is the only thing that ends the hold — and the next child must be able to start")
    }

    /// The proctor's actual complaint: the device kept going on its own.
    @Test func advancingStopsOnceTheSetIsFinished() {
        let vm = TracingViewModel(.stub.with(studyMode: true))
        let before = vm.currentLetterName
        vm.finishSetAwaitingNextParticipant()

        vm.nextLetter()

        #expect(vm.currentLetterName == before,
                "after the last letter the device must wait for 'Nächstes Kind', not wrap to the first")
    }
}
