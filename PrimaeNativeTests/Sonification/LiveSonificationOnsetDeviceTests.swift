// LiveSonificationOnsetDeviceTests.swift
// PrimaeNativeTests — protocol r17 DEVICE INSTRUMENT (2026-11-03)
//
// Touch -> audible onset through the real view model, the real live voice
// (`LiveSonificationAudio.production`) and the real AVAudioEngine graph, per
// arm. Method as lane LAT (LAT.md): a stroke along the
// letter's first stroke at 150 pt/s, updates at 120 Hz; onset = the first
// 5 ms window at >= -20 dB re that stroke's steady RMS, measured at the main
// mixer by a tap, timed from the FIRST MOVE; the speaker figure adds the
// session's reported `outputLatency`.
//
// SKIPS ON THE SIMULATOR (AVAudioEngine cannot run there), so it adds nothing
// to CI's evidence: it is the device instrument the r17 onset figure comes
// from, run on the iPad with the Primae scheme. It asserts the L4 bound
// (<= 70 ms at the speaker, median per arm), so it can fail. It skips unless the
// output route is the built-in speaker (T1.1): the bound does not hold on Bluetooth.

import XCTest
import Foundation
import AVFoundation
import CoreGraphics
import QuartzCore
@testable import PrimaeNative

private nonisolated let onsetIsSim: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}()

/// The 70 ms bound is a SPEAKER figure (mixer onset + the session's
/// `outputLatency`). On a Bluetooth route `outputLatency` alone is 100+ ms
/// (AirPods, 2026-11-16: 193 ms phoneme / 180 ms spatial), so the test would
/// fail for the route, not the voice. It runs only on the built-in speaker.
nonisolated enum OnsetOutputRoute {
    /// nil when every reported output is the built-in speaker; otherwise the
    /// skip message, naming the port types. An EMPTY list is "not reported
    /// yet" (the session may not be active before the first measurement), not
    /// a headphone: the test checks again once the engine has run.
    static func skipReason(outputPortTypes: [String]) -> String? {
        let speaker = AVAudioSession.Port.builtInSpeaker.rawValue
        guard outputPortTypes.allSatisfy({ $0 == speaker }) else {
            return "the 70 ms touch -> speaker bound is a built-in-speaker figure; current output route is [\(outputPortTypes.joined(separator: ","))], not \(speaker)"
        }
        return nil
    }
}

nonisolated final class OnsetRecorder: @unchecked Sendable {
    struct Seg { let host: Double; let cb: Double; let start: Int; let frames: Int }
    private let lock = NSLock()
    private var x: [Float] = []
    private var segs: [Seg] = []
    private(set) var sr: Double = 48000
    init() { x.reserveCapacity(48000 * 120) }
    /// SDK27: fed by `installAudioTap` (iOS 27), whose buffer is read-only.
    func append(_ buffer: AVReadOnlyAudioPCMBuffer, _ when: AVAudioTime) {
        let cb = CACurrentMediaTime()
        let n = buffer.frameLength
        let host = when.isHostTimeValid ? AVAudioTime.seconds(forHostTime: when.hostTime) : -1
        var l = [Float](repeating: 0, count: n)
        if case .float(let d) = buffer.channelData(0) { for i in 0..<min(n, d.count) { l[i] = d[i] } }
        lock.withLock {
            sr = buffer.format.sampleRate
            segs.append(Seg(host: host, cb: cb, start: x.count, frames: n))
            x.append(contentsOf: l)
        }
    }
    func snapshot() -> (x: [Float], segs: [Seg], sr: Double) { lock.withLock { (x, segs, sr) } }
}

final class LiveSonificationOnsetDeviceTests: XCTestCase {

    let canvas = CGSize(width: 600, height: 600)

    override func setUpWithError() throws {
        if onsetIsSim { throw XCTSkip("device instrument: AVAudioEngine does not run on the simulator") }
    }

