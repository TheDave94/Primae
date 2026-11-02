// CanvasAndSettingsFixTests.swift
// PrimaeNativeTests
//
// Pins three fixes from the 2026-11-02 bug-hunt fix round (lane L3):
//
// - VERIFY-11 (A21): `CanvasDrawPlan.showsGhost` is what the canvas draws.
//   The canvas used to decide the ghost itself and never read the plan, so
//   the plan said "no ghost" in guided with the toggle off while the canvas
//   drew one, and every assertion on the plan tested nothing drawn.
// - VERIFY-13 (A23): "Vergleichsmodus zurücksetzen" blocks the session only
//   when the reset actually changed a switch.
// - UI-1 / B10: `CanvasTouchArbiter`, the rule for which finger on the
//   canvas is the pen. The device half (real synthesized touches) is
//   `RestingContactUITests` in PrimaeUITests.
//
// No test here writes a device key: the reset runs against a throwaway
// suite, and the view models come from `TracingDependencies.stub`.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - A21

@MainActor
@Suite struct CanvasGhostPlanTests {

    private func studyVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 400, height: 400)
        return vm
    }

    /// The repro from VERIFY-11: guided, the parent toggle off. The canvas
    /// draws the ghost there (the phase default), so the plan must say so.
    @Test("guided with the ghost toggle off still draws the ghost")
    func guidedToggleOffStillDrawsGhost() {
        let vm = studyVM()
        vm.showGhost = false
        vm.phaseController.resume(at: .guided)
        #expect(vm.learningPhase == .guided, "precondition: the session must be in guided")
        #expect(vm.canvasDrawPlan.showsGhost,
                "the plan says no ghost in guided with the toggle off, but the phase draws one — the plan is not what the canvas draws")
    }

    @Test("observe draws the ghost whatever the toggle says")
    func observeDrawsGhost() {
        let vm = studyVM()
        #expect(vm.learningPhase == .observe, "precondition: a study session starts in observe")
        vm.showGhost = false
        #expect(vm.canvasDrawPlan.showsGhost)
        vm.showGhost = true
        #expect(vm.canvasDrawPlan.showsGhost)
    }

    @Test("freeWrite never draws the ghost, even with the toggle on")
    func freeWriteNeverDrawsGhost() {
        let vm = studyVM()
        vm.showGhost = true
        vm.phaseController.resume(at: .freeWrite)
        #expect(vm.learningPhase == .freeWrite, "precondition: the session must be in freeWrite")
        #expect(vm.canvasDrawPlan.showsGhost == false,
                "the toggle re-added the ghost in freeWrite, which withdraws all scaffolding")
    }
}

// MARK: - A23

@Suite struct ComparisonResetChangeTests {

    @Test("a reset on an untouched store reports no change")
    func resetOnDefaultsIsNoChange() {
        let box = ThrowawayDefaults()
        #expect(StudyComparisonSettings.resetToDefaults(in: box.defaults) == false,
                "a reset on an untouched device reported a change, so the session would be blocked for nothing")
    }

    @Test("a reset after one switch moved reports a change")
    func resetAfterAChangeIsAChange() {
        let box = ThrowawayDefaults()
        box.defaults.set(2, forKey: StudyComparisonSettings.observePassesKey)
        #expect(StudyComparisonSettings.resetToDefaults(in: box.defaults),
                "a reset that moved observePasses back to 1 reported no change — a comparison session would keep running")
        #expect(StudyComparisonSettings.configuration(in: box.defaults) == .defaults)
    }

    /// A key stored AT its default value changes nothing when removed: the
    /// resolved configuration is what a session runs, not the stored keys.
    @Test("a reset of a switch stored at its default value reports no change")
    func resetOfDefaultValuedKeyIsNoChange() {
        let box = ThrowawayDefaults()
        box.write(.defaults)
        #expect(StudyComparisonSettings.resetToDefaults(in: box.defaults) == false)
    }
}

// MARK: - UI-1 / B10

@MainActor
@Suite struct CanvasTouchArbiterTests {

    typealias Arbiter = CanvasTouchArbiter<Int>
    typealias Sample = Arbiter.Sample

    /// A reference holder: `#expect` evaluates its expression in a closure,
    /// where a `var` struct cannot be mutated.
    final class Box { var v = Arbiter() }

    private func s(_ x: CGFloat, _ y: CGFloat, _ t: CFTimeInterval) -> Sample {
        Sample(point: CGPoint(x: x, y: y), time: t)
    }

