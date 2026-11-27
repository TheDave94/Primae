// C1Metrics.swift
// PrimaeNativeTests — pitch bake-off phase 2, lane C1 "TDPSOLA2" (2026-11-23)
//
// The lane's own instruments, used until lane BENCH-P's harness lands (BAKEOFF-PITCH.md section 4; BENCH-P owns the
// definitions, and these are to be replaced by its API). Ported from the phase-1 analysis scripts
// (`method/metrics_r27.py`, `method/measure.py`), Foundation + Accelerate only, no test framework, so the same file
// also builds into the lane's macOS render driver:
//   - long-term spectrum (Hann, nfft 4096, 75 % overlap) and its Roebel-Rodet true envelope (cepstral order
//     0.5 fs / f0 of the segment itself; phase 1 fixed f0 at 360 Hz, see `envelope`), iterate max(A, V) until the
//     largest excess < 0.1 neper, <= 60 iterations);
//   - envelope comparison over 150-5000 Hz: level-free LSD at alpha = 1, and the warp alpha in [0.6, 1.6]
//     (201 steps) minimising the LSD of out(f) against src(f / alpha);
//   - f0 (normalised autocorrelation, 70-500 Hz; SonificationMetrics.f0's rule) and its median;
//   - mark-based period jitter / peak shimmer (marks from `TDPSOLAAnalysis` on the signal itself);
//   - an autocorrelation HNR (Boersma 1993's r / (1 - r) at the strongest lag near the period, 40 ms frames).
// Jitter, shimmer and HNR here are NOT Praat's numbers (no Praat on this seat); compare them only as ratios
// against the source or another render measured the same way.

import Foundation
import Accelerate
@testable import PrimaeNative

