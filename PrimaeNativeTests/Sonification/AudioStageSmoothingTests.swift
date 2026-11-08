// AudioStageSmoothingTests.swift
// PrimaeNativeTests: lane R20 (2026-11-08)
//
// Pins what R20 changed in the r18 stages, each read off the RENDERED output (the instruments are `R20StageSupport`):
//   1. the stage smoothing is in SECONDS: tone gain / mute / pressure follow a one-pole of `StageSmoothing` at every call size
//      (r18 measured on the iPad: 6.0 ms at the real 235-frame call, 13.1 ms at 512, 3.3 ms at 128);
//   2. the cutoff approach is in seconds too, and OPENING the filter no longer steps the signal (r18: 4.3x the sound's own largest
//      sample-to-sample step on the carrier at 800 Hz -> 20 kHz, because the coefficient jumped at a call edge);
//   3. the 2-pole low-pass candidate (switchable, default off): response, stability, and that it is not the default;
//   4. the direction mute's hysteresis: a pen on the boundary stops chattering, a clean reversal is as fast as before;
//   5. every stage is bit-exact r17 once it is back at neutral.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite("R20 stage smoothing in seconds") nonisolated struct StageSmoothingSecondsTests {
    static let sizes: [R20.Pattern] = [.fixed(64), .fixed(128), .ipad, .fixed(256), .fixed(512), .fixed(1024)]

    /// y_on and y_off with `event` applied to `on` after 0.3 s (the sound is steady by then).
    static func pair(_ pattern: R20.Pattern, before: (LiveSonificationKernel) -> Void = { _ in }, settle: Double = 0,
                     event: (LiveSonificationKernel) -> Void, after: Double = 0.5) throws
        -> (on: R20.Driver, off: R20.Driver, n0: Int) {
        let src = try StudySources.load("spatial_carrier")
        let on = R20.Driver(source: src, pattern: pattern), off = R20.Driver(source: src, pattern: pattern)
        before(on.kernel)
        on.run(0.3 + settle); off.run(0.3 + settle)
        let n0 = on.count
        event(on.kernel)
        on.run(after); off.run(after)
        return (on, off, n0)
    }

    @Test("the production constants")
    func production() {
        #expect(LiveSonificationKernel.StageSmoothing.production
                == .init(toneGainSeconds: 0.006, toneCutoffSeconds: 0.012, pressureSeconds: 0.006))
    }

    @Test("level step: the time constant is 6 ms at every call size", arguments: StageSmoothingSecondsTests.sizes)
    func gainTimeConstant(pattern: R20.Pattern) throws {
        let p = try Self.pair(pattern, event: { $0.setStrokeLevel(gainDB: -12) })
        let g = R20.gainProgress(on: p.on.y, off: p.off.y, step: p.n0, g0: 1, g1: pow(10, -12 / 20), span: 0.5)
        let t = try #require(R20.tc(g.pts).tau63)
        #expect(abs(t - 6.0) < 0.5, "\(pattern): tau63 \(t) ms")
    }

    @Test("mute: -60 dB at about 41 ms at every call size (r18: 21 / 39 / 86 ms)", arguments: StageSmoothingSecondsTests.sizes)
    func muteCompletes(pattern: R20.Pattern) throws {
        let p = try Self.pair(pattern, event: { $0.setStrokeMute(true) })
        let g = R20.gainProgress(on: p.on.y, off: p.off.y, step: p.n0, g0: 1, g1: 0, span: 0.5)
        let m = try #require(g.tMinus60)
        #expect(m > 37 && m < 46, "\(pattern): -60 dB after \(m) ms")
    }

    @Test("pressure gain: the time constant is 6 ms at every call size (r18: it finished inside one call)",
          arguments: StageSmoothingSecondsTests.sizes)
    func pressureTimeConstant(pattern: R20.Pattern) throws {
        let lo = Float(pow(10, -18.0 / 20))
        let p = try Self.pair(pattern, event: { $0.setPressureGain(lo) })
        let g = R20.gainProgress(on: p.on.y, off: p.off.y, step: p.n0, g0: 1, g1: Double(lo), span: 0.5)
        let t = try #require(R20.tc(g.pts).tau63)
        #expect(abs(t - 6.0) < 0.5, "\(pattern): tau63 \(t) ms")
    }

    @Test("cutoff: the log-domain approach has a 12 ms time constant at every call size (call-edge bias included)",
          arguments: StageSmoothingSecondsTests.sizes)
    func cutoffTimeConstant(pattern: R20.Pattern) throws {
        let p = try Self.pair(pattern, event: { $0.setStrokeLowpass(cutoffHz: 800) })
        let trk = R20.cutoffTrack(on: p.on.y, off: p.off.y, starts: p.on.starts, from: p.n0)
        let t = try #require(R20.tc(R20.cutoffProgress(trk, f0: 20000, f1: 800)).tau63)
        let callMs = pattern.seconds * 1000
        #expect(t > 12 - 0.5 * callMs - 1.5 && t < 12 + 0.5 * callMs + 3, "\(pattern): tau63 \(t) ms")
    }

    @Test("opening the low-pass (800 Hz -> 20 kHz) does not step the signal: the carrier's largest sample step stays within 1.15x its own",
          arguments: [LiveSonificationKernel.LowpassSlope.sixDB, .twelveDB])
    func openingDoesNotStep(slope: LiveSonificationKernel.LowpassSlope) throws {
        let src = try StudySources.load("spatial_carrier")
        let steady = R20.Driver(source: src); steady.run(1.5)
        let d = R20.Driver(source: src)
        d.kernel.setStrokeLowpassSlope(slope)
        d.kernel.setStrokeLowpass(cutoffHz: 800)
        d.run(0.9)
        let n0 = d.count
        d.kernel.setStrokeLowpass(cutoffHz: 20000)
        d.run(0.6)
        let c = R20.click(d.y, steady: steady.y, at: n0, window: 0.040)
        #expect(c.deltaRatio < 1.15, "\(slope): the opening stepped the signal \(c.deltaRatio)x (r18 one-pole: 4.34x)")
    }

    @Test("a stage that is back at neutral is the r17 render, bit for bit")
    func neutralAgainIsR17() throws {
        let src = try StudySources.load("spatial_carrier")
        let ref = R20.Driver(source: src), d = R20.Driver(source: src)
        d.kernel.setStrokeLevel(gainDB: -12); d.kernel.setStrokeLowpass(cutoffHz: 800); d.kernel.setPressureGain(0.3)
        ref.run(0.3); d.run(0.3)
        d.kernel.setStrokeLevel(gainDB: 0); d.kernel.setStrokeLowpass(cutoffHz: StrokeTone.bypassHz); d.kernel.setPressureGain(1)
        ref.run(1.2); d.run(1.2)
        let from = Int(1.0 * R20.sr)
        #expect(Array(d.y[from...]) == Array(ref.y[from...]), "a settled stage left the r17 path")
    }

    @Test("the pressure gain with the switch off is r17 exactly (never written == written 1)")
    func pressureOffIsR17() throws {
        let src = try StudySources.load("A_phoneme1")
        let a = R20.Driver(source: src), b = R20.Driver(source: src)
        b.kernel.setPressureGain(1)
        a.run(0.6); b.run(0.6)
        #expect(a.y == b.y)
    }
}

