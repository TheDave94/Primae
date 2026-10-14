// RetryCueTests.swift
// R-071 (audit 2026-10-13, H1-09 / H1-10).
//  - "Probier's nochmal" was spoken with a raw `speak` on EVERY
//    out-of-bounds rising edge in guided. AVSpeechSynthesizer queues
//    utterances, so a child scribbling past the edge three times in two
//    seconds heard it three times back to back, talking over the next
//    attempt. Now at most one per `TouchDispatcher.retryCueMinimumInterval`
//    (measured on the touch clock); the toast still shows on every edge.
//  - The stop of a just-queued utterance is `SpeechQueueTests`' (review
//    of batch C, item 2): the mock-only check that used to sit here proved
//    nothing about the device.

import Testing
import AVFoundation
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct RetryCueTests {

    private let retry = "Probier's nochmal"

    /// Guided on A, pen down, then `edges` excursions out of the canvas
    /// and back, the k-th leaving at touch time `t0 + k * spacing`.
    private func excursions(_ rig: LifecycleRig, edges: Int, spacing: CFTimeInterval) {
        var t: CFTimeInterval = 5000
        rig.vm.beginTouch(at: CGPoint(x: 200, y: 200), t: t)
        for k in 0..<edges {
            t = 5000 + Double(k) * spacing
            rig.vm.updateTouch(at: CGPoint(x: 380, y: 200), t: t, canvasSize: rig.canvas)
            rig.vm.updateTouch(at: CGPoint(x: 450, y: 200), t: t + 0.01, canvasSize: rig.canvas)  // out
            rig.vm.updateTouch(at: CGPoint(x: 380, y: 200), t: t + 0.02, canvasSize: rig.canvas)  // back in
        }
    }

    private func guidedRig() -> LifecycleRig {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .guided)
        return rig
    }

    @Test("three excursions inside the interval speak the retry cue once")
    func burstSpeaksOnce() {
        let rig = guidedRig()
        excursions(rig, edges: 3, spacing: 0.3)
        #expect(rig.speech.count(retry) == 1,
                "the retry cue was queued \(rig.speech.count(retry)) times for one burst of excursions")
    }

    @Test("an excursion after the interval speaks it again")
    func laterExcursionSpeaksAgain() {
        let rig = guidedRig()
        let spacing = TouchDispatcher.retryCueMinimumInterval + 0.1
        excursions(rig, edges: 2, spacing: spacing)
        #expect(rig.speech.count(retry) == 2)
    }
}