    /// The one-finger case is unchanged: a lone finger is the pen at once.
    @Test("a lone finger is the pen at touch-down")
    func loneFingerBeginsAtOnce() {
        let a = Box()
        #expect(a.v.began(1, at: s(10, 10, 0), fingersInView: 1) == .begin(1, replay: [s(10, 10, 0)]))
        #expect(a.v.moved(1, samples: [s(50, 10, 0.1)]) == .none, "the pen's own moves are delivered by the caller")
        let ended1 = a.v.ended(1)
        #expect(ended1)
        #expect(a.v.tracked == nil)
    }

    /// B10, the palm-first case: the palm lands alone and is taken as the
    /// pen; the finger that lands next and moves takes over, and its stroke
    /// is replayed from its own touch-down.
    @Test("a moving finger takes over from a resting palm")
    func movingFingerTakesOverFromRestingPalm() {
        let a = Box()
        #expect(a.v.began(1, at: s(700, 700, 0), fingersInView: 1) == .begin(1, replay: [s(700, 700, 0)]))
        #expect(a.v.began(2, at: s(100, 100, 0.3), fingersInView: 2) == .none,
                "a second finger is not the pen at touch-down")
        #expect(a.v.moved(1, samples: [s(700.3, 700, 0.4)]) == .none, "palm tremor")
        #expect(a.v.moved(2, samples: [s(110, 100, 0.35)]) == .none, "not yet moving")
        let decision = a.v.moved(2, samples: [s(130, 100, 0.45)])
        #expect(decision == .handOver(from: 1, to: 2,
                                      replay: [s(100, 100, 0.3), s(110, 100, 0.35), s(130, 100, 0.45)]),
                "the resting palm kept the pen while the finger traced: \(decision)")
        #expect(a.v.tracked == 2)
        #expect(a.v.ended(1) == false, "the palm's lift must not end the finger's stroke")
        let ended2 = a.v.ended(2)
        #expect(ended2)
    }

    /// The palm stays down across strokes: after the first stroke's lift
    /// nothing is the pen, and the next stroke's finger lands as a second
    /// touch. It must still become the pen when it moves.
    @Test("with the palm still down, the next stroke's finger becomes the pen")
    func palmStaysDownAcrossStrokes() {
        let a = Box()
        _ = a.v.began(1, at: s(700, 700, 0), fingersInView: 1)
        _ = a.v.began(2, at: s(100, 100, 0.3), fingersInView: 2)
        _ = a.v.moved(2, samples: [s(140, 100, 0.5)])
        let ended2 = a.v.ended(2)
        #expect(ended2)
        #expect(a.v.tracked == nil)
        #expect(a.v.began(3, at: s(100, 200, 1.0), fingersInView: 2) == .none)
        #expect(a.v.moved(3, samples: [s(100, 240, 1.2)]) == .begin(3, replay: [s(100, 200, 1.0), s(100, 240, 1.2)]),
                "a finger tracing with the palm still down was ignored")
    }

    /// A pen that is drawing is never taken over by a second finger.
    @Test("a moving pen is never handed over")
    func movingPenIsNeverHandedOver() {
        let a = Box()
        _ = a.v.began(1, at: s(100, 100, 0), fingersInView: 1)
        _ = a.v.moved(1, samples: [s(160, 100, 0.3)])
        #expect(a.v.began(2, at: s(700, 700, 0.4), fingersInView: 2) == .none)
        #expect(a.v.moved(2, samples: [s(760, 700, 0.6)]) == .none,
                "a second finger took the stroke from a pen that was drawing")
        #expect(a.v.tracked == 1)
    }

    /// Two fingers landing and moving together (a two-finger swipe) adopt
    /// neither: neither is ever moving while the other rests.
    @Test("two fingers moving together adopt neither")
    func twoFingerSwipeAdoptsNeither() {
        let a = Box()
        #expect(a.v.began(1, at: s(100, 300, 0), fingersInView: 2) == .none)
        #expect(a.v.began(2, at: s(200, 300, 0), fingersInView: 2) == .none)
        for k in 1...10 {
            let dy = CGFloat(k) * 8
            let t = Double(k) * 0.02
            #expect(a.v.moved(1, samples: [s(100, 300 - dy, t)]) == .none)
            #expect(a.v.moved(2, samples: [s(200, 300 - dy, t)]) == .none)
        }
        #expect(a.v.tracked == nil)
    }

    @Test("reset forgets every finger")
    func resetForgetsEverything() {
        let a = Box()
        _ = a.v.began(1, at: s(0, 0, 0), fingersInView: 1)
        a.v.reset()
        #expect(a.v.tracked == nil)
        #expect(a.v.ended(1) == false)
    }
}
