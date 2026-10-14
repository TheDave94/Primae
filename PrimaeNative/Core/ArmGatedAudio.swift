// ArmGatedAudio.swift
// PrimaeNative
//
// The view model's ONE engine, for the whole session, whatever arm is
// current (2026-10-13, protocol r7).
//
// WHY. The silent arm's authority (ruling C3-2) used to be established by
// construction alone: `TracingViewModel.init` handed the view model and its
// playback controller a `SilentAudio` when the LAUNCH arm was silent, and the
// real engine otherwise — once, for the life of the view model. But the arm
// changes in place since 2026-09-14: the next child is enrolled without a
// relaunch (`resetForNewParticipant`), and a comparison run steps the arm per
// letter (`cycleAllConditions`). An app launched in the silent arm therefore
// kept the no-op engine for every later child — a phoneme or spatial child
// heard NOTHING while their rows recorded a sound arm and their observe sound
// was marked delivered (audit D1).
//
// HOW. This forwards every call to `SilentAudio` while the arm is silent —
// literally that object, so the silent arm's behaviour is exactly what it was
// at launch — and to the real engine otherwise. `enter(_:)`, called on every
// arm change and every new participant, flips it. Shared by the view model
// and its `PlaybackController`, so the two can never disagree about which
// engine is live (a swappable reference held in two places could).
//
// LEAVING A LIVE ENGINE neutralises it first: `stop()` (which, in the real
// engine, also drops the loaded file) and rate 1.0 / pan 0 / pitch 0 — the
// values `AudioEngine.init` sets. Those calls go to the real engine BEFORE
// the gate closes, so a sound arm stepping into silence cannot leave a file
// loaded or a loop running behind the no-op. And pitch is driven only by the
// spatial arm, so without the reset a phoneme child enrolled after a spatial
// child heard every phoneme shifted by that child's last pen height (audit
// D2); rate and pan are reset with it so no coupling state outlives the arm
// or the child it belonged to.
//
// While the gate is closed the real engine is untouched, so it is still
// stopped and neutral when the gate opens again — opening needs no calls.

import Foundation

final class ArmGatedAudio: AudioControlling {
    private let engine: AudioControlling
    private let silent = SilentAudio()
    /// Whether every call is going to `SilentAudio`. Derived from the arm
    /// passed to `init` / `enter(_:)`, never set on its own.
    private(set) var isSilenced: Bool

    private var live: AudioControlling { isSilenced ? silent : engine }

    init(engine: AudioControlling, arm: PilotAudioCondition) {
        self.engine = engine
        self.isSilenced = arm == .silent
    }

    /// Make `arm` the gate's arm. Called for every arm change AND every new
    /// participant (the same arm included — a new child must not inherit
    /// the previous child's coupling state). See the header for the order.
    func enter(_ arm: PilotAudioCondition) {
        if !isSilenced {
            engine.stop()
            engine.setAdaptivePlayback(speed: 1.0, horizontalBias: 0)
            engine.setSpatialPitch(cents: 0)
        }
        isSilenced = arm == .silent
    }

    // MARK: - AudioControlling — forwarded to the live target

    var initializationError: String? { live.initializationError }
    func loadAudioFile(named fileName: String, autoplay: Bool) { live.loadAudioFile(named: fileName, autoplay: autoplay) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { live.setAdaptivePlayback(speed: speed, horizontalBias: horizontalBias) }
    func setSpatialPitch(cents: Float) { live.setSpatialPitch(cents: cents) }
    func play() { live.play() }
    func play(fadeInSeconds: TimeInterval) { live.play(fadeInSeconds: fadeInSeconds) }
    func stop() { live.stop() }
    func restart() { live.restart() }
    func suspendForLifecycle() { live.suspendForLifecycle() }
    func resumeAfterLifecycle() { live.resumeAfterLifecycle() }
    func cancelPendingLifecycleWork() { live.cancelPendingLifecycleWork() }
    func emitAudioSignalSummary(label: String) { live.emitAudioSignalSummary(label: label) }
    func startAudioSignalTicker(intervalSeconds: TimeInterval,
                                label: @escaping @MainActor () -> String) {
        live.startAudioSignalTicker(intervalSeconds: intervalSeconds, label: label)
    }
    func stopAudioSignalTicker() { live.stopAudioSignalTicker() }
    var latestAudioSignalSummary: String? { live.latestAudioSignalSummary }
}
