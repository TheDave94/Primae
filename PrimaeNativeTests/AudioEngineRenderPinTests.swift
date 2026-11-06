// AudioEngineRenderPinTests.swift — device pins for the bounded AudioEngine
// override of 2026-11-02 (FIXPLAN C1, C2, C3; audit exp2 AUDIO-1, AUDIO-2,
// AUDIO-6). Each test drives the REAL `AudioEngine` and reads what its main
// mixer actually rendered through a tap, rather than asserting on
// `isPlaying` (which the route/stop/suspend tests in AudioEngineTests showed
// cannot fail). Physical iPad only: AVAudioEngine cannot run on the
// simulator, so these skip there (and so in CI).
//
// XCTest, not Swift Testing, on purpose. The audio session is process-global
// state, and Swift Testing runs suites in parallel: measured on the iPad in
// the full suite, a Swift Testing version of these pins failed beside the
// device speech tests (`SpeechQueueTests`) because both drove the one
// session, and the main actor, which the engine's fade steps and loop
// re-scheduling run on, was starved for seconds at a time. XCTest cases run
// serially, before the Swift Testing run starts, with nothing beside them.
//
// The tap goes on the engine the AudioEngine owns, reached through `Mirror`
// so that AudioEngine.swift carries no test hook. The tap closure is built in
// a `nonisolated` context (AudioSignalProbe's realtime-thread lesson).

import XCTest
import Foundation
import AVFoundation
import QuartzCore
@testable import PrimaeNative

private nonisolated let renderPinIsSimulator: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}()

/// Stores every rendered sample (mono mean of the channels) in render order.
/// Analysis is by SAMPLE INDEX, not wall-clock time: if the main actor is
/// late, command times drift from the rendered timeline, so windows are
/// anchored on how many samples had been rendered when a command was issued.
nonisolated final class RenderPinRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private(set) var sampleRate: Double = 48000

    init() { samples.reserveCapacity(48000 * 60) }

    func append(_ buffer: AVReadOnlyAudioPCMBuffer, _ when: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        let nch = max(1, Int(buffer.format.channelCount))
        let interleaved = buffer.format.isInterleaved
        var mono = [Float](repeating: 0, count: frames)
        buffer.withUnsafeAudioBufferList { abl in
            let blocks = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            if interleaved, let d = blocks.first?.mData {
                let p = d.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { var s: Float = 0; for c in 0..<nch { s += p[i * nch + c] }; mono[i] = s / Float(nch) }
            } else {
                let n = blocks.count
                for b in 0..<n { if let d = blocks[b].mData {
                    let p = d.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { mono[i] += p[i] / Float(n) }
                } }
            }
        }
        lock.withLock {
            sampleRate = buffer.format.sampleRate
            samples.append(contentsOf: mono)
        }
    }

    static func install(on av: AVAudioEngine, recorder: RenderPinRecorder) throws {
        let mixer = av.mainMixerNode
        let format = mixer.outputFormat(forBus: 0)
        try mixer.installAudioTap(onBus: 0, bufferSize: 512, format: format,
                                  tapProvider: { (b: AVReadOnlyAudioPCMBuffer, w: AVAudioTime) in recorder.append(b, w) })
    }

    /// Samples rendered so far.
    var count: Int { lock.withLock { samples.count } }

    /// RMS per `step`-second bin over samples [from, to).
    func bins(from: Int, to: Int? = nil, step: Double = 0.02) -> [Double] {
        lock.withLock {
            let n = max(1, Int(sampleRate * step))
            let end = min(to ?? samples.count, samples.count)
            var out: [Double] = []
            var i = max(0, from)
            while i + n <= end {
                var sum = 0.0
                for k in i..<(i + n) { let v = Double(samples[k]); sum += v * v }
                out.append((sum / Double(n)).squareRoot()); i += n
            }
            return out
        }
    }

    /// True if the most recent 20 ms of rendered audio is louder than `floor` RMS.
    func tailIsAudible(floor: Double = 1e-3) -> Bool {
        let c = count
        return (bins(from: max(0, c - Int(sampleRate * 0.02))).last ?? 0) > floor
    }

    /// Seconds of rendered audio louder than `floor` RMS (20 ms bins) since `from`.
    func audibleSeconds(from: Int, floor: Double = 1e-3) -> Double {
        Double(bins(from: from).filter { $0 > floor }.count) * 0.02
    }
}

final class AudioEngineRenderPinTests: XCTestCase {

    static let carrier = "Resources/Sonification/spatial_carrier.wav"

