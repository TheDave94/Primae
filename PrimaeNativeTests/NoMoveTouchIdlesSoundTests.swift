// NoMoveTouchIdlesSoundTests.swift
// Audit R-077(a): a touch that never moves left the playback machine
// `.active` (the previous stroke's lift hold), so `finishTouch` re-armed the
// 0.8 s hold; repeated taps under 0.8 s apart kept the sound alive.

import Testing
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct NoMoveTouchIdlesSoundTests {

    private func rigHoldingSound() -> LifecycleRig {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.strokeDown()
        rig.vm.endTouch()
        return rig
    }

    @Test("R-077a: a tap that never moves ends the lift-hold sound at once")
    func noMoveTapIdlesSound() {
        let rig = rigHoldingSound()
        #expect(rig.vm.playback.state == .active,
                "precondition: the lift hold of a real stroke keeps the machine active")
        let stopsBefore = rig.audio.events.filter { $0 == .stop }.count
        rig.vm.beginTouch(at: CGPoint(x: 50, y: 200), t: 1002)
        rig.vm.endTouch()
        #expect(rig.vm.playback.state == .idle, "a no-move tap must not re-arm the hold")
        #expect(rig.audio.events.filter { $0 == .stop }.count > stopsBefore,
                "the sound must be stopped, not left to a re-armed hold")
    }

    @Test("R-077a control: a touch that moves still gets the lift hold")
    func movingTouchStillHolds() {
        let rig = rigHoldingSound()
        rig.strokeDown(t0: 1002)
        rig.vm.endTouch()
        #expect(rig.vm.playback.state == .active, "a real stroke's lift keeps its hold")
    }
}
