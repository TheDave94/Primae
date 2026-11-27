// TDPSOLA2BranchTests.swift
// PrimaeNativeTests — pitch bake-off phase 2, lane C1 "TDPSOLA2", items 1 and 2 (2026-11-23)
//
// Item 1 is r27 candidate A as is, item 2 candidate B generalised; their r27 candidate suites
// (`UnvoicedPitchShiftTests`, `VoicedDownshiftWindowTests`, branch t3/tdpsola-pitch-candidates, 5dcc4b4f / a601f528)
// are ported here onto TDPSOLA2 with their thresholds unchanged (BAKEOFF-PITCH.md section 3, "F"), plus the two
// cases the generalisation adds: an upshift with even periods is untouched, and with the formant ratio beta of item 6
// a downshifted grain still holds one SOURCE period.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("C1 item 1: a pitch-shifted F is a clean resample (candidate A's suite)")
nonisolated struct TDPSOLA2UnvoicedTests {

    static let sr = LiveSonificationKernel.referenceSampleRate
    static let shifts: [Float] = [-600, -300, 300, 600]

    static func renderF(cents: Float, rate: Float = 1) throws -> [Float] {
        SonificationDriver.steady(C1Make.make(try StudySources.load("F_phoneme1")), seconds: 2.5, rate: rate, cents: cents)
    }
    static var region: Range<Int> { Int(0.3 * sr)..<Int(2.4 * sr) }

    static func grainRateWobble(_ y: [Float], period: Int) -> Double {
        let bins = 20
        var acc = [Double](repeating: 0, count: bins), cnt = [Double](repeating: 0, count: bins)
        for i in region {
            let b = ((i - region.lowerBound) % period) * bins / period
            acc[b] += Double(y[i]) * Double(y[i]); cnt[b] += 1
        }
        let p = zip(acc, cnt).map { $0 / $1 }
        return 10 * log10(p.max()! / p.min()!)
    }

    static func acf(_ y: [Float], lag: Double) -> Double {
        let l = Int(lag), f = lag - Double(l)
        var ab = 0.0, aa = 0.0, bb = 0.0
        for i in region.lowerBound..<(region.upperBound - l - 1) {
            let a = Double(y[i])
            let b = (1 - f) * Double(y[i + l]) + f * Double(y[i + l + 1])
            ab += a * b; aa += a * a; bb += b * b
        }
        return ab / (aa * bb).squareRoot()
    }

    @Test("no 200 Hz grain-rate buzz: power folded on the unvoiced hop varies by <= 1 dB at +-300 and +-600 cents")
    func noGrainRateBuzz() throws {
        let h = C1Make.make(try StudySources.load("F_phoneme1")).analysis.unvoicedHop
        #expect(h == 221, "precondition: the hop the bounds were measured at")
        for c in Self.shifts {
            let w = Self.grainRateWobble(try Self.renderF(cents: c), period: h)
            #expect(w <= 1.0, "F at \(c) cents: grain-rate wobble \(w) dB (shipped r27: ~3 dB)")
        }
    }

    @Test("level holds: downshift within 0.3 dB of the 0-cent render, upshift within 1.2 dB")
    func levelHolds() throws {
        let r0 = SonificationMetrics.rms(try Self.renderF(cents: 0)[Self.region])
        for c in Self.shifts {
            let d = SonificationMetrics.dB(SonificationMetrics.rms(try Self.renderF(cents: c)[Self.region]), r0)
            let bound = c < 0 ? 0.3 : 1.2
            #expect(abs(d) <= bound, "F at \(c) cents: level \(d) dB re 0 cents (bound \(bound); shipped r27 -1.9)")
        }
    }

    @Test("no upshift comb: the normalised autocorrelation at hop * (1 - 1/pf) stays below 0.1")
    func noUpshiftComb() throws {
        let h = Double(C1Make.make(try StudySources.load("F_phoneme1")).analysis.unvoicedHop)
        for c in Self.shifts where c > 0 {
            let pf = exp2(Double(c) / 1200)
            let r = Self.acf(try Self.renderF(cents: c), lag: h * (1 - 1 / pf))
            #expect(abs(r) < 0.1, "F at \(c) cents: ACF \(r) at the comb lag (shipped r27: 0.26 / 0.36)")
        }
    }

    @Test("rate still does not move F: a shifted F renders bit-identically at rates 0.5, 1 and 2")
    func rateDoesNotMoveShiftedF() throws {
        for c in [Float(-600), 600] {
            let a = try Self.renderF(cents: c, rate: 1)
            for rt in [Float(0.5), 2] {
                let b = try Self.renderF(cents: c, rate: rt)
                #expect(a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern },
                        "F at \(c) cents: rate \(rt) changed the render")
            }
        }
    }
}

