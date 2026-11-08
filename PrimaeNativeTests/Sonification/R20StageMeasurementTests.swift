// R20StageMeasurementTests.swift
// PrimaeNativeTests: lane R20 (audio stage measurement, 2026-11-08)
//
// MEASUREMENTS, not pins: every test prints `R20 ...` lines the report reads, and asserts only what cannot be wrong
// (that the instrument saw something). Run on the iPad, Release-Study (cost and clicks are properties of the -O build).
//   A1 render cost per call, stages ON vs OFF       (device only: mach clock)
//   A2 time constants at the real call size          (offline, runs anywhere)
//   A3 clicks / zipper at every step change          (offline)
//   A4 direction-mute chatter on a boundary pen      (touch path, offline)
// A5 (onset latency) is in R20OnsetDeviceTests.

import XCTest
import Foundation
import CoreGraphics
@testable import PrimaeNative

private nonisolated let r20IsSim: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}()

final class R20StageMeasurementTests: XCTestCase {

    /// Measurements print numbers and pin nothing (the pins are `AudioStageSmoothingTests`): they run only when asked, so CI's
    /// -Onone simulator run does not spend minutes on prints. `TEST_RUNNER_R20_INSTRUMENTS=1` (see `r20InstrumentsEnabled`).
    override func setUpWithError() throws {
        if !r20InstrumentsEnabled { throw XCTSkip("measurements: run with TEST_RUNNER_R20_INSTRUMENTS=1") }
    }

    static let patterns: [R20.Pattern] = [.ipad, .fixed(128), .fixed(256), .fixed(512), .fixed(1024)]

