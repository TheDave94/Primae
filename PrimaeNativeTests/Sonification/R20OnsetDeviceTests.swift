// R20OnsetDeviceTests.swift
// PrimaeNativeTests: lane R20 (2026-11-08) DEVICE INSTRUMENT
//
// A5: touch -> audible onset with each r18 switch ON, by the method of `LiveSonificationOnsetDeviceTests` (r17: 13-16 ms
// median at the speaker; ENV3 re-measured 12.5 ms mixer / 18.3 ms speaker in Release-Study, before the R17D phoneme onsets: the
// phoneme arm now reads 22.5-27.5 ms at the mixer because the recorded onsets start quietly, the engine part is unchanged,
// docs/DECISIONS.md r20): the real view model, the real
// `LiveSonificationAudio.production` voice and AVAudioEngine graph, a stroke along the letter's first stroke at 150 pt/s
// sampled at 120 Hz, the clock at the touch-down, the onset the first 5 ms window >= -20 dB re the stroke's steady RMS at the main
// mixer (a tap), plus the same for -6 dB. SKIPS ON THE SIMULATOR. Asserts only the L4 bound (70 ms at the speaker).
//
// Scenarios (what is active at the first move):
//   off        every switch off (the r19 control)
//   distance   distance tone on, the stroke traced half a gate radius off the reference (target -6 dB / ~4 kHz from the first sample)
//   direction  direction mute on, traced forwards (the stage is armed, the tone neutral)
//   pressure   Pencil force 0.4 with pressure -> loudness on (target gain -10.8 dB)
//   roughness  dysfluency roughness on (inert at a clean stroke start: no stop-start events yet)
//   all        everything above together, off the stroke
//   off-freeWrite  the r17 method itself (free write, no reference stroke), to tie the guided numbers to ENV3's

import XCTest
import Foundation
import AVFoundation
import CoreGraphics
import QuartzCore
@testable import PrimaeNative

private nonisolated let r20OnsetIsSim: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}()

final class R20OnsetDeviceTests: XCTestCase {

    let canvas = CGSize(width: 600, height: 600)

    struct Scenario {
        var name: String
        var distance = false, direction = false, pressureForce: CGFloat? = nil, roughness = false
        var offsetGates: CGFloat = 0
        var freeWrite = false
        var configure: (LiveSonificationAudio) -> Void = { _ in }
    }

    override func setUpWithError() throws {
        if r20OnsetIsSim { throw XCTSkip("device instrument: AVAudioEngine does not run on the simulator") }
        if !r20InstrumentsEnabled { throw XCTSkip("minutes-long instrument: run with TEST_RUNNER_R20_INSTRUMENTS=1") }
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

    @MainActor private func measure(arm: PilotAudioCondition, scenario sc: Scenario, n: Int = 8) async throws -> (m20: [Double], m6: [Double]) {
        var bins: [[Double]] = Array(repeating: [], count: 24)   // 10 ms bins from the first move, dB re the steady RMS, per run
        let box = ThrowawayDefaults()
        let host = SoundEnvelope.makeHostEngine()
        let voice = LiveSonificationAudio.production(host: host, fadeOutSeconds: SoundEnvelope.fadeOutSeconds)
        sc.configure(voice)
        let output = try XCTUnwrap(Mirror(reflecting: voice).descendant("output") as? SourceNodeOutput)
        let av = try XCTUnwrap(output.node.engine, "the live node is not attached to the host's graph")
        let rec = OnsetRecorder()
        av.stop()
        let mixer = av.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 512, format: mixer.outputFormat(forBus: 0)) { [rec] b, w in rec.append(b, w) }
        output.startIfNeeded()
        defer { mixer.removeTap(onBus: 0); av.stop() }

        var deps = TracingDependencies.stubReading(comparisonDefaults: box.defaults).with(audio: voice)
        deps.repo = LetterRepository(resources: BundleLetterResourceProvider(), cache: NullLetterCache())
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = arm
        deps.trainedSubset = TrainedLetterSubset.allSubsets.first { !$0.letters.contains("I") } ?? TrainedLetterSubset.allSubsets[0]
        deps.observeCueFallbackSeconds = 3600
        deps.observeCueEndToPresentationSeconds = 3600
        deps.soundGatingEnabled = false          // the proximity gate would silence the controls' first samples; the tone stages read the reference stroke either way
        deps.distanceToneEnabled = sc.distance
        deps.directionMuteEnabled = sc.direction
        deps.pressureLoudnessEnabled = sc.pressureForce != nil
        deps.dysfluencyRoughness = sc.roughness
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        vm.loadLetter(name: "I")
        // Guided, not free write: free write has no reference stroke, so the distance and direction stages would stay neutral.
        vm.phaseController.resume(at: sc.freeWrite ? .freeWrite : .guided)
        let cell = vm.grid.activeCell.frame
        let fr = (cell.width > 0 && cell.height > 0) ? cell : CGRect(origin: .zero, size: canvas)
        let cps = vm.strokeTracker.definition?.strokes.first?.checkpoints ?? []
        let offset = sc.offsetGates * vm.strokeGateRadius() * fr.height
        let path = cps.map { CGPoint(x: fr.minX + CGFloat($0.x) * fr.width + offset, y: fr.minY + CGFloat($0.y) * fr.height) }
        XCTAssertGreaterThan(path.count, 1, "no stroke to trace")
        await sleep(1.5)

        var o20: [Double] = [], o6: [Double] = []
        var contaminated = 0
        for _ in 0..<n {
            vm.strokeTempo = StrokeTempo()
            vm.playback.idleDebounceSeconds = SoundEnvelope.stallSeconds
            if let f = sc.pressureForce { vm.pencilDidTouchDown(); vm.pencilPressure = f }
            let tDown = CACurrentMediaTime()
            vm.beginTouch(at: point(path, at: 0), t: tDown)
            await sleep(0.05)
            var s: CGFloat = 0; var prev = CACurrentMediaTime(); var tFirst: Double?
            let stop = prev + 0.9
            while true {
                await sleep(1.0 / 120.0)
                let t = CACurrentMediaTime(); s += CGFloat(150 * (t - prev)); prev = t
                if tFirst == nil { tFirst = t }
                if let f = sc.pressureForce { vm.pencilPressure = f }
                vm.updateTouch(at: point(path, at: s), t: t, canvasSize: canvas)
                if t >= stop { break }
            }
            vm.endTouch()
            await sleep(1.7)
            guard let tm = tFirst else { continue }
            let snap = rec.snapshot()
            let v = View(x: snap.x, segs: snap.segs, sr: snap.sr)
            let ref = v.rms(tm + 0.5, tm + 0.85)
            let pre = v.rms(tm - 0.045, tm - 0.005)
            print(String(format: "R20 ONSET run ref=%.5f pre=%.5f", ref, pre))
            if ref > 0, pre < ref * pow(10, -20.0 / 20) {
                for b in 0..<24 { bins[b].append(20 * log10(max(v.rms(tm + Double(b) * 0.010 - 0.010, tm + Double(b) * 0.010), 1e-9) / ref)) }
            }
            if ref > 0, pre >= ref * pow(10, -20.0 / 20) { contaminated += 1; continue }
            if ref > 0, let o = v.firstAbove(from: tm - 0.005, to: tm + 0.5, ref: ref, dB: -20) { o20.append(o - tm) }
            if ref > 0, let o = v.firstAbove(from: tm - 0.005, to: tm + 0.5, ref: ref, dB: -6) { o6.append(o - tm) }
        }
        print("R20 ONSET \(sc.name) \(arm): runs=\(n) valid=\(o20.count) contaminated=\(contaminated)")
        let env = bins.map { b in b.isEmpty ? "n/a" : String(format: "%.0f", b.sorted()[b.count / 2]) }.joined(separator: " ")
        print("R20 ONSETENV \(sc.name) \(arm): median dB re steady per 10 ms bin, -10..+230 ms from the first move: \(env)")
        return (o20, o6)
    }

