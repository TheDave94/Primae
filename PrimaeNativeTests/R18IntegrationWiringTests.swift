// R18IntegrationWiringTests.swift
// PrimaeNativeTests — R18DIM integration lane (slice 7b)
//
// The three call-site wiring tests the six lane reports name as gaps:
//
//   s1  the pen's LIFT tail must honour "Tempo folgt dem Stift" at the
//       TouchDispatcher level (the lane only pinned the pure helper).
//   s2  the OBSERVE call site must pass `pitch: pitchCoupling`, so the
//       both-arms scope reaches the phoneme arm's dot — and the default
//       spatial-only scope leaves the phoneme arm unpitched.
//   s7  both roughness paths — the pen (TouchDispatcher) and the observe
//       dot (TracingViewModel.handleGuideFrame) — must carry the switch.
//       Switch off writes 0 on every sample, switch on writes the meter's
//       stop-and-go value.
//
// Every assertion was mutation-checked (see r18dim/int/REPORT.md).

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite("R18DIM integration wiring", .serialized)
@MainActor struct R18IntegrationWiringTests {

    // MARK: - s1: touch-level lift tail

    @Test("s1: the lift's frozen tail holds rate 1.0 with Tempo folgt dem Stift off")
    func liftTailAtTouchLevelHonoursTheSwitch() {
        let rig = LifecycleRig(arm: .phoneme, configure: { $0.rateCoupling = false })
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .guided)