    private func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "n/a" }

    // MARK: A1 cost

    private enum Cfg: String, CaseIterable { case off, tone, mute, pressure, rough, all }

    private func configure(_ k: LiveSonificationKernel, _ c: Cfg) {
        switch c {
        case .off: break
        case .tone: k.setStrokeLevel(gainDB: -12); k.setStrokeLowpass(cutoffHz: 800)
        case .mute: k.setStrokeMute(true)
        case .pressure: k.setPressureGain(0.5)
        case .rough: k.setRoughness(1)
        case .all:
            k.setStrokeLevel(gainDB: -12); k.setStrokeLowpass(cutoffHz: 800); k.setPressureGain(0.5); k.setRoughness(1)
        }
    }

    /// µs per render call over `seconds` of sound (1 s of warm-up discarded), pressure written every call.
    private func cost(_ src: StudySource, _ c: Cfg, seconds: Double) -> [Double] {
        let d = R20.Driver(source: src)
        configure(d.kernel, c)
        d.run(1.0)
        var us = [Double]()
        let tb: mach_timebase_info_data_t = { var x = mach_timebase_info_data_t(); mach_timebase_info(&x); return x }()
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { buf.deallocate() }
        var k = 1000
        let calls = Int(seconds * R20.sr / 235.2)
        for i in 0..<calls {
            let n = R20.Pattern.ipad.size(k); k += 1
            if c == .pressure || c == .all { d.kernel.setPressureGain(i % 2 == 0 ? 0.4 : 0.6) }
            let a = mach_absolute_time()
            _ = d.kernel.render(into: buf, frames: n)
            let b = mach_absolute_time()
            us.append(Double((b &- a) * UInt64(tb.numer) / UInt64(tb.denom)) / 1000)
        }
        return us
    }

    func testA1_RenderCostPerBuffer() throws {
        if r20IsSim { throw XCTSkip("device instrument: the simulator's clock and CPU say nothing about the iPad") }
        let sources = try ["spatial_carrier", "A_phoneme1", "I_phoneme1"].map { try StudySources.load($0) }
        var acc: [String: [Double]] = [:]
        let reps = 20
        for rep in 0..<reps {
            // alternate the order each repetition so neither a warm cache nor thermal drift favours a configuration
            let order = rep % 2 == 0 ? Cfg.allCases : Cfg.allCases.reversed()
            for src in sources {
                for c in order { acc["\(src.name)/\(c.rawValue)", default: []] += cost(src, c, seconds: 10) }
            }
        }
        let budget = 235.2 / R20.sr * 1e6
        print(String(format: "R20 COST budget per call = %.0f us (235.2 frames at 44.1 kHz = the iPad's 5.33 ms I/O buffer); %d reps x 10 s per sound/config", budget, reps))
        for src in sources {
            for c in Cfg.allCases {
                let v = acc["\(src.name)/\(c.rawValue)"] ?? []
                print(String(format: "R20 COST src=%@ cfg=%@ calls=%d mean=%.2f p50=%.2f p99=%.2f p99.9=%.2f max=%.2f us | mean=%.3f%% p99=%.3f%% of budget",
                             src.name, c.rawValue, v.count, R20.mean(v), R20.percentile(v, 0.5), R20.percentile(v, 0.99),
                             R20.percentile(v, 0.999), v.max() ?? 0, 100 * R20.mean(v) / budget, 100 * R20.percentile(v, 0.99) / budget))
            }
        }
        XCTAssertGreaterThan(acc.count, 0)
    }

    // MARK: A2 time constants

    func testA2_TimeConstantsAtTheRealCallSize() throws {
        let src = try StudySources.load("spatial_carrier")
        for pattern in Self.patterns {
            func pair(_ before: (LiveSonificationKernel) -> Void, _ onEvent: (LiveSonificationKernel) -> Void,
                      settle: Double, after: Double) -> (on: R20.Driver, off: R20.Driver, n0: Int) {
                let on = R20.Driver(source: src, pattern: pattern), off = R20.Driver(source: src, pattern: pattern)
                before(on.kernel)
                on.run(0.3 + settle); off.run(0.3 + settle)
                let n0 = on.count
                onEvent(on.kernel)
                on.run(after); off.run(after)
                return (on, off, n0)
            }
            // tone gain, down and up (cutoff untouched)
            do {
                let p = pair({ _ in }, { $0.setStrokeLevel(gainDB: -12) }, settle: 0, after: 0.5)
                let g = R20.gainProgress(on: p.on.y, off: p.off.y, step: p.n0, g0: 1, g1: pow(10, -12 / 20), span: 0.5)
                print("R20 TC \(pattern) level -12 dB (down): tau63=\(fmt(R20.tc(g.pts).tau63)) t90=\(fmt(R20.tc(g.pts).t90)) t99=\(fmt(R20.tc(g.pts).t99)) ms")
                let q = pair({ $0.setStrokeLevel(gainDB: -12) }, { $0.setStrokeLevel(gainDB: 0) }, settle: 0.5, after: 0.5)
                let h = R20.gainProgress(on: q.on.y, off: q.off.y, step: q.n0, g0: pow(10, -12 / 20), g1: 1, span: 0.5)
                print("R20 TC \(pattern) level 0 dB (up): tau63=\(fmt(R20.tc(h.pts).tau63)) t90=\(fmt(R20.tc(h.pts).t90)) t99=\(fmt(R20.tc(h.pts).t99)) ms")
            }
            // mute on / off
            do {
                let p = pair({ _ in }, { $0.setStrokeMute(true) }, settle: 0, after: 0.5)
                let g = R20.gainProgress(on: p.on.y, off: p.off.y, step: p.n0, g0: 1, g1: 0, span: 0.5)
                let t = R20.tc(g.pts, tMinus60: g.tMinus60)
                print("R20 TC \(pattern) mute ON: tau63=\(fmt(t.tau63)) t90=\(fmt(t.t90)) t99=\(fmt(t.t99)) -60dB=\(fmt(t.tMinus60)) ms")
                let q = pair({ $0.setStrokeMute(true) }, { $0.setStrokeMute(false) }, settle: 0.5, after: 0.5)
                let h = R20.gainProgress(on: q.on.y, off: q.off.y, step: q.n0, g0: 0, g1: 1, span: 0.5)
                print("R20 TC \(pattern) mute OFF (unmute): tau63=\(fmt(R20.tc(h.pts).tau63)) t90=\(fmt(R20.tc(h.pts).t90)) t99=\(fmt(R20.tc(h.pts).t99)) ms")
            }
            // cutoff 20 kHz -> 800 Hz and back
            do {
                let p = pair({ _ in }, { $0.setStrokeLowpass(cutoffHz: 800) }, settle: 0, after: 0.5)
                let trk = R20.cutoffTrack(on: p.on.y, off: p.off.y, starts: p.on.starts, from: p.n0)
                let t = R20.tc(R20.cutoffProgress(trk, f0: 20000, f1: 800))
                let first = trk.prefix(4).map { String(format: "%.0f", $0.hz) }.joined(separator: ",")
                print("R20 TC \(pattern) cutoff 20k -> 800 Hz (down, log domain): tau63=\(fmt(t.tau63)) t90=\(fmt(t.t90)) t99=\(fmt(t.t99)) ms; first calls Hz=\(first)")
                let q = pair({ $0.setStrokeLowpass(cutoffHz: 800) }, { $0.setStrokeLowpass(cutoffHz: 20000) }, settle: 0.5, after: 0.5)
                let trk2 = R20.cutoffTrack(on: q.on.y, off: q.off.y, starts: q.on.starts, from: q.n0)
                let u = R20.tc(R20.cutoffProgress(trk2, f0: 800, f1: 20000))
                print("R20 TC \(pattern) cutoff 800 -> 20k Hz (up): tau63=\(fmt(u.tau63)) t90=\(fmt(u.t90)) t99=\(fmt(u.t99)) ms")
            }
            // pressure gain 1 -> -18 dB and back
            do {
                let lo = Float(pow(10, -18.0 / 20))
                let p = pair({ _ in }, { $0.setPressureGain(lo) }, settle: 0, after: 0.5)
                let g = R20.gainProgress(on: p.on.y, off: p.off.y, step: p.n0, g0: 1, g1: Double(lo), span: 0.5)
                print("R20 TC \(pattern) pressure 1 -> -18 dB (down): tau63=\(fmt(R20.tc(g.pts).tau63)) t90=\(fmt(R20.tc(g.pts).t90)) t99=\(fmt(R20.tc(g.pts).t99)) ms")
                let q = pair({ $0.setPressureGain(lo) }, { $0.setPressureGain(1) }, settle: 0.5, after: 0.5)
                let h = R20.gainProgress(on: q.on.y, off: q.off.y, step: q.n0, g0: Double(lo), g1: 1, span: 0.5)
                print("R20 TC \(pattern) pressure -18 dB -> 1 (up): tau63=\(fmt(R20.tc(h.pts).tau63)) t90=\(fmt(R20.tc(h.pts).t90)) t99=\(fmt(R20.tc(h.pts).t99)) ms")
            }
            // roughness depth 0 -> 0.8 (start) and 0.8 -> 0 (stop)
            do {
                let p = pair({ _ in }, { $0.setRoughness(1) }, settle: 0, after: 0.4)
                let trk = R20.depthTrack(on: p.on.y, off: p.off.y, starts: p.on.starts, from: p.n0, rateHz: 40)
                let pts = trk.map { (ms: $0.ms, p: $0.d / Double(RoughnessTuning.maxDepth)) }
                print("R20 TC \(pattern) roughness depth 0 -> 0.8 (start): tau63=\(fmt(R20.tc(pts).tau63)) t90=\(fmt(R20.tc(pts).t90)) t99=\(fmt(R20.tc(pts).t99)) ms; settled depth=\(String(format: "%.3f", trk.last?.d ?? 0))")
            }
        }
        XCTAssertTrue(true)
    }

    // MARK: A3 clicks

    func testA3_ClicksAndZipperAtStepChanges() throws {
        for name in ["spatial_carrier", "I_phoneme1", "A_phoneme1"] {
            let src = try StudySources.load(name)
            let steady = R20.Driver(source: src)
            steady.run(1.5)
            func show(_ label: String, _ y: [Float], at n0: Int, window: Double = 0.040) {
                let c = R20.click(y, steady: steady.y, at: n0, window: window)
                print(String(format: "R20 CLICK src=%@ %@ (window %.0f ms): splatter=%+.1f dB slope=%+.1f dB maxDelta=%.2fx steady", name, label, window * 1000, c.splatterDB, c.slopeDB, c.deltaRatio))
            }
            /// A transition: `before` settles for `settle` s, then `event`, then `after` s; returns y and the step index.
            func trans(_ before: (LiveSonificationKernel) -> Void, settle: Double, _ event: (LiveSonificationKernel) -> Void,
                       after: Double = 0.6) -> ([Float], Int) {
                let d = R20.Driver(source: src)
                before(d.kernel)
                d.run(0.4 + settle)
                let n0 = d.count
                event(d.kernel)
                d.run(after)
                return (d.y, n0)
            }
            // r17's own references: the stop fade (linear 0.4 s), the letter-end raised cosine (50 ms), the 8 ms onset from silence
            do {
                let (y, n0) = trans({ _ in }, settle: 0.4, { $0.close(fadeOutFrames: UInt32(0.4 * R20.sr)) }, after: 0.6)
                show("REF r17 stop fade linear 0.4 s", y, at: n0)
                let (y2, n2) = trans({ _ in }, settle: 0.4, { $0.closeRaisedCosine(frames: UInt32(0.05 * R20.sr)) }, after: 0.3)
                show("REF r17 letter-end raised cosine 50 ms", y2, at: n2, window: 0.050)
                let d = R20.Driver(source: src); d.run(0.5)
                if let on = PopMeter.silenceOnsets(d.y, sr: R20.sr).first?.index ?? SonificationMetrics.firstNonZero(d.y, from: 0) {
                    show("REF r17 onset from silence (8 ms raised cosine)", d.y, at: on, window: 0.010)
                    show("REF r17 onset from silence (8 ms raised cosine)", d.y, at: on)
                }
            }
            let lo = Float(pow(10, -18.0 / 20))
            // stages
            struct Step { let label: String; let before: (LiveSonificationKernel) -> Void; let settle: Double
                          let event: (LiveSonificationKernel) -> Void }
            let none: (LiveSonificationKernel) -> Void = { _ in }
            let steps: [Step] = [
                Step(label: "mute ON", before: none, settle: 0, event: { $0.setStrokeMute(true) }),
                Step(label: "mute OFF", before: { $0.setStrokeMute(true) }, settle: 0.5, event: { $0.setStrokeMute(false) }),
                Step(label: "level 0 -> -12 dB", before: none, settle: 0, event: { $0.setStrokeLevel(gainDB: -12) }),
                Step(label: "level -12 -> 0 dB", before: { $0.setStrokeLevel(gainDB: -12) }, settle: 0.5, event: { $0.setStrokeLevel(gainDB: 0) }),
                Step(label: "cutoff 20k -> 800 Hz", before: none, settle: 0, event: { $0.setStrokeLowpass(cutoffHz: 800) }),
                Step(label: "cutoff 800 -> 20k Hz", before: { $0.setStrokeLowpass(cutoffHz: 800) }, settle: 0.5, event: { $0.setStrokeLowpass(cutoffHz: 20000) }),
                Step(label: "distance far (-12 dB + 800 Hz) ON", before: none, settle: 0, event: { $0.setStrokeLevel(gainDB: -12); $0.setStrokeLowpass(cutoffHz: 800) }),
                Step(label: "pressure 1 -> -18 dB", before: none, settle: 0, event: { $0.setPressureGain(lo) }),
                Step(label: "pressure -18 dB -> 1", before: { $0.setPressureGain(lo) }, settle: 0.5, event: { $0.setPressureGain(1) }),
                Step(label: "roughness start (0.8 @ 40 Hz)", before: none, settle: 0, event: { $0.setRoughness(1) }),
                Step(label: "roughness stop", before: { $0.setRoughness(1) }, settle: 0.6, event: { $0.setRoughness(0) }),
            ]
            for s in steps {
                let (y, n0) = trans(s.before, settle: s.settle, s.event)
                show(s.label, y, at: n0)
            }
            // steady rasp itself (the modulation is the effect; its own splatter is the floor of the roughness stage)
            do {
                let (y, n0) = trans({ $0.setRoughness(1) }, settle: 0.6, { _ in }, after: 0.5)
                show("roughness steady (0.8 @ 40 Hz, no event)", y, at: n0)
            }
            // a Pencil force ramp written at the touch rate (120 Hz): force 1 -> 0.3 over 0.5 s, staircase of per-call ramps
            do {
                let d = R20.Driver(source: src)
                d.run(0.4)
                let n0 = d.count
                for i in 0..<60 {
                    let f = 1 - 0.7 * Double(i) / 59
                    d.kernel.setPressureGain(Float(pow(10, -18 * (1 - f) / 20)))
                    d.run(1.0 / 120)
                }
                d.run(0.3)
                show("pressure ramp 1 -> 0.3 force at 120 Hz", d.y, at: n0, window: 0.5)
            }
        }
        XCTAssertTrue(true)
    }

    // MARK: B: the smoothing sweep (new kernel only)

    /// Click metrics for each candidate time constant (gain, cutoff and pressure together), and the SVF candidate.
    func testB_SmoothingSweep() throws {
        let lo = Float(pow(10, -18.0 / 20))
        for name in ["spatial_carrier", "I_phoneme1", "A_phoneme1"] {
            let src = try StudySources.load(name)
            let steady = R20.Driver(source: src); steady.run(1.5)
            for tau in [0.003, 0.006, 0.012, 0.020, 0.030] {
                for slope in [LiveSonificationKernel.LowpassSlope.sixDB, .twelveDB] {
                    func trans(_ before: (LiveSonificationKernel) -> Void, settle: Double, _ event: (LiveSonificationKernel) -> Void) -> ([Float], Int) {
                        let d = R20.Driver(source: src, make: {
                            LiveSonificationKernel(smoothing: .init(toneGainSeconds: tau, toneCutoffSeconds: tau, pressureSeconds: tau))
                        })
                        d.kernel.setStrokeLowpassSlope(slope)
                        before(d.kernel)
                        d.run(0.4 + settle)
                        let n0 = d.count
                        event(d.kernel)
                        d.run(0.6)
                        return (d.y, n0)
                    }
                    let cases: [(String, (LiveSonificationKernel) -> Void, Double, (LiveSonificationKernel) -> Void)] = [
                        ("mute ON", { _ in }, 0, { $0.setStrokeMute(true) }),
                        ("cutoff 20k->800", { _ in }, 0, { $0.setStrokeLowpass(cutoffHz: 800) }),
                        ("cutoff 800->20k", { $0.setStrokeLowpass(cutoffHz: 800) }, 0.5, { $0.setStrokeLowpass(cutoffHz: 20000) }),
                        ("pressure 1->-18dB", { _ in }, 0, { $0.setPressureGain(lo) }),
                    ]
                    for (label, before, settle, event) in cases {
                        let (y, n0) = trans(before, settle: settle, event)
                        let c = R20.click(y, steady: steady.y, at: n0, window: 0.040)
                        print(String(format: "R20 SWEEP tau=%.0f ms slope=%@ src=%@ %@: splatter=%+.1f dB slope=%+.1f dB maxDelta=%.2fx", tau * 1000,
                                     slope == .sixDB ? "6dB" : "12dB", name, label, c.splatterDB, c.slopeDB, c.deltaRatio))
                    }
                }
            }
        }
        XCTAssertTrue(true)
    }

    // MARK: A4 chatter

    @MainActor func testB_ChatterHysteresisSweep() {
        for margin in [Float(0), 0.1, 0.2, 0.3, 0.4] {
            let lat = R20Pen.reversalLatency(margin: margin)
            print(String(format: "R20 HYST margin=%.1f (release above cos %.2f): reversal -> mute %@ ms, turn back -> unmute %@ ms", margin,
                         StrokeTone.backwardCosine + margin, lat.mute.map { String(format: "%.0f", $0) } ?? "never", lat.unmute.map { String(format: "%.0f", $0) } ?? "never"))
            for (base, wobble) in [(104.5, 0.0), (104.5, 8.0), (97.0, 15.0)] {
                var row = ""
                for sigma in [0.3, 0.7, 1.5] {
                    let r = R20Pen.chatter(base: base, wobble: wobble, sigma: sigma, margin: margin)
                    row += String(format: " jitter %.1f: %.2f/s (flickers %d);", sigma, r.toggles, r.flickers)
                }
                print(String(format: "R20 HYST margin=%.1f heading %.1f +- %.0f deg (ideal crossings /s see A4):%@", margin, base, wobble, row))
            }
        }
        XCTAssertTrue(true)
    }

    @MainActor func testA4_DirectionMuteChatter() {
        for (base, wobble) in [(104.5, 0.0), (104.5, 8.0), (97.0, 15.0)] {
            for sigma in [0.0, 0.3, 0.7, 1.5] {
                let r = R20Pen.chatter(base: base, wobble: wobble, sigma: sigma)
                print(String(format: "R20 CHATTER heading %.1f deg +- %.0f deg wobble, jitter %.1f pt: mute toggles %.2f /s (ideal boundary crossings %.2f /s), flickers (<100 ms) %d, muted %.0f %% of samples",
                             base, wobble, sigma, r.toggles, r.crossings, r.flickers, 100 * r.mutedFraction))
            }
        }
        XCTAssertTrue(true)
    }
}

