// ObserveCueCounterTests.swift
// R-022 (audit 2026-10-13, H1-07 / B2-06 / C2-11): the observe start waits
// for the cue's end report, counted in `pendingObserveCues`, which was
// never reset. ONE lost end report (an utterance dropped by the system, a
// cut cue whose cancel never arrives) left the count above zero for the
// rest of the session — every later observe, for every later child, then
// started on the 3.0 s fallback instead of 1.0 s after its cue ended.
//
// Fix: the count belongs to the presentation it gates. When a
// presentation STARTS (by the cue's end or by the fallback), or is
// cancelled by an interruption that will restart it, no earlier cue can
// matter any more and the count is cleared. A stale report can then cost
// at most the one observe it arrives in, never the session.

import Testing
import SwiftUI
import AVFoundation
@testable import PrimaeNative

/// The production prompt path for a missing recording: stop, then speak
/// the fallback text through the session's synthesiser.
@MainActor
final class SpeakingPrompts: PromptPlaying {
    let speech: SpeechSynthesizing
    init(_ speech: SpeechSynthesizing) { self.speech = speech }
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) { speech.stop(); speech.speak(fallbackText) }
    func stop() { speech.stop() }
    func playSuccessChime() {}
    func playTapChime() {}
    func playWrongTapChime() {}
    func playStrokeTick() {}
}

@Suite @MainActor struct ObserveCueCounterTests {

    private var cue: String { ChildSpeechLibrary.phaseEntry(.observe) }

    @Test("a lost end report is forgotten once the fallback has started the presentation")
    func fallbackClearsALostReport() async {
        let rig = LifecycleRig(fallback: 0.2)
        rig.vm.loadLetter(name: "A")             // its cue's end report never arrives
        await rig.waitUntil { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil, "precondition: the fallback started it")
        #expect(rig.vm.debugPendingObserveCues == 0,
                "the lost report is still counted — every later observe would wait for the fallback")
        rig.vm.loadLetter(name: "A")             // the next observe
        #expect(rig.vm.debugPendingObserveCues == 1)
        rig.speech.end(cue)                      // its own cue ends
        #expect(rig.vm.debugPendingObserveCues == 0,
                "the next observe's own cue end no longer opens its presentation")
    }

    @Test("a cut cue whose cancel never arrives does not hold the restarted observe (fallback never fires here)")
    func lostCancelDoesNotHoldTheRestart() async {
        let rig = LifecycleRig(fallback: 3600)
        rig.vm.loadLetter(name: "A")
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        // No cancel report for the cut cue.
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.prompts.count(.phaseObserve) == 2, "precondition: the observe restarted from its cue")
        rig.speech.end(cue)                      // the restarted cue ends
        await rig.waitUntil(10) { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil,
                "the restarted observe waits for a report that will never come")
    }

    @Test("still true: an OLDER load's cue ending does not start the newer load's presentation")
    func olderCueStillIgnored() async {
        let rig = LifecycleRig(fallback: 3600)
        rig.vm.loadLetter(name: "A")
        rig.vm.loadLetter(name: "A")             // newer load; the first cue is stale
        rig.speech.end(cue)                      // the stale one
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.vm.animation.armedStrokes == nil, "a stale cue end started the presentation")
        rig.speech.end(cue)                      // this load's
        await rig.waitUntil(10) { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil)
    }

    // Review of batch C, item 3 (device probe P6b): a cut cue reports BOTH
    // cancelled and finished. Arriving after the restart's own cue was
    // queued, the extra "finished" counted down the restarted cue and
    // started the presentation while that cue was still being spoken.
    @Test("a cut cue's extra 'finished' report does not start the restarted observe before its own cue ends")
    func cutCueDoubleReportDoesNotStartEarly() async {
        let system = DeviceLikeSynthesizer()
        system.doubleReportOnCancel = true
        let synth = AVSpeechSpeechSynthesizer(synthesizer: system)
        let rig = LifecycleRig(fallback: 3600) { deps in
            deps.speech = synth
            deps.makePromptPlayer = { _ in SpeakingPrompts(synth) }
        }
        rig.vm.loadLetter(name: "A")
        await rig.waitUntil { system.handedOver >= 1 }      // the hand-over is one turn later
        system.startNext()                                   // the cue is being spoken
        await rig.waitUntil(1) { false }
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value   // cut: cancelled + finished
        await rig.vm.scenePhaseDidChange(to: .active)?.value     // restart: cue again
        await rig.waitUntil { system.handedOver >= 2 }
        #expect(system.handedOver >= 2, "precondition: the restarted cue reached the system")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(rig.vm.animation.armedStrokes == nil,
                "the observe started while its restarted cue had not even begun")
        system.startNext()
        system.finishCurrent()                               // the restarted cue ends
        await rig.waitUntil(10) { rig.vm.animation.armedStrokes != nil }
        #expect(rig.vm.animation.armedStrokes != nil, "the restarted cue's own end did not start the observe")
    }
}
