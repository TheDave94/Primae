// TDPSOLA2Epochs.swift
// PrimaeNative — pitch bake-off phase 2, candidate C1 "TDPSOLA2", item 5 (2026-11-23); the phoneme arm's renderer from protocol r31 (lane PITCHWIN, 2026-11-26)
//
// Epoch refinement at init: today's pitch marks (`TDPSOLAAnalysis`: waveform-consistent epochs, the same phase in
// every period, NOT glottal closures) are kept as the coarse estimate and snapped to glottal closure instants (GCIs)
// found by a SEDREAMS-style search. Written from the published descriptions only:
//   Drugman, Thomas, Gudnason, Naylor, Dutoit, "Detection of Glottal Closure Instants from Speech Signals: a
//   Quantitative Review", arXiv 2001.00473 (SEDREAMS, section 3); Drugman & Dutoit, Interspeech 2009.
//
// 1. A 16 kHz copy (Kaiser-sinc decimation, zero phase, `TDPSOLA2Sinc`).
// 2. LP residual: order fs/1000 + 2 = 18, autocorrelation method (Hann, 25 ms frames, 5 ms hop, Levinson), the
//    inverse filter applied to the un-windowed signal around each frame centre.
// 3. Mean-based signal (MBS): a Blackman-weighted moving mean whose length is 1.75 x the LOCAL period (from the
//    coarse marks), then its own one-period moving mean removed. It oscillates once per cycle.
// 4. One interval per cycle: from each MBS minimum (the lowest within +-0.5 period) to the MBS's next positive-going
//    zero crossing, at most half a period long. Inside it, the strongest residual peak of the GCI polarity is the GCI
//    (parabola-refined). Polarity: the brief names the strongest NEGATIVE peak; the sign is taken from the residual's
//    skewness over the voiced region (negative skew -> negative peaks), so an inverted recording is read correctly.
//    A skew of exactly 0 falls back to negative.
// 5. Association: each mark's nearest GCI within +-T/2 gives a signed offset; their median is the constant phase
//    offset between the two mark families. Each mark then snaps to the GCI nearest (mark + median offset) within
//    +-T/4; a mark with no GCI there moves by the median offset only (so the set stays phase-consistent).
// 6. Guards (a gross failure keeps the OLD marks for the whole source, and says why in the report):
//    - marks must stay strictly increasing, with every new period within 0.7..1.3 x the old one;
//    - the period-to-period jitter of the marks themselves (mean |T[k+1] - T[k]| / mean T over the loop marks) must
//      not grow by more than `guardRatio` (1.2 = +20 %, the brief's value).
//
// Indices (attack, loop end) are kept; the loop bounds are re-derived from the moved marks exactly as the analysis
// derives them, so every downstream step (loop seam, TDQ limiter, renderer) sees one consistent mark set.
// Deterministic: plain IEEE arithmetic, no randomness.

import Foundation

