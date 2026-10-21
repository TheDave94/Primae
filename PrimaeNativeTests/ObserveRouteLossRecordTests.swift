// ObserveRouteLossRecordTests.swift
//
// A LOST OUTPUT IN OBSERVE IS RECORDED: WHEN, AND HOW MUCH OF THE OBSERVE
// SOUND IT COST (protocol r11, lane E 2026-10-21; audit lane A §4a).
//
// Before r11 the observe row showed a loss only as `routeChanges ≥ 1` and a
// different `outputRouteAtEnd`. That cannot tell a loss during the cue
// (the sound later starts on the output then present: full exposure) from
// a loss during the dot-tracked sound (the rest is cut and not replayed:
// partial exposure). The observe row now carries
// `observeLossesDuringSound`, `observeLossesWithoutSound`,
// `observeSoundSeconds` and `observeSoundDeliveredSeconds`. RECORD-ONLY:
// these tests assert nothing new about what is heard.
//
// The clock is the injected `TracingDependencies.mediaClock`, stepped by
// hand; nothing here writes a global.
//
// Mutation checks (break, confirm RED with the test count read, restore):
//   - lossDuringTheSoundCutsTheDelivery: in
//     `LifecycleCounters.observeOutputLost`, book every loss as
//     `observeLossesWithoutSound` and leave the delivery running.

import Testing
import Foundation
import AVFoundation
@testable import PrimaeNative

/// A hand-stepped monotonic clock.
final class SteppedMediaClock {
    var now: TimeInterval = 100
}

@Suite @MainActor struct ObserveRouteLossRecordTests {

    private typealias Reason = AVAudioSession.RouteChangeReason
    private var cue: String { ChildSpeechLibrary.phaseEntry(.observe) }

    private func rig(_ arm: PilotAudioCondition, _ clock: SteppedMediaClock) -> LifecycleRig {
        LifecycleRig(arm: arm) { $0.mediaClock = { clock.now } }
    }

    /// The headphones go; the engine's own reaction is modelled by the
    /// double, as in `RouteRecoveryTests`.
    private func lose(_ rig: LifecycleRig) {
        rig.audio.stop()
        rig.vm.handleAudioRouteChange(reasonRawValue: Reason.oldDeviceUnavailable.rawValue,
                                      outputLost: true, outputPortType: "Speaker",
                                      previousOutputPortType: "Headphones")
    }

    private func observeDelivery(_ rig: LifecycleRig) -> PhaseDelivery? {
        rig.vm.phaseRowContext(for: .observe, finalizedBy: .navigation).delivery
    }

    /// End the cue and wait for the presentation (and, in a sound arm,
    /// the observe sound) to start.
    private func presentationStarts(_ rig: LifecycleRig) async {
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil }
    }

    @Test("a loss during the observe sound: counted as during, delivery stops at the loss",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func lossDuringTheSoundCutsTheDelivery(arm: PilotAudioCondition) async throws {
        let clock = SteppedMediaClock()
        let rig = rig(arm, clock)
        rig.vm.loadLetter(name: "A")
        await presentationStarts(rig)          // sound starts at t = 100
        #expect(rig.audio.isPlaying, "precondition: the observe sound is playing")

        clock.now = 101.5
        lose(rig)
        clock.now = 104                         // the row is written with the phase still open

        let d = try #require(observeDelivery(rig))
        #expect(d.observeLossesDuringSound == 1, "\(arm): \(String(describing: d.observeLossesDuringSound))")
        #expect(d.observeLossesWithoutSound == 0)
        #expect(d.observeSoundDeliveredSeconds == 1.5,
                "\(arm): only the 1.5 s before the loss reached the child: \(String(describing: d.observeSoundDeliveredSeconds))")
        #expect(d.observeSoundSeconds == 4.0,
                "\(arm): the sound ran 4 s, start to the row: \(String(describing: d.observeSoundSeconds))")
    }

    @Test("a loss during the cue: counted as without sound, and the later sound is delivered in full",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func lossDuringTheCueLeavesTheSoundWhole(arm: PilotAudioCondition) async throws {
        let clock = SteppedMediaClock()
        let rig = rig(arm, clock)
        rig.vm.loadLetter(name: "A")
        lose(rig)                               // the cue is still running
        await presentationStarts(rig)           // sound starts at t = 100, on the speaker
        clock.now = 103

        let d = try #require(observeDelivery(rig))
        #expect(d.observeLossesDuringSound == 0)
        #expect(d.observeLossesWithoutSound == 1)
        #expect(d.observeSoundSeconds == 3.0 && d.observeSoundDeliveredSeconds == 3.0,
                "\(arm): \(String(describing: d.observeSoundSeconds)) / \(String(describing: d.observeSoundDeliveredSeconds))")
    }

    @Test("the silent arm: no observe sound, so 0 / 0.000 / 0.000 and every loss is without sound")
    func silentArmHasDefinedValues() async throws {
        let clock = SteppedMediaClock()
        let rig = rig(.silent, clock)
        rig.vm.loadLetter(name: "A")
        await presentationStarts(rig)
        clock.now = 101
        lose(rig)
        clock.now = 104

        let d = try #require(observeDelivery(rig))
        #expect(d.observeLossesDuringSound == 0)
        #expect(d.observeLossesWithoutSound == 1)
        #expect(d.observeSoundSeconds == 0 && d.observeSoundDeliveredSeconds == 0)
        #expect(rig.audio.playCount == 0, "the silent arm sounded: \(rig.audio.events)")
    }

    @Test("no loss: delivered equals ran; the fields are the observe row's alone")
    func noLossAndOtherPhases() async throws {
        let clock = SteppedMediaClock()
        let rig = rig(.phoneme, clock)
        rig.vm.loadLetter(name: "A")
        await presentationStarts(rig)
        clock.now = 102.25

        let d = try #require(observeDelivery(rig))
        #expect(d.observeLossesDuringSound == 0 && d.observeLossesWithoutSound == 0)
        #expect(d.observeSoundSeconds == 2.25 && d.observeSoundDeliveredSeconds == 2.25)

        // A later phase: a loss there is not an observe loss, and its row
        // carries no observe-sound fields.
        rig.vm.phaseController.resume(at: .freeWrite)
        lose(rig)
        let free = try #require(rig.vm.phaseRowContext(for: .freeWrite, finalizedBy: .navigation).delivery)
        #expect(free.observeLossesDuringSound == nil && free.observeLossesWithoutSound == nil
                && free.observeSoundSeconds == nil && free.observeSoundDeliveredSeconds == nil)
        let closed = try #require(observeDelivery(rig))
        #expect(closed.observeLossesDuringSound == 0 && closed.observeLossesWithoutSound == 0,
                "the freeWrite loss was booked to the closed observe phase")
    }
}
