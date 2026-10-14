// ParentAreaPauseTests.swift
// R-026 (audit 2026-10-13, E1-03): opening the parent area (a
// fullScreenCover over the child's screen) did not pause the session —
// the observe animation and sound, the active-time slice and the
// free-writing quiet window all ran on underneath, so a trial could
// complete while the proctor was in Settings. The parent area now
// suspends the session exactly like an inactive scene, and closing it
// resumes it.

import Testing
import SwiftUI
@testable import PrimaeNative

@Suite @MainActor struct ParentAreaPauseTests {

    private var cue: String { ChildSpeechLibrary.phaseEntry(.observe) }

    @Test("a pending quiet window is held while the parent area is open, and re-armed when it closes")
    func quietWindowHeldUnderTheParentArea() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.strokeDown()
        rig.vm.endTouch()
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled, "precondition")
        rig.vm.parentAreaDidOpen()
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled,
                "the trial could complete underneath the parent area")
        rig.vm.parentAreaDidClose()
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
        #expect(rig.store.rows(.freeWrite).isEmpty)
    }

    @Test("active time stops while the parent area is open")
    func activeTimeExcludesTheParentArea() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        #expect(rig.vm.debugLetterLoadTime != nil, "precondition: the live slice is running")
        rig.vm.parentAreaDidOpen()
        #expect(rig.vm.debugLetterLoadTime == nil, "active time accrued while the proctor was in the parent area")
        rig.vm.parentAreaDidClose()
        #expect(rig.vm.debugLetterLoadTime != nil)
    }

    @Test("observe stops under the parent area and restarts from the cue when it closes")
    func observeRestartsAfterTheParentArea() async {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil }
        rig.vm.parentAreaDidOpen()
        #expect(rig.vm.animation.armedStrokes == nil, "the demonstration ran on under the parent area")
        #expect(!rig.audio.isPlaying)
        let cuesBefore = rig.prompts.count(.phaseObserve)
        rig.vm.parentAreaDidClose()
        #expect(rig.prompts.count(.phaseObserve) == cuesBefore + 1)
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil && rig.audio.isPlaying }
        #expect(rig.vm.animation.armedStrokes != nil && rig.audio.isPlaying)
    }

    @Test("a letter loaded while the parent area is open (e.g. enrolment) starts its observe only when it closes, and that is not a restart")
    func loadUnderTheParentAreaWaits() async {
        let rig = LifecycleRig(arm: .phoneme, fallback: 3600)
        rig.vm.parentAreaDidOpen()
        rig.vm.loadLetter(name: "A")
        #expect(rig.prompts.count(.phaseObserve) == 0,
                "the incoming letter's cue was spoken under the parent area")
        #expect(!rig.vm.debugObservePresentationPending,
                "the incoming letter's demonstration was armed under the parent area")
        #expect(rig.vm.debugLetterLoadTime == nil, "active time accrued under the parent area")
        rig.vm.parentAreaDidClose()
        #expect(rig.prompts.count(.phaseObserve) == 1, "the deferred cue was never spoken")
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil, "the deferred observe never started")
        #expect(rig.vm.lifecycleCounters.observeRestarts == 0, "a deferred first start is not a restart")
    }

    @Test("an inactive scene inside an open parent area does not resume the session on its own")
    func sceneReturnInsideTheParentAreaStaysPaused() async {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.parentAreaDidOpen()
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.vm.debugLetterLoadTime == nil, "the scene's return resumed a session the parent area still covers")
        rig.vm.parentAreaDidClose()
        #expect(rig.vm.debugLetterLoadTime != nil)
    }
}
