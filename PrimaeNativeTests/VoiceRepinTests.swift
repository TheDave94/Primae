// VoiceRepinTests.swift
// R-021 follow-up (review of batch D): the voice refusal had no recovery
// short of uninstalling the app — which wipes the participant archive. The
// proctor can now clear the pin and re-pin from the Research Dashboard;
// the fault is re-evaluated WITHOUT a relaunch.

import Testing
import Foundation
import AVFoundation
@testable import PrimaeNative

/// A synthesiser whose voice state a re-pin changes, like the real one's.
@MainActor
final class RepinnableVoiceDouble: SpeechSynthesizing {
    var resolvedVoice: SpeechVoiceInfo?
    var voiceFault: String?
    private let afterRepin: SpeechVoiceInfo
    private(set) var repinCount = 0
    init(faulted: String, afterRepin: SpeechVoiceInfo) {
        voiceFault = faulted; resolvedVoice = nil; self.afterRepin = afterRepin
    }
    func repinVoice() { repinCount += 1; resolvedVoice = afterRepin; voiceFault = nil }
    func speak(_ text: String) {}
    func stop() {}
    func setUtteranceEndHandler(_ handler: (@MainActor (String, Bool) -> Void)?) {}
}

private let installedVoices = AVSpeechSynthesisVoice.speechVoices()
private let hasGermanVoice = installedVoices.contains { $0.language.hasPrefix("de") }

@Suite @MainActor struct VoiceRepinTests {

    private let healed = SpeechVoiceInfo(identifier: "com.apple.voice.enhanced.de-DE.Anna",
                                         name: "Anna", quality: "Erweitert")

    private func studyVM(speech: SpeechSynthesizing, spoken: Bool = true) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = .silent
        deps.spokenFeedbackInStudy = spoken
        deps.speech = speech
        return TracingViewModel(deps)
    }

    @Test("R-021 / r9: the re-pin still works, but the recorded voiceover is never refused for the device voice and its rows keep naming the recorded set")
    func repinDoesNotTouchTheRecordedSet() {
        let synth = RepinnableVoiceDouble(faulted: "Stimme fehlt", afterRepin: healed)
        let vm = studyVM(speech: synth)
        let id = RecordedPromptSet.setId()
        #expect(vm.studyPreconditionFailure == nil, "the recorded voiceover needs no device voice")
        vm.parentAreaDidOpen()
        #expect(vm.repinSpeechVoice() == true)
        #expect(synth.repinCount == 1)
        #expect(vm.studyPreconditionFailure == nil)
        #expect(vm.speechVoice?.identifier == healed.identifier)
        #expect(vm.sessionVoiceId == id, "a re-pin of the TTS voice changed what the rows say the child heard")
    }

    @Test("R-021: a re-pin is refused while a trial is running (parent area closed)")
    func repinRefusedMidTrial() {
        let synth = RepinnableVoiceDouble(faulted: "Stimme fehlt", afterRepin: healed)
        let vm = studyVM(speech: synth)
        #expect(vm.repinSpeechVoice() == false)
        #expect(synth.repinCount == 0, "the voice changed under a running trial")
        #expect(vm.speechVoiceFault == "Stimme fehlt")
    }

    @Test("R-021: the real synthesiser clears a stale pin and re-pins the first-pin rule's voice",
          .enabled(if: hasGermanVoice))
    func realSynthesiserRepins() {
        let pin = InMemorySpeechVoicePin("de.uninstalled")
        let synth = AVSpeechSpeechSynthesizer(voices: { installedVoices }, voicePin: pin)
        #expect(synth.voiceFault != nil)
        synth.repinVoice()
        let expected = GermanVoiceChooser.resolve(installedVoices.map(VoiceCandidate.init), pinned: nil)
        guard case .voice(let voice, _) = expected else { Issue.record("no German voice"); return }
        #expect(synth.voiceFault == nil, "fault survived the re-pin")
        #expect(synth.resolvedVoice?.identifier == voice.identifier)
        #expect(pin.pinnedIdentifier == voice.identifier, "the stale pin was not replaced")
    }

    @Test("R-021: a re-pin with no German voice installed stays a fault and leaves no pin")
    func repinWithoutAnyGermanVoiceStaysFaulted() {
        let pin = InMemorySpeechVoicePin("de.uninstalled")
        let synth = AVSpeechSpeechSynthesizer(voices: { [] }, voicePin: pin)
        synth.repinVoice()
        #expect(synth.voiceFault != nil)
        #expect(synth.resolvedVoice == nil)
        #expect(pin.pinnedIdentifier == nil, "a pin to nothing was left behind")
    }
}
