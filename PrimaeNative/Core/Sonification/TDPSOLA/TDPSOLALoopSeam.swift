// TDPSOLALoopSeam.swift
// PrimaeNative
//
// SEAM2 (2026-11-04): the loop is prepared ONCE, at init, so the read-head
// never meets a step in level or timbre where the loop wraps.
//
// The recordings are ~2 s of sustained voice. The loop [loopStart, loopEnd)
// plays that sustained part end to start, and the end of a recording is not
// the same sound as its beginning: a different level (the voice decays or
// swells by up to ~1 dB), a different brightness. Played in a loop, that
// difference is a step at every wrap. No pop, so the click detector (LOOPX)
// saw nothing; the ear hears "it starts again" (David 2026-11-04).
//
// 1. Crossfade. The loop is shortened by `crossfade` seconds (whole pitch
//    periods for a voiced source) and its first `crossfade` seconds become a
//    blend from the material that FOLLOWS the new loop end to the loop's own
//    head. The read-head then leaves the end and arrives at the start on the
//    same waveform; the difference between end and start is spread over the
//    blend, not stepped. Voiced: the head's pitch marks are matched to the
//    tail's, mark to mark, so the blended waveforms are in phase. The weights
//    are quarter-sine / quarter-cosine, normalised per band (below 1 kHz,
//    1-3 kHz, above 3 kHz) for the two parts' measured correlation rho
//    (power-complementary for rho = 0, amplitude-complementary for rho = 1),
//    so neither the level nor the brightness bumps in the middle.
// 2. Flatten (optional). What remains is a slow level trajectory that
//    repeats each cycle. A gentle gain (200 ms circular RMS, limited to
//    +-`flattenDB`) holds the loop at the level of its own head, so there is
//    no drift to reset and the hand-over from the attack stays continuous.
//
// The attack, the marks, the periods and every render path are untouched:
// the renderer plays the prepared copy with a shortened loop end.

import Foundation