        // A fast horizontal stroke on the stub letter's line: 1000 pt/s maps
        // to 1.25 when the rate coupling is on, so a leaked tail is visible.
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 60, y: 200)
        rig.vm.beginTouch(at: p, t: t)
        for _ in 0..<15 {
            t += 0.01
            p.x += 10
            rig.vm.updateTouch(at: p, t: t, canvasSize: rig.canvas)
        }
        #expect(rig.vm.playback.state == .active,
                "precondition: the stroke is still sounding at the lift")

        let before = rig.audio.setAdaptiveCalls.count
        rig.vm.endTouch()
        let tail = Array(rig.audio.setAdaptiveCalls[before...])
        #expect(tail.count == 1,
                "precondition: the lift writes exactly one frozen tail (got \(tail.count): \(tail.map(\.speed)))")
        #expect(tail.allSatisfy { $0.speed == 1.0 },
                "the lift tail leaked the M3 rate with the switch off: \(tail.map(\.speed))")
    }

    // MARK: - D1: the roughness tuning survives a silent launch

    @Test("D1: a rig launched silent hands the proctor's roughness depth/rate to the engine when it moves to a sound arm",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func roughnessTuningReachesTheEngineAfterASilentLaunch(to arm: PilotAudioCondition) {
        let rig = LifecycleRig(arm: .silent, configure: {
            $0.dysfluencyRoughnessDepth = 0.35
            $0.dysfluencyRoughnessRateHz = 25
        })
        #expect(rig.audio.roughnessTunings.isEmpty,
                "precondition: the silent gate kept the construction push away from the real engine (got \(rig.audio.roughnessTunings))")

        rig.vm.applyArm(arm)
        #expect(rig.vm.audioCondition == arm, "precondition: the rig moved to \(arm)")
        #expect(rig.vm.engineFollowsArm, "precondition: the gate is open")

        #expect(!rig.audio.roughnessTunings.isEmpty,
                "the gate opened onto the engine and the roughness tuning was never delivered — the two strength rows would render at the built-in 0.8 / 40 Hz")
        if let last = rig.audio.roughnessTunings.last {
            #expect(last.depth == Float(0.35) && last.frequencyHz == Float(25),
                    "the engine got depth \(last.depth) / \(last.frequencyHz) Hz, not the settings' 0.35 / 25 Hz")
        }
    }

    // MARK: - s2: observe call-site pitch

    /// Load A into observe and let the presentation (and its sound) start:
    /// the same recipe as `TouchLiftAudioTests.observePlaying`.
    private func observing(_ configure: (inout TracingDependencies) -> Void = { _ in }) async -> LifecycleRig {
        let rig = LifecycleRig(arm: .phoneme, configure: configure)
        rig.vm.loadLetter(name: "A")
        rig.speech.end(ChildSpeechLibrary.phaseEntry(.observe))
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil && rig.audio.isPlaying }
        rig.vm.animation.stop()   // keep the phase in observe; the test drives the dot itself
        return rig
    }

    @Test("s2: the observe dot drives phoneme pitch with scope both, and none at the default")
    func observeCallSiteCarriesPitchScope() async {
        let both = await observing { $0.pitchCoupling = PitchCoupling(scope: .both) }
        #expect(both.vm.learningPhase == .observe, "precondition: still in observe")
        // The guide's frame points are CELL fractions; the view model maps
        // them to the canvas before the pitch mapping. Compute the expected
        // cents from that same cell geometry instead of assuming the cell is
        // the canvas (it is not in a laid-out study grid).
        let cell = both.vm.grid.activeCell.frame
        let canvas = both.vm.canvasSize
        let normY = cell.height > 0 ? (cell.minY + 0.25 * cell.height) / canvas.height : 0.25
        let expected = SpatialSonification.pitchCents(forNormalizedY: normY,
                                                      spanCents: PitchCoupling.defaultSpanCents)
        let mark = both.audio.spatialPitches.count
        both.vm.handleGuideFrame(.still(CGPoint(x: 0.5, y: 0.25)))
        let added = Array(both.audio.spatialPitches[mark...])
        #expect(added.count == 1,
                "the observe call site did not drive the pitch the both-scope asks for: \(added)")
        #expect(added.first.map { abs($0 - expected) < 1 } ?? false,
                "cell y=0.25 must map to \(expected) cents, got \(added)")

        let dflt = await observing()
        let before = dflt.audio.spatialPitches.count
        dflt.vm.handleGuideFrame(.still(CGPoint(x: 0.5, y: 0.25)))
        #expect(dflt.audio.spatialPitches.count == before,
                "the default spatial-only scope pitched the phoneme arm's dot: \(Array(dflt.audio.spatialPitches[before...]))")
    }

    // MARK: - s7: roughness wiring, pen and observe

    /// A synthetic stop-and-go stroke through the real dispatcher: 10 samples
    /// at 220 pt/s, then 10 at 10 pt/s, repeated — the meter's own definition
    /// of dysfluent, expressed on the touch clock.
    private func driveJerkyStroke(_ rig: LifecycleRig) {
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .guided)
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 60, y: 200)
        rig.vm.beginTouch(at: p, t: t)
        for i in 0..<150 {
            t += 1.0 / 120
            let speed: CGFloat = (i / 10) % 2 == 0 ? 220 : 10
            p.x += speed / 120
            rig.vm.updateTouch(at: p, t: t, canvasSize: rig.canvas)
        }
        rig.vm.endTouch()
    }

    @Test("s7: the pen path writes the meter's roughness when the switch is on and 0 when off")
    func penRoughnessWiring() {
        let on = LifecycleRig(arm: .phoneme, configure: { $0.dysfluencyRoughness = true })
        driveJerkyStroke(on)
        #expect(on.audio.roughnessWrites.count > 0, "precondition: the pen path wrote roughness")
        #expect(on.audio.roughnessWrites.contains { $0 > 0.2 },
                "the pen's jerky stroke never reached the audio (switch on): \(on.audio.roughnessWrites.suffix(8))")

        let off = LifecycleRig(arm: .phoneme)
        driveJerkyStroke(off)
        #expect(off.audio.roughnessWrites.count > 0, "precondition: the pen path wrote roughness")
        #expect(off.audio.roughnessWrites.allSatisfy { $0 == 0 },
                "switch off wrote roughness: \(off.audio.roughnessWrites.filter { $0 != 0 }.prefix(8))")
    }

    @Test("s7: the observe dot writes its own roughness when the switch is on and 0 when off")
    func observeRoughnessWiring() async {
        let on = await observing { $0.dysfluencyRoughness = true }
        #expect(on.vm.learningPhase == .observe, "precondition: still in observe")
        var x: CGFloat = 100
        for _ in 0..<4 {
            on.vm.handleGuideFrame(.move(from: CGPoint(x: x, y: 200),
                                         to: CGPoint(x: x + 11, y: 200), seconds: 0.05))
            x += 11
            try? await Task.sleep(for: .milliseconds(60))
            on.vm.handleGuideFrame(.move(from: CGPoint(x: x, y: 200),
                                         to: CGPoint(x: x + 0.5, y: 200), seconds: 0.05))
            x += 0.5
            try? await Task.sleep(for: .milliseconds(60))
        }
        on.vm.handleGuideFrame(.still(CGPoint(x: x, y: 200)))
        #expect(on.audio.roughnessWrites.contains { $0 > 0.2 },
                "the observe dot's roughness never reached the audio (switch on): \(on.audio.roughnessWrites.suffix(8))")

        let off = await observing()
        off.vm.handleGuideFrame(.move(from: CGPoint(x: 100, y: 200),
                                      to: CGPoint(x: 111, y: 200), seconds: 0.05))
        off.vm.handleGuideFrame(.still(CGPoint(x: 111, y: 200)))
        #expect(off.audio.roughnessWrites.count > 0, "precondition: the observe path wrote roughness (else the check below is vacuous)")
        #expect(off.audio.roughnessWrites.allSatisfy { $0 == 0 },
                "switch off wrote observe roughness: \(off.audio.roughnessWrites.filter { $0 != 0 }.prefix(8))")
    }
}
