// PromptPlayer.swift
// PrimaeNative
//
// Plays the bundled MP3 phrases the child hears during practice.
// A study build plays ONLY recorded takes (protocol r9: the five phrases in
// Resources/Prompts, voice Kiki) and never substitutes the system voice for
// a missing one. Dynamic per-letter phrases (recognition feedback) bypass
// this and go through the synthesizer directly; none is reachable in a
// study build.

import AudioToolbox
import AVFoundation
import Foundation
import os.log

/// Public surface of `PromptPlayer`. Tests use `NullPromptPlayer` —
/// real AVAudioPlayer setup costs enough wall-clock time (~10–20 ms
/// on simulator) to push rapid-tap tests past the playback debounce.
@MainActor
protocol PromptPlaying: AnyObject {
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String)
    func stop()
    func playSuccessChime()
    func playTapChime()
    func playWrongTapChime()
    func playStrokeTick()
}

/// No-op stub used by tests and previews.
@MainActor
final class NullPromptPlayer: PromptPlaying {
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) {}
    func stop() {}
    func playSuccessChime() {}
    func playTapChime() {}
    func playWrongTapChime() {}
    func playStrokeTick() {}
}

/// The study session's voiceover (P3, David 2026-10-04): the SPOKEN
/// content is IDENTICAL in all three arms.
///
/// Speech used to be switched off together with the silent arm's sound
/// (ruling C3-2's null pair), so with spoken feedback on, the phoneme and
/// spatial arms heard the phase prompts and the silent arm heard none — a
/// second difference between arms that the design does not contain.
/// Speech is not sonification: the silent arm's condition is that WRITING
/// makes no sound, and that stays unconditional (`SilentAudio`,
/// `TouchDispatcher`'s silent-arm return).
///
/// What passes, by construction rather than by call-site discipline:
///   - `play(key:)` for the phrases in `studySpokenKeys` — the phase-entry
///     prompts and the end-of-set phrase — in every arm alike. The
///     score-dependent praise tiers, paper-transfer and retrieval phrases
///     are not in the set, so no arm hears them in a study session (the
///     praise tiers were unreachable there before this, too).
///   - The non-speech effects (stroke tick, success chime, tap chimes) are
///     dropped in EVERY arm (protocol r13, David 2026-10-21): they are
///     supplementary auditory feedback that, since r4, only the phoneme and
///     spatial arms received, a confound on the sound-vs-silence contrast.
///     The three arms now differ only in the arm's own sound.
///
/// "Probier's nochmal" is the recorded `retryCue` and goes through here
/// like the others (protocol r9), so it reaches every arm alike.
@MainActor
final class StudyVoiceoverPromptPlayer: PromptPlaying {
    /// The phrases a study child can hear, identical in every arm.
    static let studySpokenKeys: Set<PromptPlayer.PromptKey> = [
        .phaseObserve, .phaseDirect, .phaseGuided, .phaseFreeWrite,
        .retryCue, .celebration,
    ]

    private let inner: any PromptPlaying

    init(inner: any PromptPlaying) {
        self.inner = inner
    }

    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) {
        guard Self.studySpokenKeys.contains(key) else { return }
        inner.play(key, fallbackText: fallbackText)
    }
    func stop() { inner.stop() }
    func playSuccessChime()  {}
    func playTapChime()      {}
    func playWrongTapChime() {}
    func playStrokeTick()    {}
}

@MainActor
final class PromptPlayer: PromptPlaying {

    /// Stable identifiers for pre-recorded phrases. Raw value is the
    /// filename stem in `Resources/Prompts/<key>.mp3` — keep in sync
    /// with the PROMPTS table in `scripts/generate_prompts.py`.
    enum PromptKey: String, CaseIterable {
        case phaseObserve   = "phase_observe"
        case phaseDirect    = "phase_direct"
        case phaseGuided    = "phase_guided"
        case phaseFreeWrite = "phase_freewrite"
        case praise4 = "praise_4"
        case praise3 = "praise_3"
        case praise2 = "praise_2"
        case praise1 = "praise_1"
        case praise0 = "praise_0"
        case paperShow   = "paper_show"
        case paperWrite  = "paper_write"
        case paperAssess = "paper_assess"
        case retrievalQuestion = "retrieval_question"
        case celebration = "celebration"
        /// "Probier's nochmal." — the off-path retry cue (protocol r9).
        case retryCue = "retry_cue"
    }

