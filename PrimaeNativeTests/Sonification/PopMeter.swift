// PopMeter.swift
// PrimaeNativeTests: lane POP2 (2026-11-04). Pure Swift, no frameworks (compiles into the Mac driver and the device tests).
//
// WHY. POPCAP's detectors (hf / dip / cut / jump / zero-run / level step) are threshold detectors tuned for
// clicks. David hears more than they flag. A hard onset (silence to full level in 2-3 ms) is not a click in the
// waveform; it is spectral SPLATTER: broadband energy, above 1-2 kHz, that the sound itself does not have.
//
// Onset splatter. For a transition at sample n0: the 2 ms frames (hop 1 ms) of the first 10 ms, high-passed
// above 1.5 kHz (4th-order Butterworth, forward only: the transient is the point); splatter = the strongest
// frame's HF SHARE (HF power / total power, level-independent) in dB re the sound's OWN steady-state share (95th percentile of the 2 ms HF frames of the
// sounding part of the same signal, floored at 60 dB below its total power so a clean tone, whose steady HF is ~0, has a
// finite reference). <= 0 dB: the onset has no more HF than the sound has anyway. Slope: the largest second
// difference in the first 10 ms in dB re the 99.9th percentile of the sound's own second differences.
//
// Fluctuation (lane POP2 item e). 20 ms RMS frames (hop 20 ms), frame-to-frame step in dB (p50/p95/p99/max);
// 2-30 Hz modulation of the 10 ms-hop dB envelope (amplitude of each integer Hz bin, Hann-windowed) as band RMS.

import Foundation

