// PopCaptureAudio.swift
// PrimaeNative
//
// POPCAP: logs every arm-sound command on the capture clock and forwards it,
// unchanged, to the real voice. Wraps whatever `SoundEnvelope.makeAudioEngine`
// built (the r17 live voice, or the r16 `AudioEngine` in the reference
// build), so one instrument serves both and neither engine file is edited.
// DEBUG-only (`#if DEBUG || POPCAP`), and only when launched with
// `-popCapture`: `wrap` returns the voice itself otherwise.

#if DEBUG || POPCAP
import Foundation

@MainActor
final class PopCaptureAudio: AudioControlling {
    private let inner: AudioControlling
    private let cap: PopCapture

    private init(_ inner: AudioControlling, _ cap: PopCapture) { self.inner = inner; self.cap = cap }

    static func wrap(_ voice: AudioControlling) -> AudioControlling {
        guard let cap = PopCapture.armed else { return voice }
        return PopCaptureAudio(voice, cap)
    }

    func loadAudioFile(named fileName: String, autoplay: Bool) {
        cap.event("audio.load", "file=\(fileName) autoplay=\(autoplay)")
        inner.loadAudioFile(named: fileName, autoplay: autoplay)
    }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        cap.event("audio.rate_pan", "rate=\(speed) pan=\(horizontalBias)")
        inner.setAdaptivePlayback(speed: speed, horizontalBias: horizontalBias)
    }
    func setSpatialPitch(cents: Float) {
        cap.event("audio.pitch", "cents=\(cents)")
        inner.setSpatialPitch(cents: cents)
    }
    func setStrokeLevel(gainDB: Float) { cap.event("audio.level", "db=\(gainDB)"); inner.setStrokeLevel(gainDB: gainDB) }
    func setStrokeLowpass(cutoffHz: Float) { cap.event("audio.lowpass", "hz=\(cutoffHz)"); inner.setStrokeLowpass(cutoffHz: cutoffHz) }
    func setStrokeMute(_ muted: Bool) { cap.event("audio.mute", "muted=\(muted)"); inner.setStrokeMute(muted) }
    func setPressureGain(_ gain: Float) {
        cap.event("audio.pressure_gain", "gain=\(gain)")
        inner.setPressureGain(gain)
    }
    func setRoughness(_ amount: Float) {
        cap.event("audio.roughness", "amount=\(amount)")
        inner.setRoughness(amount)
    }
    func setRoughnessTuning(depth: Float, frequencyHz: Float) {
        cap.event("audio.roughness_tuning", "depth=\(depth) hz=\(frequencyHz)")
        inner.setRoughnessTuning(depth: depth, frequencyHz: frequencyHz)
    }
    func play() { cap.event("audio.play", "fade=0"); inner.play() }
    func play(fadeInSeconds: TimeInterval) { cap.event("audio.play", "fade=\(fadeInSeconds)"); inner.play(fadeInSeconds: fadeInSeconds) }
    func stop() { cap.event("audio.stop"); inner.stop() }
    func stop(fadeOutSeconds: TimeInterval) { cap.event("audio.stop", "fade=\(fadeOutSeconds)"); inner.stop(fadeOutSeconds: fadeOutSeconds) }
    func restart() { cap.event("audio.restart"); inner.restart() }
    func suspendForLifecycle() { cap.event("audio.suspend"); inner.suspendForLifecycle() }
    func resumeAfterLifecycle() { cap.event("audio.resume"); inner.resumeAfterLifecycle() }
    func cancelPendingLifecycleWork() { inner.cancelPendingLifecycleWork() }

    func emitAudioSignalSummary(label: String) { inner.emitAudioSignalSummary(label: label) }
    func startAudioSignalTicker(intervalSeconds: TimeInterval, label: @escaping @MainActor () -> String) {
        inner.startAudioSignalTicker(intervalSeconds: intervalSeconds, label: label)
    }
    func stopAudioSignalTicker() { inner.stopAudioSignalTicker() }
    var latestAudioSignalSummary: String? { inner.latestAudioSignalSummary }
    var initializationError: String? { inner.initializationError }
    var debugAudioStateSummary: String { inner.debugAudioStateSummary }
}
#endif