    private let speech: SpeechSynthesizing
    /// A study build never falls back to the system voice for a recorded
    /// phrase (r9): a missing take is a logged fault and silence, and the
    /// session precondition (`RecordedPromptSet.refusal`) keeps a session
    /// from starting without it. `true` keeps the old speak-the-text
    /// fallback, for tests only. `STUDY_BUILD` is unconditional, so the
    /// production default is always `false`.
    private let speechFallback: Bool
    private let makeSound: (URL) throws -> any RecordedSounding
    private let locate: @MainActor (PromptKey) -> URL?
    /// The watchdog's wait; a seam so a test decides when it ends.
    private let watchdogSleep: @MainActor (TimeInterval) async -> Void
    /// Releases a phrase the system never reports on (see `play`).
    private var watchdog: Task<Void, Never>?
    /// How long past its own length a recorded phrase may stay unreported.
    static let watchdogSlackSeconds: TimeInterval = 1.0
    /// The recorded phrase in flight. Exactly one end report is owed for it.
    private var active: (id: Int, text: String, sound: any RecordedSounding)?
    private var nextCueID = 0
    /// A retry cue that arrived while another phrase was playing; it plays
    /// when that one ends and is dropped by any later `play` or `stop`.
    private var queuedRetry: (key: PromptKey, text: String)?
    /// Lazy cache of effect-sound players. AVAudioPlayer inherits the
    /// AudioEngine's `.playback` session so these effects bypass the
    /// iPad ringer switch. Lazy because pre-loading shifts timing
    /// enough to push rapid-tap tests past the playback debounce.
    private var effectPlayers: [String: AVAudioPlayer] = [:]
    /// Effect names that failed to load — cached so the bundle isn't
    /// re-probed on every play call.
    private var missingEffects: Set<String> = []
    private let log = Logger(subsystem: "buchstaben.primae", category: "prompts")

