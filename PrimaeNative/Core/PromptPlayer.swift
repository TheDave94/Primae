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

@MainActor
final class PromptPlayer {

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
    /// Pre-loaded short-effect player for the direct-phase tap chime
    /// (and any future short UI sounds). Kept separate from `player`
    /// so a long phase-prompt MP3 doesn't get cancelled by a per-tap
    /// click. AVAudioPlayer inherits the existing `.playback` session
    /// the AudioEngine sets up, so it bypasses the iPad ringer/silent
    /// switch — a regression vs. AudioServicesPlaySystemSound which
    /// the user couldn't hear with mute on.
    private var tapPlayer: AVAudioPlayer?
    private let log = Logger(subsystem: "buchstaben.primae", category: "prompts")

    init(fallbackSpeech: SpeechSynthesizing) {
        self.speech = fallbackSpeech
        tapPlayer = loadTapPlayer()
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
        if let p = tapPlayer {
            p.currentTime = 0
            p.play()
        } else {
            AudioServicesPlaySystemSound(1104)
        }
    }

    /// One-time tap-chime player setup. Bundle lookup mirrors
    /// `locate(_:)` (probes `.module` and `.main` with the
    /// `Resources/Prompts` and `Prompts` subdirs). Returns nil if
    /// the asset isn't bundled — `playTapChime()` falls back to a
    /// system sound in that case.
    private func loadTapPlayer() -> AVAudioPlayer? {
        let bundles: [Bundle] = [.module, .main]
        let subdirs: [String?] = ["Resources/Prompts", "Prompts", nil]
        for bundle in bundles {
            for subdir in subdirs {
                let url: URL?
                if let subdir {
                    url = bundle.url(forResource: "tap",
                                     withExtension: "wav",
                                     subdirectory: subdir)
                } else {
                    url = bundle.url(forResource: "tap",
                                     withExtension: "wav")
                }
                if let url, let p = try? AVAudioPlayer(contentsOf: url) {
                    p.prepareToPlay()
                    return p
                }
            }
        }
        log.info("tap.wav not bundled — falling back to system sound for direct-phase tap chime.")
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
