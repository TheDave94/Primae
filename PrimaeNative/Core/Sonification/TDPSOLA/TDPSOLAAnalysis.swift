// TDPSOLAAnalysis.swift
// PrimaeNative
//
// Init-time (off the render thread) analysis for the TDPSOLA bake-off
// candidate: onset, voicing, a period contour, pitch marks (epochs), the
// attack region that plays unmodified, and the loop region. Computed from
// the source samples alone, so the asset stays the single source of truth
// (BAKEOFF.md: no shipped JSON). Deterministic: plain IEEE arithmetic over
// the samples, no randomness, no libm calls except `sqrt`.
//
// Method.
// 1. Onset: first sample with |x| >= 1 % of the file's peak (-40 dB).
// 2. Period contour: normalised autocorrelation over 30 ms frames every
//    20 ms, lags for 70..500 Hz. The FIRST local maximum within 90 % of the
//    frame's best value is taken (suppresses sub-harmonic picks), refined
//    by a parabola. A frame is voiced when its clarity >= 0.6 and its RMS is
//    within 26 dB of the loudest frame. Periods more than a third away from
//    the voiced median are replaced by the median (octave errors).
// 3. Marks: an anchor at the largest-|x| sample inside the clearest voiced
//    frame, then propagated forward and backward one period at a time; each
//    next mark is the lag in [0.85 T, 1.15 T] whose one-period waveform best
//    matches the current mark's (cross-correlation), parabola-refined. The
//    marks are therefore waveform-consistent epochs (same phase in every
//    period), which is what PSOLA needs; they are not glottal closures.
// 4. Attack end: first 10 ms frame whose RMS reaches -3 dB of the median
//    frame RMS; the attack index is the first mark at or after it that also
//    leaves 1.5 periods of source to its left (grain room).
// 5. Loop: [mark[attackIndex], mark[loopEnd] + period[loopEnd]); loopEnd is
//    the last mark with 1.5 periods of source to its right.
// Unvoiced sources (or a voiced kind whose voiced fraction is < 0.5) get no
// marks; the renderer uses fixed 5 ms grains with a WSOLA search instead.

import Foundation