    init(fallbackSpeech: SpeechSynthesizing,
         speechFallback: Bool = !StudyBuild.isActive,
         makeSound: @escaping (URL) throws -> any RecordedSounding = { try AVRecordedSound(url: $0) },
         locate: @escaping @MainActor (PromptKey) -> URL? = PromptPlayer.locate,
         watchdogSleep: @escaping @MainActor (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.watchdogSleep = watchdogSleep
        self.speech = fallbackSpeech
        self.speechFallback = speechFallback
        self.makeSound = makeSound
        self.locate = locate
    }

    /// Play the recorded phrase for `key`. `fallbackText` is the phrase's
    /// text: it is what a missing take falls back to where that is allowed,
    /// and it is the TEXT of the end report the view model matches the
    /// observe cue by. Stops BOTH pipelines on entry — `AVSpeechSynthesizer.speak()`
    /// queues utterances, so without `speech.stop()` rapid letter-
    /// skipping stacks the phase cue N+1 deep. The phrase it cuts reports
    /// its end as cancelled (once), so the observe-cue count stays true.
    ///
    /// The retry cue is the exception: it waits for a phrase in flight
    /// instead of cutting it (the synthesiser's hand-over did the same for
    /// the spoken line it replaces), and any later `play` or `stop` drops it.
    func play(_ key: PromptKey, fallbackText: String) {
        if key == .retryCue, active != nil {
            queuedRetry = (key, fallbackText)
            return
        }
        queuedRetry = nil
        stopRecorded()
        speech.stop()
        guard let url = locate(key) else {
            log.fault("Recorded prompt missing for '\(key.rawValue, privacy: .public)'")
            fallBackToSpeech(fallbackText)
            return
        }
        do {
            let sound = try makeSound(url)
            nextCueID += 1
            let id = nextCueID
            active = (id, fallbackText, sound)
            sound.onFinish = { [weak self] successfully in
                self?.recordedSoundEnded(id: id, cancelled: !successfully)
            }
            sound.play()
            // A player the system pauses (an interruption no scene change
            // reported, a lost route) never calls its delegate; without
            // this the phrase would stay "in flight" for good and every
            // later retry cue would queue behind it unheard. Past its own
            // length plus a second, it is treated as cut.
            let wait = sound.duration + Self.watchdogSlackSeconds
            let sleep = watchdogSleep
            watchdog = Task { @MainActor [weak self] in
                await sleep(wait)
                guard !Task.isCancelled else { return }
                self?.expire(id: id)
            }
        } catch {
            log.fault("AVAudioPlayer failed for '\(key.rawValue, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            fallBackToSpeech(fallbackText)
        }
    }

    private func fallBackToSpeech(_ text: String) {
        guard speechFallback else { return }
        speech.speak(text)
    }

    func stop() {
        queuedRetry = nil
        stopRecorded()
        speech.stop()
    }

    /// Halt the phrase in flight and report it cancelled, once.
    /// `AVAudioPlayer.stop()` does not call the delegate, so the report is
    /// made here; its own late finish callback is detached first.
    private func stopRecorded() {
        guard let cue = active else { return }
        watchdog?.cancel(); watchdog = nil
        active = nil
        cue.sound.onFinish = nil
        cue.sound.stop()
        speech.reportRecordedUtteranceEnd(text: cue.text, cancelled: true)
    }

    /// The watchdog's wake: the same phrase is still active, so it is cut
    /// and reported cancelled once, and a waiting retry cue plays.
    private func expire(id: Int) {
        guard let cue = active, cue.id == id else { return }
        log.fault("Recorded prompt never reported its end — releasing it.")
        cue.sound.stop()
        recordedSoundEnded(id: id, cancelled: true)
    }

    private func recordedSoundEnded(id: Int, cancelled: Bool) {
        guard let cue = active, cue.id == id else { return }
        watchdog?.cancel(); watchdog = nil
        active = nil
        cue.sound.onFinish = nil
        speech.reportRecordedUtteranceEnd(text: cue.text, cancelled: cancelled)
        if let next = queuedRetry {
            queuedRetry = nil
            play(next.key, fallbackText: next.text)
        }
    }

    /// Letter-completion celebration. Uses a system sound so it fires
    /// even while the letter-sound pipeline is reconfiguring.
    func playSuccessChime() {
        AudioServicesPlaySystemSound(1322)
    }

    /// Correct dot-tap click. AVAudioPlayer route bypasses the device
    /// mute switch via the AudioEngine's `.playback` session.
    func playTapChime() {
        playEffect(name: "tap", systemFallback: 1104)
    }

    /// Wrong-tap buzz — same mute-bypass route, lower pitched.
    func playWrongTapChime() {
        playEffect(name: "tap_wrong", systemFallback: 1053)
    }

    /// Beat played when StrokeTracker flips a stroke to complete.
    func playStrokeTick() {
        playEffect(name: "tick_stroke", systemFallback: nil)
    }

    /// Lazy effect playback: load + cache on first call. Falls back
    /// to `systemFallback` when the asset isn't bundled; pass nil to
    /// skip silently.
    private func playEffect(name: String, systemFallback: SystemSoundID?) {
        if let p = effectPlayers[name] {
            p.currentTime = 0
            p.play()
            return
        }
        if missingEffects.contains(name) {
            if let id = systemFallback { AudioServicesPlaySystemSound(id) }
            return
        }
        if let p = loadEffectPlayer(name: name) {
            effectPlayers[name] = p
            p.play()
        } else {
            missingEffects.insert(name)
            if let id = systemFallback { AudioServicesPlaySystemSound(id) }
        }
    }

    /// Bundle-relative layouts for an effect sound. Shared with
    /// `ResourceResolutionTests`, so the test probes the list the player
    /// walks rather than a copy of it that can drift.
    static func effectLayouts(_ name: String) -> [String] {
        PrimaeBundle.layouts(dir: "Prompts", name: name, ext: "wav")
    }

    private func loadEffectPlayer(name: String) -> AVAudioPlayer? {
        guard let url = PrimaeBundle.resourceURL(firstOf: Self.effectLayouts(name)),
              let p = try? AVAudioPlayer(contentsOf: url) else {
            log.info("\(name, privacy: .public).wav not bundled — falling back to system sound.")
            return nil
        }
        p.prepareToPlay()
        return p
    }

    // MARK: - Bundle lookup

    /// Probe `<key>.mp3` across the layouts SPM/Xcode bundling produces.
    ///
    /// Was `Bundle.module` + `url(forResource:)`. `Bundle.module` calls
    /// `fatalError` when it cannot resolve, which turns a missing resource
    /// into a launch crash in a test host — the hazard `PrimaeBundle` was
    /// extracted to remove (`cb7291d`). One resolver, so there is no second
    /// path for a lookup to succeed through by accident.
    static func locate(_ key: PromptKey) -> URL? {
        PrimaeBundle.resourceURL(
            firstOf: PrimaeBundle.layouts(dir: "Prompts", name: key.rawValue, ext: "mp3"))
    }
}

// MARK: - Recorded sound seam

/// One recorded phrase, as `PromptPlayer` drives it. A seam so tests play
/// no audio (AVAudioPlayer setup on the simulator costs wall-clock time).
@MainActor
protocol RecordedSounding: AnyObject {
    func play()
    /// The take's length in seconds.
    var duration: TimeInterval { get }
    /// Halt playback. Must NOT call `onFinish`.
    func stop()
    /// Called (main actor) when the take reached its end, `true`, or
    /// failed to decode, `false`.
    var onFinish: ((Bool) -> Void)? { get set }
}

/// `AVAudioPlayer` with its delegate. `stop()` does not notify the delegate
/// (documented behaviour), which is what lets `PromptPlayer` own the
/// cancelled report.
@MainActor
final class AVRecordedSound: NSObject, RecordedSounding, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    var onFinish: ((Bool) -> Void)?

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    var duration: TimeInterval { player.duration }
    func play() { player.play() }
    func stop() { player.stop() }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.onFinish?(flag) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.onFinish?(false) }
    }
}
