// RouteRecoveryTests.swift
//
// A LOST OUTPUT THAT COMES BACK PLAYS NOTHING — and only a genuine re-plug
// counts as it coming back (audit 2026-10-18, L-B).
//
// #62 recovered a lost route with `playback.request(.active, immediate:
// true)`. The stall timer stopped that 0.3 s later, so every recovery was a
// blip of the arm's file — in any phase, with no pen down, recorded nowhere
// (for the phoneme arm, an unrecorded exposure) — while the observe sound,
// which observe plays straight through the engine, was not restored at all.
// The gate opened on ANY later valid notification (a wake, a configuration
// change), never checked which output came back, and outlived the arm and
// the child it happened to.
//
// Now: the pen-coupled phases need no recovery (R-019's idle machine lets
// the next moving sample play); observe is not replayed mid-pass (D9: never
// heard from the middle); a re-plug of the lost port type ends the loss and
// is logged and counted (`routeRecoveries`), once; an arm change or a new
// child forgets the loss (`settleEngineForArm`).
//
// The new-child half of that last rule is not driven here:
// `resetForNewParticipant` writes the global `ParticipantStore`, which this
// suite must not touch. It reaches the same `settleEngineForArm` as an arm
// change does (`reapplyParticipantIdentity` → `applyArmAuthority`, the same
// arm included) — the link `ArmEngineCarryOverTests.sameArmEnrolmentNeutralises`
// already pins — so the arm-change tests below pin the resets themselves
// (the loss, and since 2026-10-21 `routeRecoveries`).
//
// Mutation check (lane E, 2026-10-21): delete `routeRecoveries = 0` in
// `settleEngineForArm`; `recoveriesResetAtTheHandOver` goes RED.

