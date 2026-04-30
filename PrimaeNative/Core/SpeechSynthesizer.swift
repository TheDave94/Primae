// SpeechSynthesizer.swift
// PrimaeNative
//
// German voice playback for child-facing verbal feedback. The thesis app
// targets 5-6 year-olds who can't read fluently yet, so every numeric
// score (Klarheit, Form, Tempo, Druck, Rhythmus) stays inside the
// research dashboard while the *child* hears short German encouragement
// spoken by the system TTS instead.
//
// Built on top of `AVSpeechSynthesizer` so we get on-device German
// voices (the iPad ships with multiple "de-DE" voices including
// Anna/Petra/Markus). No network call, no API key, no extra dependency.
//
// IMPORTANT: AudioEngine.swift remains the canonical interactive
// audio path (proximity-triggered letter sounds). This synthesizer
// uses a separate AVSpeechSynthesizer instance so the two pipelines
// can coexist — speech does not flow through the AVAudioEngine graph.

import AVFoundation
import Foundation

// MARK: - Protocol seam

/// Async-free TTS API for child-facing verbal feedback. The protocol
/// lets tests substitute a recording stub while production uses the
/// AVSpeechSynthesizer-backed implementation.
@MainActor
protocol SpeechSynthesizing {
    /// Speak `text` in German. Cancels any ongoing utterance first so
    /// rapid feedback events ("Anschauen" → "Richtung lernen") don't
    /// queue up and overlap the next phase prompt.
    func speak(_ text: String)
    /// Halt any in-flight utterance. Called when the canvas leaves a
    /// world or when an overlay sequence resets so the child doesn't
    /// hear stale feedback after switching context.
    func stop()
    /// True between `speak(_:)` and the moment the synthesizer
    /// actually finishes (or is cancelled). Read by TouchDispatcher
    /// to mute letter-sound playback during a verbal prompt — the
    /// AudioEngine's per-touch AVAudioSession reconfiguration
    /// otherwise clips in-flight TTS short.
    var isSpeaking: Bool { get }
    /// U8 (ROADMAP_V5): parent-tunable rate so a 5-year-old who needs a
    /// slower tempo can be accommodated. Default `nil` means leave the
    /// production rate (0.42) untouched. Bound to a 3-position slider in
    /// SettingsView with values: 0.36 langsam / 0.42 normal / 0.50 schnell.
    func setRate(_ rate: Float?)
}

extension SpeechSynthesizing {
    /// Default no-op so older mocks compile without retrofitting.
    func setRate(_ rate: Float?) {}
}

// MARK: - Production implementation

/// AVSpeechSynthesizer-backed TTS. Picks the best installed German voice
/// at instantiation. If no German voice is present the synthesizer
/// silently no-ops so a missing voice asset never crashes the app.
@MainActor
final class AVSpeechSpeechSynthesizer: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private let germanVoice: AVSpeechSynthesisVoice?
    /// Tracked via the synthesizer delegate. Goes true on
    /// `didStart` and false on `didFinish` / `didCancel`. The
    /// AVSpeechSynthesizer's own `isSpeaking` flag drops a beat too
    /// late on iOS 18+ for the gate's purposes — by the time the
    /// next touch event reads it the utterance has already been
    /// truncated by AudioEngine's session reconfig.
    private(set) var isSpeaking: Bool = false

    /// Tunable speech rate. AVSpeechUtterance defaults to ~0.5 which
    /// reads too quickly for a 5-year-old; 0.42 is comfortably slow
    /// without sounding artificially dragged. Override via
    /// `setRate(_:)` (U8 — Settings slider).
    var rate: Float = 0.42

    func setRate(_ rate: Float?) {
        self.rate = rate ?? 0.42
    }
    /// Tunable pitch. 1.0 is the default; we shift slightly above to
    /// match the warm, child-friendly tone the recorded letter audio
    /// uses.
    var pitchMultiplier: Float = 1.05

    override init() {
        // Prefer an enhanced German voice when one is installed (more
        // natural prosody), then fall back to the default `de-DE`. Some
        // installs only ship the smaller default voice; both work.
        let germanVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("de") }
        let enhanced = germanVoices.first(where: { $0.quality == .enhanced })
        self.germanVoice = enhanced
            ?? germanVoices.first
            ?? AVSpeechSynthesisVoice(language: "de-DE")
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        // Cancel anything still playing so phase transitions feel snappy
        // and a slow recogniser callback can't talk over a fresh utterance.
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = germanVoice
        utterance.rate = rate
        utterance.pitchMultiplier = pitchMultiplier
        // Default volume of 1.0 sits below the AudioEngine's letter
        // sound so the child hears both: ducked verbal feedback layered
        // over the proximity-triggered phoneme.
        utterance.volume = 0.9
        // Optimistically flip the gate true *before* asking the
        // synthesizer to speak so the very next TouchDispatcher tick
        // (which can fire within a millisecond on a held finger)
        // sees the active state and skips letter-audio activation.
        // The delegate callbacks below correct the flag on actual
        // start / finish.
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didStart utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = true }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                        didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.isSpeaking = false }
    }
}