extension R20.Pattern: CustomTestStringConvertible {
    var testDescription: String { description }
}

@Suite("R20 2-pole low-pass candidate") nonisolated struct TwoPoleLowpassTests {

    /// Steady-state gain of a probe sine through the filter at `ratio` x the cutoff.
    static func gain(ratio: Double, cutoff: Double = 1000) -> Double {
        let sr = R20.sr, f = cutoff * ratio
        var lp = TPTLowpass()
        let g = TPTLowpass.coefficient(cutoffHz: Float(cutoff), sampleRate: Float(sr))
        var inP = 0.0, outP = 0.0
        let n = Int(sr), settle = Int(0.3 * sr)
        for i in 0..<n {
            let x = Float(sin(2 * Double.pi * f * Double(i) / sr))
            let y = lp.tick(x, g: g)
            if i >= settle { inP += Double(x * x); outP += Double(y * y) }
        }
        return 10 * log10(outP / inP)
    }

    @Test("Butterworth: unity at a quarter of the cutoff, -3 dB at the cutoff, -24 dB at four times (12 dB/octave)")
    func response() {
        // power ratio in dB equals 20 log10 of the amplitude ratio
        #expect(abs(Self.gain(ratio: 0.25) - 10 * log10(1 / (1 + pow(0.25, 4)))) < 0.2)
        #expect(abs(Self.gain(ratio: 1) - -3.01) < 0.2, "cutoff: \(Self.gain(ratio: 1)) dB")
        #expect(abs(Self.gain(ratio: 4) - 10 * log10(1 / (1 + pow(4.0, 4)))) < 0.6, "4x: \(Self.gain(ratio: 4)) dB")
        let octave = Self.gain(ratio: 2) - Self.gain(ratio: 4)   // 2 -> 4 kHz: below the bilinear warp of the top octave
        #expect(abs(octave - 12) < 1.0, "slope \(octave) dB/octave")
    }

    @Test("the one-pole stays the default: nothing is written, the render equals a kernel that never heard of the slope")
    func defaultIsTheOnePole() throws {
        let src = try StudySources.load("spatial_carrier")
        let a = R20.Driver(source: src), b = R20.Driver(source: src)
        #expect(a.kernel.requestedLowpassSlope == .sixDB)
        b.kernel.setStrokeLowpassSlope(.sixDB)
        for d in [a, b] { d.kernel.setStrokeLowpass(cutoffHz: 800); d.run(0.8) }
        #expect(a.y == b.y)
    }

    @Test("12 dB/octave at 800 Hz is darker than the one-pole at 800 Hz, both are finite and bounded")
    func darkerAndStable() throws {
        let src = try StudySources.load("spatial_carrier")
        func render(_ slope: LiveSonificationKernel.LowpassSlope) -> [Float] {
            let d = R20.Driver(source: src)
            d.kernel.setStrokeLowpassSlope(slope)
            d.kernel.setStrokeLowpass(cutoffHz: 800)
            d.run(1.0)
            return Array(d.y[Int(0.5 * R20.sr)...])
        }
        let six = render(.sixDB), twelve = render(.twelveDB)
        let steady = R20.Driver(source: src); steady.run(1.0)
        let peak = steady.y.map(abs).max() ?? 1
        #expect(twelve.allSatisfy { $0.isFinite && abs($0) < 2 * peak })
        let hp6 = PopMeter.highPass(six, sr: R20.sr, fc: 3000), hp12 = PopMeter.highPass(twelve, sr: R20.sr, fc: 3000)
        #expect(PopMeter.power(hp12, 0, hp12.count) < PopMeter.power(hp6, 0, hp6.count), "the 2-pole is not darker above 3 kHz")
    }

    @Test("stable under a cutoff that jumps between 100 Hz and 20 kHz every call, and when the slope is switched while sounding")
    func abusive() throws {
        let src = try StudySources.load("spatial_carrier")
        let steady = R20.Driver(source: src); steady.run(1.5)
        let peak = steady.y.map(abs).max() ?? 1
        let d = R20.Driver(source: src)
        d.kernel.setStrokeLowpassSlope(.twelveDB)
        for i in 0..<300 {
            d.kernel.setStrokeLowpass(cutoffHz: i % 2 == 0 ? 100 : 20_000)
            if i % 50 == 25 { d.kernel.setStrokeLowpassSlope(i % 100 == 25 ? .sixDB : .twelveDB) }
            d.run(0.005)
        }
        #expect(d.y.allSatisfy { $0.isFinite && abs($0) < 3 * peak }, "peak \(d.y.map(abs).max() ?? 0) against \(peak)")
    }
}

