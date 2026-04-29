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

import AVFoundation
import Foundation
import os.log

@MainActor
public final class PromptPlayer {

    /// Stable identifiers for each pre-recorded phrase. The raw value
    /// is the filename stem inside `Resources/Prompts/<key>.mp3`.
    /// Keep in sync with `scripts/generate_prompts.py` PROMPTS table.
    public enum PromptKey: String, CaseIterable {
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
    }

    private let speech: SpeechSynthesizing
    private var player: AVAudioPlayer?
    private let log = Logger(subsystem: "buchstaben.primae", category: "prompts")

    public init(fallbackSpeech: SpeechSynthesizing) {
        self.speech = fallbackSpeech
    }

    /// Play the prompt audio for `key`. Falls back to
    /// `speech.speak(fallbackText)` when the bundled MP3 is missing.
    /// Stops any prompt currently playing first so a stream of
    /// phase transitions doesn't pile up overlapping audio.
    public func play(_ key: PromptKey, fallbackText: String) {
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
    public func stop() {
        player?.stop()
        speech.stop()
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
