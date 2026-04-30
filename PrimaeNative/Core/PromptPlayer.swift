// PromptPlayer.swift
// PrimaeNative
//
// Plays bundled, pre-recorded ElevenLabs MP3 prompts (in
// `Resources/Prompts/`) for the 13 static phrases the child hears
// during normal practice — phase entries, praise tiers, paper-
// transfer cues, the retrieval-prompt question. Replaces the
// AVSpeechSynthesizer voice for these phrases (the user flagged
// the system TTS quality as poor).
//
// Falls back to AVSpeechSynthesizer when an MP3 is missing —
// covers builds where `scripts/generate_prompts.py` hasn't been run
// yet, so the app is functional pre-asset-generation.
//
// Dynamic phrases that template per-letter (recognition feedback,
// retrieval correction) stay on AVSpeechSynthesizer for now —
// pre-generating 26+ × 26 × 3 templates is a combinatorial blow-up
// that this scaffold doesn't try to handle.
//
// Audio session note: AVAudioPlayer shares AVAudioSession with the
// AudioEngine letter-sound pipeline. The freeWrite cutoff
// (touching the canvas reconfigures the session and can clip an
// in-flight prompt) isn't fixed here — that's an AudioEngine
// concern (gated as "DO NOT modify" in CLAUDE.md). The change is
// purely quality.

import AudioToolbox
import AVFoundation
import Foundation
import os.log

/// Public surface of `PromptPlayer`. Lets tests inject a no-op
/// (`NullPromptPlayer`) so the test loop doesn't pay the cost of real
/// `AVAudioPlayer.play()` calls — those have enough setup overhead in
/// the simulator (~10–20 ms each, especially without an active
/// `.playback` AVAudioSession) to push the rapid-tap test past the
/// `PlaybackController.playIntentDebounceSeconds` wall-clock window.
@MainActor
protocol PromptPlaying: AnyObject {
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String)
    func stop()
    func playSuccessChime()
    func playTapChime()
    func playWrongTapChime()
    func playStrokeTick()
    func playOutOfBoundsChime()
}

/// Test/stub implementation. Every method is a no-op so unit tests
/// don't drive real audio. Production code path is `PromptPlayer`.
@MainActor
final class NullPromptPlayer: PromptPlaying {
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) {}
    func stop() {}
    func playSuccessChime() {}
    func playTapChime() {}
    func playWrongTapChime() {}
    func playStrokeTick() {}
    func playOutOfBoundsChime() {}
}

@MainActor
final class PromptPlayer: PromptPlaying {

    /// Stable identifiers for each pre-recorded phrase. The raw value
    /// is the filename stem inside `Resources/Prompts/<key>.mp3`.
    /// Keep in sync with `scripts/generate_prompts.py` PROMPTS table.
    enum PromptKey: String, CaseIterable {
        // Phase entries
        case phaseObserve   = "phase_observe"
        case phaseDirect    = "phase_direct"
        case phaseGuided    = "phase_guided"
        case phaseFreeWrite = "phase_freewrite"
        // Praise tiers (0–4 stars)
        case praise4 = "praise_4"
        case praise3 = "praise_3"
        case praise2 = "praise_2"
        case praise1 = "praise_1"
        case praise0 = "praise_0"
        // Paper transfer
        case paperShow   = "paper_show"
        case paperWrite  = "paper_write"
        case paperAssess = "paper_assess"
        // Retrieval prompt headline
        case retrievalQuestion = "retrieval_question"
        // Letter-completion celebration (plays after the final
        // phase of every letter, regardless of star count — the
        // visual N-of-4 star row in CompletionCelebrationOverlay
        // carries the gradation; the audio is always positive).
        case celebration = "celebration"
    }

    private let speech: SpeechSynthesizing
    private var player: AVAudioPlayer?
    /// Lazily-loaded short-effect players keyed by asset name.
    /// AVAudioPlayer inherits the existing `.playback` session the
    /// AudioEngine sets up, so these bypass the iPad ringer/silent
    /// switch — a regression vs. AudioServicesPlaySystemSound which
    /// the user couldn't hear with mute on.
    ///
    /// Lazy loading matters for tests: pre-loading 4+ AVAudioPlayer
    /// instances at init shifts the timing of subsequent operations
    /// enough to push past the playback debounce window in the rapid-
    /// taps test, which previously passed when only 2 effects existed.
    /// First play() incurs a one-time load; subsequent plays reuse.
    private var effectPlayers: [String: AVAudioPlayer] = [:]
    /// Names that we tried to load and failed — cached so we don't
    /// re-probe the bundle on every play() call.
    private var missingEffects: Set<String> = []
    private let log = Logger(subsystem: "buchstaben.primae", category: "prompts")

    init(fallbackSpeech: SpeechSynthesizing) {
        self.speech = fallbackSpeech
    }

