// VoicePinTests.swift
// R-021 (audit 2026-10-13, B1-04 / A2-11 / H1-08): the German TTS voice was
// the first enhanced German voice in whatever order the system listed them,
// re-chosen at every launch, never recorded, and "no German voice" was not
// a refusal. D6 default: PIN the voice the device resolves today, stamp it
// on every row and every enrolment, and refuse — never silently switch —
// when the pinned voice is gone.
//
// The first pin reproduces today's rule deliberately (first enhanced, else
// first German): choosing Premium or re-ordering would CHANGE the voice of
// a pilot already running. That choice is D6's, not this batch's.

import Testing
import Foundation
import AVFoundation
@testable import PrimaeNative

/// A synthesiser that resolved a voice, or reports a fault.
@MainActor
final class VoiceDouble: SpeechSynthesizing {
    let resolvedVoice: SpeechVoiceInfo?
    let voiceFault: String?
    init(voice: SpeechVoiceInfo?, fault: String? = nil) { resolvedVoice = voice; voiceFault = fault }
    func speak(_ text: String) {}
    func stop() {}
    func setUtteranceEndHandler(_ handler: (@MainActor (String, Bool) -> Void)?) {}
}

@Suite @MainActor struct VoicePinTests {

    private let candidates = [
        VoiceCandidate(identifier: "en.premium", name: "Ava", language: "en-US", quality: 3),
        VoiceCandidate(identifier: "de.default.b", name: "Helena", language: "de-DE", quality: 1),
        VoiceCandidate(identifier: "de.enhanced.z", name: "Petra", language: "de-AT", quality: 2),
        VoiceCandidate(identifier: "de.enhanced.a", name: "Anna", language: "de-DE", quality: 2),
        VoiceCandidate(identifier: "de.premium.p", name: "Martin", language: "de-DE", quality: 3),
    ]

    @Test("R-021: with no pin, the voice today's rule picks is chosen AND pinned")
    func firstResolutionPins() {
        #expect(GermanVoiceChooser.resolve(candidates, pinned: nil)
                == .voice(candidates[2], newlyPinned: true),
                "the first pin must be the voice the device speaks with today (first enhanced German)")
    }

    @Test("R-021: a pinned voice wins over any order and any quality")
    func pinWins() {
        #expect(GermanVoiceChooser.resolve(candidates, pinned: "de.default.b")
                == .voice(candidates[1], newlyPinned: false))
        #expect(GermanVoiceChooser.resolve(candidates.reversed(), pinned: "de.default.b")
                == .voice(candidates[1], newlyPinned: false))
    }

    @Test("R-021: a pinned voice that is gone is a fault, never a silent switch")
    func missingPinIsAFault() {
        let r = GermanVoiceChooser.resolve(candidates, pinned: "de.uninstalled")
        #expect(r == .pinnedVoiceMissing("de.uninstalled"))
        #expect(GermanVoiceChooser.faultText(r)?.contains("de.uninstalled") == true)
        #expect(GermanVoiceChooser.resolve([candidates[0]], pinned: nil) == .noGermanVoice)
    }

    @Test("R-021: the synthesiser stores the pin, and refuses a missing pinned voice")
    func synthesiserPinsThroughTheSeam() {
        let installed = AVSpeechSynthesisVoice.speechVoices()
        let pin = InMemorySpeechVoicePin()
        let synth = AVSpeechSpeechSynthesizer(voices: { installed }, voicePin: pin)
        if installed.contains(where: { $0.language.hasPrefix("de") }) {
            #expect(synth.voiceFault == nil)
            #expect(pin.pinnedIdentifier != nil, "the resolved voice was not pinned")
            #expect(pin.pinnedIdentifier == synth.resolvedVoice?.identifier)
        }
        let gone = AVSpeechSpeechSynthesizer(voices: { installed }, voicePin: InMemorySpeechVoicePin("de.uninstalled"))
        #expect(gone.voiceFault != nil)
        #expect(gone.resolvedVoice == nil, "a missing pinned voice was replaced by another")
        #expect(AVSpeechSpeechSynthesizer(voices: { [] }, voicePin: InMemorySpeechVoicePin()).voiceFault != nil)
    }

    private func studyVM(speech: SpeechSynthesizing, spoken: Bool = true) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = .silent
        deps.spokenFeedbackInStudy = spoken
        deps.speech = speech
        return TracingViewModel(deps)
    }

    @Test("R-021: a study session that speaks refuses to start without its voice")
    func faultRefusesTheSession() {
        let vm = studyVM(speech: VoiceDouble(voice: nil, fault: "Stimme fehlt"))
        #expect(vm.studyPreconditionFailure == "Stimme fehlt")
        let silent = studyVM(speech: VoiceDouble(voice: nil, fault: "Stimme fehlt"), spoken: false)
        #expect(silent.studyPreconditionFailure == nil, "a session that never speaks needs no voice")
    }

    @Test("R-021: every row names the voice the child heard")
    func rowCarriesTheVoice() {
        let voice = SpeechVoiceInfo(identifier: "com.apple.voice.enhanced.de-DE.Anna", name: "Anna", quality: "Erweitert")
        let vm = studyVM(speech: VoiceDouble(voice: voice))
        #expect(vm.sessionVoiceId == voice.identifier)
        #expect(vm.phaseRowContext(for: .observe, finalizedBy: .child).delivery?.voiceId == voice.identifier)
        let mute = studyVM(speech: VoiceDouble(voice: voice), spoken: false)
        #expect(mute.sessionVoiceId == nil, "a session that never speaks heard no voice")
    }
}
