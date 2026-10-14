// CancelledTouchTests.swift
// R-024 (audit 2026-10-13, H1-03): a touch the SYSTEM cancels — an edge
// gesture, Control Center, palm rejection — reached the view model as a
// deliberate pen lift (`touchesCancelled` → `touchesEnded`, finger and
// Pencil). In free-writing a lift arms the 2.0 s quiet window, so a
// cancelled stroke could end the outcome trial. A cancel must close the
// stroke (its samples stay in the trace) WITHOUT arming the quiet window,
// and is counted.

import Testing
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct CancelledTouchTests {

    @Test("control: a real lift after a free-writing stroke arms the quiet window")
    func liftArmsTheQuietWindow() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.strokeDown()
        rig.vm.endTouch()
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled,
                "precondition: the rig's stroke is a production")
    }

    @Test("a cancelled free-writing stroke is kept and closed, but does NOT arm the quiet window")
    func cancelDoesNotArmTheQuietWindow() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.strokeDown()
        let pointsBefore = rig.vm.freeWritePoints.count
        rig.vm.cancelTouch()
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled,
                "a system-cancelled touch armed the 2.0 s quiet window like a deliberate lift")
        #expect(!rig.vm.touchDispatcher.isSingleTouchInteractionActive, "the stroke is closed")
        #expect(rig.vm.freeWritePoints.count >= pointsBefore, "the cancelled stroke's samples stay in the trace")
        #expect(rig.vm.lifecycleCounters.strokesCancelled == 1)
    }

    @Test("the Pencil's cancel is a cancel too")
    func pencilCancelDoesNotArmTheQuietWindow() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.vm.pencilDidTouchDown()
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 50, y: 200)
        rig.vm.beginTouch(at: p, t: t)
        for _ in 0..<15 {
            t += 0.01; p.x += 10
            rig.vm.pencilPressure = 0.5
            rig.vm.updateTouch(at: p, t: t, canvasSize: rig.canvas)
        }
        #expect(rig.vm.freeWritePoints.count >= 2, "precondition: the Pencil stroke was recorded")
        rig.vm.cancelTouch(fromPencil: true)
        #expect(!rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
        #expect(!rig.vm.touchDispatcher.isSingleTouchInteractionActive)
        #expect(rig.vm.lifecycleCounters.strokesCancelled == 1)
    }

    @Test("after a cancelled stroke, the child's next real lift arms the quiet window as usual")
    func nextLiftStillArms() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.strokeDown()
        rig.vm.cancelTouch()
        rig.strokeDown(from: CGPoint(x: 50, y: 250), t0: 2000)
        rig.vm.endTouch()
        #expect(rig.vm.touchDispatcher.isFreeWriteAdvanceScheduled)
        #expect(rig.vm.lifecycleCounters.strokesCancelled == 1)
    }

    @Test("a cancel with no touch down counts nothing")
    func cancelWithoutTouchCountsNothing() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.cancelTouch()
        #expect(rig.vm.lifecycleCounters.strokesCancelled == 0)
    }
}
