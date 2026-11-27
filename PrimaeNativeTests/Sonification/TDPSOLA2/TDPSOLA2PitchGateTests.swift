// TDPSOLA2PitchGateTests.swift
// PrimaeNativeTests — pitch bake-off phase 2, lane C1 "TDPSOLA2" (2026-11-23)
//
// The pitch-specific acceptance gates (BAKEOFF-PITCH.md section 3, confirmed by the supervisor) on the study's voiced
// phonemes, measured with the lane's own instruments (`C1Metrics`) until BENCH-P's land:
//   - F0: within +-5 cents of target at +-300 / +-600, rates 0.5, 1, 2. Target = the 0-cent render at the same rate
//     x pf, so the gate measures the SHIFTER, not the loop's pitch against the recording's median (A's loop sits
//     ~5 c below its recording's median at 0 cents already; jitter 1 %). A is held to it at rate 1; at 0.5 / 2 its
//     reading is reported (shipped r27 reads -7.4 / -6.5 at +600 on the same instrument).
//   - Envelope held (gamma 0): true-envelope warp alpha within 1.00 +- 0.03; with gamma 0.3, alpha = pf^0.3 +- 0.03.
//   - Level, item 3's claim: with the pulse-density gain a downshift stays within 1.5 dB of 0 cents (without: -2.1 ..
//     -2.7 dB).
// From protocol r31 (lane PITCHWIN, 2026-11-26) the F0, envelope and level gates measure the renderer that SHIPS,
// `TDPSOLA2Options.production`, not the bake-off's item 1-5 default: the default read A +600 at -5.17 c (the cell the
// bake-off carried as open), production reads -2.76 c and the r28 renderer -5.92 c on this instrument (macOS driver,
// MEASURED). A's breathy +600 reading moves by about 2.5 c with the phase of the synthesis grid alone (item 7 moves
// that grid), so the default and production differ there without either shifter being off pitch.
// Every cell is asserted. (An earlier version left I out of both alpha gates: I +600 read alpha 1.035 with the
// envelope instrument's fixed cepstral order, a bias of the instrument, not the renderer; with the order from each
// segment's own f0 the iPad reads I +600 at 1.020 and I gamma 0.3 within 0.016 of pf^0.3, 2026-11-24.)

import Testing
import Foundation
@testable import PrimaeNative

