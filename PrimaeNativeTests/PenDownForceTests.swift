// PenDownForceTests.swift
// PrimaeNativeTests
//
// Audit R-074: the pen-down sample recorded `vm.pencilPressure ?? 0`, which is
// nil at touch-down (only moves stamp it; finishTouch clears it), so every
// Pencil stroke's first recorded force was 0. The touch's own force now
// travels with `beginTouch`, into the recorded sample only, never into
// `pencilPressure` (which drives the sound).

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct PenDownForceTests {
    private func freeWriteVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 1000, height: 750)
        vm.phaseController.resume(at: .freeWrite)
        return vm
    }

    @Test("the pen-down sample records the touch's own force; later moves keep theirs")
    func penDownRecordsRealForce() {
        let vm = freeWriteVM()
        // The Pencil overlay's onBegan marks the touch-down as Pencil before
        // beginTouch (TracingCanvasView). Without it the session is a finger
        // session and updateTouch drops a move that carries pencilPressure as
        // the other device's (measured on device 2026-11-16: forces [0.6]).
        vm.pencilDidTouchDown()
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: 1000, force: 0.6)
        vm.pencilPressure = 0.3
        vm.updateTouch(at: CGPoint(x: 120, y: 100), t: 1000.01, canvasSize: vm.canvasSize)
        #expect(vm.freeWriteRecorder.forces == [0.6, 0.3])
    }

    @Test("pen-down force never reaches pencilPressure, which drives the sound")
    func penDownForceDoesNotTouchSoundInput() {
        let vm = freeWriteVM()
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: 1000, force: 0.6)
        #expect(vm.pencilPressure == nil)
    }

    @Test("a finger pen-down (no force) still records 0")
    func fingerPenDownRecordsZero() {
        let vm = freeWriteVM()
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: 1000)
        #expect(vm.freeWriteRecorder.forces == [0])
    }
}