@Suite("C1 item 2: a voiced grain holds one source period (candidate B's suite, generalised)")
nonisolated struct TDPSOLA2WindowTests {

    static let sr = LiveSonificationKernel.referenceSampleRate
    static let period = 200

    /// Candidate B's instrument: a 3 s train of 17-sample Hann blips (peak 0.5) every `period` frames, marks exactly on
    /// the blips (analysis built by hand), `.bakeoff` tuning (no seam, no limiter). Items 3-5 off: this isolates the
    /// window.
    static func pulseTrain(_ o: TDPSOLA2Options) -> TDPSOLA2 {
        let n = Int(3 * sr)
        var x = [Float](repeating: 0, count: n)
        var marks: [Double] = []
        var m = 1000
        while m + 2 * period < n {
            for j in -8...8 { x[m + j] = Float(0.5 * (0.5 + 0.5 * cos(Double.pi * Double(j) / 9))) }
            marks.append(Double(m))
            m += period
        }
        let periods = [Double](repeating: Double(period), count: marks.count)
        let attack = 3, loopEndIndex = marks.count - 4
        let a = TDPSOLAAnalysis(onset: 0, isVoiced: true, voicedFraction: 1, medianPeriod: Double(period),
                                marks: marks, periods: periods, attackIndex: attack, loopEndIndex: loopEndIndex,
                                loopStart: marks[attack], loopEnd: marks[loopEndIndex] + Double(period),
                                unvoicedHop: 221)
        var opts = o
        opts.pulseDensityExponent = 0; opts.harmonicNoiseSwap = false; opts.gciSnap = false
        return TDPSOLA2(source: x, sampleRate: sr, kind: .voicedPhoneme, maxFramesPerRender: 512, analysis: a,
                        tuning: .bakeoff, options: opts)
    }

    static func peaks(_ y: [Float]) -> [Float] {
        var p: [Float] = []
        for i in Int(0.4 * sr)..<Int(1.4 * sr) {
            let v = abs(y[i])
            guard v > 0.002 else { continue }
            if ((i - 4)...(i + 4)).allSatisfy({ $0 == i || abs(y[$0]) < v || ($0 > i && abs(y[$0]) == v) }) { p.append(v) }
        }
        return p
    }

    static func checkNoEcho(_ y: [Float], cents: Float, label: String) throws {
        let p = Self.peaks(y)
        let main = try #require(p.max())
        #expect(main > 0.45, "\(label): precondition: the main pulses play at full weight (\(main))")
        let worst = p.filter { $0 < 0.5 * main }.max() ?? 0
        #expect(worst < 0.02 * main, "\(label) \(cents) cents: secondary peak \(worst / main) of the main pulse")
        let mains = p.filter { $0 >= 0.5 * main }.count
        let expected = 1.0 * Self.sr / (Double(Self.period) / exp2(Double(cents) / 1200))
        #expect(abs(Double(mains) - expected) <= 2, "\(label) \(cents) cents: \(mains) main pulses in 1 s, expected \(expected)")
    }

    @Test("-600 and -300 cents: no echo of a neighbouring source pulse (every secondary peak < 2 % of the main pulse)",
          arguments: [Float(-600), -300])
    func noOriginalPeriodEcho(cents: Float) throws {
        try Self.checkNoEcho(SonificationDriver.steady(Self.pulseTrain(.default), seconds: 1.5, rate: 1, cents: cents),
                             cents: cents, label: "gamma 0")
    }

    @Test("with the formant ratio of item 6 (gamma 0.5) a downshifted grain still holds one SOURCE period",
          arguments: [Float(-600), -300])
    func noEchoWithGamma(cents: Float) throws {
        let o = C1Make.with { $0.formantGamma = 0.5 }
        try Self.checkNoEcho(SonificationDriver.steady(Self.pulseTrain(o), seconds: 1.5, rate: 1, cents: cents),
                             cents: cents, label: "gamma 0.5")
    }

    @Test("gamma 1 at -600 / -300 is a continuous resample: a sine with marks keeps a flat envelope (the cap is T / beta)",
          arguments: [Float(-600), -300])
    func gammaOneIsContinuous(cents: Float) throws {
        // A sine of exactly one period per mark: at gamma 1 every grain is read at pf and spaced at T / pf, so
        // consecutive grains are in phase and their halves (width T / beta = spacing) sum to 1. A cap of one OUTPUT
        // period T instead of T / beta would leave gaps between the grains.
        let n = Int(3 * Self.sr)
        let x = (0..<n).map { Float(0.5 * sin(2 * Double.pi * Double($0) / Double(Self.period))) }
        var marks: [Double] = []
        var m = 1000
        while m + 2 * Self.period < n { marks.append(Double(m)); m += Self.period }
        let a = TDPSOLAAnalysis(onset: 0, isVoiced: true, voicedFraction: 1, medianPeriod: Double(Self.period),
                                marks: marks, periods: [Double](repeating: Double(Self.period), count: marks.count),
                                attackIndex: 3, loopEndIndex: marks.count - 4, loopStart: marks[3],
                                loopEnd: marks[marks.count - 4] + Double(Self.period), unvoicedHop: 221)
        let o = C1Make.with { $0.formantGamma = 1; $0.harmonicNoiseSwap = false; $0.gciSnap = false }
        let r = TDPSOLA2(source: x, sampleRate: Self.sr, kind: .voicedPhoneme, maxFramesPerRender: 512, analysis: a,
                         tuning: .bakeoff, options: o)
        let y = SonificationDriver.steady(r, seconds: 1.5, rate: 1, cents: cents)
        let outT = Int((Double(Self.period) / exp2(Double(cents) / 1200)).rounded())
        var lo = Double.infinity, hi = 0.0
        var i = Int(0.4 * Self.sr)
        while i + outT < Int(1.4 * Self.sr) {
            var pk: Float = 0
            for k in i..<(i + outT) { pk = max(pk, abs(y[k])) }
            lo = min(lo, Double(pk)); hi = max(hi, Double(pk))
            i += outT
        }
        #expect(20 * log10(hi / lo) < 0.5, "\(cents) cents, gamma 1: per-period peak varies \(20 * log10(hi / lo)) dB")
        #expect(abs(20 * log10(hi / 0.5)) < 0.5, "\(cents) cents, gamma 1: level \(hi) (source peak 0.5; no density gain at gamma 1)")
    }

    @Test("upshift with even periods is untouched by the cap (+300, +600: bit-identical to the cap off)")
    func upshiftUntouched() throws {
        var off = TDPSOLA2Options.default; off.voicedWindowCap = false
        for c in [Float(300), 600] {
            let a = SonificationDriver.steady(Self.pulseTrain(.default), seconds: 1.5, rate: 1, cents: c)
            let b = SonificationDriver.steady(Self.pulseTrain(off), seconds: 1.5, rate: 1, cents: c)
            #expect(zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern }, "\(c) cents: the cap changed an upshift")
        }
    }
}