nonisolated enum TDPSOLA2Epochs {
    final class Box: Sendable, Equatable {
        let report: Report
        init(_ r: Report) { report = r }
        static func == (a: Box, b: Box) -> Bool { a.report == b.report }
    }
    struct Report: Sendable, Equatable {
        /// The snapped marks were adopted.
        var applied: Bool
        /// Why not (or "snapped").
        var reason: String
        var jitterBefore: Double = 0
        var jitterAfter: Double = 0
        var gciCount: Int = 0
        /// Marks that found a GCI within +-T/4 of (mark + median offset).
        var matched: Int = 0
        var markCount: Int = 0
        /// Median GCI - mark offset, source samples.
        var medianOffset: Double = 0
        /// Mean |new mark - (old mark + median offset)|, source samples.
        var meanResidualShift: Double = 0
        /// -1 or +1.
        var polarity: Double = -1
        /// Phase fallback: the refused snap's own report.
        var refusedSnap: Box? = nil
        var snapRefused: Report? { get { refusedSnap?.report } set { refusedSnap = newValue.map(Box.init) } }
        static func kept(_ why: String) -> Report { Report(applied: false, reason: why) }
    }

    static let lpcOrder = 18
    static let decimatedRate = 16000.0

    static func refine(_ x: [Float], sampleRate sr: Double, analysis a: TDPSOLAAnalysis,
                       guardRatio: Double, phaseOnly: Bool = false) -> (analysis: TDPSOLAAnalysis, report: Report) {
        guard a.isVoiced, a.marks.count >= 8, a.loopEndIndex - a.attackIndex >= 4 else {
            return (a, .kept("not voiced / too few marks"))
        }
        let gcis = detectGCIs(x, sampleRate: sr, analysis: a)
        var rep = Report(applied: false, reason: "", gciCount: gcis.times.count, markCount: a.marks.count,
                         polarity: gcis.polarity)
        guard gcis.times.count >= a.marks.count / 2 else {
            rep.reason = "too few GCIs (\(gcis.times.count) for \(a.marks.count) marks)"
            return (a, rep)
        }
        let g = gcis.times
        func nearest(_ t: Double) -> Double? {
            var lo = 0, hi = g.count
            while lo < hi { let mid = (lo + hi) / 2; if g[mid] < t { lo = mid + 1 } else { hi = mid } }
            var best: Double? = nil
            for k in [lo - 1, lo] where k >= 0 && k < g.count {
                if best == nil || abs(g[k] - t) < abs(best! - t) { best = g[k] }
            }
            return best
        }
        var offsets: [Double] = []
        for (m, t) in zip(a.marks, a.periods) {
            if let n = nearest(m), abs(n - m) <= 0.5 * t { offsets.append(n - m) }
        }
        guard offsets.count >= a.marks.count / 2 else {
            rep.reason = "too few marks near a GCI (\(offsets.count)/\(a.marks.count))"
            return (a, rep)
        }
        let off = TDPSOLAAnalysis.median(offsets)
        rep.medianOffset = off
        var newMarks = [Double](repeating: 0, count: a.marks.count)
        var matched = 0, shift = 0.0
        for i in 0..<a.marks.count {
            let target = a.marks[i] + off
            if !phaseOnly, let n = nearest(target), abs(n - target) <= 0.25 * a.periods[i] {
                newMarks[i] = n; matched += 1; shift += abs(n - target)
            } else {
                newMarks[i] = target
            }
        }
        rep.matched = matched
        rep.meanResidualShift = matched > 0 ? shift / Double(matched) : 0
        // Gross-failure guards.
        let n = x.count
        guard newMarks.first! >= 0, newMarks.last! < Double(n) else { rep.reason = "marks left the source"; return (a, rep) }
        for i in 1..<newMarks.count {
            let tNew = newMarks[i] - newMarks[i - 1], tOld = a.marks[i] - a.marks[i - 1]
            guard tNew > 0, tNew >= 0.7 * tOld, tNew <= 1.3 * tOld else {
                rep.reason = "period \(i) moved out of 0.7..1.3x (\(tOld) -> \(tNew))"
                return (a, rep)
            }
        }
        var newPeriods = [Double](repeating: 0, count: newMarks.count)
        for i in 0..<(newMarks.count - 1) { newPeriods[i] = newMarks[i + 1] - newMarks[i] }
        newPeriods[newMarks.count - 1] = newPeriods[newMarks.count - 2]
        rep.jitterBefore = jitter(a.marks, from: a.attackIndex, to: a.loopEndIndex + 1)
        rep.jitterAfter = jitter(newMarks, from: a.attackIndex, to: a.loopEndIndex + 1)
        guard rep.jitterAfter <= guardRatio * rep.jitterBefore + 1e-9 else {   // 1e-9: rounding of a pure shift
            rep.reason = String(format: "jitter guard: %.4f -> %.4f (> %.2fx)", rep.jitterBefore, rep.jitterAfter, guardRatio)
            return (a, rep)
        }
        let ei = a.loopEndIndex
        var ai = a.attackIndex
        // A declared onset end (R17D, `TDPSOLAAnalysis.applying`) holds for the SNAPPED marks too: the loop starts at
        // the first mark at or after it, so the recorded onset never re-enters the loop. Lane PITCHWIN (2026-11-26):
        // without this the snap moved I's attack mark 14 samples before its declared end (4236 < 4250, MEASURED,
        // PhonemeOnsetTests.loopStartsAtTheDeclaredAttackEnd).
        if let h = a.recordedOnset.map({ Double($0.attackEndFrame) }), h > 0 {
            while ai > 0 && newMarks[ai - 1] >= h { ai -= 1 }
            while ai < ei - 2 && newMarks[ai] < h { ai += 1 }
        }
        let refined = TDPSOLAAnalysis(onset: a.onset, isVoiced: true, voicedFraction: a.voicedFraction,
                                      medianPeriod: TDPSOLAAnalysis.median(newPeriods), marks: newMarks,
                                      periods: newPeriods, attackIndex: ai, loopEndIndex: ei,
                                      loopStart: newMarks[ai], loopEnd: newMarks[ei] + newPeriods[ei],
                                      unvoicedHop: a.unvoicedHop, recordedOnset: a.recordedOnset)
        rep.applied = true
        rep.reason = "snapped"
        return (refined, rep)
    }

    /// Mean |T[k+1] - T[k]| / mean T over the marks in [from, to] (forward periods between consecutive marks).
    static func jitter(_ marks: [Double], from: Int, to: Int) -> Double {
        let hi = min(to, marks.count - 1)
        guard hi - from >= 2 else { return 0 }
        var t: [Double] = []
        for k in from..<hi { t.append(marks[k + 1] - marks[k]) }
        var d = 0.0
        for k in 1..<t.count { d += abs(t[k] - t[k - 1]) }
        let mean = t.reduce(0, +) / Double(t.count)
        return mean > 0 ? (d / Double(t.count - 1)) / mean : 0
    }

    // MARK: SEDREAMS-style GCI detection

    struct GCIs { var times: [Double]; var polarity: Double }

    static func detectGCIs(_ x: [Float], sampleRate sr: Double, analysis a: TDPSOLAAnalysis) -> GCIs {
        let r = sr / decimatedRate
        let s = decimate(x, ratio: r)
        let e = lpResidual(s, order: lpcOrder)
        let m16 = a.marks.map { $0 / r }
        let t16 = a.periods.map { $0 / r }
        // Local period at a 16 kHz sample (from the coarse marks; constant outside them).
        var localT = [Double](repeating: t16[0], count: s.count)
        var k = 0
        for i in 0..<s.count {
            while k < m16.count - 1 && m16[k + 1] <= Double(i) { k += 1 }
            localT[i] = t16[k]
        }
        let lo = max(0, Int(m16.first! - 2 * t16.first!)), hi = min(s.count, Int(m16.last! + 2 * t16.last!) + 1)
        guard hi - lo > 64 else { return GCIs(times: [], polarity: -1) }
        // Polarity from the residual's skewness over the voiced region.
        var mu = 0.0
        for i in lo..<hi { mu += e[i] }
        mu /= Double(hi - lo)
        var m2 = 0.0, m3 = 0.0
        for i in lo..<hi { let d = e[i] - mu; m2 += d * d; m3 += d * d * d }
        let pol: Double = m3 > 0 ? 1 : -1
        // Mean-based signal: Blackman window of length 1.75 x the local period.
        var blackman: [Int: [Double]] = [:]
        var mbs = [Double](repeating: 0, count: s.count)
        for i in lo..<hi {
            let half = max(2, Int((0.875 * localT[i]).rounded()))
            let w: [Double]
            if let c = blackman[half] { w = c } else {
                w = (0...(2 * half)).map { j in
                    let u = Double(j - half) / Double(half)
                    return 0.42 + 0.5 * cos(Double.pi * u) + 0.08 * cos(2 * Double.pi * u)
                }
                blackman[half] = w
            }
            var acc = 0.0, ws = 0.0
            for j in 0...(2 * half) {
                let p = i + j - half
                if p >= 0 && p < s.count { acc += w[j] * s[p]; ws += w[j] }
            }
            mbs[i] = ws > 0 ? acc / ws : 0
        }
        // Remove the MBS's own one-period moving mean (so its zero crossings are the cycle's).
        var y = [Double](repeating: 0, count: s.count)
        for i in lo..<hi {
            let h = max(1, Int((0.5 * localT[i]).rounded()))
            var acc = 0.0, c = 0
            for p in max(lo, i - h)...min(hi - 1, i + h) { acc += mbs[p]; c += 1 }
            y[i] = mbs[i] - acc / Double(c)
        }
        // Minima: below zero, the lowest within +-0.5 local period.
        var times: [Double] = []
        var i = lo + 1
        while i < hi - 1 {
            defer { i += 1 }
            guard y[i] < 0, y[i] < y[i - 1], y[i] <= y[i + 1] else { continue }
            let h = max(1, Int((0.5 * localT[i]).rounded()))
            var lowest = true
            for p in max(lo, i - h)...min(hi - 1, i + h) where p != i && y[p] < y[i] { lowest = false; break }
            guard lowest else { continue }
            // Interval: to the next positive-going zero crossing, at most half a period.
            let cap = min(hi - 2, i + h)
            var end = i + 1
            while end < cap && !(y[end - 1] < 0 && y[end] >= 0) { end += 1 }
            var best = i, bv = -Double.infinity
            for p in i...end { let v = pol * e[p]; if v > bv { bv = v; best = p } }
            var off = 0.0
            if best > 0 && best < s.count - 1 {
                let l = pol * e[best - 1], c = pol * e[best], rr = pol * e[best + 1]
                let d = l - 2 * c + rr
                if d < 0 { off = max(-0.5, min(0.5, 0.5 * (l - rr) / d)) }
            }
            times.append((Double(best) + off) * r)
        }
        // Strictly increasing, de-duplicated (two minima can share an interval end).
        var out: [Double] = []
        for t in times where out.last.map({ t > $0 + 1 }) ?? true { out.append(t) }
        return GCIs(times: out, polarity: pol)
    }

    /// Zero-phase Kaiser-sinc decimation by `ratio` (> 1), low-passed at 0.95 x the new Nyquist.
    static func decimate(_ x: [Float], ratio r: Double) -> [Double] {
        let table = TDPSOLA2Sinc.makeTable()
        defer { table.deallocate() }
        let cut = 0.95 / r
        let pad = Int((Double(TDPSOLA2Sinc.zeros) / cut).rounded(.up)) + 2
        var padded = [Float](repeating: 0, count: x.count + 2 * pad)
        for i in 0..<x.count { padded[pad + i] = x[i] }
        let n = Int(Double(x.count) / r)
        var y = [Double](repeating: 0, count: n)
        padded.withUnsafeBufferPointer { b in
            let base = b.baseAddress! + pad
            for i in 0..<n { y[i] = Double(TDPSOLA2Sinc.read(base, table, Double(i) * r, cut)) }
        }
        return y
    }

    /// LP residual (autocorrelation method, Hann-windowed 25 ms frames every 5 ms, Levinson-Durbin).
    static func lpResidual(_ s: [Double], order p: Int) -> [Double] {
        let fs = decimatedRate
        let len = Int(0.025 * fs), hop = Int(0.005 * fs)
        let win = (0..<len).map { 0.5 - 0.5 * cos(2 * Double.pi * (Double($0) + 0.5) / Double(len)) }
        var e = [Double](repeating: 0, count: s.count)
        var c = 0
        while c < s.count {
            var r = [Double](repeating: 0, count: p + 1)
            var fr = [Double](repeating: 0, count: len)
            for j in 0..<len { let q = c - len / 2 + j; fr[j] = q >= 0 && q < s.count ? s[q] * win[j] : 0 }
            for lag in 0...p { var acc = 0.0; for j in lag..<len { acc += fr[j] * fr[j - lag] }; r[lag] = acc }
            let a = levinson(r, order: p)
            for q in max(0, c - hop / 2)..<min(s.count, c - hop / 2 + hop) {
                var v = s[q]
                for k in 1...p where q - k >= 0 { v += a[k] * s[q - k] }
                e[q] = v
            }
            c += hop
        }
        return e
    }

    /// A(z) = 1 + a1 z^-1 + ... ; a[0] = 1. Silent frames give a = [1, 0, ...].
    static func levinson(_ r0: [Double], order p: Int) -> [Double] {
        var a = [Double](repeating: 0, count: p + 1)
        a[0] = 1
        var r = r0
        r[0] *= 1 + 1e-9
        guard r[0] > 1e-12 else { return a }
        var err = r[0]
        for i in 1...p {
            var acc = r[i]
            for j in 1..<i { acc += a[j] * r[i - j] }
            let k = -acc / err
            var na = a
            for j in 1..<i { na[j] = a[j] + k * a[i - j] }
            na[i] = k
            a = na
            err *= 1 - k * k
            if err <= 0 { break }
        }
        return a
    }
}