    @MainActor private func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1e9)) }

    private struct View {
        let x: [Float]; let segs: [OnsetRecorder.Seg]; let sr: Double
        func base(_ s: OnsetRecorder.Seg) -> Double { s.host >= 0 ? s.host : s.cb - Double(s.frames) / sr }
        func index(at t: Double) -> Int {
            guard !segs.isEmpty else { return 0 }
            var best = 0
            for (k, s) in segs.enumerated() { if base(s) <= t { best = k } else { break } }
            let s = segs[best]
            return max(0, min(x.count, s.start + Int((t - base(s)) * sr)))
        }
        func rms(_ a: Double, _ b: Double) -> Double {
            let i = index(at: a), j = max(i, index(at: b)); guard j > i else { return 0 }
            var s = 0.0; for k in i..<j { s += Double(x[k] * x[k]) }; return (s / Double(j - i)).squareRoot()
        }
        func firstAbove(from a: Double, to b: Double, ref: Double, dB: Double) -> Double? {
            let thr = ref * pow(10, dB / 20); var t = a
            while t < b { if rms(t, t + 0.005) >= thr { return t }; t += 0.0025 }
            return nil
        }
    }

    @MainActor private func point(_ pts: [CGPoint], at s: CGFloat) -> CGPoint {
        var acc: CGFloat = 0
        for i in 1..<pts.count {
            let seg = hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y)
            if acc + seg >= s, seg > 0 {
                let f = (s - acc) / seg
                return CGPoint(x: pts[i-1].x + f * (pts[i].x - pts[i-1].x), y: pts[i-1].y + f * (pts[i].y - pts[i-1].y))
            }
            acc += seg
        }
        return pts.last!
    }

    /// Median move -> -20 dB at the mixer, in seconds, over `n` strokes.
    @MainActor private func measure(arm: PilotAudioCondition, n: Int = 8) async throws -> [Double] {
        let box = ThrowawayDefaults()
        let host = SoundEnvelope.makeHostEngine()
        let voice = LiveSonificationAudio.production(host: host, fadeOutSeconds: SoundEnvelope.fadeOutSeconds)
        let output = try XCTUnwrap(Mirror(reflecting: voice).descendant("output") as? SourceNodeOutput)
        let av = try XCTUnwrap(output.node.engine, "the live node is not attached to the host's graph")
        let rec = OnsetRecorder()
        av.stop()
        let mixer = av.mainMixerNode
        try mixer.installAudioTap(onBus: 0, bufferSize: 512, format: mixer.outputFormat(forBus: 0)) { [rec] b, w in rec.append(b, w) }
        output.startIfNeeded()
        await host.startGate.settle()   // SDK27: the start follows an asynchronous activation
        defer { mixer.removeTap(onBus: 0); av.stop() }

        var deps = TracingDependencies.stubReading(comparisonDefaults: box.defaults).with(audio: voice)
        deps.repo = LetterRepository(resources: BundleLetterResourceProvider(), cache: NullLetterCache())
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = arm
        deps.trainedSubset = TrainedLetterSubset.allSubsets.first { !$0.letters.contains("I") } ?? TrainedLetterSubset.allSubsets[0]
        deps.observeCueFallbackSeconds = 3600
        deps.observeCueEndToPresentationSeconds = 3600
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.loadLetter(name: "I")
        vm.phaseController.resume(at: .freeWrite)
        let cell = vm.grid.activeCell.frame
        let fr = (cell.width > 0 && cell.height > 0) ? cell : CGRect(origin: .zero, size: canvas)
        let cps = vm.strokeTracker.definition?.strokes.first?.checkpoints ?? []
        let path = cps.map { CGPoint(x: fr.minX + CGFloat($0.x) * fr.width, y: fr.minY + CGFloat($0.y) * fr.height) }
        XCTAssertGreaterThan(path.count, 1, "no stroke to trace")
        await sleep(1.5)                         // the off-main prewarm adopts its renderers

        var onsets: [Double] = []
        var contaminated = 0
        for _ in 0..<n {
            // ENV3 (2026-11-05): the clock starts at the TOUCH-DOWN. It used to start at the first move sample, 50 ms later, and the
            // sound is already requested by `beginTouch`: the first-above-threshold search then began after the onset and every
            // run returned its own lower bound (-50.0 ms), so "median -50" was a clamp, not a latency.
            // Each run is a cold start: the adaptive hold would otherwise follow this loop's own 1.7 s gaps (hold 2.1 s+), the previous
            // stroke's sound would still be held at the next touch-down, and the run would measure a resume, not an onset.
            vm.strokeTempo = StrokeTempo()
            vm.playback.idleDebounceSeconds = SoundEnvelope.stallSeconds
            let tDown = CACurrentMediaTime()
            vm.beginTouch(at: point(path, at: 0), t: tDown)
            await sleep(0.05)
            var s: CGFloat = 0; var prev = CACurrentMediaTime(); var tFirst: Double?
            let stop = prev + 0.9
            while true {
                await sleep(1.0 / 120.0)
                let t = CACurrentMediaTime(); s += CGFloat(150 * (t - prev)); prev = t
                if tFirst == nil { tFirst = t }
                vm.updateTouch(at: point(path, at: s), t: t, canvasSize: canvas)
                if t >= stop { break }
            }
            vm.endTouch()
            await sleep(1.7)                     // the 0.8 s lift hold + the 0.4 s fade (+ margin) are over; stays under the 2.0 s free-write quiet window (longer ends the trial and refuses the next touch)
            guard tFirst != nil else { continue }
            let tm = tFirst!                      // the stroke's first move sample: `beginTouch` alone starts no sound (measured: onset from touch-down = 50 ms + latency)
            let snap = rec.snapshot()
            let v = View(x: snap.x, segs: snap.segs, sr: snap.sr)
            let ref = v.rms(tm + 0.5, tm + 0.85)
            // A run whose 45 ms BEFORE the touch-down already holds sound above the threshold (a previous stroke's tail, a prompt) is
            // contaminated: its first-above point is the window start, not a latency. Counted, not averaged in.
            let pre = v.rms(tm - 0.045, tm - 0.005)
            print(String(format: "R17 ONSET run ref=%.5f pre=%.5f (%.1f dB re ref)", ref, pre, 20 * log10(max(pre, 1e-9) / max(ref, 1e-9))))
            if ref > 0, pre >= ref * pow(10, -20.0 / 20) { contaminated += 1; continue }
            if ref > 0, let o = v.firstAbove(from: tm - 0.005, to: tm + 0.5, ref: ref, dB: -20) { onsets.append(o - tm) }
        }
        print("R17 ONSET runs=\(n) valid=\(onsets.count) contaminated-by-pre-sound=\(contaminated)")
        return onsets
    }

    @MainActor func testTouchToOnsetPerArm() async throws {
        let failures = try await OnsetPerArmRun.live(measure: { try await self.measure(arm: $0) })
            .run(engine: LiveSonificationKernel.engineStamp)
        XCTAssertTrue(failures.isEmpty, "touch -> speaker onset above the 70 ms bound: \(failures)")
    }
}