nonisolated struct TDPSOLAAnalysis: Sendable {
    /// First audible sample.
    let onset: Int
    /// PSOLA (true) or fixed-grain WSOLA (false).
    let isVoiced: Bool
    /// Fraction of energetic frames judged voiced.
    let voicedFraction: Double
    /// Median voiced period in samples (0 when unvoiced).
    let medianPeriod: Double
    /// Pitch marks in source samples (fractional), ascending. Empty when unvoiced.
    let marks: [Double]
    /// Forward period at each mark (`marks[i+1] - marks[i]`; the last repeats the one before).
    let periods: [Double]
    /// First mark of the sustained (looping) region; everything before it plays unmodified.
    let attackIndex: Int
    /// Last mark inside the loop.
    let loopEndIndex: Int
    /// Loop bounds in source samples: [loopStart, loopEnd).
    let loopStart: Double
    let loopEnd: Double
    /// Fixed grain hop for the unvoiced mode, samples (5 ms).
    let unvoicedHop: Int
    /// R17D: the file's recorded onset when its attack end was declared (`PhonemeOnsets`); nil = the -3 dB rule.
    var recordedOnset: RecordedOnset? = nil

    var f0: Double { medianPeriod > 0 ? 1 / medianPeriod : 0 } // cycles per sample

    /// `unvoicedHopSeconds`: the fixed grain hop of the unvoiced (WSOLA) mode; 5 ms is the bake-off value.
    /// `onset` (R17D): a declared attack end; the analysis is computed as without it, then its loop start is moved to
    /// the first mark (voiced) / sample (unvoiced) at or after `onset.attackEndFrame` (`applying(_:)`).
    static func analyse(_ source: [Float], sampleRate sr: Double, kind: SourceKind,
                        unvoicedHopSeconds: Double = 0.005, onset: RecordedOnset? = nil) -> TDPSOLAAnalysis {
        analyseSamples(source, sampleRate: sr, kind: kind, unvoicedHopSeconds: unvoicedHopSeconds).applying(onset)
    }

    /// R17D: this analysis with the attack ending at a declared onset end (ONSET.md section 7.2; the lane's driver
    /// `override`, line for line). Voiced: the attack index advances to the first mark at or after the hint, keeping
    /// at least two loop marks; unvoiced: the loop starts at the hint. nil = unchanged.
    func applying(_ onset: RecordedOnset?) -> TDPSOLAAnalysis {
        guard let onset, onset.attackEndFrame > 0 else { return self }
        let h = Double(onset.attackEndFrame)
        if isVoiced {
            var ai = attackIndex
            while ai < loopEndIndex - 2 && marks[ai] < h { ai += 1 }
            return TDPSOLAAnalysis(onset: self.onset, isVoiced: true, voicedFraction: voicedFraction,
                                   medianPeriod: medianPeriod, marks: marks, periods: periods, attackIndex: ai,
                                   loopEndIndex: loopEndIndex, loopStart: marks[ai], loopEnd: loopEnd,
                                   unvoicedHop: unvoicedHop, recordedOnset: onset)
        }
        let ls = min(max(h, loopStart), loopEnd - Double(unvoicedHop))
        return TDPSOLAAnalysis(onset: self.onset, isVoiced: false, voicedFraction: voicedFraction, medianPeriod: 0,
                               marks: [], periods: [], attackIndex: 0, loopEndIndex: 0, loopStart: ls,
                               loopEnd: loopEnd, unvoicedHop: unvoicedHop, recordedOnset: onset)
    }

    private static func analyseSamples(_ source: [Float], sampleRate sr: Double, kind: SourceKind,
                                       unvoicedHopSeconds: Double) -> TDPSOLAAnalysis {
        let n = source.count
        let hop5 = max(16, Int((unvoicedHopSeconds * sr).rounded()))
        return source.withUnsafeBufferPointer { buf -> TDPSOLAAnalysis in
            let x = buf.baseAddress!
            // 1. Onset.
            var peak: Float = 0
            for i in 0..<n { peak = max(peak, abs(x[i])) }
            var onset = 0
            if peak > 0 {
                while onset < n - 1 && abs(x[onset]) < peak * 0.01 { onset += 1 }
            }

            // 2. Period contour.
            let win = Int((0.030 * sr).rounded())
            let hop = Int((0.020 * sr).rounded())
            let minLag = max(2, Int((sr / 500).rounded(.down)))
            let maxLag = Int((sr / 70).rounded(.up))
            var framePeriod: [Double] = []
            var frameClarity: [Double] = []
            var frameRMS: [Double] = []
            var frameStart: [Int] = []
            var nc = [Double](repeating: 0, count: maxLag + 2)
            var f = onset
            while f + win + maxLag + 1 < n {
                var e0 = 0.0
                for j in 0..<win { e0 += Double(x[f + j]) * Double(x[f + j]) }
                var e1 = 0.0
                for j in 0..<win { e1 += Double(x[f + minLag + j]) * Double(x[f + minLag + j]) }
                var best = 0.0
                for lag in minLag...maxLag {
                    if lag > minLag {
                        let out = Double(x[f + lag - 1]), inn = Double(x[f + lag - 1 + win])
                        e1 += inn * inn - out * out
                    }
                    var c = 0.0
                    var j = 0
                    // Stride 2: half the cost; the energies are full-rate, so scale by 2.
                    while j < win { c += Double(x[f + j]) * Double(x[f + lag + j]); j += 2 }
                    let d = (e0 * max(e1, 0)).squareRoot()
                    nc[lag] = d > 1e-12 ? 2 * c / d : 0
                    best = max(best, nc[lag])
                }
                var pick = 0
                for lag in (minLag + 1)..<maxLag where nc[lag] >= best * 0.9
                    && nc[lag] >= nc[lag - 1] && nc[lag] >= nc[lag + 1] {
                    pick = lag; break
                }
                var period = 0.0
                if pick > 0 {
                    let a = nc[pick - 1], b = nc[pick], c = nc[pick + 1]
                    let den = a - 2 * b + c
                    let delta = abs(den) > 1e-12 ? 0.5 * (a - c) / den : 0
                    period = Double(pick) + max(-0.5, min(0.5, delta))
                }
                framePeriod.append(period)
                frameClarity.append(pick > 0 ? nc[pick] : 0)
                frameRMS.append((e0 / Double(win)).squareRoot())
                frameStart.append(f)
                f += hop
            }
            let loudest = frameRMS.max() ?? 0
            var voiced = [Bool](repeating: false, count: framePeriod.count)
            var energetic = 0, voicedCount = 0
            for k in 0..<framePeriod.count where frameRMS[k] >= loudest * 0.05 {
                energetic += 1
                if frameClarity[k] >= 0.6 && framePeriod[k] > 0 { voiced[k] = true; voicedCount += 1 }
            }
            let fraction = energetic > 0 ? Double(voicedCount) / Double(energetic) : 0
            let wantsVoiced = kind != .unvoicedPhoneme && fraction >= 0.5

            // Attack end from a 10 ms RMS envelope.
            let envWin = max(8, Int((0.010 * sr).rounded()))
            var env: [Double] = []
            var e = onset
            while e + envWin <= n {
                var s = 0.0
                for j in 0..<envWin { s += Double(x[e + j]) * Double(x[e + j]) }
                env.append((s / Double(envWin)).squareRoot()); e += envWin
            }
            let medianEnv = Self.median(env)
            var attackSample = onset
            for (k, v) in env.enumerated() where v >= medianEnv * 0.708 { attackSample = onset + k * envWin; break }

            guard wantsVoiced else {
                let lo = Double(max(attackSample, onset + hop5, 2 * hop5 + 4))
                let hi = Double(n - 3 * hop5 - 4)
                return TDPSOLAAnalysis(onset: onset, isVoiced: false, voicedFraction: fraction,
                                       medianPeriod: 0, marks: [], periods: [], attackIndex: 0,
                                       loopEndIndex: 0, loopStart: lo, loopEnd: max(lo + Double(hop5), hi),
                                       unvoicedHop: hop5)
            }

            let voicedPeriods = zip(framePeriod, voiced).filter { $0.1 }.map { $0.0 }
            let med = Self.median(voicedPeriods)
            for k in 0..<framePeriod.count {
                // PERIOD CLAMP (documented R17, 2026-11-03; RVF.md). An octave-error guard
                // for steady phonemes: a frame period outside [0.75, 1.33] x the voiced
                // median is replaced by the median, and mark propagation then searches
                // [0.85 T, 1.15 T] of that T. Consequence: a source whose f0 GLIDES by more
                // than about -25 %/+33 % around its median gets marks on the wrong period
                // outside that band (RVF measured it on a 120 -> 480 Hz probe sweep: marks
                // correct only for 0.6-1.4 s of 2 s), and the voiced path then repeats or
                // skips the wrong spans there. The study phonemes are steady (f0 within a
                // few % of the median: A 233, I 250.5, L 238.6, M 224.3 Hz) and never reach
                // it, and the carrier is a constant 440 Hz tone. Any new arm recording with
                // a pitch contour must be checked against this before it ships
                // (`SonificationRegressionTests.periodClampBoundsHold` pins the study set).
                if !voiced[k] || framePeriod[k] < med * 0.75 || framePeriod[k] > med * 1.33 { framePeriod[k] = med }
            }
            func periodAt(_ pos: Double) -> Double {
                guard !framePeriod.isEmpty else { return med }
                let fi = (pos - Double(win / 2) - Double(onset)) / Double(hop)
                if fi <= 0 { return framePeriod[0] }
                let i0 = Int(fi)
                if i0 >= framePeriod.count - 1 { return framePeriod[framePeriod.count - 1] }
                let t = fi - Double(i0)
                return framePeriod[i0] * (1 - t) + framePeriod[i0 + 1] * t
            }

            // 3. Marks: anchor in the clearest voiced frame.
            var anchorFrame = 0
            var bestClarity = -1.0
            for k in 0..<frameClarity.count where voiced[k] && frameClarity[k] > bestClarity {
                bestClarity = frameClarity[k]; anchorFrame = k
            }
            let a0 = frameStart.isEmpty ? onset : frameStart[anchorFrame]
            var anchor = a0
            var anchorAbs: Float = -1
            for i in a0..<min(n, a0 + Int(med.rounded(.up))) where abs(x[i]) > anchorAbs { anchorAbs = abs(x[i]); anchor = i }

            func score(_ m: Int, _ c: Int, _ h: Int) -> Double {
                var s = 0.0
                for j in -h...h {
                    let p = m + j, q = c + j
                    if p < 0 || q < 0 || p >= n || q >= n { continue }
                    s += Double(x[p]) * Double(x[q])
                }
                return s
            }
            func step(from m: Double, direction: Int) -> Double? {
                let t = periodAt(m)
                let mi = Int(m.rounded())
                let h = Int(t / 2)
                let lo = Int((0.85 * t).rounded(.down)), hi = Int((1.15 * t).rounded(.up))
                var bestC = 0, bestS = -Double.infinity
                var scores = [Double](repeating: 0, count: hi - lo + 3)
                for d in (lo - 1)...(hi + 1) {
                    let c = mi + direction * d
                    if c - h < 0 || c + h >= n { return nil }
                    let s = score(mi, c, h)
                    scores[d - lo + 1] = s
                    if d >= lo && d <= hi && s > bestS { bestS = s; bestC = d }
                }
                let a = scores[bestC - lo], b = scores[bestC - lo + 1], c = scores[bestC - lo + 2]
                let den = a - 2 * b + c
                let delta = abs(den) > 1e-12 ? max(-0.5, min(0.5, 0.5 * (a - c) / den)) : 0
                return m + Double(direction) * (Double(bestC) + delta)
            }
            var forward: [Double] = [Double(anchor)]
            while let next = step(from: forward[forward.count - 1], direction: 1) { forward.append(next) }
            var backward: [Double] = []
            var cur = Double(anchor)
            while let prev = step(from: cur, direction: -1), prev >= Double(onset) { backward.append(prev); cur = prev }
            let marks = backward.reversed() + forward
            var periods = [Double](repeating: med, count: marks.count)
            for i in 0..<max(0, marks.count - 1) { periods[i] = marks[i + 1] - marks[i] }
            if marks.count >= 2 { periods[marks.count - 1] = periods[marks.count - 2] }

            // 4./5. Attack and loop.
            var attackIndex = 0
            while attackIndex < marks.count - 1
                    && (marks[attackIndex] < Double(attackSample)
                        || marks[attackIndex] < 1.5 * periods[attackIndex] + 4) { attackIndex += 1 }
            var loopEndIndex = marks.count - 1
            while loopEndIndex > attackIndex
                    && marks[loopEndIndex] + 1.5 * periods[loopEndIndex] + 4 >= Double(n) { loopEndIndex -= 1 }
            guard marks.count >= 4, loopEndIndex >= attackIndex + 2 else {
                // Too short to loop pitch-synchronously: fall back to fixed grains.
                let lo = Double(max(attackSample, onset + hop5, 2 * hop5 + 4))
                return TDPSOLAAnalysis(onset: onset, isVoiced: false, voicedFraction: fraction,
                                       medianPeriod: 0, marks: [], periods: [], attackIndex: 0,
                                       loopEndIndex: 0, loopStart: lo,
                                       loopEnd: max(lo + Double(hop5), Double(n - 3 * hop5 - 4)),
                                       unvoicedHop: hop5)
            }
            return TDPSOLAAnalysis(onset: onset, isVoiced: true, voicedFraction: fraction,
                                   medianPeriod: med, marks: marks, periods: periods,
                                   attackIndex: attackIndex, loopEndIndex: loopEndIndex,
                                   loopStart: marks[attackIndex],
                                   loopEnd: marks[loopEndIndex] + periods[loopEndIndex],
                                   unvoicedHop: hop5)
        }
    }

    static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }
}
