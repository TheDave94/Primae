// StudySpeechPinTests.swift
// PrimaeNativeTests
//
// Pins the speech ruling of 2026-10-05: in a study build the TTS rate is
// always `SpeechRate.standard` (0.42), whatever the old "Sprache" picker
// left stored on the device; and the research dashboard's voice readout
// is the voice the synthesiser actually speaks with.
//
// MUTATION CHECKS (run each, confirm RED, read "N tests" in the log, restore):
//   R — in `SpeechSynthesizer.swift`, `SpeechRate.effective`, replace the
//       study branch's `return standard` with
//       `let stored = defaults.float(forKey: defaultsKey); return stored > 0 ? stored : standard`
//       → `storedSlowRateDoesNotReachAStudySession` goes red (0.36).
//   V — in `AVSpeechSpeechSynthesizer.makeUtterance`, set
//       `utterance.voice = AVSpeechSynthesisVoice.speechVoices().last`
//       → `dashboardVoiceIsTheVoiceTheUtteranceCarries` goes red on any
//       device or simulator with more than one installed voice.
//   D — in `TracingViewModel.init`, assign `self.speechVoice = nil`
//       → `viewModelCapturesTheInjectedSynthesisersVoice` goes red.
//
// Uses a private `UserDefaults` suite, never `.standard`: suites run in
// parallel, and a stored rate there would leak into other tests.

import Testing
import Foundation
import AVFoundation
@testable import PrimaeNative

@MainActor
fileprivate final class FixedVoiceSpeech: SpeechSynthesizing {
    let resolvedVoice: SpeechVoiceInfo?
    init(_ voice: SpeechVoiceInfo?) { resolvedVoice = voice }
    func speak(_ text: String) {}
    func stop() {}
}

@Suite @MainActor struct StudySpeechPinTests {

    private func isolatedDefaults() -> (UserDefaults, String) {
        let name = "StudySpeechPinTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    #if STUDY_BUILD
    @Test("a stored 0.36 does not reach a study session: the effective rate is 0.42")
    func storedSlowRateDoesNotReachAStudySession() {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Float(0.36), forKey: SpeechRate.defaultsKey)
        #expect(defaults.float(forKey: SpeechRate.defaultsKey) == 0.36,
                "precondition: the stored value is really there")

        // The same two steps SettingsView's on-appear performs.
        let synth = AVSpeechSpeechSynthesizer()
        synth.setRate(SpeechRate.effective(storedIn: defaults))

        #expect(SpeechRate.effective(storedIn: defaults) == 0.42)
        #expect(synth.rate == 0.42)
        #expect(synth.makeUtterance("Jetzt du.").rate == 0.42)
    }
    #endif

    @Test("the dashboard's voice is the voice the synthesiser's utterances carry")
    func dashboardVoiceIsTheVoiceTheUtteranceCarries() {
        let synth = AVSpeechSpeechSynthesizer()
        let carried = synth.makeUtterance("Schau genau hin.").voice.map(SpeechVoiceInfo.init)
        #expect(synth.resolvedVoice == carried)
        #expect(SpeechVoiceInfo.dashboardText(synth.resolvedVoice)
                == SpeechVoiceInfo.dashboardText(carried))
        if let carried {
            #expect(SpeechVoiceInfo.dashboardText(synth.resolvedVoice).contains(carried.identifier))
        }
    }

    @Test("the view model shows the INJECTED synthesiser's voice, also when study mode nulls speech")
    func viewModelCapturesTheInjectedSynthesisersVoice() {
        let voice = SpeechVoiceInfo(identifier: "com.apple.voice.enhanced.de-DE.Anna",
                                    name: "Anna", quality: "Erweitert")
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.spokenFeedbackInStudy = false   // the null speech pair
        deps.speech = FixedVoiceSpeech(voice)
        let vm = TracingViewModel(deps)
        #expect(vm.speech is NullSpeechSynthesizer,
                "precondition: the live speech is the null one, so the readout cannot come from it")
        #expect(vm.speechVoice == voice)
        #expect(SpeechVoiceInfo.dashboardText(vm.speechVoice)
                == "Anna · Erweitert · com.apple.voice.enhanced.de-DE.Anna")
    }

    @Test("no resolved voice reads as such, not as an empty line")
    func missingVoiceIsNamed() {
        #expect(SpeechVoiceInfo.dashboardText(nil) == "Keine deutsche Stimme aufgelöst")
    }
}