/// The per-arm run and its route guard, with the session's facts and the
/// measurement injected (T1.1 residual, 2026-11-24). `testTouchToOnsetPerArm`
/// runs it against `AVAudioSession.sharedInstance()` and the real engine;
/// `OnsetPerArmRunTests` runs it against a stubbed route and a stubbed
/// measurement, so the skip decision AND its enforcement (the two `throw`s)
/// are exercised in the normal suite, not only by the device instrument
/// with headphones attached.
@MainActor struct OnsetPerArmRun {
    /// Output port types of the current route (`AVAudioSession.Port` raw values).
    var outputPorts: () -> [String]
    var outputLatency: () -> Double
    /// "io=… sr=…" for the log line.
    var sessionFormat: () -> String
    var measure: (PilotAudioCondition) async throws -> [Double]
    var settle: () async -> Void

    static func live(measure: @escaping (PilotAudioCondition) async throws -> [Double]) -> OnsetPerArmRun {
        let ses = AVAudioSession.sharedInstance()
        return OnsetPerArmRun(
            outputPorts: { ses.currentRoute.outputs.map { $0.portType.rawValue } },
            outputLatency: { ses.outputLatency },
            sessionFormat: { String(format: "io=%.2f ms sr=%.0f", ses.ioBufferDuration * 1000, ses.sampleRate) },
            measure: measure,
            settle: { try? await Task.sleep(nanoseconds: 500_000_000) })
    }

    /// The L4 bound failures, one per arm whose median touch -> speaker onset
    /// exceeds 70 ms. Throws `XCTSkip` when the route is not the built-in speaker.
    func run(engine: String) async throws -> [String] {
        // Before measuring anything: a run on headphones is a skip, not a pass or a false failure.
        if let why = OnsetOutputRoute.skipReason(outputPortTypes: outputPorts()) {
            throw XCTSkip(why)
        }
        var failures: [String] = []
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let o = try await measure(arm).sorted()
            let out = outputLatency()
            let routePorts = outputPorts()
            let route = routePorts.joined(separator: ",")
            // The session is active now: re-check, in case the first look found no route yet.
            if let why = OnsetOutputRoute.skipReason(outputPortTypes: routePorts) { throw XCTSkip(why) }
            guard !o.isEmpty else { failures.append("\(engine) \(arm): no onset"); continue }
            let med = o[o.count / 2]
            print(String(format: "R17 ONSET engine=%@ arm=%@ N=%d mixer med=%.1f min=%.1f max=%.1f ms | outputLatency=%.1f ms %@ route=%@ | speaker med=%.1f max=%.1f ms",
                         engine, "\(arm)", o.count, med * 1000, o.first! * 1000, o.last! * 1000,
                         out * 1000, sessionFormat(), route,
                         (med + out) * 1000, (o.last! + out) * 1000))
            if med + out > 0.070 { failures.append(String(format: "%@ %@: %.1f ms", engine, "\(arm)", (med + out) * 1000)) }
            await settle()
        }
        return failures
    }
}

