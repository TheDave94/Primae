// ROADMAP D9 (renderer architecture), decided 2026-11-24 — see
// docs/DECISIONS.md, "Renderer architecture (ROADMAP D9)".
//
// Question 1: every ink width the canvas strokes is a VALUE in the draw
// plan (absolute points, the live stroke at its device's width), so a test
// can read what the Canvas closure replays (CLAUDE.md, Test Infrastructure 3).
// Question 2: a stroke keeps the device it started with; a move from the
// other device is ignored in BOTH directions (protocol r28).

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct RendererD9Tests {

    private let canvas = CGSize(width: 400, height: 400)

    private func studyVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        return vm
    }

    // MARK: - Question 1: ink widths in the draw plan

    @Test("the draw plan hands the canvas every ink width: finger 14, retained 12, lingering 14, lifted free-writing 14")
    func planInkWidthsForAFinger() {
        let vm = studyVM()
        vm.pencilPressure = nil
        let ink = vm.canvasDrawPlan.ink
        #expect(ink.live == 14, "live finger ink")
        #expect(ink.retained == 12, "retained ink")
        #expect(ink.lingering == 14, "lingering ink")
        #expect(ink.completedFreeWrite == 14, "lifted free-writing ink")
    }

    @Test("the live width in the plan follows the Pencil's pressure; the lifted free-writing width does not")
    func planLiveInkFollowsPencilPressure() {
        let vm = studyVM()
        vm.pencilPressure = 0.5
        let ink = vm.canvasDrawPlan.ink
        #expect(ink.live == 15, "8 + 14 x 0.5")
        #expect(ink.completedFreeWrite == 14, "lifted strokes stay at the finger width whatever the device")
        vm.pencilPressure = 1
        #expect(vm.canvasDrawPlan.ink.live == 22)
        vm.pencilPressure = 0
        #expect(vm.canvasDrawPlan.ink.live == 8)
    }

    @Test("the widths are absolute: the plan's ink does not move with the canvas size")
    func inkWidthsDoNotScaleWithTheCanvas() {
        let vm = studyVM()
        let small = vm.canvasDrawPlan.ink
        vm.canvasSize = CGSize(width: 1270, height: 874)
        #expect(vm.canvasDrawPlan.ink == small)
    }

    // MARK: - Question 2: the stroke keeps its touch-down device

    @Test("a finger move during a Pencil stroke is ignored, and the Pencil's stroke goes on")
    func fingerMoveDuringPencilStrokeIsIgnored() {
        let vm = studyVM()
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        vm.pencilDidTouchDown()
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t, force: 0.5)
        vm.pencilPressure = 0.6
        t += 0.01; vm.updateTouch(at: CGPoint(x: 60, y: 200), t: t, canvasSize: canvas, fromPencil: true)
        let points = vm.freeWritePoints.count
        let ink = vm.activePath.count
        // A resting finger moves while the Pencil is still down. The
        // Pencil's pressure stamp is still set from its last move.
        t += 0.01; vm.updateTouch(at: CGPoint(x: 300, y: 50), t: t, canvasSize: canvas, fromPencil: false)
        #expect(vm.freeWritePoints.count == points, "the finger's point must not enter the Pencil's record")
        #expect(vm.activePath.count == ink, "the finger's point must not join the Pencil's ink")
        #expect(vm.pencilPressure == 0.6, "the Pencil's own stamp is not the finger's to clear")
        // The finger lifts: the Pencil's stroke survives it.
        vm.endTouch(fromPencil: false)
        t += 0.01; vm.updateTouch(at: CGPoint(x: 70, y: 200), t: t, canvasSize: canvas, fromPencil: true)
        #expect(vm.freeWritePoints.count == points + 1, "the Pencil is still drawing after the finger lifted")
        #expect(vm.activePath.last == CGPoint(x: 70, y: 200))
        vm.endTouch(fromPencil: true)
        #expect(vm.freeWriteStrokeStartIndices.isEmpty, "one stroke, no boundary from the ignored events")
    }

    @Test("a Pencil move during a finger stroke is ignored when the overlay names the device")
    func pencilMoveDuringFingerStrokeIsIgnored() {
        let vm = studyVM()
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000
        vm.fingerDidTouchDown()
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t)
        t += 0.01; vm.updateTouch(at: CGPoint(x: 60, y: 200), t: t, canvasSize: canvas, fromPencil: false)
        let points = vm.freeWritePoints.count
        vm.pencilPressure = 0.6
        t += 0.01; vm.updateTouch(at: CGPoint(x: 300, y: 50), t: t, canvasSize: canvas, fromPencil: true)
        #expect(vm.freeWritePoints.count == points)
        #expect(vm.pencilPressure == nil, "the stray Pencil stamp is cleared, so the finger ink keeps the finger width")
        #expect(vm.canvasDrawPlan.ink.live == 14)
        t += 0.01; vm.updateTouch(at: CGPoint(x: 70, y: 200), t: t, canvasSize: canvas, fromPencil: false)
        #expect(vm.freeWritePoints.count == points + 1)
        vm.endTouch(fromPencil: false)
    }
}
