// ObserveInterruptionRestartTests.swift
// R-006 (audit 2026-10-13, H1-02 / B2-07 / C2-03): an interruption during
// observe cut the cue, stopped the arm's sound (the engine drops its file
// on stop) and nothing ever restarted it, while the animation ran on and
// the row said `completed: true`. The sound arms silently lost the rest of
// their exposure; the silent arm lost only the cue — an arm-asymmetric
// loss, invisible in the data.
//
// D9 default (David has not ruled; register §3): an interrupted observe
// RESTARTS FROM THE CUE in every arm — cue, then animation and the arm's
// sound together — and is counted (`observeRestarts`).

import Testing
import SwiftUI
@testable import PrimaeNative

@Suite @MainActor struct ObserveInterruptionRestartTests {

    private var cue: String { ChildSpeechLibrary.phaseEntry(.observe) }

    /// Load A in observe and let the presentation start (cue ended).
    private func observing(_ arm: PilotAudioCondition) async -> LifecycleRig {
        let rig = LifecycleRig(arm: arm)
        rig.vm.loadLetter(name: "A")
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil }
        return rig
    }

    @Test("sound arms: after an interruption in observe the cue is spoken again, then animation AND sound restart together",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func soundArmRestartsFromTheCue(arm: PilotAudioCondition) async {
        let rig = await observing(arm)
        #expect(rig.vm.learningPhase == .observe)
        #expect(rig.audio.isPlaying && rig.audio.loadedFile != nil, "precondition: the observe sound is playing")
        let cuesBefore = rig.prompts.count(.phaseObserve)
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        #expect(rig.vm.animation.armedStrokes == nil, "the animation ran on, silently, behind the interruption")
        #expect(!rig.audio.isPlaying, "precondition: the interruption stopped the sound")
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.prompts.count(.phaseObserve) == cuesBefore + 1,
                "\(arm): the observe instruction was not spoken again after the interruption")
        #expect(rig.vm.animation.armedStrokes == nil, "\(arm): the animation restarted before the cue")
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil && rig.audio.isPlaying }
        #expect(rig.vm.animation.armedStrokes != nil, "\(arm): the animation never restarted")
        #expect(rig.audio.isPlaying && rig.audio.loadedFile != nil,
                "\(arm): the arm's sound never came back after the interruption — events \(rig.audio.events.suffix(6))")
        #expect(rig.vm.lifecycleCounters.observeRestarts == 1)
        #expect(rig.vm.learningPhase == .observe)
    }

    @Test("silent arm: the same restart — cue, then animation — and still no sound")
    func silentArmRestartsWithoutSound() async {
        let rig = await observing(.silent)
        let cuesBefore = rig.prompts.count(.phaseObserve)
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.prompts.count(.phaseObserve) == cuesBefore + 1, "the silent arm must get the same restart")
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil)
        #expect(rig.audio.playCount == 0, "the silent arm sounded: \(rig.audio.events)")
        #expect(rig.vm.lifecycleCounters.observeRestarts == 1)
    }

    @Test("an interruption while the cue is still being spoken restarts the cue too",
          arguments: [PilotAudioCondition.phoneme, .silent])
    func interruptionDuringTheCueRestartsIt(arm: PilotAudioCondition) async {
        let rig = LifecycleRig(arm: arm)
        rig.vm.loadLetter(name: "A")
        let cuesBefore = rig.prompts.count(.phaseObserve)
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        rig.speech.end(cue, cancelled: true)    // the cut cue reports its cancel
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.prompts.count(.phaseObserve) == cuesBefore + 1)
        rig.speech.end(cue)
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil, "\(arm): the restarted cue's end did not start the presentation")
        #expect(rig.vm.lifecycleCounters.observeRestarts == 1)
    }

    @Test("an interruption outside observe restarts nothing")
    func noRestartOutsideObserve() async {
        let rig = LifecycleRig()
        rig.vm.loadLetter(name: "A")
        rig.vm.phaseController.resume(at: .guided)
        let cuesBefore = rig.prompts.count(.phaseObserve)
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.prompts.count(.phaseObserve) == cuesBefore)
        #expect(rig.vm.lifecycleCounters.observeRestarts == 0)
    }

    // Phase rows are written together when the LETTER completes, so
    // "once" is read off the phase controller: observe scored once, and
    // the session moved on to guided and no further.
    @Test("observe ends once: the restarted pass completes observe, scored once")
    func restartedObserveCompletesOnce() async {
        let rig = await observing(.phoneme)
        rig.vm.animation.unitsPerSecond = 50    // a fast pass for the test
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        rig.speech.end(cue)
        await rig.waitUntil(120) { rig.vm.learningPhase != .observe }
        #expect(rig.vm.learningPhase == .guided, "observe never completed after the restart")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.vm.learningPhase == .guided, "a second observe completion advanced past guided")
        #expect(rig.vm.phaseController.phaseScores.count == 1
                && rig.vm.phaseController.phaseScores[.observe] != nil,
                "phase scores: \(rig.vm.phaseController.phaseScores)")
    }
}
