// LiveSonificationAudioTests.swift
// PrimaeNativeTests — protocol r17 (2026-11-03)
//
// The main-actor half of the live voice: the r16 `AudioEngine` semantics,
// re-derived (BRIEF-r17 item 6). Each case drives the same entry points the
// view model, the playback controller and the session notifications drive,
// with a fake engine output (AVAudioEngine cannot run on the simulator) and
// the REAL kernel, which is then rendered offline so "sounds" means samples,
// not a flag. Interruption, route change, headphone unplug (r16 B1: the view
// model makes it an interruption; here the engine's own `.oldDeviceUnavailable`
// stop), background/foreground, letter change, arm change.

import Testing
import Foundation
import AVFoundation
@testable import PrimaeNative

@MainActor
final class FakeLiveOutput: LiveSonificationOutput {
    var isRunning = true
    var canStart = true
    var startCalls = 0
    var pan: Float = 0
    func startIfNeeded() {
        guard !isRunning else { return }
        startCalls += 1
        if canStart { isRunning = true }
    }
    func setPan(_ pan: Float) { self.pan = pan }
}

@MainActor
final class HostSpy: AudioControlling {
    var calls: [String] = []
    var initializationError: String? { nil }
    func loadAudioFile(named fileName: String, autoplay: Bool) { calls.append("load") }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { calls.append("rate") }
    func play() { calls.append("play") }
    func stop() { calls.append("stop") }
    func restart() { calls.append("restart") }
    func suspendForLifecycle() { calls.append("suspend") }
    func resumeAfterLifecycle() { calls.append("resume") }
    func cancelPendingLifecycleWork() { calls.append("cancelPending") }
}

@Suite("r17 live voice: r16 semantics re-derived")
@MainActor struct LiveSonificationAudioTests {

    static let sr = LiveSonificationKernel.sampleRate
    typealias Reason = AVAudioSession.RouteChangeReason

    /// Synthetic 200 Hz voiced tone, 1 s.
    static func tone(_ key: String, hz: Double = 200) -> SonificationSource {
        let n = Int(sr)
        let s = (0..<n).map { i -> Float in
            let t = Double(i) / sr
            return Float(0.3 * sin(2 * .pi * hz * t) + 0.1 * sin(4 * .pi * hz * t))
        }
        return SonificationSource(key: key, samples: s, kind: .voicedPhoneme, gain: 1)
    }

    struct Rig {
        let voice: LiveSonificationAudio
        let output: FakeLiveOutput
        let host: HostSpy
        var kernel: LiveSonificationKernel { voice.kernel }

        init(fade: TimeInterval = 0.05) {
            output = FakeLiveOutput()
            host = HostSpy()
            let sources = ["a": LiveSonificationAudioTests.tone("a"), "m": LiveSonificationAudioTests.tone("m", hz: 150)]
            voice = LiveSonificationAudio(host: host, output: output, kernel: LiveSonificationKernel(),
                                          fadeOutSeconds: fade, observeSession: false,
                                          resolve: { sources[$0] })
        }

        /// Renders `seconds` and returns the RMS of the last 50 ms (0 = silent).
        func sound(_ seconds: Double = 0.15) -> Double {
            let n = Int(seconds * LiveSonificationAudioTests.sr)
            var y = [Float](repeating: 0, count: n)
            var pos = 0
            y.withUnsafeMutableBufferPointer { b in
                while pos < n { let k = min(256, n - pos); kernel.render(into: b.baseAddress! + pos, frames: k); pos += k }
            }
            return SonificationMetrics.rms(y[(n - Int(0.05 * LiveSonificationAudioTests.sr))...])
        }
    }

    /// Waits out the 50 ms fade, then until the fade's main-actor task has
    /// actually run (on a loaded device the main actor can be busy for
    /// seconds; a fixed sleep raced it — measured on the iPad, 2026-11-03).
    static func waitPastFade(_ r: Rig) async {
        try? await Task.sleep(for: .milliseconds(200))
        for _ in 0..<400 where r.voice.isFadingOut { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test("load + play sounds; stop fades, then discards the file: a play without a load is silent (r16)")
    func playStopDiscards() async {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: false)
        #expect(r.sound() == 0, "a load without autoplay must not sound")
        r.voice.play()
        #expect(r.voice.isPlaying)
        #expect(r.sound() > 0.01)
        r.voice.stop()
        #expect(r.voice.isFadingOut, "a stop while sounding must fade (fadeOutSeconds)")
        await Self.waitPastFade(r)
        #expect(r.voice.loadedKey == nil, "the fade's end must discard the loaded file")
        #expect(r.sound() == 0)
        r.voice.play()
        #expect(!r.voice.isPlaying, "play() without a load must be a no-op, as AudioEngine's")
        #expect(r.sound() == 0)
    }

    @Test("autoplay load sounds at once (the observe demonstration path)")
    func autoplay() {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: true)
        #expect(r.voice.isPlaying)
        #expect(r.sound() > 0.01)
    }