@Suite("R20 direction mute hysteresis") @MainActor struct DirectionHysteresisTests {

    @Test("the pure mapping: no hysteresis unless asked (r18/r19 semantics), then release above the margin")
    func pureMapping() {
        func tone(_ cos: Float, was: Bool, margin: Float) -> Bool {
            let ctx = StrokeContext(normalizedDistance: 0.2, directionCosine: cos)
            return StrokeTone.make(context: ctx, distanceEnabled: false, directionEnabled: true,
                                   wasMuted: was, releaseMarginCosine: margin)!.muted
        }
        #expect(tone(-0.3, was: false, margin: 0.3))
        #expect(!tone(-0.2, was: false, margin: 0.3), "entering is still below -0.25 only")
        #expect(tone(-0.2, was: true, margin: 0.3), "a muted pen at -0.2 stays muted inside the band")
        #expect(tone(0.04, was: true, margin: 0.3))
        #expect(!tone(0.06, was: true, margin: 0.3), "released above -0.25 + 0.3")
        #expect(!tone(-0.2, was: true, margin: 0), "margin 0 is the r19 mapping")
        #expect(StrokeTone.releaseMarginCosine == 0.3)
    }

    @Test("a pen hovering on the boundary toggles the mute < 1 /s, not 5 /s (measured A4: 5.2 /s without)")
    func boundaryDoesNotChatter() {
        let without = R20Pen.chatter(base: 104.5, wobble: 0, sigma: 0.3, margin: 0)
        let with = R20Pen.chatter(base: 104.5, wobble: 0, sigma: 0.3)
        #expect(without.toggles > 3, "the control did not chatter: the test measures nothing (\(without.toggles) /s)")
        #expect(with.toggles < 1, "\(with.toggles) toggles/s with the hysteresis")
        let wobbly = R20Pen.chatter(base: 104.5, wobble: 8, sigma: 0.7)
        #expect(wobbly.flickers <= 1, "flickers \(wobbly.flickers)")
    }

    @Test("a clean reversal mutes and a turn forward unmutes as fast as without the hysteresis")
    func reversalIsNotSlower() {
        let base = R20Pen.reversalLatency(margin: 0)
        let now = R20Pen.reversalLatency(margin: StrokeTone.releaseMarginCosine)
        #expect(now.mute != nil && now.unmute != nil, "no mute/unmute at all: the test measures nothing")
        let m = now.mute ?? 999, u = now.unmute ?? 999
        #expect(abs(m - (base.mute ?? 0)) < 1, "mute \(m) vs \(String(describing: base.mute)) ms")
        #expect(u <= (base.unmute ?? 0) + 20, "unmute \(u) vs \(String(describing: base.unmute)) ms")
        #expect(m < 200 && u < 150)
    }
}