// MARK: - Null implementation (tests, previews)

/// No-op TTS used by tests and SwiftUI previews. Records every spoken
/// phrase so test assertions can verify the right verbal feedback fired
/// without driving the real audio pipeline.
@MainActor
final class NullSpeechSynthesizer: SpeechSynthesizing {
    private(set) var spokenLines: [String] = []
    private(set) var stopCount: Int = 0
    var isSpeaking: Bool { false }

    func speak(_ text: String) { spokenLines.append(text) }
    func stop() { stopCount += 1 }
    func clear() { spokenLines.removeAll(); stopCount = 0 }
}

// MARK: - Phrase library

/// Centralised German feedback phrases. Keeping the strings here (vs.
/// scattered across views) means the research team can review every
/// utterance the child hears in one place, and copywriters can iterate
/// without touching view layout. Each phrase is short and uses
/// kindergarten-level vocabulary.
enum ChildSpeechLibrary {

    /// Phase entry prompts spoken when a learning phase becomes
    /// active. Imperative + short — the child can't read the
    /// on-screen phase pill, so the spoken instruction has to
    /// stand on its own. Action verb first (the German child voice
    /// convention from the design system), no fillers ("mal",
    /// "Jetzt") that don't add meaning, and **kept brief enough
    /// that the AVSpeechSynthesizer utterance finishes before the
    /// child can plausibly touch the canvas** — the AudioEngine
    /// reconfigures AVAudioSession on every touch-driven letter-
    /// sound load, and that reconfiguration cuts in-flight TTS
    /// short (observed: the freeWrite prompt was clipped on every
    /// non-trivial letter — "I" was the only one short enough to
    /// avoid the race).
    static func phaseEntry(_ phase: LearningPhase) -> String {
        switch phase {
        case .observe:    return "Pass jetzt gut auf!"
        case .direct:     return "Tipp die Punkte der Reihe nach an."
        case .guided:     return "Fahr die Linie nach."
        case .freeWrite:  return "Und jetzt du alleine."
        }
    }

    /// Spoken on any guided / freeWrite stroke completion that earned a
    /// star. Praise is intentionally short and never patronising —
    /// children at this age can't read percentages and don't need
    /// long sentences after a successful trace. The 0-star case
    /// stays warm: "probier nochmal" without any judgement.
    static func praise(starsEarned: Int) -> String {
        switch starsEarned {
        case 4: return "Wow, das war perfekt! Super gemacht."
        case 3: return "Toll gemacht!"
        case 2: return "Gut gemacht!"
        case 1: return "Schon gut! Probier's nochmal."
        default: return "Probier's gleich nochmal."
        }
    }

    /// Recognition badge announcement. Mirrors the German strings in
    /// `RecognitionFeedbackView` so what the child sees is identical to
    /// what they hear, without any percentages or technical wording.
    /// Imperative phrasing for corrections ("schreib nochmal ein A")
    /// is more concrete for a 5-year-old than the abstract "versuche
    /// nochmal das A" — the child can act on the verb directly.
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
        // Low confidence + wrong: stay silent at the badge level so the
        // child isn't confused. Caller already gates on confidence.
        return ""
    }

    /// Paper-transfer prompt spoken in two parts so the reference letter
    /// is visible while the child hears the instruction. Matches the
    /// `PaperTransferView` UI text exactly.
    static let paperTransferShow = "Schau dir den Buchstaben gut an."
    static let paperTransferWrite = "Jetzt schreibst du den Buchstaben auf Papier."
    static let paperTransferAssess = "Wie ist dein Buchstabe geworden?"

    /// Headline of the spaced-retrieval modal — spoken on appear so
    /// the child knows the screen is asking them to identify a
    /// letter. Mirrors the on-screen text exactly.
    static let retrievalQuestion = "Welchen Buchstaben hörst du?"

    /// Letter-completion celebration phrase. Spoken after every
    /// letter completes, regardless of how many stars the child
    /// earned — the N-of-4 star row in
    /// `CompletionCelebrationOverlay` is the visual differentiator;
    /// the audio is always the same warm "Super gemacht!".
    static let celebration = "Super gemacht!"

    // MARK: - PromptPlayer mapping

    /// Map a learning phase to its `PromptPlayer.PromptKey` so
    /// `vm.prompts.play(...)` can play the recorded ElevenLabs MP3
    /// (when bundled) instead of the AVSpeechSynthesizer voice.
    static func phaseEntryPromptKey(_ phase: LearningPhase) -> PromptPlayer.PromptKey {
        switch phase {
        case .observe:   return .phaseObserve
        case .direct:    return .phaseDirect
        case .guided:    return .phaseGuided
        case .freeWrite: return .phaseFreeWrite
        }
    }

    /// Map a star count (0–4) to its praise prompt key. Out-of-range
    /// counts collapse to the 0-star "probier's nochmal" tier.
    static func praisePromptKey(starsEarned: Int) -> PromptPlayer.PromptKey {
        switch starsEarned {
        case 4: return .praise4
        case 3: return .praise3
        case 2: return .praise2
        case 1: return .praise1
        default: return .praise0
        }
    }
}
