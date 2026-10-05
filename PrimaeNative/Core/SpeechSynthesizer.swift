// SpeechSynthesizer.swift
// PrimaeNative
//
// German voice playback for child-facing verbal feedback. Built on
// AVSpeechSynthesizer for on-device German voices (Anna/Petra/Markus
// when installed) — no network calls, no API keys.
//
// PromptPlayer is the canonical path for the static recorded phrases;
// this synthesizer owns the dynamic templated phrases (recognition
// outcomes, retrieval correction) and acts as the fallback for
// PromptPlayer when an MP3 is missing.

import AVFoundation
import Foundation

// MARK: - Protocol seam

/// Async-free TTS API for child-facing verbal feedback. Tests use
/// `NullSpeechSynthesizer` which records spoken lines.
@MainActor
protocol SpeechSynthesizing {
    /// Speak `text` in German. Utterances queue natively — call
    /// `stop()` first to interrupt.
    func speak(_ text: String)
    /// Halt any in-flight or queued utterance.
    func stop()
    /// Parent-tunable rate; `nil` restores the default.
    func setRate(_ rate: Float?)
    /// The voice this synthesiser speaks with, resolved once at init;
    /// `nil` when it speaks with none (null/spy implementations, or a
    /// device with no German voice). Read-only, for the research
    /// dashboard — see `SpeechVoiceInfo`.
    var resolvedVoice: SpeechVoiceInfo? { get }
    /// Called (main actor) when an utterance ENDS — finished, or cancelled
    /// by `stop()` — with the utterance's text. One handler at a time;
    /// `nil` removes it. Used by the study observe phase to start its
    /// presentation after the spoken cue has actually ended (2026-10-05).
    func setUtteranceEndHandler(_ handler: (@MainActor (_ text: String, _ cancelled: Bool) -> Void)?)
}

extension SpeechSynthesizing {
    func setRate(_ rate: Float?) {}
    var resolvedVoice: SpeechVoiceInfo? { nil }
    /// Null default: stubs and spies never report an end, so a caller
    /// waiting for one must have a fallback.
    func setUtteranceEndHandler(_ handler: (@MainActor (_ text: String, _ cancelled: Bool) -> Void)?) {}
}

// MARK: - Rate

/// The TTS rate a session speaks at, and the one place that decides it.
///
/// STUDY BUILD: always `standard` (0.42). The rate is part of every
/// spoken prompt the child hears, identical in all three arms (P3), so it
/// is a property of the instrument, not a parent preference — and a value
/// left stored on the device from earlier testing (the old "Langsam"
/// 0.36) must not reach a study session. The "Sprache" picker that wrote
/// it is compiled out of `SettingsView` in study builds; this ignores
/// whatever it stored before. Ruled by the supervisor 2026-10-05.
///
/// Casual build: the stored picker value, or `standard` when none.
enum SpeechRate {
    static let standard: Float = 0.42
    static let defaultsKey = "de.flamingistan.primae.speechRate"

    /// `defaults` is a seam so a test can store a value without touching
    /// `UserDefaults.standard` (suites run in parallel).
    static func effective(storedIn defaults: UserDefaults = .standard) -> Float {
        #if STUDY_BUILD
        return standard
        #else
        let stored = defaults.float(forKey: defaultsKey)
        return stored > 0 ? stored : standard
        #endif
    }
}

// MARK: - Resolved voice

/// The German voice a synthesiser resolved, as the proctor reads it off
/// the research dashboard and records it at session start. Which voice
/// `AVSpeechSpeechSynthesizer.init` picks depends on what is installed on
/// the device, so it is a property of the one study iPad: displayed, not
/// pinned (a hard identifier pin fails or falls back on a device without
/// that voice) and not exported.
struct SpeechVoiceInfo: Equatable {
    let identifier: String
    let name: String
    let quality: String

    init(identifier: String, name: String, quality: String) {
        self.identifier = identifier
        self.name = name
        self.quality = quality
    }

    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(identifier: voice.identifier,
                  name: voice.name,
                  quality: Self.qualityName(voice.quality))
    }

    static func qualityName(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default:  return "Standard"
        case .enhanced: return "Erweitert"
        case .premium:  return "Premium"
        @unknown default: return "unbekannt (\(quality.rawValue))"
        }
    }

    /// The exact text the research dashboard shows for `voice`.
    static func dashboardText(_ voice: SpeechVoiceInfo?) -> String {
        guard let voice else { return "Keine deutsche Stimme aufgelöst" }
        return "\(voice.name) · \(voice.quality) · \(voice.identifier)"
    }
}

// MARK: - Production implementation

/// AVSpeechSynthesizer-backed TTS. Picks the best installed German
/// voice at instantiation. If no German voice is present the
/// synthesizer silently no-ops.
@MainActor
final class AVSpeechSpeechSynthesizer: SpeechSynthesizing {

    private let synthesizer = AVSpeechSynthesizer()
    private let germanVoice: AVSpeechSynthesisVoice?
    /// Relays `AVSpeechSynthesizerDelegate`'s finish/cancel to the handler.
    private let endRelay = UtteranceEndRelay()

    func setUtteranceEndHandler(_ handler: (@MainActor (_ text: String, _ cancelled: Bool) -> Void)?) {
        endRelay.handler = handler
        synthesizer.delegate = handler == nil ? nil : endRelay
    }

    /// Default 0.5 reads too fast for a 5-year-old; 0.42 is comfortably
    /// slow without sounding artificially dragged.
    var rate: Float = SpeechRate.standard

    func setRate(_ rate: Float?) {
        self.rate = rate ?? SpeechRate.standard
    }

