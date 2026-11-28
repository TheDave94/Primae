// BakeoffSynthetic.swift
// PrimaeNativeTests — sonification bake-off harness (BENCH lane, 2026-11-02)
//
// Synthetic signals with a known answer, for mutation-checking the metrics
// (`BakeoffMetricSelfTests`). Foundation only.

import Foundation

enum BakeoffSynthetic {

    /// Deterministic white noise in -0.5...0.5 (LCG; identical every run).
    static func noise(_ n: Int, seed: UInt32 = 12345) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 1_664_525 &+ 1_013_904_223
            return Float(s >> 8) / Float(1 << 24) - 0.5
        }
    }

    /// Harmonic tone (3 partials) at `f` Hz with a 2 ms attack starting at `start`.
    static func tone(_ f: Double, count: Int, sampleRate: Double, start: Int = 0, amplitude: Float = 0.3) -> [Float] {
        var x = [Float](repeating: 0, count: count)
        let ramp = Int(0.002 * sampleRate)
        for i in start..<count {
            let t = Double(i - start) / sampleRate
            let s = sin(2 * .pi * f * t) + 0.5 * sin(4 * .pi * f * t) + 0.25 * sin(6 * .pi * f * t)
            let g = Float(min(1, Double(i - start) / Double(ramp)))
            x[i] = Float(s) * amplitude * g / 1.75
        }
        return x
    }

    // MARK: - Sweep probe (the rate metrics' source)

    static let sweepF0 = 120.0
    static let sweepOctaves = 2.0
    static let sweepSeconds = 2.0

    /// A harmonic tone (3 partials, 0.3 peak) gliding exponentially from
    /// 120 Hz to 480 Hz over 2 s, phase-continuous, with 10 ms fades at the
    /// loop seam. Voice-like in range and spectrum, so a PSOLA candidate can
    /// mark it; its pitch is its clock (`BakeoffMetrics.sweepTrack`).
    static func sweepProbe(sampleRate: Double) -> [Float] {
        let n = Int(sweepSeconds * sampleRate)
        let fade = Int(0.01 * sampleRate)
        var x = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let f = sweepF0 * pow(2, sweepOctaves * t / sweepSeconds)
            phase += 2 * .pi * f / sampleRate
            let s = sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)
            let g = min(1, Double(min(i, n - 1 - i)) / Double(fade))
            x[i] = Float(s * g * 0.3 / 1.75)
        }
        return x
    }

    /// What a PERFECT time-scale modification outputs for the sweep probe:
    /// the source is read at `rate(outputFrame)` (source seconds per output
    /// second) while the pitch at each instant is the source's pitch at the
    /// read position, phase integrated in output time (a sinusoidal-model
    /// TSM, exact for this signal). The known answer for the rate metrics.
    static func idealSweepTSM(count: Int, sampleRate: Double, rate: (Int) -> Double) -> [Float] {
        var x = [Float](repeating: 0, count: count)
        var s = 0.0, phase = 0.0
        for i in 0..<count {
            let pos = s.truncatingRemainder(dividingBy: sweepSeconds)
            let f = sweepF0 * pow(2, sweepOctaves * pos / sweepSeconds)
            phase += 2 * .pi * f / sampleRate
            let edge = min(pos, sweepSeconds - pos)
            let g = min(1, edge / 0.01)
            x[i] = Float((sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) * g * 0.3 / 1.75)
            s += rate(i) / sampleRate
        }
        return x
    }
}

// MARK: - Pitch phase 2 (lane BENCH-P): a source-filter vowel with a known answer

extension BakeoffSynthetic {

    /// A vowel by construction: band-limited glottal impulses (16-tap Hann-windowed sinc at the exact, fractional
    /// pulse time) through a FIXED cascade of formant resonators (700/80, 1220/90, 2600/120 Hz; Klatt). Changing
    /// `f0` moves the harmonics under the SAME envelope (an ideal envelope-preserving shift: warp alpha 1);
    /// resampling the output moves the envelope with them (alpha = the resampling factor).
    /// `f0At(t)` gives the instantaneous f0 (Hz) at time t (s); `jitter` / `shimmer` are the standard deviations of an
    /// i.i.d. relative perturbation of each period / pulse amplitude (deterministic LCG). Returns the signal and the
    /// periods (s) and amplitudes actually used. `formants: false` returns the band-limited pulse train itself (periods
    /// unambiguous: the jitter estimator's cleanest truth case).
    static func vowel(seconds: Double, sampleRate sr: Double, f0At: (Double) -> Double, jitter: Double = 0,
                      shimmer: Double = 0, seed: UInt32 = 777,
                      formants: Bool = true) -> (x: [Float], periods: [Double], amps: [Double]) {
        let n = Int(seconds * sr)
        var e = [Double](repeating: 0, count: n + 32)
        var state = seed
        func gauss() -> Double {   // Box-Muller over the LCG
            state = state &* 1_664_525 &+ 1_013_904_223
            let u1 = max(1e-12, Double(state) / 4_294_967_296)
            state = state &* 1_664_525 &+ 1_013_904_223
            let u2 = Double(state) / 4_294_967_296
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
        var t = 0.01
        var periods: [Double] = [], amps: [Double] = []
        while t * sr < Double(n) {
            let a = 1 + shimmer * gauss()
            let pos = t * sr
            let c = Int(pos.rounded(.down))
            for k in -7...8 {
                let i = c + k
                guard i >= 0 && i < e.count else { continue }
                let d = Double(i) - pos
                let w = 0.5 + 0.5 * cos(.pi * d / 8.5)
                let s = abs(d) < 1e-12 ? 1 : sin(.pi * d) / (.pi * d)
                e[i] += a * s * w
            }
            amps.append(a)
            let p = (1 / f0At(t)) * (1 + jitter * gauss())
            periods.append(p)
            t += p
        }
        var y = Array(e[0..<n])
        for (f, bw) in formants ? [(700.0, 80.0), (1220.0, 90.0), (2600.0, 120.0)] : [] {
            let r = exp(-.pi * bw / sr)
            let a1 = 2 * r * cos(2 * .pi * f / sr), a2 = -r * r
            let g = 1 - a1 - a2   // unity gain at DC
            var y1 = 0.0, y2 = 0.0
            for i in 0..<n {
                let v = g * y[i] + a1 * y1 + a2 * y2
                y2 = y1; y1 = v; y[i] = v
            }
        }
        let peak = y.map(abs).max() ?? 1
        return (y.map { Float(0.5 * $0 / peak) }, periods, amps)
    }

    /// Reads `x` at `factor` times its own speed (linear interpolation): a resampled ("chipmunk") copy.
    static func resample(_ x: [Float], factor: Double) -> [Float] {
        let n = Int(Double(x.count - 1) / factor)
        return (0..<n).map { i in
            let p = Double(i) * factor
            let k = Int(p), f = Float(p - Double(k))
            return x[k] + f * (x[min(k + 1, x.count - 1)] - x[k])
        }
    }

    /// Local jitter / shimmer (percent) of a generated sequence, the quantity `PitchMetrics.perturbation` estimates.
    static func localPerturbation(_ v: [Double]) -> Double {
        var d = 0.0, s = 0.0
        for i in 1..<v.count { d += abs(v[i] - v[i - 1]); s += 0.5 * (v[i] + v[i - 1]) }
        return d / s * 100
    }
}