    override func setUpWithError() throws {
        if renderPinIsSimulator { throw XCTSkip("AVAudioEngine needs real hardware") }
    }

    /// A real engine with a recorder on its main mixer.
    @MainActor func makeRig() throws -> (AudioEngine, AVAudioEngine, RenderPinRecorder) {
        let engine = SoundEnvelope.makeHostEngine()
        let av = try XCTUnwrap(Mirror(reflecting: engine).children.first { $0.label == "engine" }?.value as? AVAudioEngine,
                               "AudioEngine's stored AVAudioEngine must be reachable")
        let recorder = RenderPinRecorder()
        try RenderPinRecorder.install(on: av, recorder: recorder)
        return (engine, av, recorder)
    }

    @MainActor func teardown(_ engine: AudioEngine, _ av: AVAudioEngine) {
        engine.fadeOutSeconds = 0
        engine.stop()
        av.mainMixerNode.removeTap(onBus: 0)
        av.stop()
    }

    func sleep(_ s: Double) async throws { try await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    func dB(_ x: Double, _ ref: Double) -> Double { x <= 0 ? -200 : 20 * log10(x / ref) }

    @MainActor func postInterruption(began: Bool) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey:
            NSNumber(value: (began ? AVAudioSession.InterruptionType.began : .ended).rawValue)]
        if !began { info[AVAudioSessionInterruptionOptionKey] = NSNumber(value: AVAudioSession.InterruptionOptions.shouldResume.rawValue) }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(), userInfo: info)
    }

    /// Polls `cond` every 20 ms; false if it never held within `timeout`.
    @MainActor func waitUntil(_ timeout: Double, _ cond: @escaping () -> Bool) async throws -> Bool {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if cond() { return true }
            try await sleep(0.02)
        }
        return cond()
    }

    /// Plays the carrier until at least `seconds` of it have actually rendered
    /// AND it is sounding right now. The engine re-schedules its loop through a
    /// main-queue hop, so a late main actor leaves a gap of silence after each
    /// 2 s pass of the carrier (measured under load: ~8 s); a stop issued in
    /// that gap tests nothing. Returns the sample index at which play() was
    /// issued, or nil (after recording the failure) if it never sounded.
    @MainActor func playCarrier(_ engine: AudioEngine, _ rec: RenderPinRecorder, seconds: Double) async throws -> Int? {
        engine.setAdaptivePlayback(speed: 1, horizontalBias: 0)
        engine.loadAudioFile(named: Self.carrier, autoplay: false)
        let i0 = rec.count
        engine.play()
        let audible = try await waitUntil(15) { rec.audibleSeconds(from: i0) >= seconds && rec.tailIsAudible() }
        guard audible else { XCTFail("the carrier never rendered \(seconds) s of sound"); return nil }
        return i0
    }

    // C1 (AUDIO-1): after a faded stop the level must not come back. Before the
    // fix the time-pitch unit's ~93 ms of buffered audio played at FULL level
    // once finishStop restored the volume, ~0.5 s after stop().
    @MainActor func testC1_fadedStopHasNoBurst() async throws {
        // A stop that lands in a loop gap (see playCarrier) is retried, at most
        // three times: the first 60 ms after stop() must still be sounding, or
        // the attempt did not exercise a fade at all.
        for attempt in 1...3 {
            let (engine, av, rec) = try makeRig()
            defer { teardown(engine, av) }
            guard let i0 = try await playCarrier(engine, rec, seconds: 1.0) else { return }
            let iStop = rec.count
            engine.stop()
            let finished = try await waitUntil(15) { engine.isPlaying == false }
            guard finished else { XCTFail("the faded stop never finished"); return }
            let iDone = rec.count
            // Capture the tail: 0.8 s of rendered samples after finishStop ran.
            let tailRendered = try await waitUntil(15) { rec.count - iDone >= Int(rec.sampleRate * 0.8) }
            guard tailRendered else { XCTFail("the engine stopped rendering after the stop"); return }

            let ref = rec.bins(from: i0, to: iStop).max() ?? 0
            XCTAssertGreaterThan(ref, 1e-3, "the carrier must render before the stop")
            let bins = rec.bins(from: iStop).map { dB($0, ref) }
            let head = Array(bins.prefix(3))
            if head.count < 3 || !head.allSatisfy({ $0 > -10 }) {
                if attempt < 3 { continue }
                XCTFail("three stops in a row landed in silence; first bins: \(bins.prefix(10).map { Int($0) })")
                return
            }
            // The fade reaches -25 dB, and not abruptly: at least 0.15 s after it last sat within 3 dB of steady.
            guard let firstLow = bins.firstIndex(where: { $0 < -25 }) else {
                XCTFail("the fade never reached -25 dB: \(bins.map { Int($0) })"); return
            }
            let lastSteady = bins[..<firstLow].lastIndex { $0 > -3 } ?? 0
            XCTAssertGreaterThanOrEqual(Double(firstLow - lastSteady) * 0.02, 0.15,
                                        "fade envelope shortened: -3 dB to -25 dB in \(Double(firstLow - lastSteady) * 0.02) s")
            // Once faded, nothing comes back above -20 dB.
            let rebound = bins[firstLow...].max() ?? -200
            XCTAssertLessThan(rebound, -20, "post-fade rebound to \(rebound) dB re steady; 20 ms bins from stop: \(bins.map { Int($0) })")
            return
        }
    }

    // C2 (AUDIO-2): an interruption that begins during the fade-out must not
    // capture resume intent, so `.ended(shouldResume)` brings nothing back.
    // The `.began` is posted right after stop(): the observer runs before the
    // 0.4 s fade can finish.
    @MainActor func testC2_interruptionDuringFadeDoesNotResume() async throws {
        let (engine, av, rec) = try makeRig()
        defer { teardown(engine, av) }
        guard let i0 = try await playCarrier(engine, rec, seconds: 1.0) else { return }
        let iStop = rec.count
        engine.stop()
        postInterruption(began: true)
        try await sleep(0.5)
        postInterruption(began: false)
        try await sleep(0.3)
        let iEnded = rec.count
        let rendered = try await waitUntil(15) { rec.count - iEnded >= Int(rec.sampleRate * 1.5) }

        let ref = rec.bins(from: i0, to: iStop).max() ?? 0
        XCTAssertGreaterThan(ref, 1e-3, "the carrier must render before the stop")
        // Either the engine paused (nothing rendered) or what it rendered is silence.
        let after = dB(rec.bins(from: iEnded, step: 0.1).max() ?? 0, ref)
        XCTAssertTrue(!rendered || after < -40, "sound resumed with nobody touching: loudest 100 ms bin \(after) dB re steady after .ended")
        XCTAssertFalse(engine.isPlaying)
    }

    // Control for C2: an interruption while the sound is PLAYING (no fade)
    // still resumes it. Keeps the C2 fix from being "never resume".
    @MainActor func testC2Control_interruptionDuringPlaybackResumes() async throws {
        let (engine, av, rec) = try makeRig()
        defer { teardown(engine, av) }
        guard let i0 = try await playCarrier(engine, rec, seconds: 1.0) else { return }
        let iBegan = rec.count
        postInterruption(began: true)
        try await sleep(0.5)
        postInterruption(began: false)
        let iEnded = rec.count
        let resumed = try await waitUntil(15) { rec.audibleSeconds(from: iEnded) >= 0.5 }

        let ref = rec.bins(from: i0, to: iBegan).max() ?? 0
        XCTAssertGreaterThan(ref, 1e-3, "the carrier must render before the interruption")
        XCTAssertTrue(resumed, "playback did not resume after .ended(shouldResume)")
        XCTAssertTrue(engine.isPlaying)
    }

    // C3 (AUDIO-6): suspend/resume with NO file loaded (normal between
    // strokes) must cancel the suspend's pending engine pause. Before the fix
    // resumeAfterLifecycle returned at its currentFile guard first, and the
    // engine paused 0.2 s later: the mixer stops rendering.
    @MainActor func testC3_lifecycleBlipWithNoFileKeepsEngineRunning() async throws {
        let (engine, av, rec) = try makeRig()
        defer { teardown(engine, av) }
        let started = try await waitUntil(15) { rec.count > 0 }
        XCTAssertTrue(started && av.isRunning, "precondition: the engine runs after init")
        engine.suspendForLifecycle()
        engine.resumeAfterLifecycle()
        let tResume = CACurrentMediaTime()
        // Well past the 0.2 s pending pause, by wall clock (the pause is a Task.sleep).
        try await sleep(0.8)
        XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - tResume, 0.8)
        XCTAssertTrue(av.isRunning, "the engine paused after resume (the pending lifecycle pause was not cancelled)")
        let c1 = rec.count
        let grew = try await waitUntil(5) { rec.count > c1 + Int(rec.sampleRate * 0.1) }
        XCTAssertTrue(grew, "the mixer stopped rendering after the blip")
    }
}
