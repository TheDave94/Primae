// PhasePromptDelayTests.swift
// R-029 (audit 2026-10-13, H2-18): at a phase transition the arm's sound
// is stopped with a 0.4 s fade (`SoundEnvelope.fadeOutSeconds`) and the
// next phase's instruction ("Jetzt du.", "Und jetzt ganz allein.") was
// spoken in the same turn — so in the two sound arms the fade tail ran
// under the instruction, and in the silent arm it did not. The instruction
// now waits out the fade length in EVERY arm of a study session, so the
// timing stays identical across arms.

import Testing
import SwiftUI
@testable import PrimaeNative

@Suite @MainActor struct PhasePromptDelayTests {

    private var cue: String { ChildSpeechLibrary.phaseEntry(.observe) }

    @Test("the guided instruction waits out the fade, in every arm",
          arguments: [PilotAudioCondition.phoneme, .spatial, .silent])
    func guidedPromptWaitsForTheFade(arm: PilotAudioCondition) async {
        let rig = LifecycleRig(arm: arm)
        rig.vm.loadLetter(name: "A")
        let clock = ContinuousClock()
        let advanced = clock.now
        rig.vm.completeObservePhase()
        #expect(rig.vm.learningPhase == .guided, "precondition")
        #expect(rig.prompts.count(.phaseGuided) == 0,
                "\(arm): \"Jetzt du.\" started under the fading arm sound")
        await rig.vm.awaitPendingPhasePrompt()
        #expect(rig.prompts.count(.phaseGuided) == 1, "\(arm): the instruction was never spoken")
        #expect(clock.now - advanced >= .milliseconds(Int(SoundEnvelope.fadeOutSeconds * 1000) - 20),
                "\(arm): spoken before the fade could end")
    }

    @Test("a letter change inside the wait drops the outgoing phase's instruction")
    func loadDropsThePendingInstruction() async {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.completeObservePhase()
        rig.vm.loadLetter(name: "A")
        await rig.vm.awaitPendingPhasePrompt()
        try? await Task.sleep(for: .milliseconds(Int(SoundEnvelope.fadeOutSeconds * 1000) + 100))
        #expect(rig.prompts.count(.phaseGuided) == 0, "the previous letter's instruction was spoken over the new one")
    }

    @Test("an interruption inside the wait holds the instruction; it is spoken once after the return")
    func interruptionHoldsTheInstruction() async {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.completeObservePhase()
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        try? await Task.sleep(for: .milliseconds(Int(SoundEnvelope.fadeOutSeconds * 1000) + 100))
        #expect(rig.prompts.count(.phaseGuided) == 0, "spoken behind Control Center")
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        await rig.vm.awaitPendingPhasePrompt()
        #expect(rig.prompts.count(.phaseGuided) == 1)
    }

    @Test("outside a study session the instruction is spoken at once, as before")
    func casualUnchanged() {
        let rig = LifecycleRig { $0.studyMode = false }
        rig.vm.loadLetter(name: "A")
        let keysBefore = rig.prompts.keys.count
        rig.vm.completeObservePhase()
        #expect(rig.vm.learningPhase != .observe, "precondition: observe ended")
        #expect(rig.prompts.keys.count == keysBefore + 1
                && rig.prompts.keys.last == ChildSpeechLibrary.phaseEntryPromptKey(rig.vm.learningPhase),
                "casual: the phase instruction must still be played in the same turn: \(rig.prompts.keys)")
    }
}
