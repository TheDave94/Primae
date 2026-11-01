// TouchLiftAudioTests.swift
// Code analysis 2026-11-01, F1 and F2: two touch paths that reached the
// audio when they should not have.
//
// F1: a lift (or a system cancel) whose touch-down `beginTouch` rejected —
// any touch during observe — reached `finishTouch`, found the playback
// machine `.idle` (the observe demonstration plays through
// `audio.play(fadeInSeconds:)` directly) and called `audio.stop()`: a
// child's tap silenced the demonstration, in the sound arms only.
//
// F2: on the sample that completes the letter, `updateAdaptivePlayback`
// ran before `handleStrokeCompletionIfReached`, so with the machine idle
// (the stall timeout had fired) it started the sound at full level and the
// completion stopped it in the same turn.

import Testing
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct TouchLiftAudioTests {

    // MARK: - F1

    /// Load A in observe and let the presentation (animation + the arm's
    /// sound) start: the same recipe as ObserveInterruptionRestartTests.
    private func observePlaying(_ arm: PilotAudioCondition) async -> LifecycleRig {
        let rig = LifecycleRig(arm: arm)
        rig.vm.loadLetter(name: "A")
        rig.speech.end(ChildSpeechLibrary.phaseEntry(.observe))
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil && rig.audio.isPlaying }
        return rig
    }

    @Test("F1: a lift whose touch-down observe rejected does not stop the demonstration sound",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeLiftDoesNotStopSound(arm: PilotAudioCondition) async {
        let rig = await observePlaying(arm)
        #expect(rig.vm.learningPhase == .observe, "precondition: still in observe")
        #expect(rig.audio.isPlaying, "precondition: the \(arm) observe sound is playing — events \(rig.audio.events)")
        let stopsBefore = rig.audio.stopsDuringObserve
        rig.vm.beginTouch(at: CGPoint(x: 50, y: 200), t: 1000)
        #expect(!rig.vm.touchDispatcher.isSingleTouchInteractionActive,
                "precondition: observe rejects the touch-down")
        rig.vm.endTouch()
        #expect(rig.audio.stopsDuringObserve == stopsBefore,
                "\(arm): a tap in observe stopped the demonstration sound — events \(rig.audio.events.suffix(4))")
        #expect(rig.audio.isPlaying)
    }

    @Test("F1: a system cancel, and a Pencil lift, with no touch-down do not stop it either",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeCancelAndPencilLiftDoNotStopSound(arm: PilotAudioCondition) async {
        let rig = await observePlaying(arm)
        #expect(rig.vm.learningPhase == .observe, "precondition: still in observe")
        #expect(rig.audio.isPlaying, "precondition: the \(arm) observe sound is playing — events \(rig.audio.events)")
        let stopsBefore = rig.audio.stopsDuringObserve
        rig.vm.cancelTouch()
        rig.vm.endTouch(fromPencil: true)
        rig.vm.cancelTouch(fromPencil: false)
        #expect(rig.audio.stopsDuringObserve == stopsBefore,
                "\(arm): an end event with no session stopped the demonstration sound — events \(rig.audio.events.suffix(4))")
        #expect(rig.audio.isPlaying)
        #expect(rig.vm.lifecycleCounters.strokesCancelled == 0)
    }

    @Test("F1 control: a lift that ends a REAL stroke still stops an idle machine's sound")
    func realLiftStillStops() {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        rig.strokeDown()
        #expect(rig.vm.touchDispatcher.isSingleTouchInteractionActive, "precondition: a stroke is in progress")
        rig.vm.playback.request(.idle, immediate: true)   // the stall timeout fired
        let stopsBefore = rig.audio.events.filter { $0 == .stop }.count
        rig.vm.endTouch()
        #expect(rig.audio.events.filter { $0 == .stop }.count > stopsBefore,
                "the lift of a real stroke must still close the sound")
    }

    // MARK: - F2

    @Test("F2: the sample that completes the letter does not start the sound")
    func completingSampleDoesNotStartSound() {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .guided)
        // The stub letter: one horizontal stroke at y = 0.5, 50 checkpoints
        // from x = 0.00 to 0.98 (same gesture as HapticEngineTests).
        let w = rig.canvas.width, h = rig.canvas.height
        let points = (0..<50).map { CGPoint(x: CGFloat($0) * 0.02 * w, y: 0.5 * h) }
        var t: CFTimeInterval = 1000
        rig.vm.beginTouch(at: points[0], t: t)
        var completed = false
        var idleSampleStartedSound = false
        for p in points {
            t += 0.05
            // Before every sample the machine is idle, as after the stall
            // timeout: the pen rested, then nudged on.
            rig.vm.playback.request(.idle, immediate: true)
            let mark = rig.audio.events.count
            rig.vm.updateTouch(at: p, t: t, canvasSize: rig.canvas)
            let played = rig.audio.events[mark...].contains { if case .play = $0 { return true } else { return false } }
            if rig.vm.phaseController.currentPhase != .guided {
                completed = true
                #expect(!played,
                        "the completing sample started the sound — events \(Array(rig.audio.events[mark...]))")
                break
            }
            if played { idleSampleStartedSound = true }
        }
        #expect(completed, "precondition: the trace must complete guided, or this proves nothing")
        #expect(idleSampleStartedSound,
                "control: a non-completing sample on the letter restarts an idle machine's sound")
    }

    // MARK: - F1, second effect

    /// Measured on the iPad (render tap, 2026-11-01, on a build WITHOUT F1):
    /// the letter completes with the pen still down, the transition stops
    /// the sound with its fade and ends the session (`resetTouchState`),
    /// and the later lift called `stop()` again mid-fade — restarting the
    /// fade from the faded volume (0.83 s tail instead of 0.4 s). F1's
    /// no-session guard is what prevents it; this pins that effect.
    @Test("F1: lifting after the letter completed under the pen does not stop the sound a second time")
    func liftAfterCompletionDoesNotStopAgain() {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .guided)
        let w = rig.canvas.width, h = rig.canvas.height
        let points = (0..<50).map { CGPoint(x: CGFloat($0) * 0.02 * w, y: 0.5 * h) }
        var t: CFTimeInterval = 1000
        rig.vm.beginTouch(at: points[0], t: t)
        for p in points {
            t += 0.05
            rig.vm.updateTouch(at: p, t: t, canvasSize: rig.canvas)
            if rig.vm.phaseController.currentPhase != .guided { break }
        }
        #expect(rig.vm.phaseController.currentPhase != .guided,
                "precondition: the trace must complete guided under the pen")
        let stopsAtCompletion = rig.audio.events.filter { if case .stop = $0 { return true } else { return false } }.count
        #expect(stopsAtCompletion > 0, "precondition: the completion itself stops the sound")
        let mark = rig.audio.events.count
        rig.vm.endTouch()
        let laterStops = rig.audio.events[mark...].filter { if case .stop = $0 { return true } else { return false } }.count
        #expect(laterStops == 0,
                "the lift stopped the already-fading sound again — events \(Array(rig.audio.events[mark...]))")
    }
}
