// LoopXDetector.swift
// PrimaeNativeTests — lane LOOPX (2026-11-03): the click / discontinuity
// detector behind the loop-seam and stroke-crossover diagnosis.
//
// A listener calls something a pop when a SHORT broadband burst stands out
// of the sound around it, or when the sound drops out for a few ms inside an
// otherwise continuous sound. Two measures, both relative to the signal's
// own neighbourhood (so they work on a vowel, a noise phoneme and a tone):
//
//   hf    energy above ~3 kHz (4th-order Butterworth high-pass) in 1.5 ms
//         windows, hop 0.5 ms, divided by the LARGER of the medians of the
//         25 ms before and the 25 ms after (excluding +/- 3 ms). The larger
//         side makes a legitimate onset (silence before, sound after) or a
//         legitimate end read ~1, while a burst inside steady sound, or at a
//         hard cut, reads high.
//   cut   the level falls by >= 20 dB within ~3 ms from a sounding level
//         (an abrupt stop: a short duck to silence, a hard cut).
//   dip   2 ms RMS below a quarter (-12 dB) of the medians of BOTH the
//         30 ms before and the 30 ms after, with both sides sounding (above
//         -30 dB of the render's own 95th-percentile level): a dropout
//         inside a continuous sound (a duck-and-restart), not an end.
//
// Thresholds are calibrated on planted controls (LoopXDiagnosisTests:
// a hard cut, a hard restart splice, a phase-jump loop splice; and the
// negative controls: every source as recorded, steady renders before any
// wrap). Pure Swift: no XCTest, so the same file also builds the Mac-native
// quick driver the lane used before the device runs.

import Foundation