    @Test("a missing file changes nothing")
    func missingFile() {
        let r = Rig()
        r.voice.loadAudioFile(named: "nope", autoplay: true)
        #expect(r.voice.loadedKey == nil)
        #expect(!r.voice.isPlaying)
    }

    @Test("interruption: began keeps the file and the intent; ended + shouldResume resumes")
    func interruptionResumes() {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: false)
        r.voice.play()
        _ = r.sound()
        r.voice.handleInterruption(typeRawValue: AVAudioSession.InterruptionType.began.rawValue, optionsRawValue: nil)
        #expect(!r.voice.isPlaying)
        #expect(r.voice.loadedKey == "a", "an interruption must not discard the file")
        #expect(r.voice.shouldResumePlayback)
        #expect(r.sound() == 0, "sound during an interruption")
        #expect(!r.host.calls.contains("cancelPending"), "the host's engine pause must stand during an interruption")
        r.voice.handleInterruption(typeRawValue: AVAudioSession.InterruptionType.ended.rawValue,
                                   optionsRawValue: AVAudioSession.InterruptionOptions.shouldResume.rawValue)
        #expect(r.voice.isPlaying)
        #expect(r.sound() > 0.01, "no sound after the interruption ended with shouldResume")
    }

    @Test("interruption: ended WITHOUT shouldResume stays silent until the next play")
    func interruptionWithoutResume() {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: true)
        _ = r.sound()
        r.voice.handleInterruption(typeRawValue: AVAudioSession.InterruptionType.began.rawValue, optionsRawValue: nil)
        r.voice.handleInterruption(typeRawValue: AVAudioSession.InterruptionType.ended.rawValue, optionsRawValue: 0)
        #expect(!r.voice.isPlaying)
        #expect(r.sound() == 0)
        r.voice.play()
        #expect(r.sound() > 0.01, "an explicit play after the interruption must sound (R5)")
    }

    @Test("C2: an interruption that begins during a stop fade does not bring the sound back")
    func interruptionDuringFade() async {
        let r = Rig(fade: 0.4)
        r.voice.loadAudioFile(named: "a", autoplay: true)
        _ = r.sound()
        r.voice.stop()
        #expect(r.voice.isFadingOut)
        r.voice.handleInterruption(typeRawValue: AVAudioSession.InterruptionType.began.rawValue, optionsRawValue: nil)
        r.voice.handleInterruption(typeRawValue: AVAudioSession.InterruptionType.ended.rawValue,
                                   optionsRawValue: AVAudioSession.InterruptionOptions.shouldResume.rawValue)
        #expect(!r.voice.isPlaying, "the faded stop came back after the interruption")
        #expect(r.sound(0.6) == 0)
    }

    @Test("route: a lost output (headphones unplugged) stops the sound")
    func unplugStops() async {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: true)
        _ = r.sound()
        r.voice.handleRouteChange(reasonRawValue: Reason.oldDeviceUnavailable.rawValue)
        #expect(!r.kernel.gateRequested)
        await Self.waitPastFade(r)
        #expect(!r.voice.isPlaying)
        #expect(r.voice.loadedKey == nil)
        #expect(r.sound() == 0)
    }

    @Test("route: a new device while sounding keeps the sound and does NOT restart it")
    func newDeviceWhileSounding() {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: true)
        _ = r.sound()
        let starts = r.kernel.starts
        r.voice.handleRouteChange(reasonRawValue: Reason.newDeviceAvailable.rawValue)
        #expect(r.sound() > 0.01)
        #expect(r.kernel.starts == starts, "a route change restarted a sounding voice")
    }

    @Test("route: a new device while idle starts nothing")
    func newDeviceWhileIdle() {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: false)
        r.voice.handleRouteChange(reasonRawValue: Reason.newDeviceAvailable.rawValue)
        #expect(!r.voice.isPlaying)
        #expect(r.sound() == 0)
    }

    @Test("background closes the gate; foreground re-opens it when it was playing")
    func lifecycle() {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: true)
        _ = r.sound()
        r.voice.suspendForLifecycle()
        #expect(!r.voice.isPlaying)
        #expect(r.host.calls.contains("suspend"), "the host must schedule its engine pause")
        #expect(r.sound() == 0)
        r.output.isRunning = false          // the host paused the engine
        r.voice.resumeAfterLifecycle()
        #expect(r.output.startCalls == 1, "the voice must restart the paused engine")
        #expect(r.voice.isPlaying)
        #expect(r.sound() > 0.01)
    }

    @Test("C3: a foreground return with nothing loaded opens nothing and clears the intent")
    func lifecycleWithNothingLoaded() {
        let r = Rig()
        r.voice.suspendForLifecycle()
        r.voice.resumeAfterLifecycle()
        #expect(r.host.calls.contains("resume"))
        #expect(!r.voice.shouldResumePlayback)
        #expect(!r.voice.isPlaying)
        #expect(r.sound() == 0)
    }

    @Test("an engine that cannot start opens nothing")
    func engineCannotStart() {
        let r = Rig()
        r.output.isRunning = false
        r.output.canStart = false
        r.voice.loadAudioFile(named: "a", autoplay: true)
        #expect(!r.voice.isPlaying)
        #expect(!r.kernel.gateRequested)
    }

    @Test("letter change: loading another letter's file while sounding ducks it; the next play is the new file")
    func letterChange() {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: true)
        _ = r.sound()
        r.voice.loadAudioFile(named: "m", autoplay: false)
        #expect(!r.kernel.gateRequested, "the old letter kept sounding after the new letter's load")
        #expect(r.voice.loadedKey == "m")
        #expect(r.sound() == 0)
        r.voice.play()
        #expect(r.sound() > 0.01)
    }

    @Test("a reload of the same file does not stop the sound (the r7 lift-hold case)")
    func sameFileReloadKeepsSounding() {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: true)
        _ = r.sound()
        let starts = r.kernel.starts
        r.voice.loadAudioFile(named: "a", autoplay: false)
        #expect(r.sound() > 0.01)
        #expect(r.kernel.starts == starts)
    }

    @Test("a load during a stop fade keeps the new file: the fade can no longer discard it")
    func loadDuringFadeKeepsFile() async {
        let r = Rig()
        r.voice.loadAudioFile(named: "a", autoplay: true)
        _ = r.sound()
        r.voice.stop()
        r.voice.loadAudioFile(named: "a", autoplay: false)
        await Self.waitPastFade(r)
        #expect(r.voice.loadedKey == "a")
        r.voice.play()
        #expect(r.sound() > 0.01)
    }

    @Test("arm change (ArmGatedAudio.enter): stop, rate 1, pan 0, pitch 0; silent arm reaches nothing")
    func armChange() {
        let r = Rig()
        let gate = ArmGatedAudio(engine: r.voice, arm: .spatial)
        gate.loadAudioFile(named: "a", autoplay: true)
        gate.setAdaptivePlayback(speed: 1.8, horizontalBias: 0.7)
        gate.setSpatialPitch(cents: 900)
        _ = r.sound()
        gate.enter(.silent)
        #expect(!r.kernel.gateRequested)
        #expect(r.kernel.requestedRate == 1)
        #expect(r.kernel.requestedCents == 0)
        #expect(r.output.pan == 0)
        gate.loadAudioFile(named: "a", autoplay: true)
        #expect(r.sound(0.6) == 0, "the silent arm reached the voice")
        gate.enter(.phoneme)
        gate.loadAudioFile(named: "a", autoplay: true)
        #expect(r.sound() > 0.01)
    }

    @Test("rate, pan and pitch reach the kernel, clamped as AudioEngine clamps")
    func coupling() {
        let r = Rig()
        r.voice.setAdaptivePlayback(speed: 5, horizontalBias: -3)
        #expect(r.kernel.requestedRate == 2)
        #expect(r.output.pan == -1)
        r.voice.setAdaptivePlayback(speed: 0.1, horizontalBias: 0.25)
        #expect(r.kernel.requestedRate == 0.5)
        #expect(r.output.pan == 0.25)
        r.voice.setSpatialPitch(cents: 5000)
        #expect(r.kernel.requestedCents == 1200)
        r.voice.setAdaptivePlayback(speed: .nan, horizontalBias: 0)
        #expect(r.kernel.requestedRate == 0.5, "a non-finite speed must be ignored")
    }
}

// POPCAP (2026-11-04): a load must use a renderer pair the launch prewarm
// already built instead of building its own on the main actor.
@Suite("POPCAP: prewarmed renderers are used, not rebuilt on the main actor")
@MainActor struct PrewarmedRendererTests {

    @Test func loadTakesThePrewarmedPairAndBuildsNothingOnMain() {
        let rig = LiveSonificationAudioTests.Rig()
        let src = LiveSonificationAudioTests.tone("a")
        rig.voice.prewarmed.put(src.key, LiveSonificationAudio.makeRendererPair(src))
        #expect(rig.voice.prewarmed.count == 1)
        rig.voice.loadAudioFile(named: "a", autoplay: true)
        #expect(rig.voice.mainActorBuilds == 0, "the load must take the prewarmed pair")
        #expect(rig.voice.prewarmed.count == 0)
        #expect(rig.sound() > 0.01, "and the taken pair must sound")
    }

    @Test func withoutAPrewarmedPairTheLoadStillWorksAndCountsTheMainBuild() {
        let rig = LiveSonificationAudioTests.Rig()
        rig.voice.loadAudioFile(named: "a", autoplay: true)
        #expect(rig.voice.mainActorBuilds == 1)
        #expect(rig.sound() > 0.01)
    }
}