/// The route guard's decision, as a plain function. Runs on the simulator too
/// (it touches no engine), unlike the device instrument above.
final class OnsetOutputRouteTests: XCTestCase {
    func testOnlyTheBuiltInSpeakerRunsTheBound() {
        let speaker = AVAudioSession.Port.builtInSpeaker.rawValue
        XCTAssertNil(OnsetOutputRoute.skipReason(outputPortTypes: [speaker]))
        XCTAssertNil(OnsetOutputRoute.skipReason(outputPortTypes: []), "no route reported yet is not a headphone")
        for port in [AVAudioSession.Port.bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .headphones, .airPlay, .usbAudio, .builtInReceiver] {
            let why = OnsetOutputRoute.skipReason(outputPortTypes: [port.rawValue])
            XCTAssertNotNil(why, "\(port.rawValue) must skip")
            XCTAssertTrue(why?.contains(port.rawValue) ?? false, "the message names the route port type")
        }
        XCTAssertNotNil(OnsetOutputRoute.skipReason(outputPortTypes: [speaker, AVAudioSession.Port.bluetoothA2DP.rawValue]),
                        "the speaker plus another output is not the speaker alone")
    }
}

/// The run's route guard ENFORCED, not just decided: a non-speaker route must
/// end the run in `XCTSkip` before the measurement it guards. Stubbed route and
/// measurement, so it runs on the simulator and in CI.
final class OnsetPerArmRunTests: XCTestCase {
    private let speaker = AVAudioSession.Port.builtInSpeaker.rawValue

    @MainActor private func run(ports: @escaping (Int) -> [String], latency: Double = 0.010,
                                onsets: [Double] = [0.020, 0.030, 0.040]) async -> (skipped: Bool, measured: [PilotAudioCondition], failures: [String]?) {
        var calls = 0
        var measured: [PilotAudioCondition] = []
        let r = OnsetPerArmRun(
            outputPorts: { defer { calls += 1 }; return ports(calls) },
            outputLatency: { latency },
            sessionFormat: { "stub" },
            measure: { measured.append($0); return onsets },
            settle: {})
        do {
            let failures = try await r.run(engine: "stub")
            return (false, measured, failures)
        } catch is XCTSkip {
            return (true, measured, nil)
        } catch {
            XCTFail("unexpected error \(error)")
            return (false, measured, nil)
        }
    }

    @MainActor func testNonSpeakerRouteSkipsBeforeMeasuring() async {
        for port in [AVAudioSession.Port.bluetoothA2DP, .headphones] {
            let r = await run(ports: { _ in [port.rawValue] })
            XCTAssertTrue(r.skipped, "\(port.rawValue): the run must skip")
            XCTAssertEqual(r.measured, [], "\(port.rawValue): nothing is measured on a non-speaker route")
        }
    }

    @MainActor func testRouteReportedOnlyAfterActivationSkipsAfterTheFirstMeasurement() async {
        for port in [AVAudioSession.Port.bluetoothA2DP, .headphones] {
            // First look: no route reported yet (session inactive); once the engine ran, the route is the headset.
            let r = await run(ports: { $0 == 0 ? [] : [port.rawValue] })
            XCTAssertTrue(r.skipped, "\(port.rawValue): the re-check once the session is active must skip")
            XCTAssertEqual(r.measured, [.phoneme], "\(port.rawValue): the run stops at the first arm's re-check")
        }
    }

    @MainActor func testSpeakerRouteMeasuresBothArmsAndAppliesTheBound() async {
        let pass = await run(ports: { _ in [self.speaker] }, latency: 0.010)
        XCTAssertFalse(pass.skipped)
        XCTAssertEqual(pass.measured, [.phoneme, .spatial])
        XCTAssertEqual(pass.failures, [], "30 ms median + 10 ms output latency is inside 70 ms")
        let fail = await run(ports: { _ in [self.speaker] }, latency: 0.050)
        XCTAssertFalse(fail.skipped)
        XCTAssertEqual(fail.failures?.count, 2, "30 ms median + 50 ms output latency is above 70 ms, both arms")
        let none = await run(ports: { _ in [self.speaker] }, onsets: [])
        XCTAssertEqual(none.failures?.count, 2, "an arm with no onset is a failure, not a pass")
    }
}
