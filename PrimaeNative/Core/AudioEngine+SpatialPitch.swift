// AudioEngine+SpatialPitch.swift
// PrimaeNative
//
// Spatial-arm pitch drive, kept OUT of AudioEngine.swift on purpose:
// that file is stable-and-fragile (LESSONS.md — init/deinit/observer
// pattern, shared audio session) and must not grow surface area. The
// engine already exposes `pitchCents` (a proxy onto the existing
// AVAudioUnitTimePitch node, wired since the debug audio panel); this
// extension only forwards to it. No session, node-graph, or lifecycle
// code is touched.
//
// Since protocol r17 this is NOT the arm sound's pitch path: the arm sound
// is `LiveSonificationAudio` (`SoundEnvelope`'s production voice), whose
// `setSpatialPitch` drives the TDPSOLA kernel (clamp ±1200), and from r26
// the default coupling pitches the phoneme arm too, over ±600 cents.

extension AudioEngine {
    /// `PilotAudioCondition.spatial` per-tick pitch drive. Cents are
    /// relative to the carrier's authored frequency (440 Hz — see
    /// `SpatialSonification`); the mapping layer emits ±1200. The clamp
    /// here is the AVAudioUnitTimePitch hardware bound, a backstop only.
    func setSpatialPitch(cents: Float) {
        guard cents.isFinite else { return }
        pitchCents = max(-2400, min(2400, cents))
    }
}
