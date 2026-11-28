// TDPSOLA2HarmonicNoiseTests.swift
// PrimaeNativeTests — pitch bake-off phase 2, lane C1 "TDPSOLA2", item 4 (2026-11-23)
//
// The harmonic/noise split (Stylianou 2001; Bailly 1999) and the noise swap:
//   - the bank: h_i + n_i is the analysis grain g_i, and a strictly periodic source has no noise part;
//   - the swap does what it is for: on a "voiced" source of pure noise (marks by hand), an upshift re-plays periods;
//     without the swap a re-played grain repeats its noise exactly (the output correlates with itself one output
//     period later), with it the repeat carries another period's noise. What stays correlated is the harmonic
//     estimate: on pure noise h_i is the 1-2-3-2-1 mean of five grains (19/81 of a grain's energy) and neighbouring
//     grains share four of them, so the swap cannot reach zero here (measured macOS: 0.222 -> 0.125, x0.56);
//   - determinism (product gate 4): the draws are seeded per source and re-seeded at every onset, so two instances,
//     a reset and a gate re-open all reproduce the same output bit for bit.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("C1 item 4: harmonic/noise split and noise swap")
nonisolated struct TDPSOLA2HarmonicNoiseTests {

    static let sr = LiveSonificationKernel.referenceSampleRate
    static let period = 200

    struct LCG {
        var s: UInt64
        mutating func next() -> Float {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Double(s >> 11) / Double(1 << 53) * 2 - 1)
        }
    }

    static func handAnalysis(count n: Int) -> TDPSOLAAnalysis {
        var marks: [Double] = []
        var m = 1000.0
        while m + 2 * Double(period) < Double(n) { marks.append(m); m += Double(period) }
        return TDPSOLAAnalysis(onset: 0, isVoiced: true, voicedFraction: 1, medianPeriod: Double(period), marks: marks,
                               periods: [Double](repeating: Double(period), count: marks.count), attackIndex: 3,
                               loopEndIndex: marks.count - 4, loopStart: marks[3],
                               loopEnd: marks[marks.count - 4] + Double(period), unvoicedHop: 221)
    }

    @Test("the bank: h_i + n_i == g_i, and a periodic source's noise part is ~0")
    func bankReconstructs() throws {
        let n = Int(2 * Self.sr)
        var rng = LCG(s: 7)
        let noisy = (0..<n).map { _ in 0.3 * rng.next() }
        let periodic = (0..<n).map { i in Float(0.4 * sin(2 * Double.pi * Double(i % Self.period) / Double(Self.period))) }
        let a = Self.handAnalysis(count: n)
        for (label, x) in [("noise", noisy), ("periodic", periodic)] {
            let bank = x.withUnsafeBufferPointer {
                TDPSOLA2HarmonicNoise($0.baseAddress!, count: n, marks: a.marks, periods: a.periods,
                                      first: a.attackIndex, last: a.loopEndIndex)
            }
            var maxRec: Float = 0, maxN: Float = 0, maxG: Float = 0
            for i in a.attackIndex...a.loopEndIndex {
                let h = bank.harmonic(i), nz = bank.noise(i)
                for k in 0..<bank.slotLength {
                    let d = Double(k - bank.radius)            // marks are integers here: offset from the mark
                    let t = Double(Self.period)
                    let g: Float = abs(d) < t ? x[Int(a.marks[i]) + Int(d)] * Float(0.5 + 0.5 * cos(Double.pi * d / t)) : 0
                    maxRec = max(maxRec, abs(h[k] + nz[k] - g))
                    maxN = max(maxN, abs(nz[k])); maxG = max(maxG, abs(g))
                }
            }
            #expect(maxRec < 1e-6, "\(label): |h + n - g| up to \(maxRec)")
            if label == "periodic" { #expect(maxN < 1e-4 * maxG, "periodic: noise part up to \(maxN) (grain peak \(maxG))") }
            else { #expect(maxN > 0.1 * maxG, "noise: the split left no noise part (\(maxN))") }
        }
    }

    /// Normalised autocorrelation of the steady output at `lag`.
    static func acf(_ y: [Float], lag: Int) -> Double {
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in Int(0.4 * sr)..<Int(1.9 * sr) {
            let a = Double(y[i]), b = Double(y[i + lag])
            ab += a * b; aa += a * a; bb += b * b
        }
        return ab / (aa * bb).squareRoot()
    }

    @Test("upshift +600 on a noise 'voice': without the swap a re-played grain repeats its noise; with it, it does not")
    func swapBreaksRepeatedNoise() throws {
        let n = Int(3 * Self.sr)
        var rng = LCG(s: 11)
        let x = (0..<n).map { _ in 0.3 * rng.next() }
        let a = Self.handAnalysis(count: n)
        func render(_ hn: Bool) -> [Float] {
            let o = C1Make.with { $0.harmonicNoiseSwap = hn; $0.gciSnap = false; $0.pulseDensityExponent = 0 }
            let r = TDPSOLA2(source: x, sampleRate: Self.sr, kind: .voicedPhoneme, maxFramesPerRender: 512, analysis: a,
                             tuning: .bakeoff, options: o)
            return SonificationDriver.steady(r, seconds: 2, rate: 1, cents: 600)
        }
        let lag = Int((Double(Self.period) / exp2(0.5)).rounded())    // one output period at +600
        let plain = Self.acf(render(false), lag: lag), swapped = Self.acf(render(true), lag: lag)
        print("C1HN acf at one output period: no swap \(plain), swap \(swapped)")
        #expect(plain > 0.15, "instrument: without the swap the repeats must show (\(plain))")
        #expect(swapped < 0.7 * plain, "the swap left the repeated noise correlated: \(swapped) (no swap \(plain))")
    }

    @Test("determinism: two instances, a reset and a gate re-open reproduce the output bit for bit",
          arguments: StudySources.voicedNames)
    func deterministic(name: String) throws {
        let s = try StudySources.load(name)
        let a = SonificationDriver.steady(C1Make.make(s), seconds: 1.5, rate: 0.7, cents: 450)
        let r = C1Make.make(s)
        let b = SonificationDriver.steady(r, seconds: 1.5, rate: 0.7, cents: 450)
        let c = SonificationDriver.steady(r, seconds: 1.5, rate: 0.7, cents: 450)   // after reset()
        let d = SonificationDriver.render(r, seconds: 2.2, events: [ControlEvent(time: 0, rate: 0.7, cents: 450, gate: true),
                                                                   ControlEvent(time: 0.3, gate: false),
                                                                   ControlEvent(time: 0.7, gate: true)])
        #expect(a.elementsEqual(b) { $0.bitPattern == $1.bitPattern }, "\(name): two instances differ")
        #expect(b.elementsEqual(c) { $0.bitPattern == $1.bitPattern }, "\(name): reset did not reproduce")
        // The re-open at 0.7 s (after the 2 ms close ramp) restarts at the source start with the same draws.
        let start = SonificationDriver.appliedFrame(0.7)
        let tail = Array(d[start..<(start + Int(1.4 * Self.sr))])
        #expect(tail.elementsEqual(a[0..<tail.count]) { $0.bitPattern == $1.bitPattern }, "\(name): re-open differs")
    }

    @Test("noiseSeedXor default 0 is bit-identical to production; non-zero varies shifted voiced draws only",
          arguments: ["A_phoneme1", "I_phoneme1"])
    func noiseSeedXorKnob(name: String) throws {
        #expect(TDPSOLA2Options.production.noiseSeedXor == 0)
        let s = try StudySources.load(name)
        let ss = s.sonificationSource
        let prod = LiveSonificationAudio.makeRenderer(ss)
        var zeroOpts = TDPSOLA2Options.production
        zeroOpts.noiseSeedXor = 0
        let explicitZero = TDPSOLA2(source: ss.samples, sampleRate: ss.sampleRate, kind: ss.kind,
                                    maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default,
                                    options: zeroOpts, onset: ss.onset, outputGain: ss.gain, file: ss.fileSource)
        var altOpts = TDPSOLA2Options.production
        altOpts.noiseSeedXor = 0x1357_9BDF_2468_ACE0
        let alt = TDPSOLA2(source: ss.samples, sampleRate: ss.sampleRate, kind: ss.kind,
                           maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default,
                           options: altOpts, onset: ss.onset, outputGain: ss.gain, file: ss.fileSource)
        // Default 0 matches production bit-for-bit on shifted voiced audio.
        let yProd = SonificationDriver.steady(prod, seconds: 1.5, rate: 0.8, cents: 450)
        let yZero = SonificationDriver.steady(explicitZero, seconds: 1.5, rate: 0.8, cents: 450)
        let yAlt = SonificationDriver.steady(alt, seconds: 1.5, rate: 0.8, cents: 450)
        #expect(yProd.elementsEqual(yZero) { $0.bitPattern == $1.bitPattern }, "\(name): noiseSeedXor 0 differed from production")
        #expect(!yProd.elementsEqual(yAlt) { $0.bitPattern == $1.bitPattern }, "\(name): non-zero noiseSeedXor had no effect")
        // Unshifted 0 c / rate 1 continues natural marks (never draws from rng), so even non-zero xor is bit-identical.
        let zProd = SonificationDriver.steady(prod, seconds: 1.5, rate: 1, cents: 0)
        let zAlt = SonificationDriver.steady(alt, seconds: 1.5, rate: 1, cents: 0)
        #expect(zProd.elementsEqual(zAlt) { $0.bitPattern == $1.bitPattern }, "\(name): 0 c / rate 1 must not depend on noiseSeedXor")
    }
}