    /// Play the prompt audio for `key`. Falls back to
    /// `speech.speak(fallbackText)` when the bundled MP3 is missing.
    /// Stops any prompt currently playing first so a stream of
    /// phase transitions doesn't pile up overlapping audio.
    func play(_ key: PromptKey, fallbackText: String) {
        guard let url = locate(key) else {
            // Asset missing — pre-asset-generation builds, or a
            // future addition that hasn't been generated yet.
            log.info("Prompt missing for '\(key.rawValue, privacy: .public)' — falling back to TTS.")
            speech.speak(fallbackText)
            return
        }
        do {
            player?.stop()
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            log.error("AVAudioPlayer failed for '\(key.rawValue, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            speech.speak(fallbackText)
        }
    }

    /// Halt the current prompt. Mirrors `SpeechSynthesizing.stop()`.
    func stop() {
        player?.stop()
        speech.stop()
    }

    /// Play a short positive chime via the system sound services —
    /// independent of AVAudioEngine, so it can fire even while the
    /// letter-sound pipeline is mid-reconfigure. Used as the
    /// celebration cue at letter completion. Asset ID 1322 is a
    /// soft, kid-appropriate "complete" tone; swap for a designed
    /// chime later (drop a `success.mp3` next to the prompts and
    /// route through `play(_:fallbackText:)` instead).
    func playSuccessChime() {
        AudioServicesPlaySystemSound(1322)
    }

    /// Short confirmation tap, fired when the child taps a correct
    /// numbered start-dot in the direct phase. Plays the bundled
    /// `tap.wav` (80 ms attack-decay click at 1.5 kHz) through
    /// AVAudioPlayer — inherits the AudioEngine's `.playback`
    /// session so it bypasses the iPad ringer switch (the user's
    /// device is muted; AudioServicesPlaySystemSound was silenced).
    /// Falls back to the system sound only if the asset is missing.
    func playTapChime() {
        playEffect(name: "tap", systemFallback: 1104)
    }

    /// Distinct wrong-tap sound: a low-pitched 120 ms buzz (220 Hz +
    /// 233 Hz dissonant pair) so the child hears "not that one"
    /// without it being harsh. Same mute-bypass path as
    /// `playTapChime()`. Falls back to the system "tock" if the
    /// asset isn't bundled.
    func playWrongTapChime() {
        playEffect(name: "tap_wrong", systemFallback: 1053)
    }

    /// Stroke-completion tick — clear "this stroke is done" beat,
    /// fired by `TouchDispatcher.fireMovementHaptics` when the
    /// strokeTracker flips a stroke complete.
    func playStrokeTick() {
        playEffect(name: "tick_stroke", systemFallback: nil)
    }

    /// Warning chime fired when the touch leaves the canvas mid-
    /// stroke. Reuses the wrong-tap buzz (220 Hz + 233 Hz dissonant
    /// pair, 120 ms) — same "you've gone wrong" semantics as the
    /// direct-phase miss. Drop a dedicated `out_of_bounds.wav` next
    /// to the prompts and switch the asset name here when a
    /// distinct sound is desired.
    func playOutOfBoundsChime() {
        playEffect(name: "tap_wrong", systemFallback: 1053)
    }

    /// Lazy effect playback. Loads the AVAudioPlayer on first call
    /// for `name`, caches it, and reuses on subsequent calls. Falls
    /// back to `systemFallback` (a SystemSoundID) when the asset
    /// isn't bundled; pass nil to silently skip the play.
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

    /// One-time effect-player setup. Bundle lookup mirrors
    /// `locate(_:)` (probes `.module` and `.main` with the
    /// `Resources/Prompts` and `Prompts` subdirs). Returns nil if
    /// the asset isn't bundled.
    private func loadEffectPlayer(name: String) -> AVAudioPlayer? {
        let bundles: [Bundle] = [.module, .main]
        let subdirs: [String?] = ["Resources/Prompts", "Prompts", nil]
        for bundle in bundles {
            for subdir in subdirs {
                let url: URL?
                if let subdir {
                    url = bundle.url(forResource: name,
                                     withExtension: "wav",
                                     subdirectory: subdir)
                } else {
                    url = bundle.url(forResource: name,
                                     withExtension: "wav")
                }
                if let url, let p = try? AVAudioPlayer(contentsOf: url) {
                    p.prepareToPlay()
                    return p
                }
            }
        }
        log.info("\(name, privacy: .public).wav not bundled — falling back to system sound.")
        return nil
    }

    // MARK: - Bundle lookup

    /// Locate `<key>.mp3` in `Resources/Prompts/` of the SPM
    /// resource bundle. Probes both nested paths used by the
    /// existing letter-audio loader so layout changes in the
    /// bundling pipeline don't break here.
    private func locate(_ key: PromptKey) -> URL? {
        let name = key.rawValue
        let bundles: [Bundle] = [.module, .main]
        let subdirs: [String?] = ["Resources/Prompts", "Prompts", nil]
        for bundle in bundles {
            for subdir in subdirs {
                if let subdir,
                   let url = bundle.url(forResource: name,
                                        withExtension: "mp3",
                                        subdirectory: subdir) {
                    return url
                }
                if subdir == nil,
                   let url = bundle.url(forResource: name,
                                        withExtension: "mp3") {
                    return url
                }
            }
        }
        return nil
    }
}