    @MainActor private func run(_ sc: Scenario) async throws {
        let ses = AVAudioSession.sharedInstance()
        var failures: [String] = []
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let (a, b) = try await measure(arm: arm, scenario: sc)
            let o = a.sorted(), o6 = b.sorted()
            let out = ses.outputLatency
            guard !o.isEmpty else { failures.append("\(sc.name) \(arm): no onset"); continue }
            let med = o[o.count / 2]
            let med6 = o6.isEmpty ? Double.nan : o6[o6.count / 2]
            print(String(format: "R20 ONSET scenario=%@ arm=%@ N=%d -20dB: mixer med=%.1f min=%.1f max=%.1f ms | -6dB: mixer med=%.1f ms | outputLatency=%.1f ms io=%.2f ms | speaker(-20dB) med=%.1f max=%.1f ms",
                         sc.name, "\(arm)", o.count, med * 1000, o.first! * 1000, o.last! * 1000, med6 * 1000,
                         out * 1000, ses.ioBufferDuration * 1000, (med + out) * 1000, (o.last! + out) * 1000))
            // The L4 bound (70 ms at the speaker). A scenario that low-passes the phoneme (distance, all) is read on the spatial arm
            // only: the recorded phoneme's first 70 ms are brighter than its vowel, so darkening it moves its -20 dB point
            // (measured, A5: +15 ms), which is the sound's own shape, not a latency of the stage.
            let darkensPhoneme = sc.distance && arm == .phoneme
            if med + out > 0.070 && !darkensPhoneme { failures.append("\(sc.name) \(arm): \((med + out) * 1000) ms") }
            await sleep(0.5)
        }
        XCTAssertTrue(failures.isEmpty, "touch -> speaker onset above the 70 ms bound: \(failures)")
    }

    @MainActor func testOnset_0_off() async throws { try await run(Scenario(name: "off")) }
    @MainActor func testOnset_1_distance() async throws { try await run(Scenario(name: "distance", distance: true, offsetGates: 0.5)) }
    @MainActor func testOnset_2_direction() async throws { try await run(Scenario(name: "direction", direction: true)) }
    @MainActor func testOnset_3_pressure() async throws { try await run(Scenario(name: "pressure", pressureForce: 0.4)) }
    @MainActor func testOnset_4_roughness() async throws { try await run(Scenario(name: "roughness", roughness: true)) }
    /// r17's own method (free write): ties the guided numbers above to the 12.5 ms / 18.3 ms ENV3 measured.
    @MainActor func testOnset_6_offFreeWrite() async throws { try await run(Scenario(name: "off-freeWrite", freeWrite: true)) }
    @MainActor func testOnset_5_all() async throws {
        try await run(Scenario(name: "all", distance: true, direction: true, pressureForce: 0.4, roughness: true, offsetGates: 0.5))
    }
}
