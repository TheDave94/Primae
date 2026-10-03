// SilentAudio.swift
// PrimaeNative
//
// The silent study arm's audio engine: a conformer that does nothing.
//
// Supervisor ruling C3-2 (2026-09-04): the study arm is AUTHORITATIVE.
// Until now `.silent` was implemented by `activeAudioFiles` returning
// `[]` plus study mode nulling speech and prompts — two conditions in
// two places, and the second only held when study mode was on. A silent-
// arm child in an enrolled, non-study session could hear TTS prompts,
// chimes and praise, and the export could not tell that session from a
// study one. Substituting this engine at the injection seam means no
// audio path can fire for the silent arm whatever any other parameter
// says: the playback controller, the coupling, the demonstration, the
// replay entries and every load all talk to an object that cannot make
// sound.

import Foundation

final class SilentAudio: AudioControlling {
    var initializationError: String? { nil }
    func loadAudioFile(named fileName: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func setSpatialPitch(cents: Float) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}

    // The four measurement hooks are protocol REQUIREMENTS now (see
    // `AudioControlling`'s MARK), so they must be spelled out. The
    // no-op defaults in the extension would satisfy them anyway, but
    // saying so HERE is the point: the silent arm reports nothing, by
    // construction, and that silence is the finding rather than an
    // accident of dispatch.
    func emitAudioSignalSummary(label: String) {}
    func startAudioSignalTicker(intervalSeconds: TimeInterval,
                                label: @escaping @MainActor () -> String) {}
    func stopAudioSignalTicker() {}
}