nonisolated enum PopMeter {

    // MARK: filters and frames

    /// 4th-order Butterworth high-pass (two biquads), single pass.
    static func highPass(_ x: [Float], sr: Double, fc: Double = 1500) -> [Float] {
        func bq(_ q: Double) -> (Double, Double, Double, Double, Double) {
            let w = 2 * Double.pi * fc / sr, c = cos(w), al = sin(w) / (2 * q), a0 = 1 + al
            return ((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - al) / a0)
        }
        var y = x.map(Double.init)
        for k in [bq(0.5412), bq(1.3066)] {
            var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
            for i in 0..<y.count {
                let v = k.0 * y[i] + k.1 * x1 + k.2 * x2 - k.3 * y1 - k.4 * y2
                x2 = x1; x1 = y[i]; y2 = y1; y1 = v; y[i] = v
            }
        }
        return y.map(Float.init)
    }

    static func power(_ x: [Float], _ lo: Int, _ n: Int) -> Double {
        guard lo >= 0, n > 0, lo + n <= x.count else { return 0 }
        var s = 0.0
        for i in lo..<(lo + n) { s += Double(x[i]) * Double(x[i]) }
        return s / Double(n)
    }
    static func db(_ p: Double) -> Double { 10 * log10(max(p, 1e-14)) }
    static func percentile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
    }

    // MARK: transitions found in the audio itself

    /// First nonzero sample after at least `minZero` seconds of exact digital silence, with the length of that
    /// silence (the kernel writes exact zeros between voices).
    static func silenceOnsets(_ x: [Float], sr: Double, minZero: Double = 0.001, eps: Float = 0) -> [(index: Int, gap: Double)] {
        let need = Int(minZero * sr)
        var out: [(Int, Double)] = [], run = 0
        for i in 0..<x.count {
            if abs(x[i]) <= eps { run += 1 } else {
                if run >= need { out.append((i, Double(run) / sr)) }
                run = 0
            }
        }
        return out
    }

    // MARK: onset splatter

    struct Reference {
        var hfPower: Double       // steady-state HF power per sample (2 ms frames, p95), floored
        var share: Double = 1e-4  // steady-state HF share (HF power / total power per 2 ms frame, p95), floored at -40 dB
        var d2P999: Double        // 99.9th percentile |second difference| of the sounding part
        var totalPower: Double
    }

    /// The sound's own steady state: 2 ms frames whose total power is within 10 dB of the median sounding
    /// frame, no closer than 30 ms after a silence (so the onsets are not their own reference).
    static func reference(_ x: [Float], hp: [Float], sr: Double, eps: Float = 0) -> Reference {
        let n = Int(0.002 * sr)
        var tot: [Double] = [], hf: [Double] = [], idx: [Int] = []
        var i = 0
        while i + n <= x.count {
            let p = power(x, i, n)
            if p > 1e-10 { tot.append(p); hf.append(power(hp, i, n)); idx.append(i) }
            i += n
        }
        guard !tot.isEmpty else { return Reference(hfPower: 1e-14, share: 1e-4, d2P999: 1, totalPower: 1e-14) }
        let med = percentile(tot, 0.5)
        var hfs: [Double] = [], shares: [Double] = [], d2: [Double] = []
        for (k, p) in tot.enumerated() where p > med / 10 && p < med * 10 {
            let s = idx[k]
            guard s >= Int(0.03 * sr), x[(s - Int(0.03 * sr))..<s].allSatisfy({ abs($0) > eps }) else { continue }
            hfs.append(hf[k]); shares.append(hf[k] / p)
            for j in max(1, s)..<min(x.count - 1, s + n) { d2.append(Double(abs(x[j + 1] - 2 * x[j] + x[j - 1]))) }
        }
        let ref = max(percentile(hfs, 0.95), med * 1e-6)
        return Reference(hfPower: ref, share: max(percentile(shares, 0.95), 1e-4), d2P999: max(percentile(d2, 0.999), 1e-9), totalPower: med)
    }

    /// `splatterDB`: the strongest frame's HF SHARE (HF power / total power, 2 ms frames, hop 1 ms, frames above -40 dB re the
    /// steady total) in dB re the steady-state share (p95): level-independent, so a smooth rise reads <= 0 while a hard
    /// onset's broadband edge reads > 0. `absDB`: the same against the absolute HF power (saturates at 0 once the window
    /// reaches full level; kept for the record).
    struct Onset { var splatterDB: Double; var slopeDB: Double; var absDB: Double }

    static func onset(_ x: [Float], hp: [Float], at n0: Int, sr: Double, ref: Reference, window: Double = 0.010) -> Onset {
        let n = Int(0.002 * sr), hop = Int(0.001 * sr), span = Int(window * sr)
        var best = 0.0, bestShare = 0.0
        var s = 0
        while s + n <= span + n / 2 {
            let h = power(hp, n0 + s, n), t = power(x, n0 + s, n)
            best = max(best, h)
            if t > ref.totalPower * 1e-4 { bestShare = max(bestShare, h / t) }
            s += hop
        }
        var d2 = 0.0
        for j in max(1, n0)..<min(x.count - 1, n0 + span) { d2 = max(d2, Double(abs(x[j + 1] - 2 * x[j] + x[j - 1]))) }
        return Onset(splatterDB: bestShare > 0 ? db(bestShare) - db(ref.share) : -60, slopeDB: 20 * log10(max(d2, 1e-9) / ref.d2P999),
                     absDB: db(best) - db(ref.hfPower))
    }

    /// Summary of every silence-onset in `x` by gap class: (count, mean, max splatter, max slope).
    struct Summary { var n = 0; var meanSplatter = 0.0; var maxSplatter = -200.0; var maxSlope = -200.0; var over0 = 0 }
    static func summarise(_ x: [Float], sr: Double, from: Int = 0, to: Int? = nil, minGap: Double = 0.001,
                          maxGap: Double = .infinity, eps: Float = 0) -> Summary {
        let hp = highPass(x, sr: sr), ref = reference(x, hp: hp, sr: sr, eps: eps)
        var s = Summary()
        for o in silenceOnsets(x, sr: sr, eps: eps) where o.index >= from && o.index < (to ?? x.count) && o.gap >= minGap && o.gap < maxGap {
            guard o.index + Int(0.012 * sr) < x.count else { continue }
            let m = onset(x, hp: hp, at: o.index, sr: sr, ref: ref)
            s.n += 1; s.meanSplatter += m.splatterDB; s.maxSplatter = max(s.maxSplatter, m.splatterDB)
            s.maxSlope = max(s.maxSlope, m.slopeDB); if m.splatterDB > 0 { s.over0 += 1 }
        }
        if s.n > 0 { s.meanSplatter /= Double(s.n) }
        return s
    }

    // MARK: crossover and wrap

    /// Dip/step at a crossover that starts at `n0` and lasts `len` samples: the lowest 2 ms frame level inside
    /// [n0, n0+len] re the lower of the 20 ms levels before n0 and after n0+len (negative = a dip), plus the
    /// signed level step between those two 20 ms windows.
    static func crossover(_ x: [Float], at n0: Int, len: Int, sr: Double) -> (dipDB: Double, stepDB: Double) {
        let w = Int(0.020 * sr), n = Int(0.002 * sr)
        let before = db(power(x, max(0, n0 - w), min(w, n0))), after = db(power(x, n0 + len, w))
        var lo = 1e9, i = n0
        while i + n <= n0 + len { lo = min(lo, db(power(x, i, n))); i += n / 2 }
        return (lo - min(before, after), after - before)
    }

    // MARK: fluctuation

    struct Fluct { var n = 0; var p50 = 0.0; var p95 = 0.0; var p99 = 0.0; var max = 0.0
                   var modRMS = 0.0; var modPeak = 0.0; var modPeakHz = 0.0 }

    static func fluctuation(_ x: [Float], sr: Double, from: Int = 0, to: Int? = nil, floorDB: Double = -50) -> Fluct {
        let end = min(to ?? x.count, x.count), w = Int(0.020 * sr)
        guard end - from > 4 * w else { return Fluct() }
        var lv: [Double] = [], i = from
        while i + w <= end { lv.append(db(power(x, i, w))); i += w }
        let top = lv.max() ?? 0
        var steps: [Double] = []
        for k in 1..<lv.count where lv[k] > top + floorDB && lv[k - 1] > top + floorDB { steps.append(abs(lv[k] - lv[k - 1])) }
        var f = Fluct()
        f.n = steps.count
        f.p50 = percentile(steps, 0.5); f.p95 = percentile(steps, 0.95); f.p99 = percentile(steps, 0.99); f.max = steps.max() ?? 0
        // 10 ms-hop envelope (20 ms windows), Hann, integer-Hz bins 2...30.
        var env: [Double] = []; i = from
        while i + w <= end { env.append(db(power(x, i, w))); i += w / 2 }
        guard env.count > 200 else { return f }
        let mean = env.reduce(0, +) / Double(env.count)
        let hann = (0..<env.count).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(env.count - 1)) }
        let sw = hann.reduce(0, +)
        var power2 = 0.0
        for hz in 2...30 {
            var re = 0.0, im = 0.0
            for (k, v) in env.enumerated() {
                let ph = 2 * Double.pi * Double(hz) * Double(k) / 100
                re += (v - mean) * hann[k] * cos(ph); im += (v - mean) * hann[k] * sin(ph)
            }
            let a = 2 * (re * re + im * im).squareRoot() / sw
            power2 += a * a / 2
            if a > f.modPeak { f.modPeak = a; f.modPeakHz = Double(hz) }
        }
        f.modRMS = power2.squareRoot()
        return f
    }

    // MARK: controls (planted signals)

    /// A harmonic tone (f0, 12 harmonics at 1/k) of `seconds`, silence before `start`, onset ramped over `ramp` s
    /// with a raised cosine (0 = hard), at 44.1 kHz.
    static func plantedOnset(f0: Double = 220, start: Double = 0.2, ramp: Double, seconds: Double = 1.5, sr: Double = 44100) -> [Float] {
        let n = Int(seconds * sr)
        return (0..<n).map { i in
            let t = Double(i) / sr
            guard t >= start else { return 0 }
            var v = 0.0
            for k in 1...12 { v += cos(2 * Double.pi * f0 * Double(k) * (t - start)) / Double(k) }
            let u = ramp > 0 ? min(1, (t - start) / ramp) : 1
            return Float(0.25 * v * (0.5 - 0.5 * cos(Double.pi * u)))
        }
    }
    /// A steady tone with sinusoidal amplitude modulation of `depthDB` peak at `hz` (the fluctuation control).
    static func amplitudeModulated(hz: Double, depthDB: Double, seconds: Double = 12, sr: Double = 44100) -> [Float] {
        (0..<Int(seconds * sr)).map { i in
            let t = Double(i) / sr
            let g = pow(10, depthDB * sin(2 * Double.pi * hz * t) / 20)
            var v = 0.0
            for k in 1...6 { v += sin(2 * Double.pi * 200 * Double(k) * t) / Double(k) }
            return Float(0.2 * v * g)
        }
    }
}