import Testing
import Foundation
import AVFoundation
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct RouteRecoveryTests {

    private typealias Reason = AVAudioSession.RouteChangeReason
    private var cue: String { ChildSpeechLibrary.phaseEntry(.observe) }

    /// The output `port` goes (the route falls back to the speaker). The
    /// engine's own reaction (`AudioEngine.handleRouteChangeValue` →
    /// `stop()`) is modelled by the double, as in `AudioRouteChangeTests`.
    private func lose(_ rig: LifecycleRig, _ port: String? = "Headphones") {
        rig.audio.stop()
        rig.vm.handleAudioRouteChange(reasonRawValue: Reason.oldDeviceUnavailable.rawValue,
                                      outputLost: true, outputPortType: "Speaker",
                                      previousOutputPortType: port)
    }

    /// A valid route notification, `port` now the first output.
    private func arrive(_ rig: LifecycleRig, _ port: String = "Headphones",
                        reason: Reason = .newDeviceAvailable) {
        rig.vm.handleAudioRouteChange(reasonRawValue: reason.rawValue,
                                      outputLost: false, outputPortType: port,
                                      previousOutputPortType: "Speaker")
    }

    /// Load A in observe and let the presentation start (cue ended).
    private func observing(_ arm: PilotAudioCondition) async -> LifecycleRig {
        let rig = LifecycleRig(arm: arm)
        rig.vm.loadLetter(name: "A")
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil }
        return rig
    }

    @Test("a route that was NEVER lost recovers nothing and plays nothing")
    func aValidRouteWithoutAPriorLossDoesNothing() {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        let events = rig.audio.events

        arrive(rig)

        #expect(rig.vm.routeRecoveries == 0)
        #expect(rig.audio.events == events, "a notification with no prior loss reached the engine: \(rig.audio.events.suffix(4))")
    }

    @Test("observe: a re-plug ends the loss and replays nothing — no blip, no mid-pass sound, no restart",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeReplugPlaysNothing(arm: PilotAudioCondition) async {
        let rig = await observing(arm)
        #expect(rig.audio.isPlaying && rig.audio.loadedFile != nil, "precondition: the observe sound is playing")
        lose(rig)
        let events = rig.audio.events

        arrive(rig)

        #expect(rig.vm.routeRecoveries == 1, "\(arm): the genuine re-plug was not recorded")
        #expect(rig.audio.events == events,
                "\(arm): the re-plug reached the engine — an unrecorded sound: \(rig.audio.events.suffix(4))")
        #expect(rig.vm.lifecycleCounters.observeRestarts == 0, "\(arm): a re-plug is not an interruption restart")
        #expect(rig.vm.learningPhase == .observe)
    }

    @Test("pen up outside observe: a re-plug plays nothing, and the pen sounds again on its next movement")
    func penPhaseReplugWaitsForThePen() {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .freeWrite)
        lose(rig)
        let events = rig.audio.events

        arrive(rig)

        #expect(rig.audio.events == events, "a re-plug with no pen down played the arm's file: \(rig.audio.events.suffix(4))")
        rig.strokeDown()
        #expect(rig.audio.isPlaying && rig.audio.loadedFile != nil,
                "the pen stayed silent after the re-plug: \(rig.audio.events.suffix(4))")
    }

    @Test("recovery is one-shot: the same output arriving again is not a second recovery")
    func recoveryHappensOnce() {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        lose(rig)
        arrive(rig)
        #expect(rig.vm.routeRecoveries == 1)

        arrive(rig)
        #expect(rig.vm.routeRecoveries == 1, "a second notification on the returned output counted as a second recovery")

        // …but a NEW loss is recoverable again.
        lose(rig)
        arrive(rig)
        #expect(rig.vm.routeRecoveries == 2)
    }

    @Test("only the lost output class returning, by .newDeviceAvailable, is a recovery")
    func onlyAGenuineReplugRecovers() {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        lose(rig, "Headphones")

        arrive(rig, "Headphones", reason: .wakeFromSleep)
        arrive(rig, "Headphones", reason: .routeConfigurationChange)
        arrive(rig, "Headphones", reason: .categoryChange)
        #expect(rig.vm.routeRecoveries == 0, "a wake / configuration / category change was taken as the output returning")

        arrive(rig, "BluetoothA2DPOutput")
        #expect(rig.vm.routeRecoveries == 0, "a DIFFERENT device arriving was taken as the lost headphones returning")

        arrive(rig, "Headphones")
        #expect(rig.vm.routeRecoveries == 1, "the lost headphones returning was not recognised")
    }

    @Test("a loss whose port was not reported is never matched")
    func anUnreportedLostPortIsNeverMatched() {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        lose(rig, nil)
        arrive(rig, "Headphones")
        #expect(rig.vm.routeRecoveries == 0)
    }

    @Test("an arm change forgets the loss: a re-plug under the next arm is not its recovery")
    func anArmChangeForgetsTheLoss() {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        lose(rig)

        rig.vm.applyArm(.spatial)
        arrive(rig)

        #expect(rig.vm.routeRecoveries == 0,
                "a loss under the outgoing arm was recovered under the incoming one")
    }

    @Test("recoveries are per child: the hand-over to the next arm or child starts the count at 0")
    func recoveriesResetAtTheHandOver() {
        let rig = LifecycleRig(arm: .phoneme)
        rig.vm.loadLetter(name: "A")
        lose(rig)
        arrive(rig)
        #expect(rig.vm.routeRecoveries == 1, "precondition: one genuine re-plug")

        rig.vm.applyArm(.spatial)

        #expect(rig.vm.routeRecoveries == 0,
                "the outgoing arm's (or child's) recoveries were carried into the incoming one")
    }

    @Test("the silent arm: the re-plug is recorded, and nothing sounds")
    func theSilentArmStaysSilent() {
        let rig = LifecycleRig(arm: .silent)
        rig.vm.loadLetter(name: "A")
        lose(rig)
        arrive(rig)
        #expect(rig.vm.routeRecoveries == 1)
        #expect(rig.audio.playCount == 0, "the silent arm sounded: \(rig.audio.events)")
    }
}