    var resolvedVoice: SpeechVoiceInfo? { germanVoice.map(SpeechVoiceInfo.init) }
    /// Slight upward shift to match the warm child-friendly tone the
    /// recorded letter audio uses.
    var pitchMultiplier: Float = 1.05

    init() {
        let germanVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de") }
        let enhanced = germanVoices.first(where: { $0.quality == .enhanced })
        self.germanVoice = enhanced
            ?? germanVoices.first
            ?? AVSpeechSynthesisVoice(language: "de-DE")
        // Default `usesApplicationAudioSession = true` shares the
        // AudioEngine's `.playback` session. Disabling it would put
        // the synth on a private session incompatible with the letter-
        // sound pipeline.
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.speak(makeUtterance(text))
    }

    /// Internal so a test can read the voice and rate an utterance
    /// actually carries, rather than the properties that feed it.
    func makeUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = germanVoice
        utterance.rate = rate
        utterance.pitchMultiplier = pitchMultiplier
        // 0.9 keeps the spoken feedback slightly under the AudioEngine's
        // letter sound so the child hears both layered.
        utterance.volume = 0.9
        return utterance
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}

/// The synthesiser's delegate. AVFoundation calls it off the main actor's
/// static knowledge, so the methods are nonisolated, copy the text out of the
/// non-Sendable utterance, and hop to the main actor for the handler.
final class UtteranceEndRelay: NSObject, AVSpeechSynthesizerDelegate {
    var handler: (@MainActor (_ text: String, _ cancelled: Bool) -> Void)?

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor [weak self] in self?.handler?(text, false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        Task { @MainActor [weak self] in self?.handler?(text, true) }
    }
}

// MARK: - Null implementation (tests, previews)

/// Records every spoken line for test assertions; drives no audio.
@MainActor
final class NullSpeechSynthesizer: SpeechSynthesizing {
    private(set) var spokenLines: [String] = []
    private(set) var stopCount: Int = 0

    func speak(_ text: String) { spokenLines.append(text) }
    func stop() { stopCount += 1 }
    func clear() { spokenLines.removeAll(); stopCount = 0 }
}

// MARK: - Phrase library

/// Centralised German feedback phrases — co-locating every phrase the
/// child hears keeps view layout free of hardcoded strings.
enum ChildSpeechLibrary {

    /// Phase entry prompts. Imperative + short so the utterance
    /// finishes before the child plausibly touches the canvas
    /// (AudioEngine's per-touch session reconfiguration cuts TTS short).
    ///
    /// REWORDED 2026-10-02 at the proctor's direction, from a device run
    /// through the three-letter sequence: "Pass jetzt gut auf!" -> "Schau
    /// genau hin.", "Fahr die Linie nach." -> "Jetzt du.", "Und jetzt ohne
    /// Hilfe." -> "Und jetzt ganz allein." The old guided line described
    /// the ACTION ("trace the line") where the new one hands the TURN to
    /// the child, which is what the phase is for; the freeWrite line now
    /// says the same thing in the words the child has heard all session.
    ///
    /// `.direct` is unreachable in a study build (the phase is cut, D5)
    /// but is retained for the casual path. Note these are SILENT under
    /// the `.silent` audio arm — `applyArmAuthority` swaps in
    /// `NullSpeechSynthesizer`, which is the arm's whole condition.
    static func phaseEntry(_ phase: LearningPhase) -> String {
        switch phase {
        case .observe:    return "Schau genau hin."
        case .direct:     return "Tipp die Punkte der Reihe nach an."
        case .guided:     return "Jetzt du."
        case .freeWrite:  return "Und jetzt ganz allein."
        }
    }

    /// Praise spoken on guided / freeWrite stroke completion. 0-star
    /// stays warm — "probier nochmal" without judgement.
    static func praise(starsEarned: Int) -> String {
        switch starsEarned {
        case 4: return "Wow, das war perfekt! Super gemacht."
        case 3: return "Toll gemacht!"
        case 2: return "Gut gemacht!"
        case 1: return "Schon gut! Probier's nochmal."
        default: return "Probier's gleich nochmal."
        }
    }

    /// Recognition badge announcement. Corrections use imperative
    /// phrasing ("schreib nochmal ein A") — a 5-year-old needs a
    /// concrete next action.
    static func recognition(_ result: RecognitionResult, expected: String) -> String {
        if result.isCorrect {
            if result.confidence > 0.7 {
                return "Du hast ein \(expected) geschrieben! Super!"
            } else {
                return "Das sieht aus wie ein \(expected). Gut gemacht!"
            }
        }
        if result.confidence > 0.7 {
            return "Das sieht eher nach \(result.predictedLetter) aus. Schreib nochmal ein \(expected)."
        }
        // Low-confidence misses stay silent at the badge level. Caller
        // is expected to gate on confidence before speaking.
        return ""
    }

    /// Paper-transfer prompts spoken alongside the matching screen.
    static let paperTransferShow = "Schau dir den Buchstaben gut an."
    static let paperTransferWrite = "Jetzt schreibst du den Buchstaben auf Papier."
    static let paperTransferAssess = "Wie ist dein Buchstabe geworden?"

    /// Spaced-retrieval modal headline — spoken on appear.
    static let retrievalQuestion = "Welchen Buchstaben hörst du?"

    /// Spoken after every letter completes. The on-screen star row
    /// carries the gradation; audio is always a warm "Super gemacht!".
    static let celebration = "Super gemacht!"

    // MARK: - PromptPlayer mapping

    /// Map a learning phase to the PromptKey for its bundled MP3.
    static func phaseEntryPromptKey(_ phase: LearningPhase) -> PromptPlayer.PromptKey {
        switch phase {
        case .observe:   return .phaseObserve
        case .direct:    return .phaseDirect
        case .guided:    return .phaseGuided
        case .freeWrite: return .phaseFreeWrite
        }
    }

}
