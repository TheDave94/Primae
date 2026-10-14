// ScenePhaseInterruptionTests.swift
// R-005 (audit 2026-10-13, H1-01 / C2-02 / E2-04): `.inactive` was handled
// as `.background`. Control Center, Notification Center, an app-switcher
// peek or a system alert — all child-reachable — ended the touch and
// FINALISED a free-writing production: a partial letter was scored and
// recorded `completed: true` as the outcome trial, the letter closed, no
// retry. `.inactive` must suspend the session (touch cancelled, quiet
// window held, sound and voice stopped, active time paused) and record
// nothing; `.active` resumes it; only `.background` keeps the last-trial
// finalisation.

import Testing
import SwiftUI
@testable import PrimaeNative

@Suite @MainActor struct ScenePhaseInterruptionTests {

    private func freeWriteRig() -> LifecycleRig {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.store.reset()
        return rig
    }

    @Test("inactive after a lifted stroke records nothing; the trial goes on after active")
    func inactiveAfterLiftRecordsNothing() async {
        let rig = freeWriteRig()
        rig.strokeDown()
        rig.vm.endTouch()
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled, "precondition: quiet window pending")
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        #expect(rig.store.rows(.freeWrite).isEmpty,
                "an inactive scene (Control Center, banner, app-switcher peek) recorded the partial letter: \(rig.store.rows.map(\.phase))")
        #expect(!rig.vm.isPhaseSessionComplete, "the letter was closed by an inactive scene")
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled,
                "the quiet window kept running while the scene was inactive — it would end the trial unseen")
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled,
                "the quiet window held at the interruption is re-armed on return")
        // The child can go on writing.
        rig.strokeDown(from: CGPoint(x: 50, y: 260), t0: 3000)
        #expect(rig.vm.touchDispatcher.isSingleTouchInteractionActive, "ink is accepted after the return")
    }

    // Review of batch C, item 4: the cut stroke is a CANCEL, so no quiet
    // window runs while the scene is away; but on the return the window
    // is armed afresh (2.0 s from the resume), or the trial would wait for
    // the child's next lift or the proctor's chevron.
    @Test("inactive mid-stroke cancels the stroke and records nothing; the return arms a fresh quiet window")
    func inactiveMidStrokeCancels() async {
        let rig = freeWriteRig()
        rig.strokeDown()
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        #expect(rig.store.rows(.freeWrite).isEmpty, "a mid-stroke interruption recorded the partial letter")
        #expect(!rig.vm.touchDispatcher.isSingleTouchInteractionActive, "the stroke is closed")
        #expect(rig.vm.lifecycleCounters.strokesCancelled == 1, "the cut stroke is a CANCEL, not a lift")
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled,
                "no quiet window may run while the scene is away")
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled,
                "after the return the production waits for the child's next lift or the chevron")
        #expect(!rig.vm.isPhaseSessionComplete)
        #expect(rig.store.rows(.freeWrite).isEmpty)
    }

    @Test("a cut stroke that is not a production (a palm) arms nothing on the return")
    func inactiveMidPalmArmsNothing() async {
        let rig = freeWriteRig()
        rig.vm.beginTouch(at: CGPoint(x: 50, y: 200), t: 1000)   // one sample, no move
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
    }

    // Delta review of batch C, item 1 (reviewer probe P8): UIKit may cancel
    // the touch BEFORE the scene goes inactive. The resume must arm the
    // window whichever of the two events came first.
    @Test("the system cancels the stroke BEFORE .inactive: the return still arms a fresh quiet window")
    func cancelThenInactiveArmsOnReturn() async {
        let rig = freeWriteRig()
        rig.strokeDown()
        rig.vm.cancelTouch()
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled, "a cancel alone arms nothing (R-024)")
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled,
                "cut by the system, then inactive: the trial waits for another lift or the chevron")
        #expect(rig.store.rows(.freeWrite).isEmpty)
    }

    @Test("the system cancels the stroke, then the parent area opens: closing it arms a fresh quiet window")
    func cancelThenParentAreaArmsOnClose() async {
        let rig = freeWriteRig()
        rig.strokeDown()
        rig.vm.cancelTouch()
        rig.vm.parentAreaDidOpen()
        rig.vm.parentAreaDidClose()
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
    }

    @Test("background after inactive still records the finished production (last-trial protection)")
    func backgroundStillFinalises() async {
        let rig = freeWriteRig()
        rig.strokeDown()
        rig.vm.endTouch()
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        await rig.vm.scenePhaseDidChange(to: .background)?.value
        let fw = rig.store.rows(.freeWrite)
        #expect(fw.count == 1 && fw.first?.completed == true,
                "backgrounding must still record the finished production: \(fw.map(\.completed))")
    }

    @Test("inactive stops sound and voice and pauses the active-time clock; active restarts the clock")
    func inactivePausesTheSession() async {
        let rig = freeWriteRig()
        rig.strokeDown()
        #expect(rig.audio.isPlaying, "precondition: the sound arm is sounding under the pen")
        let speechStops = rig.speech.stopCount
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        #expect(!rig.audio.isPlaying && !rig.vm.isPlaying, "the arm's sound kept playing behind Control Center")
        #expect(rig.speech.stopCount > speechStops, "the voice was not stopped")
        #expect(rig.vm.debugLetterLoadTime == nil, "active time kept accruing while the scene was inactive")
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.vm.debugLetterLoadTime != nil, "active time did not resume")
    }

    @Test("a second inactive inside the first changes nothing; one return resumes")
    func inactiveIsIdempotent() async {
        let rig = freeWriteRig()
        rig.strokeDown()
        rig.vm.endTouch()
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        #expect(rig.store.rows(.freeWrite).isEmpty)
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
    }
}
