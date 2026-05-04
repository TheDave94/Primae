// PromptPlayer.swift
// PrimaeNative
//
// Plays the bundled MP3 phrases the child hears during practice
// (phase entries, praise tiers, paper-transfer cues, the retrieval
// headline, the letter-completion celebration). Falls back to
// AVSpeechSynthesizer when the MP3 for a given key isn't bundled,
// so the app is functional before `scripts/generate_prompts.py`
// has been run.
//
// Dynamic, per-letter phrases (recognition feedback, retrieval
// correction) bypass this player and go through the synthesizer
// directly — the combinatorial template space is too large to
// pre-render.

import AudioToolbox
import AVFoundation
import Foundation
import os.log

/// Public surface of `PromptPlayer`. Tests substitute `NullPromptPlayer`
/// so the suite avoids real AVAudioPlayer setup; on the simulator each
/// `.play()` costs enough wall-clock time (~10–20 ms) to push rapid-tap
/// tests past `PlaybackController.playIntentDebounceSeconds`.
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

@MainActor
final class PromptPlayer: PromptPlaying {

    /// Stable identifiers for each pre-recorded phrase. The raw value
    /// is the filename stem inside `Resources/Prompts/<key>.mp3`;
    /// keep in sync with the PROMPTS table in
    /// `scripts/generate_prompts.py`.
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
    }

    private let speech: SpeechSynthesizing
    private var player: AVAudioPlayer?
    /// Lazy cache of effect-sound players keyed by asset stem. AVAudioPlayer
    /// inherits the AudioEngine's `.playback` session, so these effects
    /// bypass the iPad ringer switch. Lazy-loaded because pre-loading
    /// every effect at init shifts subsequent timing enough to push
    /// rapid-tap tests past the playback debounce window.
    private var effectPlayers: [String: AVAudioPlayer] = [:]
    /// Effect names that failed to load — cached so the bundle isn't
    /// re-probed on every play call.
    private var missingEffects: Set<String> = []
    private let log = Logger(subsystem: "buchstaben.primae", category: "prompts")

    init(fallbackSpeech: SpeechSynthesizing) {
        self.speech = fallbackSpeech
    }

    /// Play the prompt audio for `key`. Falls back to
    /// `speech.speak(fallbackText)` when the bundled MP3 is missing.
    ///
    /// Both pipelines are stopped on entry, not just the one we're
    /// about to use: when prompt MP3s aren't bundled every call falls
    /// into the synthesizer, and `AVSpeechSynthesizer.speak()` queues
    /// utterances rather than replacing them. Without `speech.stop()`,
    /// rapid letter-skipping stacks the phase cue N+1 deep.
    func play(_ key: PromptKey, fallbackText: String) {
        player?.stop()
        speech.stop()
        guard let url = locate(key) else {
            log.info("Prompt missing for '\(key.rawValue, privacy: .public)' — falling back to TTS.")
            speech.speak(fallbackText)
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            log.error("AVAudioPlayer failed for '\(key.rawValue, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            speech.speak(fallbackText)
        }
    }

    func stop() {
        player?.stop()
        speech.stop()
    }

    /// Letter-completion celebration. Uses a system sound so it can
    /// fire even while the letter-sound pipeline is reconfiguring.
    func playSuccessChime() {
        AudioServicesPlaySystemSound(1322)
    }

    /// Confirmation click for a correct dot tap in the direct phase.
    /// Routes through AVAudioPlayer so the AudioEngine's `.playback`
    /// session bypasses the device mute switch.
    func playTapChime() {
        playEffect(name: "tap", systemFallback: 1104)
    }

    /// Distinct dissonant buzz for a wrong dot tap — same mute-bypass
    /// path as `playTapChime`, lower in pitch so the child reads it
    /// as "not that one" without harshness.
    func playWrongTapChime() {
        playEffect(name: "tap_wrong", systemFallback: 1053)
    }

    /// Beat played whenever the StrokeTracker flips a stroke to
    /// complete during guided/freeWrite tracing.
    func playStrokeTick() {
        playEffect(name: "tick_stroke", systemFallback: nil)
    }

    /// Lazy effect playback: load the AVAudioPlayer on first call,
    /// cache it, reuse thereafter. Falls back to `systemFallback`
    /// when the asset isn't bundled; pass nil to skip silently.
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

    /// Probe `<key>.mp3` across the layouts the SPM/Xcode bundling
    /// pipeline produces (Resources-prefixed, flattened, root-level)
    /// in both `.module` and `.main`.
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
