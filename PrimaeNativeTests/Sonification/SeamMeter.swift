// SeamMeter.swift
// PrimaeNativeTests — lane SEAM2 (2026-11-04): the loop-seam instrument.
//
// LOOPX looked for POPS at the loop wrap and found none: the wrong instrument.
// The audible seam is a change in LEVEL or TIMBRE (and a slow in-cycle drift
// that resets at the wrap) repeating every loop cycle. This meter reads a
// rendered buffer as feature tracks at a 10 ms hop (46 ms Hann frames) and
// compares the step ACROSS each wrap with the distribution of steps INSIDE the
// loop (`SeamEvaluator.swift`). Pure Swift, no frameworks: the same file is
// compiled into the Mac driver and the device tests.

import Foundation

nonisolated struct SeamTrack {
    static let frame = 2048
    static let hop = 441
    var sr: Double
    var t: [Double] = []            // frame centre, seconds
    var level: [Double] = []        // dB, Hann-weighted mean square
    var centroid: [Double] = []     // semitones re 100 Hz
    var bands: [[Double]] = []      // octave band dB, 177 Hz ... 11.3 kHz (each holds several harmonics, so no harmonic-in-band flicker)
    var f0: [Double] = []           // cents re 100 Hz, NaN when unvoiced
    var periodicity: [Double] = []  // best normalised autocorrelation 0...1
    var flux: [Double] = []         // L2 of band-dB change from the frame before
    var hopSeconds: Double { Double(Self.hop) / sr }
}

nonisolated enum SeamMeter {
    static let bandCount = 6

    /// In-place radix-2 FFT, n a power of two.
    static func fft(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var len = 2
        while len <= n {
            let ang = -2 * Double.pi / Double(len)
            let wr = cos(ang), wi = sin(ang)
            var i = 0
            while i < n {
                var cr = 1.0, ci = 0.0
                for k in 0..<(len / 2) {
                    let a = i + k, b = i + k + len / 2
                    let tr = re[b] * cr - im[b] * ci, ti = re[b] * ci + im[b] * cr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    let nr = cr * wr - ci * wi
                    ci = cr * wi + ci * wr; cr = nr
                }
                i += len
            }
            len <<= 1
        }
    }

    static func analyse(_ x: [Float], sr: Double) -> SeamTrack {
        var tr = SeamTrack(sr: sr)
        let n = SeamTrack.frame
        guard x.count >= n else { return tr }
        let win = (0..<n).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(n)) }
        let wsq = win.reduce(0) { $0 + $1 * $1 }
        // Octave band edges as bin ranges: [177 * 2^k, 354 * 2^k) Hz.
        let binHz = sr / Double(n)
        var edges: [(Int, Int)] = []
        for k in 0..<bandCount {
            let f0 = 177 * pow(2, Double(k))
            let lo = max(1, Int((f0 / binHz).rounded(.up)))
            let hi = min(n / 2 - 1, max(lo, Int((2 * f0 / binHz).rounded(.up)) - 1))
            edges.append((lo, hi))
        }
        let minLag = Int(sr / 500), maxLag = Int(sr / 70)
        let acN = 1764
        var start = 0
        var prevBands: [Double]?
        while start + n <= x.count {
            var re = [Double](repeating: 0, count: n), im = re
            var ms = 0.0
            for i in 0..<n { let v = Double(x[start + i]) * win[i]; re[i] = v; ms += v * v }
            fft(&re, &im)
            var pow2 = [Double](repeating: 0, count: n / 2)
            for k in 0..<(n / 2) { pow2[k] = re[k] * re[k] + im[k] * im[k] }
            var num = 0.0, den = 0.0
            for k in 1..<(n / 2) { num += Double(k) * binHz * pow2[k]; den += pow2[k] }
            let cen = den > 1e-18 ? num / den : 100
            var b = [Double](repeating: -100, count: bandCount)
            for (i, e) in edges.enumerated() {
                var s = 0.0
                for k in e.0...e.1 { s += pow2[k] }
                // Floored 50 dB under the frame's level, so empty bands (leakage, rounding) do not enter the profile.
                b[i] = max(10 * log10(ms / wsq + 1e-12) - 50, 10 * log10(s / (Double(n) * wsq) + 1e-12))
            }
            var fl = 0.0
            if let p = prevBands { for i in 0..<bandCount { fl += (b[i] - p[i]) * (b[i] - p[i]) }; fl = fl.squareRoot() }
            prevBands = b
            // f0 and periodicity: normalised autocorrelation of a 40 ms window at the frame centre.
            let c0 = start + n / 2 - acN / 2
            var best = 0.0, bestLag = 0
            if c0 >= 0, c0 + acN + maxLag < x.count {
                var e0 = 0.0
                var j = 0
                while j < acN { let v = Double(x[c0 + j]); e0 += v * v; j += 2 }
                var rs = [Double](repeating: 0, count: maxLag + 2)
                for lag in minLag...maxLag {
                    var c = 0.0, e1 = 0.0
                    j = 0
                    while j < acN {
                        let a = Double(x[c0 + j]), bb = Double(x[c0 + lag + j])
                        c += a * bb; e1 += bb * bb; j += 2
                    }
                    let d = (e0 * e1).squareRoot()
                    rs[lag] = d > 1e-12 ? c / d : 0
                    best = max(best, rs[lag])
                }
                // First local maximum within 90 % of the best (suppresses sub-harmonic picks, as the analysis does).
                for lag in (minLag + 1)..<maxLag where rs[lag] >= best * 0.9 && rs[lag] >= rs[lag - 1] && rs[lag] >= rs[lag + 1] {
                    bestLag = lag; break
                }
            }
            tr.t.append(Double(start + n / 2) / sr)
            tr.level.append(10 * log10(ms / wsq + 1e-12))
            tr.centroid.append(12 * log2(max(cen, 1) / 100))
            tr.bands.append(b)
            tr.flux.append(fl)
            tr.periodicity.append(max(0, best))
            tr.f0.append(best > 0.5 && bestLag > 0 ? 1200 * log2((sr / Double(bestLag)) / 100) : .nan)
            start += SeamTrack.hop
        }
        return tr
    }
}
