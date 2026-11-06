// TDPSOLADeclick.swift
// PrimaeNative
//
// Lane TDQ (2026-11-03). Init-time (never on the render thread) limiter for the isolated strong glottal
// pulses of a voiced recording.
//
// Why. LOOPX measured 2-9 hf "clicks" per 8 s on the A phoneme at rates != 1 (TDQ.md section 1). The cause is
// not a seam: the engine's grain overlaps match (1 - NCC <= 0.2 at the 99th percentile, A; <= 0.012 on I, L, M),
// and no output pulse is stronger than the loudest pulse of the recording. A's recording has a few isolated
// pulses whose energy above 3 kHz is 3-4x the pulses around them. At rate 1 they sit inside each other's 25 ms
// context; a time-stretch (repeat or skip of periods) moves the strong pulses apart or drops their neighbours,
// so they stand out of the sound around them as a tick. The same events appear on the unprocessed recording
// when the detector's context is scaled to source time.
//
// What. For each pitch period, the strongest 1.5 ms window of the >3 kHz band (4th-order Butterworth,
// zero-phase) is the period's pulse. A pulse whose energy exceeds `cap` x the median pulse energy of the
// `neighbours` periods on each side is attenuated: only its >3 kHz part, by sqrt(cap * ref / energy)
// (never more than a few dB), under a Hann window of +/- `halfWidth` samples. Everything below 3 kHz, every
// other pulse, and all timing are untouched, so pitch marks, loop and attack stay valid.
//
// The renderer plays the processed copy; `TDPSOLAAnalysis` still describes the recording (the marks do not
// move). `cap = 0` (TDPSOLATuning.bakeoff) reproduces the pre-TDQ output bit for bit.

import Foundation

nonisolated enum TDPSOLADeclick {
    /// Pulses further than this many periods from a pulse are not its context.
    static let neighbours = 6
    /// Half width of the attenuation window, samples (+/- 1.4 ms at 44.1 kHz).
    static let halfWidth = 60

    private typealias Coeffs = (b0: Double, b1: Double, b2: Double, a1: Double, a2: Double)

    private static func highPass(fc: Double, sr: Double, q: Double) -> Coeffs {
        let w = 2 * Double.pi * fc / sr, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
        return ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0)
    }

    private static func run(_ x: [Double], _ k: Coeffs) -> [Double] {
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let v = k.b0 * x[i] + k.b1 * x1 + k.b2 * x2 - k.a1 * y1 - k.a2 * y2
            x2 = x1; x1 = x[i]; y2 = y1; y1 = v; y[i] = v
        }
        return y
    }

    /// The >3 kHz part of `x`: 4th-order Butterworth, run forward and backward (zero phase, so the part lines up
    /// with the samples it is subtracted from).
    static func highBand(_ x: [Float], sampleRate sr: Double, cutoff: Double = 3000) -> [Double] {
        let k1 = highPass(fc: cutoff, sr: sr, q: 0.5412), k2 = highPass(fc: cutoff, sr: sr, q: 1.3066)
        var y = run(run(x.map(Double.init), k1), k2)
        y.reverse()
        y = run(run(y, k1), k2)
        y.reverse()
        return y
    }

    struct Pulse: Equatable {
        /// Centre of the pulse's 1.5 ms window, source samples.
        let position: Int
        /// Mean square of the >3 kHz band over that window.
        let energy: Double
        /// Attenuation applied to the >3 kHz part (1 = untouched).
        let gain: Double
    }

    /// One pulse per pitch period of `a` (voiced analyses only), with the gain the limiter gives it.
    static func pulses(of x: [Float], sampleRate sr: Double, analysis a: TDPSOLAAnalysis, cap: Double,
                       band: [Double]) -> [Pulse] {
        guard a.isVoiced, !a.marks.isEmpty else { return [] }
        let w = max(8, Int((0.0015 * sr).rounded()))
        var pre = [Double](repeating: 0, count: band.count + 1)
        for i in 0..<band.count { pre[i + 1] = pre[i] + band[i] * band[i] }
        func energy(from i: Int) -> Double { (pre[i + w] - pre[i]) / Double(w) }
        var found: [(pos: Int, val: Double)] = []
        for i in 0..<a.marks.count {
            let m = Int(a.marks[i].rounded()), p = Int(a.periods[i])
            guard m >= 0, p > 0, m + p + w < band.count else { continue }
            var best = -1.0, at = m
            for s in m..<(m + p) { let e = energy(from: s); if e > best { best = e; at = s } }
            let pos = at + w / 2
            if let last = found.last, last.pos == pos { continue }   // the same pulse found from two marks
            found.append((pos, best))
        }
        var out: [Pulse] = []
        out.reserveCapacity(found.count)
        for j in 0..<found.count {
            var others: [Double] = []
            for k in max(0, j - neighbours)...min(found.count - 1, j + neighbours) where k != j { others.append(found[k].val) }
            let ref = TDPSOLAAnalysis.median(others)
            var gain = 1.0
            if cap > 0, ref > 0, found[j].val > cap * ref { gain = (cap * ref / found[j].val).squareRoot() }
            out.append(Pulse(position: found[j].pos, energy: found[j].val, gain: gain))
        }
        return out
    }

    /// `x` with its isolated strong pulses limited. Returns `x` itself when `cap` is 0, the source is not a
    /// voiced phoneme, or there is nothing to limit.
    static func process(_ x: [Float], sampleRate sr: Double, analysis a: TDPSOLAAnalysis, cap: Double) -> [Float] {
        guard cap > 0, a.isVoiced, x.count > 4096 else { return x }
        let band = highBand(x, sampleRate: sr)
        let ps = pulses(of: x, sampleRate: sr, analysis: a, cap: cap, band: band)
        var y = x
        for p in ps where p.gain < 1 {
            for d in -halfWidth...halfWidth {
                let i = p.position + d
                guard i >= 0, i < x.count else { continue }
                let hann = 0.5 + 0.5 * cos(Double.pi * Double(d) / Double(halfWidth + 1))
                y[i] -= Float((1 - p.gain) * hann * band[i])
            }
        }
        return y
    }
}
