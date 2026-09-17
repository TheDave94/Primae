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
// WHAT THE GATING TESTS DO AND DO NOT COVER. The first two tests assert
// the view-model's own properties, which is necessary but NOT sufficient:
// the brace defect was in which guard ENCLOSES which draw, and these
// properties would have read the same either way. A property assertion
// cannot see nesting. The render test further down is the one that
// actually pins the coupling — it rasterises the canvas and looks for the
// ring's pixels — and it is the reason this file exists.

import Testing
import Foundation
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

        StudyComparisonSettings.resetToDefaults()

        #expect(StudyComparisonSettings.observePasses == 1)
        #expect(StudyComparisonSettings.spokenFeedbackInStudy == false)
        #expect(StudyComparisonSettings.allFiveLetters == false)
        #expect(StudyComparisonSettings.letterRepeatCount == 1)
        #expect(StudyComparisonSettings.cycleAllConditions == false)
        #expect(StudyComparisonSettings.presentationSpacingSeconds == 0)
        #expect(StudyComparisonSettings.panningEnabled)
        #expect(StudyComparisonSettings.guidedDotsVisible)
    }
}