nonisolated enum TDPSOLALoopSeam {
    /// Pitch periods before the loop start that blend from the attack to the loop end's preceding material (ENV3; 0 = off).
    /// The default; a file with a recorded onset blends over its own `RecordedOnset.preBlendPeriods` (R17D, ONSET.md
    /// section 5: the last half of the onset, at most 100 ms). It is min(.., attackIndex), so a file whose attack is
    /// shorter is unchanged.
    static let preBlendMarks = 2
    struct Result {
        var samples: [Float]
        var loopEnd: Double
        var loopEndIndex: Int
        var rho: [Double] = []  // measured correlation of the blended parts per band (diagnostic)
    }

    /// Lane ENVGAP-A (2026-11-28) candidate knobs for the voiced head blend. `.shipped` (every knob off) is SEAM2 as
    /// shipped, bit for bit; no shipped option set turns any knob on (`TDPSOLA2Options.seamBlend`).
    ///
    /// Why (MEASURED, ENVGAP-A-REPORT.md): blending two pitch-synchronous segments of a vowel whose spectral
    /// envelope drifts sums them coherently, harmonic by harmonic. Where the head's and the tail's strongest
    /// harmonics (A: its F1 region) are out of phase, the middle of the blend cancels them: the middle third of A's
    /// 0.4 s blend reads 5.9 dB low at 500-1000 Hz against the steady segment, while the head and the tail it blends
    /// read +0.2 and -0.2 dB there. One correlation per broad band (below 1 kHz, 1-3 kHz, above 3 kHz) restores each
    /// band's average power over the whole blend, not the power where and when it cancels. And SEAM2 shortens the
    /// loop by the blend's length, so the blended head is a larger share of every loop cycle than of the recording.
    struct Blend: Sendable, Equatable, Hashable {
        /// ENVGAP-A item 14: the voiced crossfade length (seconds, rounded to whole periods as SEAM2 rounds it) in
        /// place of the tuning's `loopCrossfadeSeconds` (0.4 s). nil = the tuning's. A shorter blend shortens the loop
        /// less and holds less of the blended (two-part) material, which is the part of the loop furthest from the
        /// recording's steady spectrum (MEASURED on A, ENVGAP-A-REPORT.md). Unvoiced sources keep the tuning's.
        var crossfadeSeconds: Double? = nil
        /// ENVGAP-A item 13: waveform-similarity alignment of the tail before it is blended, the alignment step of
        /// SOLA (Roucos & Wilgus 1985, "High quality time-scale modification for speech", ICASSP) and WSOLA (Verhelst
        /// & Roelands 1993, "An overlap-add technique based on waveform similarity (WSOLA) for high quality time-scale
        /// modification of speech", ICASSP): per block of two periods, the tail read position takes the lag (within
        /// +-`alignLag` x the loop's median period) that maximises the normalised cross-correlation with the head.
        /// The lag curve is median-smoothed, faded in from 0 at the blend's start (where the tail must stay exactly
        /// the material after the loop end, so the wrap stays continuous) and slope-limited to `alignSlope` (samples
        /// per sample: a local tail pitch change of at most 1200 log2(1 + alignSlope) cents). 0 = off.
        var alignLag: Double = 0
        var alignSlope: Double = 0.004
        /// Item 13: the fraction of the blend over which the lag curve fades in from 0.
        var alignFade: Double = 0.25
        static let shipped = Blend()
    }

    /// nil when the source has nothing to prepare (disabled, too short a loop).
    static func prepare(_ x: [Float], sampleRate sr: Double, analysis a: TDPSOLAAnalysis,
                        crossfade: Double, flattenDB: Double, preBlendMarks: Int = Self.preBlendMarks,
                        blend: Blend = .shipped) -> Result? {
        let crossfade = a.isVoiced ? (blend.crossfadeSeconds.map { max(0, $0) } ?? crossfade) : crossfade
        guard crossfade > 0 || flattenDB > 0 else { return nil }
        let n = x.count
        var y = x
        var loopEnd = a.loopEnd
        var loopEndIndex = a.loopEndIndex
        let start = a.loopStart
        var maxPeriod = Double(a.unvoicedHop)
        var rho: [Double] = []
        let head0 = Int(start.rounded())

        // Head sample (offset u from the loop start) -> tail position, and the head length.
        var headLen = 0
        var tailPos: (Int) -> Double = { _ in 0 }
        if crossfade > 0 {
            if a.isVoiced {
                let ai = a.attackIndex, ei = a.loopEndIndex
                let avg = (a.loopEnd - a.loopStart) / Double(max(1, ei - ai + 1))
                let k = min(max(1, Int((crossfade * sr / avg).rounded())), (ei - ai) / 2)
                guard k >= 1 else { return nil }
                func mk(_ i: Int) -> Double {
                    i < a.marks.count ? a.marks[i] : a.marks[a.marks.count - 1] + Double(i - a.marks.count + 1) * a.periods[a.periods.count - 1]
                }
                let e2 = ei - k                          // new last mark; the new end is the mark after it
                loopEnd = mk(e2 + 1)
                loopEndIndex = e2
                headLen = Int((mk(ai + k) - mk(ai)).rounded())
                var map = [Double](repeating: 0, count: headLen)
                var j = 0
                for u in 0..<headLen {
                    let p = start + Double(u)
                    while j < k - 1 && p >= mk(ai + j + 1) { j += 1 }
                    let lo = mk(ai + j), hi = mk(ai + j + 1)
                    let f = (p - lo) / max(1e-9, hi - lo)
                    let t0 = mk(e2 + 1 + j), t1 = mk(e2 + 2 + j)
                    map[u] = t0 + f * (t1 - t0)
                }
                if blend.alignLag > 0 {
                    let loopPeriods = Array(a.periods[ai...ei]).sorted()
                    Self.align(&map, x: x, head0: head0, period: loopPeriods[loopPeriods.count / 2],
                               maxLag: blend.alignLag, slope: blend.alignSlope, fade: blend.alignFade)
                }
                tailPos = { map[$0] }
                maxPeriod = a.periods[ai...ei].max() ?? maxPeriod
            } else {
                headLen = Int((crossfade * sr).rounded())
                guard headLen * 2 < Int(a.loopEnd - a.loopStart) else { return nil }
                loopEnd = a.loopEnd - Double(headLen)
                let e = loopEnd
                tailPos = { e + Double($0) }
            }
            // Three bands (zero-phase split at 1 and 3 kHz, perfect reconstruction): the harmonics of a voice stay in
            // phase between the two parts (they blend by amplitude), the breath noise above them does not (it blends
            // by power). One correlation per band decides the weights, so the blend neither thickens the low part
            // nor thins the high part of the spectrum (a single weight did: A's brightness dipped 6 semitones).
            let hp1 = TDPSOLADeclick.highBand(x, sampleRate: sr, cutoff: 1000).map(Float.init)
            let hp3 = TDPSOLADeclick.highBand(x, sampleRate: sr, cutoff: 3000).map(Float.init)
            var cxy = [0.0, 0.0, 0.0], cxx = cxy, cyy = cxy
            var hb = [[Double]](repeating: [0, 0, 0], count: headLen), tb = hb
            for u in 0..<headLen {
                let i = head0 + u, tp = tailPos(u)
                let hx = Double(x[i]), h1 = Double(hp1[i]), h3 = Double(hp3[i])
                let tx = Double(read(x, tp)), t1 = Double(read(hp1, tp)), t3 = Double(read(hp3, tp))
                hb[u] = [hx - h1, h1 - h3, h3]
                tb[u] = [tx - t1, t1 - t3, t3]
                for k in 0..<3 { cxy[k] += hb[u][k] * tb[u][k]; cxx[k] += hb[u][k] * hb[u][k]; cyy[k] += tb[u][k] * tb[u][k] }
            }
            let rhos = (0..<3).map { k in cxx[k] > 0 && cyy[k] > 0 ? max(0, min(1, cxy[k] / (cxx[k] * cyy[k]).squareRoot())) : 0 }
            rho = rhos
            for u in 0..<headLen {
                let p = (Double(u) + 0.5) / Double(headLen)
                let w0 = cos(p * Double.pi / 2), w1 = sin(p * Double.pi / 2)
                var v = 0.0
                for k in 0..<3 {
                    let norm = (w0 * w0 + w1 * w1 + 2 * rhos[k] * w0 * w1).squareRoot()
                    v += (w1 * hb[u][k] + w0 * tb[u][k]) / norm
                }
                y[head0 + u] = Float(v)
            }
        }

        // ENV3 (2026-11-05): the grains that start the loop after the wrap are centred on the loop's first mark and read about a
        // period BEFORE it. In the prepared copy that is the end of the recording's attack, a different waveform from the
        // loop end the read-head has just left, so the join at `head0` was a step (measured on A: the first period of the
        // head had max|d1| 2.4x its neighbours, and the render's pulse at every wrap 2.4x its neighbours; without the seam 1.3x).
        // The `preBlendMarks` periods before the loop start now blend, pitch-synchronously, from the attack to the material
        // that precedes the (shortened) loop end, so the wrap joins a continuous waveform and the first pass from the attack
        // into the loop does not step either.
        if crossfade > 0, a.isVoiced, headLen > 0 {
            let ai = a.attackIndex, ei = a.loopEndIndex
            let avg = (a.loopEnd - a.loopStart) / Double(max(1, ei - ai + 1))
            let k = min(max(1, Int((crossfade * sr / avg).rounded())), (ei - ai) / 2)
            func mk(_ i: Int) -> Double {
                i < a.marks.count ? a.marks[i] : a.marks[a.marks.count - 1] + Double(i - a.marks.count + 1) * a.periods[a.periods.count - 1]
            }
            let pre = min(preBlendMarks, ai)
            if pre >= 1 {
                let e2 = ei - k
                let shift = e2 + 1 - ai            // attack mark i corresponds to tail mark i + shift
                let first = Int(mk(ai - pre).rounded(.up)), lastIdx = head0 - 1
                var i = ai - pre
                if first <= lastIdx {
                    for u in first...lastIdx {
                        let p = Double(u)
                        while i < ai - 1 && p >= mk(i + 1) { i += 1 }
                        let lo = mk(i), hi = mk(i + 1)
                        let f = (p - lo) / max(1e-9, hi - lo)
                        let t0 = mk(i + shift), t1 = mk(i + 1 + shift)
                        let tp = t0 + f * (t1 - t0)
                        let w = Double(u - first + 1) / Double(lastIdx - first + 2)
                        let ws = w * w * (3 - 2 * w)
                        y[u] = Float((1 - ws) * Double(x[u]) + ws * Double(read(x, tp)))
                    }
                }
            }
        }

        if flattenDB > 0 {
            let lo = head0, hi = Int(loopEnd.rounded())
            let len = hi - lo
            let grid = max(1, Int((0.010 * sr).rounded())), win = Int((0.2 * sr).rounded())
            guard len > 2 * win else { return Result(samples: y, loopEnd: loopEnd, loopEndIndex: loopEndIndex, rho: rho) }
            // Circular RMS on a 10 ms grid; target = the level of the ORIGINAL head (continuity with the attack).
            let cells = len / grid
            var e = [Double](repeating: 0, count: cells)
            for c in 0..<cells {
                var s = 0.0
                for i in 0..<grid { let v = Double(y[lo + c * grid + i]); s += v * v }
                e[c] = s / Double(grid)
            }
            let half = max(1, win / grid / 2)
            var target = 0.0
            let tw = 2 * half * grid
            for i in 0..<tw { let v = Double(x[lo + i]); target += v * v }
            target = max(target / Double(tw), 1e-12)
            // Circular box mean of the cell energies.
            var run = 0.0
            for i in -half..<half { run += e[(i + cells) % cells] }
            var gain = [Double](repeating: 1, count: cells)
            let limit = pow(10, flattenDB / 20)
            for c in 0..<cells {
                let lvl = max(run / Double(2 * half), 1e-12)
                gain[c] = min(limit, max(1 / limit, (target / lvl).squareRoot()))
                run += e[(c + half) % cells] - e[(c - half + cells) % cells]
            }
            func g(_ pos: Int) -> Double {      // linear between cell centres, circular
                let f = (Double(pos - lo) / Double(grid)) - 0.5
                let c0 = Int(f.rounded(.down)), t = f - Double(c0)
                return gain[(c0 % cells + cells) % cells] * (1 - t) + gain[((c0 + 1) % cells + cells) % cells] * t
            }
            for i in lo..<hi { y[i] = Float(Double(y[i]) * g(i)) }
            // The grains at the end read up to 1.5 periods past the new end: that is the head's start, same gain.
            let tailEnd = min(n, hi + Int(2 * maxPeriod))
            if hi < tailEnd { for i in hi..<tailEnd { y[i] = Float(Double(y[i]) * g(lo + (i - hi))) } }
        }
        return Result(samples: y, loopEnd: loopEnd, loopEndIndex: loopEndIndex, rho: rho)
    }

    /// ENVGAP-A item 13: moves the tail read positions `map` (one per head sample) by the waveform-similarity lag
    /// curve described at `Blend.alignLag`. `map[0]` is never moved.
    static func align(_ map: inout [Double], x: [Float], head0: Int, period: Double, maxLag: Double, slope: Double,
                      fade fadeFraction: Double) {
        let n = map.count
        let hop = max(8, Int(period.rounded())), block = 2 * hop, lagMax = max(1, Int((maxLag * period).rounded()))
        guard n > 2 * block else { return }
        // Best lag per block (centre c = b * hop + hop): normalised cross-correlation of head and lagged tail.
        var centres: [Int] = [], lags: [Double] = []
        var c0 = 0
        while c0 + block <= n {
            var best = 0, bestScore = -Double.infinity
            for d in -lagMax...lagMax {
                var xy = 0.0, xx = 0.0, yy = 0.0
                var v = c0
                while v < c0 + block {
                    let h = Double(x[head0 + v]), t = Double(read(x, map[v] + Double(d)))
                    xy += h * t; xx += h * h; yy += t * t
                    v += 1
                }
                let sc = xx > 0 && yy > 0 ? xy / (xx * yy).squareRoot() : -1
                if sc > bestScore + 1e-12 { bestScore = sc; best = d }
            }
            centres.append(c0 + hop); lags.append(Double(best))
            c0 += hop
        }
        // Median of 5 (a lag that jumps a whole period between blocks is a different period, not a drift).
        let med = lags.indices.map { i -> Double in
            let w = Array(lags[max(0, i - 2)...min(lags.count - 1, i + 2)]).sorted()
            return w[w.count / 2]
        }
        // Per-sample curve: linear between block centres, faded in (smoothstep) over the first `fadeFraction` of the blend.
        var delta = [Double](repeating: 0, count: n)
        var j = 0
        let fade = max(1, Int(Double(n) * min(1, max(0, fadeFraction))))
        for u in 0..<n {
            while j < centres.count - 1 && u >= centres[j + 1] { j += 1 }
            let d: Double
            if u <= centres[0] { d = med[0] } else if j >= centres.count - 1 { d = med[centres.count - 1] } else {
                let f = Double(u - centres[j]) / Double(centres[j + 1] - centres[j])
                d = med[j] * (1 - f) + med[j + 1] * f
            }
            let r = min(1, Double(u) / Double(fade))
            delta[u] = d * r * r * (3 - 2 * r)
        }
        // Slope limit, anchored at delta[0] = 0: forward then backward.
        delta[0] = 0
        for u in 1..<n { delta[u] = min(delta[u - 1] + slope, max(delta[u - 1] - slope, delta[u])) }
        for u in stride(from: n - 2, through: 1, by: -1) {
            delta[u] = min(delta[u + 1] + slope, max(delta[u + 1] - slope, delta[u]))
        }
        delta[0] = 0
        for u in 1..<n { delta[u] = min(delta[u - 1] + slope, max(delta[u - 1] - slope, delta[u])) }
        for u in 0..<n { map[u] += delta[u] }
    }

    /// Cubic Hermite read of `x` at a fractional position (zero outside).
    static func read(_ x: [Float], _ pos: Double) -> Float {
        let fl = pos.rounded(.down)
        let k = Int(fl), t = Float(pos - fl)
        guard k >= 1, k + 2 < x.count else { return k >= 0 && k < x.count ? x[k] : 0 }
        let y0 = x[k - 1], y1 = x[k], y2 = x[k + 1], y3 = x[k + 2]
        let c1 = 0.5 * (y2 - y0), c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3, c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + y1
    }
}
