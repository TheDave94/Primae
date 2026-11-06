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

    /// nil when the source has nothing to prepare (disabled, too short a loop).
    static func prepare(_ x: [Float], sampleRate sr: Double, analysis a: TDPSOLAAnalysis,
                        crossfade: Double, flattenDB: Double, preBlendMarks: Int = Self.preBlendMarks) -> Result? {
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