nonisolated enum C1Metrics {
    static let sr = 44100.0
    static let nfft = 4096

    static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        var s = 0.0
        for v in x { s += Double(v) * Double(v) }
        return (s / Double(x.count)).squareRoot()
    }
    static func dB(_ a: Double, _ ref: Double) -> Double { a <= 0 || ref <= 0 ? -300 : 20 * log10(a / ref) }
    static func cents(_ f: Double, _ ref: Double) -> Double { 1200 * log2(f / ref) }

    // MARK: f0

    static func f0(_ x: ArraySlice<Float>, from: Int, window: Int = 4096) -> Double? {
        let b = x.startIndex + from
        guard from >= 0, b + window + Int(sr / 70) + 2 <= x.endIndex else { return nil }
        let minLag = Int(sr / 500), maxLag = Int(sr / 70)
        var e0 = 0.0
        for i in 0..<window { e0 += Double(x[b + i]) * Double(x[b + i]) }
        guard e0 > 1e-9 else { return nil }
        var r = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var c = 0.0, e1 = 0.0
            for i in 0..<window {
                let p = Double(x[b + i]), q = Double(x[b + i + lag])
                c += p * q; e1 += q * q
            }
            r[lag] = e1 > 0 ? c / (e0 * e1).squareRoot() : 0
        }
        var best = -2.0
        for lag in minLag...maxLag { best = max(best, r[lag]) }
        guard best > 0.3 else { return nil }
        for lag in minLag...maxLag where r[lag] >= 0.9 * best && r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1] {
            let p = r[lag - 1], q = r[lag], s = r[lag + 1]
            let d = p - 2 * q + s
            return sr / (Double(lag) + (d != 0 ? 0.5 * (p - s) / d : 0))
        }
        return nil
    }

    /// f0 near `expected` (lags within +-15 %), same rule otherwise; raw pointers (fast in -Onone).
    static func f0Near(_ x: ArraySlice<Float>, expected: Double, windows k: Int = 7, window: Int = 4096) -> Double? {
        let maxLag = Int(sr / (expected / 1.15)) + 1, minLag = max(2, Int(sr / (expected * 1.15)))
        let span = x.count - window - maxLag - 2
        guard span > 0 else { return nil }
        let a = Array(x)
        var v: [Double] = []
        a.withUnsafeBufferPointer { b in
            let p = b.baseAddress!
            for w in 0..<k {
                let from = span * w / (k - 1)
                var e0 = 0.0
                for i in 0..<window { e0 += Double(p[from + i]) * Double(p[from + i]) }
                guard e0 > 1e-9 else { continue }
                var r = [Double](repeating: 0, count: maxLag + 2)
                for lag in (minLag - 1)...(maxLag + 1) {
                    var cc = 0.0, e1 = 0.0
                    var i = 0
                    while i < window { let q = Double(p[from + i + lag]); cc += Double(p[from + i]) * q; e1 += q * q; i &+= 1 }
                    r[lag] = e1 > 0 ? cc / (e0 * e1).squareRoot() : 0
                }
                var best = minLag
                for lag in minLag...maxLag where r[lag] > r[best] { best = lag }
                guard r[best] > 0.3, best > minLag, best < maxLag else { continue }
                let l = r[best - 1], m = r[best], h = r[best + 1]
                let d = l - 2 * m + h
                v.append(sr / (Double(best) + (d != 0 ? 0.5 * (l - h) / d : 0)))
            }
        }
        guard v.count >= (k + 1) / 2 else { return nil }
        v.sort()
        return v[v.count / 2]
    }

    /// Median f0 over `k` windows spread through the slice.
    static func medianF0(_ x: ArraySlice<Float>, windows k: Int = 9) -> Double? {
        let window = 4096
        let span = x.count - window - Int(sr / 70) - 2
        guard span > 0 else { return nil }
        let v = (0..<k).compactMap { f0(x, from: span * $0 / (k - 1), window: window) }.sorted()
        guard v.count >= (k + 1) / 2 else { return nil }
        return v[v.count / 2]
    }

    // MARK: true envelope

    /// Long-term power spectrum, bins 0 ... nfft/2.
    static func ltas(_ x: ArraySlice<Float>) -> [Double] {
        let n = nfft, half = n / 2, hop = n / 4
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        let win = (0..<n).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n))) }
        var acc = [Double](repeating: 0, count: half + 1)
        var frames = 0
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)
        var start = x.startIndex
        while start + n <= x.endIndex {
            for i in 0..<n { frame[i] = x[start + i] * win[i] }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            acc[0] += Double(re[0]) * Double(re[0])
            acc[half] += Double(im[0]) * Double(im[0])
            for k in 1..<half { acc[k] += Double(re[k]) * Double(re[k]) + Double(im[k]) * Double(im[k]) }
            frames += 1
            start += hop
        }
        return acc.map { $0 / Double(max(1, frames)) + 1e-20 }
    }

    /// Roebel-Rodet true envelope (dB) of a power spectrum with bins 0 ... n/2. (Raw pointers: the device test build
    /// is -Onone, where array subscripts in this 15 M multiply-add loop cost seconds per envelope.)
    static func trueEnvelope(_ P: [Double], order: Int, iters: Int = 60) -> [Double] {
        let nb = P.count, n = 2 * (nb - 1)
        let A = UnsafeMutablePointer<Double>.allocate(capacity: nb)
        let V = UnsafeMutablePointer<Double>.allocate(capacity: nb)
        let T = UnsafeMutablePointer<Double>.allocate(capacity: nb)
        let cosT = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let c = UnsafeMutablePointer<Double>.allocate(capacity: order + 1)
        defer { A.deallocate(); V.deallocate(); T.deallocate(); cosT.deallocate(); c.deallocate() }
        for k in 0..<nb { A[k] = 0.5 * log(P[k]); V[k] = -Double.infinity }
        for m in 0..<n { cosT[m] = cos(2 * Double.pi * Double(m) / Double(n)) }
        for _ in 0..<iters {
            for k in 0..<nb { T[k] = max(A[k], V[k]) }
            var q = 0
            while q <= order {
                var s = T[0] + (q % 2 == 0 ? 1 : -1) * T[nb - 1]
                var idx = 0, k = 1
                while k < nb - 1 { idx &+= q; if idx >= n { idx &-= n }; s += 2 * T[k] * cosT[idx]; k &+= 1 }
                c[q] = s / Double(n)
                q &+= 1
            }
            var maxEx = -Double.infinity
            var k = 0
            while k < nb {
                var v = c[0]
                var idx = 0, qq = 1
                while qq <= order { idx &+= k; if idx >= n { idx &-= n }; v += 2 * c[qq] * cosT[idx]; qq &+= 1 }
                V[k] = v
                maxEx = max(maxEx, A[k] - v)
                k &+= 1
            }
            if maxEx < 0.1 { break }
        }
        return (0..<nb).map { V[$0] * 20 / log(10) }
    }

    /// The true envelope with the cepstral order set by the segment's OWN f0 (0.5 fs / f0, Roebel & Rodet's rule),
    /// unless `f0max` is given (the phase-1 / BENCH-P definition fixes f0max at 360 Hz for every signal). A fixed order
    /// is not scale-covariant: a varispeed copy is smoothed at the same quefrency as its source, so its envelope is not
    /// the stretched source envelope, and the warp alpha that best maps one onto the other is biased. Measured on the
    /// four voiced study phonemes, varispeed x0.8409 / x1.1892 / x1.4142 (macOS, identical on the iPad): the fixed
    /// order reads alpha off by -0.015 ... +0.046 (A x1.4142: 1.445; L x1.4142: 1.460); the own-f0 order reads the
    /// nearest grid value (0.840 / 1.190 / 1.415) for every letter and factor. Without a measurable f0, 360 Hz.
    static func envelope(_ x: ArraySlice<Float>, f0max: Double? = nil) -> [Double] {
        let f = f0max ?? medianF0(x) ?? 360
        return trueEnvelope(ltas(x), order: Int(0.5 * sr / max(f, 100)))
    }

    /// (LSD at alpha 1, best alpha, LSD at best alpha), level-free, over lo...hi Hz. `src` and `out` are envelopes (dB).
    static func compare(src Ea: [Double], out Eb: [Double], lo: Double = 150, hi: Double = 5000)
        -> (lsd: Double, alpha: Double, lsdWarped: Double) {
        let df = sr / Double(nfft)
        let band = (0..<Ea.count).filter { Double($0) * df >= lo && Double($0) * df <= hi }
        func lsd(_ alpha: Double) -> Double {
            var d = [Double](); d.reserveCapacity(band.count)
            for k in band {
                let f = Double(k) * df / alpha
                let p = f / df
                let i = min(Ea.count - 2, max(0, Int(p)))
                let t = min(1, max(0, p - Double(i)))
                d.append(Eb[k] - (Ea[i] + (Ea[i + 1] - Ea[i]) * t))
            }
            let m = d.reduce(0, +) / Double(d.count)
            return (d.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(d.count)).squareRoot()
        }
        var bestA = 1.0, bestL = Double.infinity
        for k in 0..<201 {
            let a = 0.6 + Double(k) * 0.005
            let l = lsd(a)
            if l < bestL { bestL = l; bestA = a }
        }
        return (lsd(1), bestA, bestL)
    }

    // MARK: micro-variation

    /// Mark-based (jitter, shimmer) in percent: mean |T[k+1] - T[k]| / mean T, and mean |A[k+1] - A[k]| / mean A with
    /// A[k] the peak |x| within +-T/2 of mark k. Marks from the renderer's own analysis run on `x`.
    static func jitterShimmer(_ x: [Float]) -> (jitter: Double, shimmer: Double)? {
        let a = TDPSOLAAnalysis.analyse(x, sampleRate: sr, kind: .voicedPhoneme)
        guard a.isVoiced, a.marks.count > 20 else { return nil }
        let m = a.marks
        var t: [Double] = [], amp: [Double] = []
        for k in 1..<(m.count - 1) {
            t.append(m[k + 1] - m[k])
            let h = Int(0.5 * (m[k + 1] - m[k]))
            let c = Int(m[k])
            var p: Float = 0
            for i in max(0, c - h)..<min(x.count, c + h) { p = max(p, abs(x[i])) }
            amp.append(Double(p))
        }
        func rel(_ v: [Double]) -> Double {
            var d = 0.0
            for k in 1..<v.count { d += abs(v[k] - v[k - 1]) }
            let mean = v.reduce(0, +) / Double(v.count)
            return 100 * (d / Double(v.count - 1)) / mean
        }
        return (rel(t), rel(amp))
    }

    /// Autocorrelation HNR (dB), mean over 40 ms frames (hop 10 ms) whose best r in [T/1.25, 1.25 T] is > 0.
    static func acHNR(_ x: ArraySlice<Float>, f0: Double) -> Double {
        let w = Int(0.04 * sr), hop = Int(0.01 * sr)
        let T = sr / f0
        let lo = Int(T / 1.25), hi = Int(T * 1.25) + 1
        var vals: [Double] = []
        var s = x.startIndex
        while s + w + hi < x.endIndex {
            var best = -1.0
            var e0 = 0.0
            for i in 0..<w { e0 += Double(x[s + i]) * Double(x[s + i]) }
            for lag in lo...hi {
                var c = 0.0, e1 = 0.0
                for i in 0..<w { let q = Double(x[s + i + lag]); c += Double(x[s + i]) * q; e1 += q * q }
                let r = e0 > 0 && e1 > 0 ? c / (e0 * e1).squareRoot() : 0
                best = max(best, r)
            }
            if best > 0 { let r = min(best, 0.999999); vals.append(10 * log10(r / (1 - r))) }
            s += hop
        }
        return vals.isEmpty ? -.infinity : vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: driving a renderer

    /// Steady render: gate open at 0 with fixed rate and cents, 256-frame buffers.
    static func steady(_ r: any SonificationRenderer, seconds: Double, rate: Float, cents: Float) -> [Float] {
        r.reset()
        r.setRate(rate); r.setPitchCents(cents); r.setGate(true)
        let total = Int(seconds * sr)
        var out = [Float](repeating: 0, count: total)
        out.withUnsafeMutableBufferPointer { b in
            var pos = 0
            while pos < total { let n = min(256, total - pos); r.render(into: b.baseAddress! + pos, frames: n); pos += n }
        }
        return out
    }

    /// FNV-1a over the bit patterns (device/macOS render identity).
    static func hash(_ x: [Float]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for v in x { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        return h
    }
}