nonisolated enum LoopXDetector {
    static let hfThreshold = 2.0     // x the louder side's local maximum (6 dB)
    static let dipThreshold = 0.25   // x both sides' local median (-12 dB)
    static let cutThreshold = 0.1    // after / before across ~3 ms (-20 dB)
    static let resThreshold = 0.5    // unpredicted fraction of a 1.5 ms window (calibrated on the controls)

    struct Event: CustomStringConvertible {
        let time: Double       // seconds
        let kind: String       // "hf", "dip", "cut", "res", or a merged "a+b"
        let score: Double      // hf: ratio (>= threshold); dip: 1 / ratio
        var mechanism = "?"
        var description: String {
            String(format: "%@ %.3fs %.1f [%@]", kind, time, score, mechanism)
        }
    }

    /// Direct-form-I biquad, run in Double.
    struct Biquad {
        var b0, b1, b2, a1, a2: Double
        static func highPass(fc: Double, sr: Double, q: Double) -> Biquad {
            let w = 2 * Double.pi * fc / sr, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
            return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                          a1: -2 * c / a0, a2: (1 - al) / a0)
        }
        func run(_ x: [Double]) -> [Double] {
            var y = [Double](repeating: 0, count: x.count)
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<x.count {
                let v = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1; x1 = x[i]; y2 = y1; y1 = v; y[i] = v
            }
            return y
        }
    }

    /// 4th-order Butterworth high-pass at `fc` (two biquads, Q 0.541 / 1.307).
    static func highPass(_ x: [Float], sr: Double, fc: Double = 3000) -> [Double] {
        let d = x.map(Double.init)
        return Biquad.highPass(fc: fc, sr: sr, q: 1.3066).run(Biquad.highPass(fc: fc, sr: sr, q: 0.5412).run(d))
    }

    static func median(_ v: ArraySlice<Double>) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s[s.count / 2]
    }

    /// Windowed mean square of `x` (window `w`, hop `h`); entry k covers [k*h, k*h + w).
    static func meanSquare(_ x: [Double], w: Int, h: Int) -> [Double] {
        guard x.count >= w else { return [] }
        var pre = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { pre[i + 1] = pre[i] + x[i] * x[i] }
        return stride(from: 0, through: x.count - w, by: h).map { (pre[$0 + w] - pre[$0]) / Double(w) }
    }

    /// Every event in `y`, merged within 10 ms (the strongest kept).
    static func detect(_ y: [Float], sr: Double) -> [Event] {
        let hop = max(1, Int(0.0005 * sr))
        var events: [Event] = []

        // hf
        let h = highPass(y, sr: sr)
        let e = meanSquare(h, w: Int(0.0015 * sr), h: hop)
        let ctx = Int(0.025 * sr) / hop, gap = Int(0.003 * sr) / hop
        let peakHF = e.max() ?? 0
        for k in 0..<e.count where e[k] > peakHF * 1e-6 {
            let before = e[max(0, k - ctx)..<max(0, k - gap)].max() ?? 0
            let after = e[min(e.count, k + gap)..<min(e.count, k + ctx)].max() ?? 0
            let ref = max(before, after, peakHF * 1e-7)
            let r = e[k] / ref
            if r >= hfThreshold { events.append(Event(time: Double(k * hop) / sr, kind: "hf", score: r)) }
        }

        // dip
        let d = y.map(Double.init)
        let r2 = meanSquare(d, w: Int(0.002 * sr), h: hop).map { $0.squareRoot() }
        let r30 = Int(0.030 * sr) / hop, g2 = Int(0.004 * sr) / hop
        let sorted = r2.sorted()
        let level = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        let floor = level * 0.0316   // -30 dB
        for k in 0..<r2.count {
            let before = median(r2[max(0, k - r30)..<max(0, k - g2)])
            let after = median(r2[min(r2.count, k + g2)..<min(r2.count, k + r30)])
            guard before > floor, after > floor else { continue }
            let ref = min(before, after)
            if r2[k] < ref * dipThreshold {
                events.append(Event(time: Double(k * hop) / sr, kind: "dip", score: ref / max(r2[k], 1e-12)))
            }
        }
        // cut: the sound stops within ~3 ms (>= 20 dB from the 5 ms before
        // to the 5 ms after, 1.5 ms guard), from above the floor. Only drops:
        // a fast rise from silence is the specified onset.
        let w5 = Int(0.0045 * sr) / hop, g15 = Int(0.0015 * sr) / hop
        if r2.count > 2 * (w5 + g15) {
            for k in (w5 + g15)..<(r2.count - w5 - g15) {
                let before = r2[(k - g15 - w5)..<(k - g15)].reduce(0, +) / Double(w5)
                guard before > floor * 3.16 else { continue }   // -20 dB of the level
                let after = r2[(k + g15)..<(k + g15 + w5)].reduce(0, +) / Double(w5)
                if after < before * cutThreshold {
                    events.append(Event(time: Double(k * hop) / sr, kind: "cut", score: before / max(after, 1e-12)))
                }
            }
        }
        return merge(events, within: 0.010)
    }

    /// One event per cluster (events closer than `within`), whatever their
    /// kinds: the kinds are joined ("cut+dip"), the score is the cluster's
    /// strongest of the first kind seen.
    static func merge(_ ev: [Event], within: Double) -> [Event] {
        var out: [Event] = []
        var lastTime = -1.0
        for x in ev.sorted(by: { $0.time < $1.time }) {
            if !out.isEmpty, x.time - lastTime <= within {
                let l = out[out.count - 1]
                let kinds = Set(l.kind.split(separator: "+").map(String.init) + x.kind.split(separator: "+").map(String.init))
                let score = l.kind.hasPrefix(x.kind) ? max(l.score, x.score) : l.score
                out[out.count - 1] = Event(time: l.time, kind: kinds.sorted().joined(separator: "+"), score: score)
            } else {
                out.append(x)
            }
            lastTime = x.time
        }
        return out
    }

    /// Source-aware measure ("res", voiced sources and the carrier): how much
    /// of a 1.5 ms window is NOT the same waveform one period earlier,
    /// 1 - max over lags in `period` of the squared normalised correlation with
    /// the signal one lag back (positive correlation only; gain-free, so a fade is not an event). A
    /// periodic sound reads near 0 even with sharp glottal pulses (A); a
    /// click, a splice, a loop jump or a restart reads near 1 for about one
    /// period. Skipped where either window is quiet (onsets and ends are
    /// the cut measure's), and for noise (F), where nothing predicts it.
    static func residual(_ y: [Float], sr: Double, period: ClosedRange<Double>,
                         threshold: Double = resThreshold) -> [Event] {
        let hop = max(1, Int(0.0005 * sr)), w = Int(0.0015 * sr)
        let lo = Int(period.lowerBound.rounded(.down)), hi = Int(period.upperBound.rounded(.up))
        let d = y.map(Double.init)
        let r2 = meanSquare(d, w: w, h: hop)
        let sorted = r2.sorted()
        let level = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)]
        var out: [Event] = []
        var k = (hi + hop) / hop
        while k * hop + w <= d.count, k < r2.count {
            let a = k * hop
            if r2[k] > level * 0.01 {                     // -20 dB
                var ex = 0.0
                for j in 0..<w { ex += d[a + j] * d[a + j] }
                var best = 0.0, quiet = true
                for lag in lo...hi {
                    var xy = 0.0, yy = 0.0
                    for j in 0..<w { let b = d[a + j - lag]; xy += d[a + j] * b; yy += b * b }
                    if yy > ex * 0.1 { quiet = false; if xy > 0 { best = max(best, xy * xy / (ex * yy)) } }
                }
                if !quiet && 1 - best >= threshold {
                    out.append(Event(time: Double(a) / sr, kind: "res", score: 1 - best))
                }
            }
            k += 1
        }
        return out
    }

    /// Events of both channels, merged; each labelled with the nearest
    /// mechanism mark within 15 ms (else "none").
    static func detect(left: [Float], right: [Float], sr: Double,
                       marks: [(t: Double, label: String)], period: ClosedRange<Double>? = nil,
                       resThreshold: Double = resThreshold) -> [Event] {
        var raw = detect(left, sr: sr) + detect(right, sr: sr)
        if let period {
            raw += residual(left, sr: sr, period: period, threshold: resThreshold)
                + residual(right, sr: sr, period: period, threshold: resThreshold)
        }
        let all = merge(raw, within: 0.010)
        return all.map { ev in
            var e = ev
            let near = marks.filter { abs($0.t - ev.time) <= 0.015 }
                .min { abs($0.t - ev.time) < abs($1.t - ev.time) }
            e.mechanism = near?.label ?? "none"
            return e
        }
    }

    /// Writes 16-bit PCM WAV (interleaved when two channels).
    static func writeWAV(_ channels: [[Float]], sr: Double, to url: URL) throws {
        let n = channels[0].count, c = channels.count
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + n * c * 2))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(UInt16(c))
        u32(UInt32(sr)); u32(UInt32(sr) * UInt32(c * 2)); u16(UInt16(c * 2)); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(n * c * 2))
        for i in 0..<n {
            for ch in channels { u16(UInt16(bitPattern: Int16(max(-1, min(1, ch[i])) * 32767))) }
        }
        try d.write(to: url)
    }
}