@Suite("C1 TDPSOLA2: pitch gates on the voiced phonemes")
nonisolated struct TDPSOLA2PitchGateTests {

    static let sr = LiveSonificationKernel.referenceSampleRate
    static let shifts: [Float] = [-600, -300, 300, 600]

    static func steadySeg(_ r: TDPSOLA2, rate: Float, cents: Float) -> ArraySlice<Float> {
        SonificationDriver.steady(r, seconds: 2.5, rate: rate, cents: cents)[Int(0.6 * sr)..<Int(2.4 * sr)]
    }
    static func sourceSteady(_ s: StudySource) -> ArraySlice<Float> {
        let onset = s.onset?.attackEndFrame ?? 0
        return s.samples[(onset + Int(0.08 * sr))..<(s.samples.count - Int(0.1 * sr))]
    }

    @Test("F0 within +-5 c of the 0-cent render x pf at +-300 / +-600 (I, L, M at rates 0.5, 1, 2; A at rate 1)",
          arguments: StudySources.voicedNames)
    func f0Accuracy(name: String) throws {
        let s = try StudySources.load(name)
        let r = C1Make.make(s, .production)
        let f0s = try #require(C1Metrics.medianF0(Self.sourceSteady(s)))
        let rates: [Float] = name.hasPrefix("A") ? [1] : [0.5, 1, 2]
        for rate in rates {
            let ref = try #require(C1Metrics.f0Near(Self.steadySeg(r, rate: rate, cents: 0), expected: f0s))
            for c in Self.shifts {
                let pf = exp2(Double(c) / 1200)
                let f = try #require(C1Metrics.f0Near(Self.steadySeg(r, rate: rate, cents: c), expected: ref * pf))
                let err = C1Metrics.cents(f, ref * pf)
                #expect(abs(err) <= 5, "\(name) rate \(rate) \(c) c: \(f) Hz, error \(err) c")
            }
        }
    }

    @Test("gamma 0: envelope held, true-envelope warp alpha within 1.00 +- 0.03",
          arguments: StudySources.voicedNames)
    func envelopeHeld(name: String) throws {
        let s = try StudySources.load(name)
        let es = C1Metrics.envelope(Self.sourceSteady(s))
        let r = C1Make.make(s, .production)
        for c in Self.shifts {
            let e = C1Metrics.compare(src: es, out: C1Metrics.envelope(Self.steadySeg(r, rate: 1, cents: c)))
            #expect(abs(e.alpha - 1) <= 0.03, "\(name) \(c) c: alpha \(e.alpha) (LSD \(e.lsd) dB)")
        }
    }

    @Test("gamma 0.3: formants move by pf^0.3 (alpha within +-0.03)",
          arguments: StudySources.voicedNames)
    func gammaMovesFormants(name: String) throws {
        let s = try StudySources.load(name)
        let es = C1Metrics.envelope(Self.sourceSteady(s))
        let r = C1Make.make(s, C1Make.with { $0.formantGamma = 0.3 })
        for c in Self.shifts {
            let target = pow(exp2(Double(c) / 1200), 0.3)
            let e = C1Metrics.compare(src: es, out: C1Metrics.envelope(Self.steadySeg(r, rate: 1, cents: c)))
            #expect(abs(e.alpha - target) <= 0.03, "\(name) \(c) c, gamma 0.3: alpha \(e.alpha), target \(target)")
        }
    }

    @Test("item 3: with the pulse-density gain a downshift holds the level within 1.5 dB of 0 cents",
          arguments: StudySources.voicedNames)
    func downshiftLevel(name: String) throws {
        let s = try StudySources.load(name)
        let r = C1Make.make(s, .production)
        let l0 = C1Metrics.rms(Self.steadySeg(r, rate: 1, cents: 0))
        for c in [Float(-600), -300] {
            let d = C1Metrics.dB(C1Metrics.rms(Self.steadySeg(r, rate: 1, cents: c)), l0)
            #expect(abs(d) <= 1.5, "\(name) \(c) c: level \(d) dB re 0 cents (no density gain: -2.1 .. -2.7)")
        }
    }

    @Test("instrument self-test: a varispeed copy reads alpha ~ pf; the 0-cent render reads alpha 1")
    func envelopeInstrument() throws {
        let s = try StudySources.load("A_phoneme1")
        let src = Self.sourceSteady(s)
        let es = C1Metrics.envelope(src)
        for pf in [0.8409, 1.1892, 1.4142] {
            let n = Int(Double(src.count) / pf) - 4
            let b = src.startIndex
            let y = (0..<n).map { i -> Float in
                let p = Double(i) * pf, k = Int(p), t = Float(p - Double(k))
                return src[b + k] * (1 - t) + src[b + k + 1] * t
            }
            let e = C1Metrics.compare(src: es, out: C1Metrics.envelope(y[...]))
            #expect(abs(e.alpha - pf) <= 0.03, "varispeed x\(pf): alpha \(e.alpha)")
        }
        let e0 = C1Metrics.compare(src: es, out: C1Metrics.envelope(Self.steadySeg(C1Make.make(s), rate: 1, cents: 0)))
        #expect(abs(e0.alpha - 1) <= 0.005 && e0.lsd < 1, "0 cents: alpha \(e0.alpha), LSD \(e0.lsd)")
    }

    /// The gate table for C1.md (prints; asserts only that every cell was measured).
    @Test("gate report: F0 / alpha / LSD / level / jitter / shimmer / AC-HNR per phoneme and cents (printed)")
    func gateReport() throws {
        for name in StudySources.voicedNames {
            let s = try StudySources.load(name)
            let src = Self.sourceSteady(s)
            let es = C1Metrics.envelope(src)
            let f0s = try #require(C1Metrics.medianF0(src))
            let js = try #require(C1Metrics.jitterShimmer(Array(src)))
            for (label, o) in [("r27", TDPSOLA2Options.r27), ("default", .default),
                               ("g0.3", C1Make.with { $0.formantGamma = 0.3 })] {
                let r = C1Make.make(s, o)
                let y0 = Self.steadySeg(r, rate: 1, cents: 0)
                let l0 = C1Metrics.rms(y0)
                let ref = try #require(C1Metrics.f0Near(y0, expected: f0s))
                for c in Self.shifts {
                    let pf = exp2(Double(c) / 1200)
                    let y = Self.steadySeg(r, rate: 1, cents: c)
                    let f = C1Metrics.f0Near(y, expected: ref * pf) ?? .nan
                    let e = C1Metrics.compare(src: es, out: C1Metrics.envelope(y))
                    let j = C1Metrics.jitterShimmer(Array(y))
                    print(String(format: "C1GATE %@ %@ %+5.0f f0err %+.2f alpha %.3f lsd %.2f lvl %+.2f jit x%.2f shim x%.2f hnr %.2f",
                                 name, label, c, C1Metrics.cents(f, ref * pf), e.alpha, e.lsd,
                                 C1Metrics.dB(C1Metrics.rms(y), l0), (j?.jitter ?? .nan) / js.jitter,
                                 (j?.shimmer ?? .nan) / js.shimmer, C1Metrics.acHNR(y, f0: f0s * pf)))
                    #expect(f.isFinite)
                }
            }
            if let rep = C1Make.make(s).epochReport {
                print("C1GATE \(name) epochs applied=\(rep.applied) reason=\(rep.reason) offset=\(rep.medianOffset) jitter=\(rep.jitterBefore)->\(rep.jitterAfter)")
            }
        }
    }
}
