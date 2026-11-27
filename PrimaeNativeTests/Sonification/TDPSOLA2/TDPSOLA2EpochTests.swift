// TDPSOLA2EpochTests.swift
// PrimaeNativeTests — pitch bake-off phase 2, lane C1 "TDPSOLA2", item 5 (2026-11-23)
//
// The SEDREAMS-style epoch refinement on a synthetic voice whose glottal closures are known: an impulse train
// (closures with 0.5 % period jitter) through a two-formant all-pole tract. The coarse marks handed to the refiner
// are the closures moved by a constant offset plus +-3 samples of noise (waveform-consistent marks are a constant
// phase away from the closures, and less exact). Pinned:
//   - the snap lands on the closures and is adopted (it LOWERS the marks' jitter here). "On the closures" is a
//     precision claim plus a bounded bias: the LP residual of a band-limited signal peaks a constant ~5 samples
//     (0.11 ms) after the closure (measured: signed error p5 3.8, median 5.1, p95 6.6 samples), which no PSOLA grain
//     can hear (every mark moves alike); what matters is that the marks follow each period's closure;
//   - the guard refuses a snap that raises the jitter (perfectly regular coarse marks: jitter 0) and keeps the marks;
//   - the phase fallback moves a refused set by the median offset only when that offset is >= 0.15 period.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("C1 item 5: epoch (GCI) refinement")
nonisolated struct TDPSOLA2EpochTests {

    static let sr = 44100.0
    static let period = 189.0   // ~233 Hz, A's period

    struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
    }

    /// (signal, true closure instants).
    static func voice(seed: UInt64 = 5) -> ([Float], [Double]) {
        var rng = LCG(s: seed)
        let n = Int(2.5 * sr)
        var e = [Double](repeating: 0, count: n)
        var gci: [Double] = []
        var t = 600.0
        while t < Double(n - 600) {
            gci.append(t)
            // A fractional impulse: linear split between the two neighbouring samples (negative-going closure).
            let k = Int(t), f = t - Double(k)
            e[k] -= 1 - f; e[k + 1] -= f
            t += period * (1 + 0.005 * (2 * rng.next() - 1))
        }
        // Two resonators (F1 700 Hz, F2 1200 Hz, bandwidths 80 / 100 Hz) in cascade, plus a little noise.
        func resonate(_ x: [Double], f: Double, bw: Double) -> [Double] {
            let r = exp(-Double.pi * bw / sr), th = 2 * Double.pi * f / sr
            let a1 = 2 * r * cos(th), a2 = -r * r
            var y = [Double](repeating: 0, count: x.count)
            for i in 0..<x.count { y[i] = x[i] + a1 * (i > 0 ? y[i - 1] : 0) + a2 * (i > 1 ? y[i - 2] : 0) }
            return y
        }
        let y = resonate(resonate(e, f: 700, bw: 80), f: 1200, bw: 100)
        let peak = y.map { abs($0) }.max()!
        return (y.map { Float(0.5 * $0 / peak + 0.002 * (2 * rng.next() - 1)) }, gci)
    }

    static func analysis(marks: [Double]) -> TDPSOLAAnalysis {
        var periods = [Double](repeating: 0, count: marks.count)
        for i in 0..<(marks.count - 1) { periods[i] = marks[i + 1] - marks[i] }
        periods[marks.count - 1] = periods[marks.count - 2]
        let ai = 3, ei = marks.count - 4
        return TDPSOLAAnalysis(onset: 0, isVoiced: true, voicedFraction: 1, medianPeriod: period, marks: marks,
                               periods: periods, attackIndex: ai, loopEndIndex: ei, loopStart: marks[ai],
                               loopEnd: marks[ei] + periods[ei], unvoicedHop: 221)
    }

    @Test("the snap follows the closures (spread about the bias <= 1.5 / p95 4 samples, bias <= 0.25 ms) and is adopted")
    func snapFindsClosures() throws {
        let (x, gci) = Self.voice()
        var rng = LCG(s: 9)
        let coarse = gci.map { $0 + 40 + 6 * (rng.next() - 0.5) }
        let (a, rep) = TDPSOLA2Epochs.refine(x, sampleRate: Self.sr, analysis: Self.analysis(marks: coarse), guardRatio: 1.2)
        print("C1GCI synthetic: \(rep.reason) gcis \(rep.gciCount) matched \(rep.matched)/\(rep.markCount) offset \(rep.medianOffset) jitter \(rep.jitterBefore) -> \(rep.jitterAfter) polarity \(rep.polarity)")
        #expect(rep.applied, "refused: \(rep.reason)")
        let signed = zip(a.marks, gci).map { $0 - $1 }.sorted()
        let bias = signed[signed.count / 2]
        let err = signed.map { abs($0 - bias) }.sorted()
        let med = err[err.count / 2], p95 = err[err.count * 95 / 100]
        print("C1GCI synthetic: mark - closure: bias \(bias); |error - bias| median \(med), p95 \(p95), max \(err.last!)")
        #expect(abs(bias) <= 0.25e-3 * Self.sr, "bias \(bias) samples")
        #expect(med <= 1.5, "median |error - bias| \(med) samples")
        #expect(p95 <= 4, "p95 |error - bias| \(p95) samples")
        #expect(a.loopStart == a.marks[a.attackIndex] && a.loopEnd == a.marks[a.loopEndIndex] + a.periods[a.loopEndIndex],
                "the loop bounds follow the moved marks")
    }

    @Test("the guard keeps the old marks when the snap would raise their jitter")
    func guardRefuses() throws {
        let (x, gci) = Self.voice()
        // Perfectly regular coarse marks (jitter 0) near the jittered closures: any snap raises the jitter.
        let coarse = (0..<gci.count).map { gci[0] + 40 + Double($0) * Self.period }
        let a0 = Self.analysis(marks: coarse)
        let (a, rep) = TDPSOLA2Epochs.refine(x, sampleRate: Self.sr, analysis: a0, guardRatio: 1.2)
        #expect(!rep.applied, "the snap was adopted: \(rep.reason)")
        #expect(a.marks == a0.marks, "refused, yet the marks moved")
    }

    @Test("phase fallback: a refused set moves by the median GCI offset only when it is >= 0.15 period")
    func phaseFallback() throws {
        let (x, gci) = Self.voice()
        for (offset, expectMove) in [(60.0, true), (12.0, false)] {
            let coarse = (0..<gci.count).map { gci[0] + offset + Double($0) * Self.period }
            let a0 = Self.analysis(marks: coarse)
            // Through the renderer, as the option is applied there.
            let r = TDPSOLA2(source: x, sampleRate: Self.sr, kind: .voicedPhoneme, maxFramesPerRender: 512, analysis: a0,
                             tuning: .bakeoff, options: C1Make.with { $0.harmonicNoiseSwap = false })
            let rep = try #require(r.epochReport)
            #expect(rep.applied == expectMove, "offset \(offset): applied \(rep.applied) (\(rep.reason))")
            let shift = r.analysis.marks[10] - coarse[10]
            if expectMove {
                #expect(abs(shift + offset) <= 3, "offset \(offset): marks moved by \(shift)")
                #expect(rep.jitterAfter <= rep.jitterBefore + 1e-9, "a constant shift changed the jitter")
            } else {
                #expect(shift == 0, "offset \(offset): marks moved by \(shift)")
            }
        }
    }
}
