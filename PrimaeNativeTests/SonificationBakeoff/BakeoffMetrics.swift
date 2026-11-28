// BakeoffMetrics.swift
// PrimaeNativeTests — sonification bake-off harness (BENCH lane, 2026-11-02)
//
// The objective metrics of BAKEOFF.md, "Bench metrics", as pure functions
// over Float arrays, computed with Accelerate/vDSP. Every metric is
// mutation-checked by `BakeoffMetricSelfTests` against a synthetic signal
// whose true answer is known (a delayed copy, a pitch-shifted copy, a
// resampled noise, an inserted step).

import Accelerate
import Foundation

enum BakeoffMetrics {

    // MARK: - Basic helpers

    static func rms(_ x: [Float], _ start: Int, _ length: Int) -> Float {
        let s = max(0, start), e = min(x.count, start + length)
        guard e > s else { return 0 }
        var r: Float = 0
        x.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + s, 1, &r, vDSP_Length(e - s)) }
        return r
    }

    static func dB(_ v: Float) -> Float { 20 * log10(max(v, 1e-12)) }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }

    static func percentile(_ v: [Double], _ p: Double) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        let idx = min(s.count - 1, max(0, Int((p / 100 * Double(s.count - 1)).rounded())))
        return s[idx]
    }

    /// Windowed RMS envelope: window `win` frames, hop `hop` frames, from
    /// `start` to `end`. Element k covers `start + k*hop ..< + win`.
    static func envelope(_ x: [Float], start: Int, end: Int, win: Int, hop: Int) -> [Float] {
        var out: [Float] = []
        var i = max(0, start)
        while i + win <= min(end, x.count) {
            out.append(rms(x, i, win))
            i += hop
        }
        return out
    }

    // MARK: - Onset

    struct Onset {
        /// Frames from the gate frame to the END of the first 5 ms window
        /// whose RMS is >= -20 dB re the steady level (hop 16). nil = never.
        let toMinus20dB: Int?
        /// Frames from the gate frame to the first sample with |x| > 1e-6
        /// (-120 dBFS: "non-zero" for a renderer that ramps). nil = never.
        let toNonZero: Int?
        /// 95th percentile of the 5 ms RMS over the gate-open span.
        let steadyRMS: Float
    }

    /// Onset after a gate opens at `gateFrame`; the gate-open span ends at
    /// `openEnd` (the close, or the render end). Window hop 16 frames.
    static func onset(_ x: [Float], gateFrame: Int, openEnd: Int, sampleRate: Double) -> Onset {
        let win = Int((0.005 * sampleRate).rounded())
        let env = envelope(x, start: gateFrame, end: openEnd, win: win, hop: max(1, win / 4))
        let steady = Float(percentile(env.map(Double.init), 95) ?? 0)
        var m20: Int?
        if steady > 0 {
            // Reported at the END of the qualifying window (the moment the
            // criterion is met), scanning windows that start up to one window
            // before the gate, so a delayed copy reads exactly the delay
            // later (a start-of-window report is clamped at the gate).
            let threshold = steady * 0.1
            var i = max(0, gateFrame - win)
            while i + win <= min(openEnd, x.count) {
                if i + win > gateFrame, rms(x, i, win) >= threshold { m20 = i + win - gateFrame; break }
                i += 16
            }
        }
        var nz: Int?
        var j = max(0, gateFrame)
        while j < min(openEnd, x.count) {
            if abs(x[j]) > 1e-6 { nz = j - gateFrame; break }
            j += 1
        }
        return Onset(toMinus20dB: m20, toNonZero: nz, steadyRMS: steady)
    }

    /// 10 %-90 % rise time of the 1 ms RMS envelope after `gateFrame`,
    /// relative to the 95th-percentile level of the following 300 ms.
    /// Seconds; nil when the level never reaches 90 %.
    static func riseTime10to90(_ x: [Float], gateFrame: Int, openEnd: Int, sampleRate: Double) -> Double? {
        let win = max(1, Int((0.001 * sampleRate).rounded()))
        let hop = max(1, win / 4)
        let end = min(openEnd, gateFrame + Int(0.3 * sampleRate))
        let env = envelope(x, start: gateFrame, end: end, win: win, hop: hop)
        guard let top = percentile(env.map(Double.init), 95), top > 0 else { return nil }
        guard let i10 = env.firstIndex(where: { Double($0) >= 0.1 * top }),
              let i90 = env.firstIndex(where: { Double($0) >= 0.9 * top }) else { return nil }
        return Double(i90 - i10) * Double(hop) / sampleRate
    }

    // MARK: - f0 (YIN)

    struct PitchFrame {
        let frame: Int          // window start
        let f0: Double?         // nil = unvoiced/silent
        let aperiodicity: Double
    }

    /// YIN (de Cheveigné & Kawahara 2002): difference function from an
    /// autocorrelation (vDSP_conv) and running energies, cumulative-mean
    /// normalisation, absolute threshold 0.15, parabolic interpolation.
    /// A frame is voiced when its dip is < 0.25 and its RMS is within
    /// 40 dB of `levelRef`.
    static func yinTrack(_ x: [Float], start: Int, end: Int, sampleRate: Double,
                         hop: Int, fmin: Double = 75, fmax: Double = 1000,
                         window: Int = 1024, levelRef: Float? = nil) -> [PitchFrame] {
        let tmin = max(2, Int(sampleRate / fmax))
        let tmax = Int(sampleRate / fmin)
        let need = window + tmax + 1
        guard x.count >= need else { return [] }
        // Prefix sums of squares (Double for precision over long renders).
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + Double(x[i]) * Double(x[i]) }
        let ref = levelRef ?? rms(x, start, end - start)
        let floorRMS = ref * 0.01
        var frames: [PitchFrame] = []
        var corr = [Float](repeating: 0, count: tmax + 1)
        var d = [Double](repeating: 0, count: tmax + 1)
        var cmnd = [Double](repeating: 1, count: tmax + 1)
        var s = max(0, start)
        while s + need <= min(end, x.count) {
            x.withUnsafeBufferPointer { buf in
                let base = buf.baseAddress! + s
                vDSP_conv(base, 1, base, 1, &corr, 1, vDSP_Length(tmax + 1), vDSP_Length(window))
            }
            let e0 = prefix[s + window] - prefix[s]
            for tau in 0...tmax {
                let et = prefix[s + tau + window] - prefix[s + tau]
                d[tau] = max(0, e0 + et - 2 * Double(corr[tau]))
            }
            var running = 0.0
            cmnd[0] = 1
            for tau in 1...tmax {
                running += d[tau]
                cmnd[tau] = running > 0 ? d[tau] * Double(tau) / running : 1
            }
            var best = -1
            var tau = tmin
            while tau <= tmax {
                if cmnd[tau] < 0.15 {
                    while tau + 1 <= tmax && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                    best = tau
                    break
                }
                tau += 1
            }
            if best < 0 {
                var m = tmin
                for t in tmin...tmax where cmnd[t] < cmnd[m] { m = t }
                best = m
            }
            let ap = cmnd[best]
            var refined = Double(best)
            if best > 1 && best < tmax {
                let a = d[best - 1], b = d[best], c = d[best + 1]
                let den = a - 2 * b + c
                if den > 0 { refined += 0.5 * (a - c) / den }
            }
            let level = Float(sqrt(max(0, e0) / Double(window)))
            let voiced = ap < 0.25 && level >= floorRMS
            frames.append(PitchFrame(frame: s, f0: voiced ? sampleRate / refined : nil, aperiodicity: ap))
            s += hop
        }
        return frames
    }

    static func medianF0(_ frames: [PitchFrame]) -> Double? {
        median(frames.compactMap(\.f0))
    }

    static func cents(_ f: Double, re ref: Double) -> Double { 1200 * log2(f / ref) }

    /// Voiced fraction of a track.
    static func voicedFraction(_ frames: [PitchFrame]) -> Double {
        frames.isEmpty ? 0 : Double(frames.filter { $0.f0 != nil }.count) / Double(frames.count)
    }

    // MARK: - Local duration scale (sweep probe)

    struct AlignmentPoint { let frame: Int; let sourcePosition: Double }

    /// WHY A PROBE. The study sources are SUSTAINED sounds (a held vowel,
    /// a held /f/, a steady tone): there is no landmark in them whose
    /// position in the output reveals how fast the source was read, and a
    /// phase vocoder does not even preserve a noise waveform for a
    /// correlator to find (measured on the iPad: waveform alignment of
    /// AppleTimePitch output on F_phoneme1 correlated 0.15-0.20). So the
    /// rate metrics run on a synthetic probe whose PITCH encodes its time:
    /// a harmonic tone gliding exponentially from `sweepF0` up
    /// `sweepOctaves` over the loop (`BakeoffSynthetic.sweepProbe`). Every
    /// candidate holds pitch at cents 0, so the output's f0 at output time t
    /// says which source time it is playing; the slope is the duration
    /// scale. A varispeed (NaiveResample) shifts the f0 by a CONSTANT ratio
    /// at a fixed rate, which offsets the position by a constant and leaves
    /// the slope right.
    ///
    /// Source position (frames, unwrapped across loops) per YIN frame of the
    /// output, timed at the YIN window centre.
    static func sweepTrack(_ x: [Float], from: Int, to: Int, sampleRate: Double,
                           hopSeconds: Double = 0.0025) -> [AlignmentPoint] {
        let probe = BakeoffSynthetic.self
        let loop = probe.sweepSeconds * sampleRate
        let frames = yinTrack(x, start: from, end: to, sampleRate: sampleRate,
                              hop: max(1, Int(hopSeconds * sampleRate)),
                              fmin: probe.sweepF0 * 0.8,
                              fmax: probe.sweepF0 * pow(2, probe.sweepOctaves) * 1.25)
        var out: [AlignmentPoint] = []
        var offset = 0.0
        var last: Double?
        for f in frames {
            guard let f0 = f.f0 else { continue }
            let octaves = log2(f0 / probe.sweepF0)
            guard octaves > -0.1 && octaves < probe.sweepOctaves + 0.1 else { continue }
            var p = loop * octaves / probe.sweepOctaves + offset
            if let l = last, p < l - loop / 2 { offset += loop; p += loop }
            last = p
            out.append(AlignmentPoint(frame: f.frame + 512, sourcePosition: p))
        }
        return out
    }

    /// Local duration scale (source frames advanced per output frame) by a
    /// least-squares slope over +/-`span` neighbouring points (default 20 at
    /// the 2.5 ms hop = a 100 ms window, longer than a grain hop or a pitch
    /// period, so the staircase of an OLA algorithm averages to its true
    /// rate), then a 7-point median. Returns (output frame, rate). The 100 ms
    /// window is the estimator's time resolution: a step reads as a ~80 ms
    /// 10-90 % ramp even when instantaneous, equally for every candidate.
    static func localRate(_ track: [AlignmentPoint], span: Int = 20) -> [(frame: Int, rate: Double)] {
        guard track.count > 2 * span + 1 else { return [] }
        var raw: [(Int, Double)] = []
        for i in span..<(track.count - span) {
            let seg = track[(i - span)...(i + span)]
            // Contiguity: skip a window that spans a gap (gate closed,
            // unvoiced frames) longer than 4 hops.
            let step = track[i - span + 1].frame - track[i - span].frame
            if track[i + span].frame - track[i - span].frame > 2 * span * step + 4 * step { continue }
            let n = Double(seg.count)
            let mx = seg.reduce(0.0) { $0 + Double($1.frame) } / n
            let my = seg.reduce(0.0) { $0 + $1.sourcePosition } / n
            var sxy = 0.0, sxx = 0.0
            for p in seg {
                let dx = Double(p.frame) - mx
                sxy += dx * (p.sourcePosition - my)
                sxx += dx * dx
            }
            guard sxx > 0 else { continue }
            raw.append((track[i].frame, sxy / sxx))
        }
        var out: [(frame: Int, rate: Double)] = []
        for i in 0..<raw.count {
            let lo = max(0, i - 3), hi = min(raw.count - 1, i + 3)
            out.append((raw[i].0, median(raw[lo...hi].map(\.1)) ?? raw[i].1))
        }
        return out
    }

    // MARK: - Step response

    struct StepResponse {
        let delayTo10: Double   // seconds from the step to 10 %
        let delayTo90: Double   // seconds from the step to 90 %
        var rise10to90: Double { delayTo90 - delayTo10 }
    }

    /// Step response of a measured series (time in seconds) around a step at
    /// `stepTime`. Start/end levels are the MEASURED medians before the step
    /// ([step-0.3, step-0.05]) and in [step+settleFrom, step+settleTo], so a
    /// constant bias does not read as lag. A crossing must hold 3 points.
    static func stepResponse(_ series: [(t: Double, v: Double)], stepTime: Double,
                             settleFrom: Double = 0.4, settleTo: Double = 0.75) -> StepResponse? {
        let pre = series.filter { $0.t >= stepTime - 0.3 && $0.t <= stepTime - 0.05 }.map(\.v)
        let post = series.filter { $0.t >= stepTime + settleFrom && $0.t <= stepTime + settleTo }.map(\.v)
        guard let v0 = median(pre), let v1 = median(post), abs(v1 - v0) > 1e-9 else { return nil }
        let after = series.filter { $0.t >= stepTime }
        func crossing(_ frac: Double) -> Double? {
            guard after.count >= 3 else { return nil }
            for i in 0...(after.count - 3) {
                let ok = (0..<3).allSatisfy { (after[i + $0].v - v0) / (v1 - v0) >= frac }
                if ok { return after[i].t - stepTime }
            }
            return nil
        }
        guard let d10 = crossing(0.1), let d90 = crossing(0.9) else { return nil }
        return StepResponse(delayTo10: d10, delayTo90: d90)
    }

    /// Best lag (seconds, >= 0) of `measured` behind `commanded` (both
    /// sampled on the same time grid `times`), searched 0...maxLag, and the
    /// RMS error at that lag and at zero lag. Samples where measured is nil
    /// are skipped.
    static func trackingLag(times: [Double], commanded: (Double) -> Double, measured: [Double?],
                            maxLag: Double = 0.3, step: Double = 0.0025) -> (lag: Double, rmsAtLag: Double, rmsAtZero: Double)? {
        func rmsError(_ lag: Double) -> Double? {
            var acc = 0.0, n = 0
            for (i, t) in times.enumerated() {
                guard let m = measured[i] else { continue }
                let c = commanded(t - lag)
                acc += (m - c) * (m - c); n += 1
            }
            return n > 10 ? sqrt(acc / Double(n)) : nil
        }
        guard let zero = rmsError(0) else { return nil }
        var bestLag = 0.0, bestErr = zero
        var lag = step
        while lag <= maxLag {
            if let e = rmsError(lag), e < bestErr { bestErr = e; bestLag = lag }
            lag += step
        }
        return (bestLag, bestErr, zero)
    }

    // MARK: - Discontinuities

    static func maxAbsDelta(_ x: [Float], _ start: Int, _ end: Int) -> Float {
        let s = max(1, start), e = min(x.count, end)
        guard e > s else { return 0 }
        var m: Float = 0
        for i in s..<e { m = max(m, abs(x[i] - x[i - 1])) }
        return m
    }

    /// 99.9th percentile of |Δx| over a span: the signal's own "normal"
    /// sample-to-sample motion, used to normalise a click.
    static func typicalDelta(_ x: [Float], _ start: Int, _ end: Int) -> Float {
        let s = max(1, start), e = min(x.count, end)
        guard e > s + 100 else { return 0 }
        var d = [Double](); d.reserveCapacity(e - s)
        for i in s..<e { d.append(Double(abs(x[i] - x[i - 1]))) }
        return Float(percentile(d, 99.9) ?? 0)
    }

    // MARK: - Spectra

    final class RealDFT {
        let n: Int
        private let setup: vDSP_DFT_Setup
        private let window: [Float]
        init(n: Int) {
            self.n = n
            setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized,
                                 count: n, isHalfWindow: false)
        }
        deinit { vDSP_DFT_DestroySetup(setup) }

        /// Power spectrum (n/2+1 bins) of `x[start..<start+n]`, Hann window,
        /// zero-padded past the end of `x`.
        func power(_ x: [Float], start: Int) -> [Float] {
            var frame = [Float](repeating: 0, count: n)
            for i in 0..<n where start + i >= 0 && start + i < x.count { frame[i] = x[start + i] * window[i] }
            let h = n / 2
            var ir = [Float](repeating: 0, count: h), ii = [Float](repeating: 0, count: h)
            for k in 0..<h { ir[k] = frame[2 * k]; ii[k] = frame[2 * k + 1] }
            var or = [Float](repeating: 0, count: h), oi = [Float](repeating: 0, count: h)
            vDSP_DFT_Execute(setup, ir, ii, &or, &oi)
            var p = [Float](repeating: 0, count: h + 1)
            p[0] = or[0] * or[0]
            p[h] = oi[0] * oi[0]
            for k in 1..<h { p[k] = or[k] * or[k] + oi[k] * oi[k] }
            return p
        }
    }

    static func spectrogram(_ x: [Float], from: Int, to: Int, n: Int = 1024, hop: Int = 256) -> [[Float]] {
        let dft = RealDFT(n: n)
        var frames: [[Float]] = []
        var s = from
        while s + n <= min(to, x.count) {
            frames.append(dft.power(x, start: s))
            s += hop
        }
        return frames
    }

    /// Spectral flux (half-wave rectified magnitude difference, summed over
    /// bins) per frame; returns (max/median ratio, frames above 6x median).
    static func fluxSpikes(_ spec: [[Float]]) -> (ratio: Double, count: Int)? {
        guard spec.count > 3 else { return nil }
        var flux: [Double] = []
        for i in 1..<spec.count {
            var f = 0.0
            for k in 0..<spec[i].count {
                let d = Double(sqrt(spec[i][k]) - sqrt(spec[i - 1][k]))
                if d > 0 { f += d }
            }
            flux.append(f)
        }
        guard let med = median(flux), med > 0, let mx = flux.max() else { return nil }
        return (mx / med, flux.filter { $0 > 6 * med }.count)
    }

    /// Log-spectral distance (dB) between two spectrograms, frame by frame
    /// over the common length, bins up to `maxBin`, each frame floored at
    /// -80 dB re the frame's reference maximum. Mean over frames.
    static func logSpectralDistance(_ a: [[Float]], _ b: [[Float]], maxBin: Int? = nil) -> Double? {
        let n = min(a.count, b.count)
        guard n > 0 else { return nil }
        var total = 0.0
        for i in 0..<n {
            let bins = min(maxBin ?? a[i].count, a[i].count, b[i].count)
            let peak = max(a[i].max() ?? 0, b[i].max() ?? 0)
            let floorP = max(Double(peak) * 1e-8, 1e-20)
            var acc = 0.0
            for k in 0..<bins {
                let pa = max(Double(a[i][k]), floorP), pb = max(Double(b[i][k]), floorP)
                let diff = 10 * log10(pa / pb)
                acc += diff * diff
            }
            total += sqrt(acc / Double(bins))
        }
        return total / Double(n)
    }

    /// Modulation spectrum: 10 ms-window / 5 ms-hop RMS envelope, mean
    /// removed, 512-point DFT; bins 1..<count up to `maxHz`, in dB re the
    /// spectrum's own total power (so overall level does not count).
    static func modulationSpectrum(_ x: [Float], from: Int, to: Int, sampleRate: Double, maxHz: Double = 50) -> [Double] {
        let hop = Int((0.005 * sampleRate).rounded())
        var env = envelope(x, start: from, end: to, win: 2 * hop, hop: hop)
        guard env.count >= 32 else { return [] }
        let mean = env.reduce(0, +) / Float(env.count)
        env = env.map { $0 - mean }
        let n = 512
        let p = RealDFT(n: n).power(Array(env.prefix(n)), start: 0)
        let frameRate = sampleRate / Double(hop)
        let maxBin = min(p.count - 1, Int(maxHz / (frameRate / Double(n))))
        guard maxBin >= 2 else { return [] }
        let band = p[1...maxBin].map(Double.init)
        let total = band.reduce(0, +)
        guard total > 0 else { return band.map { _ in -200 } }
        return band.map { 10 * log10(max($0 / total, 1e-12)) }
    }

    /// RMS dB difference of two modulation spectra.
    static func modulationDeviation(_ a: [Double], _ b: [Double]) -> Double? {
        let n = min(a.count, b.count)
        guard n > 0 else { return nil }
        var acc = 0.0
        for i in 0..<n { acc += (a[i] - b[i]) * (a[i] - b[i]) }
        return sqrt(acc / Double(n))
    }
}
