// SoundEnvelope.swift
// PrimaeNative
//
// THE SOUND ARMS' ENVELOPE, in one place (supervisor ruling 2026-10-05,
// after David's own test of the pilot build; protocol revision 5). Retune
// any value here, in one line. Deliberately NOT a
// `StudyComparisonSettings` switch: this is the protocol, not a comparison
// axis, and a change to it is a `StudyProtocol` revision.
//
// Applies to every writing phase in both sound arms (guided, free-writing,
// the cold probes). The silent arm never reaches the engine (`SilentAudio`).

import Foundation

enum SoundEnvelope {
    /// Linear fade-out applied by the engine's `stop()`. Was 0.12 s
    /// (`AudioEngine.fadeOutSeconds` default). Set at the engine's
    /// construction site — `AudioEngine.swift` is not edited.
    static let fadeOutSeconds: TimeInterval = 0.4
    /// A pen that stops moving (still touching) keeps sounding this long
    /// before the stall idle fires. Was 0.12 s
    /// (`PlaybackController.idleDebounceSeconds` default).
    static let stallSeconds: TimeInterval = 0.3
    /// After a LIFT the sound keeps playing this long; a re-touch inside
    /// the hold cancels the stop, so the sound does not cut between
    /// strokes. Was 0 (a lift stopped at once).
    static let liftHoldSeconds: TimeInterval = 0.8

    /// The production engine with the envelope's fade applied.
    static func makeAudioEngine() -> AudioEngine {
        let engine = AudioEngine()
        engine.fadeOutSeconds = fadeOutSeconds
        return engine
    }
}
