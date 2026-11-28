// PitchMetrics.swift
// PrimaeNativeTests — pitch bake-off harness (BENCH-P 2026-11-23; r31 gate-method fixes, lane BENCH-R31 2026-11-28)
//
// The pitch-specific metrics of BAKEOFF-PITCH.md section 4.2, pure Swift/vDSP over Float arrays (Foundation +
// Accelerate only).
//
// r31 method fixes (lane BENCH-R31, measured in docs/DECISIONS.md):
// - STFT uses interior whole Hann windows only (no `boundary='zeros'` zero-padding), eliminating the +-0.20 dB
//   window-start-phase edge-step leakage into deep inter-formant / nasal-antiformant troughs.
// - True-envelope warp (`env_warp`) uses Roebel & Rodet's signal-own F0 cepstral order (`0.5 * fs / f0`) instead of
//   a fixed 360 Hz order (fixed order failed +-0.03 on pure varispeed of A/L +600 c), and refines the coarse 0.005
//   warp grid continuously by golden-section search (eliminating warp-grid quantisation on I +600 c @2).
// - Attack pitch error (`traj_attack`) evaluates over the actual recorded attack at causal lag 0...10 ms (matching
//   `traj_pitch_lag`'s 10 ms causal budget).
// - `PowerFFT` and `CepstralLifter` instances are cached by `(n)` / `(n, order)` for fast 8-seed spreads on device.

import Accelerate
import Foundation

enum PitchMetrics {

    // MARK: - Small helpers

    static func rmsDB(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return -240 }
        var s = 0.0
        for v in x { s += Double(v) * Double(v) }
        return 20 * log10((s / Double(x.count)).squareRoot() + 1e-12)
    }

    static func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }

    static func cents(_ f: Double, re ref: Double) -> Double { 1200 * log2(f / ref) }

    // MARK: - Real FFT (Double), power spectra

    final class PowerFFT {
        let n: Int
        let bins: Int
        private let log2n: vDSP_Length
        private let setup: FFTSetupD
        let window: [Double]
        let windowSum: Double

        private static let cacheLock = NSLock()
        private nonisolated(unsafe) static var cache: [Int: PowerFFT] = [:]

        static func cached(n: Int) -> PowerFFT {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            if let existing = cache[n] { return existing }
            let created = PowerFFT(n: n)
            cache[n] = created
            return created
        }

        init(n: Int) {
            precondition(n > 0 && n & (n - 1) == 0, "n must be a power of two")
            self.n = n
            bins = n / 2 + 1
            log2n = vDSP_Length(log2(Double(n)).rounded())
            setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
            // Periodic Hann (scipy.signal.get_window('hann', n), fftbins=True).
            window = (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(n)) }
            windowSum = window.reduce(0, +)
        }
        deinit { vDSP_destroy_fftsetupD(setup) }

        /// |Z|^2 per bin of one frame (already windowed by the caller or not), Z scaled by 1/sum(window).
        func power(frame: [Double]) -> [Double] {
            let h = n / 2
            var re = [Double](repeating: 0, count: h), im = [Double](repeating: 0, count: h)
            for k in 0..<h { re[k] = frame[2 * k]; im[k] = frame[2 * k + 1] }
            var out = [Double](repeating: 0, count: bins)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPDoubleSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    // zrip output is 2x the DFT; DC in realp[0], Nyquist in imagp[0].
                    let s = 1 / (2 * windowSum)
                    out[0] = (rp[0] * s) * (rp[0] * s)
                    out[h] = (ip[0] * s) * (ip[0] * s)
                    for k in 1..<h {
                        let a = rp[k] * s, b = ip[k] * s
                        out[k] = a * a + b * b
                    }
                }
            }
            return out
        }

        /// Interior whole-window Hann STFT power frames (no `boundary='zeros'` zero-padding, so the spectrum does not
        /// depend on the waveform amplitude at the slice edges). Falls back to one zero-padded frame only if `x.count < n`.
        func stftPower(_ x: ArraySlice<Float>, hop: Int) -> [[Double]] {
            var frames: [[Double]] = []
            var frame = [Double](repeating: 0, count: n)
            if x.count < n {
                for i in 0..<x.count { frame[i] = Double(x[x.startIndex + i]) * window[i] }
                return [power(frame: frame)]
            }
            frames.reserveCapacity((x.count - n) / hop + 1)
            var s = x.startIndex
            while s + n <= x.endIndex {
                for i in 0..<n { frame[i] = Double(x[s + i]) * window[i] }
                frames.append(power(frame: frame))
                s += hop
            }
            return frames
        }

        var frequencies: [Double] { (0..<bins).map { Double($0) } }   // in bins; scale by fs/n
    }

    /// Long-term average power spectrum: mean |Z|^2 over interior Hann frames + 1e-20, and the bin frequencies.
    static func ltas(_ x: ArraySlice<Float>, sampleRate: Double, nfft: Int = 4096) -> (f: [Double], p: [Double]) {
        let fft = PowerFFT.cached(n: nfft)
        let frames = fft.stftPower(x, hop: nfft / 4)
        var p = [Double](repeating: 0, count: fft.bins)
        for fr in frames { for k in 0..<fft.bins { p[k] += fr[k] } }
        let c = Double(max(1, frames.count))
        for k in 0..<fft.bins { p[k] = p[k] / c + 1e-20 }
        let f = (0..<fft.bins).map { Double($0) * sampleRate / Double(nfft) }
        return (f, p)
    }

    // MARK: - True envelope (Roebel & Rodet 2005)

    /// Cepstral smoothing operator for an n-point real even log-spectrum, liftered to `order`.
    final class CepstralLifter {
        let n: Int, bins: Int, order: Int
        /// basis[k * bins + m] = cos(2 pi m k / n), k = 0...order, m = 0...n/2.
        private let basis: [Double]
        private let wm: [Double]   // forward weights over bins (1, 2, ..., 2, 1) / n
        private let uk: [Double]   // inverse weights over quefrencies (1, 2, ..., 2)

        private nonisolated struct Key: Hashable { let n: Int; let order: Int }
        private static let cacheLock = NSLock()
        private nonisolated(unsafe) static var cache: [Key: CepstralLifter] = [:]

        static func cached(n: Int, order: Int) -> CepstralLifter {
            let key = Key(n: n, order: order)
            cacheLock.lock()
            defer { cacheLock.unlock() }
            if let existing = cache[key] { return existing }
            let created = CepstralLifter(n: n, order: order)
            cache[key] = created
            return created
        }

        init(n: Int, order: Int) {
            self.n = n
            bins = n / 2 + 1
            self.order = order
            let bins = n / 2 + 1
            var b = [Double](repeating: 0, count: (order + 1) * bins)
            for k in 0...order {
                for m in 0..<bins { b[k * bins + m] = cos(2 * .pi * Double((m * k) % n) / Double(n)) }
            }
            basis = b
            wm = (0..<bins).map { m in (m == 0 || m == bins - 1 ? 1.0 : 2.0) / Double(n) }
            uk = (0...order).map { $0 == 0 ? 1.0 : 2.0 }
        }

        /// rfft(lifter(irfft(t))).real, i.e. the cepstrally smoothed `t`.
        func smooth(_ t: [Double]) -> [Double] {
            var weighted = [Double](repeating: 0, count: bins)
            vDSP_vmulD(t, 1, wm, 1, &weighted, 1, vDSP_Length(bins))
            var c = [Double](repeating: 0, count: order + 1)
            // c (order+1 x 1) = basis (order+1 x bins) * weighted (bins x 1)
            vDSP_mmulD(basis, 1, weighted, 1, &c, 1, vDSP_Length(order + 1), 1, vDSP_Length(bins))
            vDSP_vmulD(c, 1, uk, 1, &c, 1, vDSP_Length(order + 1))
            var v = [Double](repeating: 0, count: bins)
            // v (1 x bins) = c^T (1 x order+1) * basis (order+1 x bins)
            vDSP_mmulD(c, 1, basis, 1, &v, 1, 1, vDSP_Length(bins), vDSP_Length(order + 1))
            return v
        }
    }

    /// `true_envelope(P, order, iters)` of metrics_r27: the envelope in dB of a power spectrum.
    static func trueEnvelope(_ p: [Double], lifter: CepstralLifter, iters: Int = 60) -> [Double] {
        let a = p.map { 0.5 * log($0) }
        var v = [Double](repeating: -.infinity, count: a.count)
        for _ in 0..<iters {
            var target = a
            for i in 0..<a.count where v[i] > target[i] { target[i] = v[i] }
            v = lifter.smooth(target)
            var excess = -Double.infinity
            for i in 0..<a.count { excess = max(excess, a[i] - v[i]) }
            if excess < 0.1 { break }
        }
        let k = 20 / log(10.0)
        return v.map { $0 * k }
    }

    /// Cepstral order of the envelope: int(0.5 fs / max(f0max, 100)).
    static func envelopeOrder(sampleRate: Double, f0max: Double) -> Int { Int(0.5 * sampleRate / max(f0max, 100)) }

    /// True envelope (dB) of the LTAS (nfft 4096) of `x`, at cepstral order `0.5 fs / max(f0max, 100)`.
    /// Pass `f0max: 360` for matched-order LSD comparisons against Praat; pass the signal's own F0 for scale-covariant
    /// warp measurement (`env_warp`).
    static func envelopeDB(_ x: ArraySlice<Float>, sampleRate: Double, f0max: Double = 360) -> (f: [Double], e: [Double]) {
        let (f, p) = ltas(x, sampleRate: sampleRate)
        let lifter = CepstralLifter.cached(n: 4096, order: envelopeOrder(sampleRate: sampleRate, f0max: f0max))
        return (f, trueEnvelope(p, lifter: lifter))
    }

    /// True envelope from a precomputed LTAS power spectrum (avoids recomputing the STFT when both fixed-order LSD
    /// and own-F0 warp are measured on the same slice).
    static func envelopeDB(ltas: (f: [Double], p: [Double]), sampleRate: Double, f0max: Double)
        -> (f: [Double], e: [Double]) {
        let n = 2 * (ltas.p.count - 1)
        let lifter = CepstralLifter.cached(n: n, order: envelopeOrder(sampleRate: sampleRate, f0max: f0max))
        return (ltas.f, trueEnvelope(ltas.p, lifter: lifter))
    }

    /// np.interp(x, xp, fp) for ascending, evenly spaced xp (clamped at both ends).
    static func interpEven(_ x: Double, x0: Double, dx: Double, _ fp: [Double]) -> Double {
        let u = (x - x0) / dx
        if u <= 0 { return fp[0] }
        let i = Int(u)
        if i >= fp.count - 1 { return fp[fp.count - 1] }
        let t = u - Double(i)
        return fp[i] + t * (fp[i + 1] - fp[i])
    }

    struct EnvelopeComparison {
        /// Level-free LSD (dB) at alpha = 1.
        let lsd: Double
        /// argmin over alpha in [0.6, 1.6] of LSD(Eb(f) vs Ea(f / alpha)), continuously refined around the grid min.
        let warp: Double
        let lsdAtWarp: Double
    }

    /// Level-free LSD at alpha = 1 and continuous best warp alpha in [0.6, 1.6] (`ea` = source, `eb` = output).
    /// Golden-section refinement around the coarse grid minimum eliminates the 0.005 grid quantisation step.
    static func envelopeCompare(f: [Double], source ea: [Double], output eb: [Double],
                                lo: Double = 150, hi: Double = 5000,
                                alphas: [Double] = PitchMetrics.warpGrid,
                                refine: Bool = true) -> EnvelopeComparison {
        let band = f.indices.filter { f[$0] >= lo && f[$0] <= hi }
        let dx = f[1] - f[0]
        func lsd(_ alpha: Double) -> Double {
            var d = band.map { eb[$0] - interpEven(f[$0] / alpha, x0: f[0], dx: dx, ea) }
            let m = d.reduce(0, +) / Double(d.count)
            for i in d.indices { d[i] -= m }
            return (d.reduce(0) { $0 + $1 * $1 } / Double(d.count)).squareRoot()
        }
        let l = alphas.map(lsd)
        var best = 0
        for i in l.indices where l[i] < l[best] { best = i }
        var bestAlpha = alphas[best]
        var bestLSD = l[best]
        if refine && alphas.count >= 3 {
            var a = alphas[max(0, best - 1)]
            var b = alphas[min(alphas.count - 1, best + 1)]
            let phi = 0.5 * (sqrt(5.0) - 1.0)
            var c = b - phi * (b - a)
            var d = a + phi * (b - a)
            var fc = lsd(c)
            var fd = lsd(d)
            for _ in 0..<24 {
                if fc < fd {
                    b = d; d = c; fd = fc; c = b - phi * (b - a); fc = lsd(c)
                } else {
                    a = c; c = d; fc = fd; d = a + phi * (b - a); fd = lsd(d)
                }
            }
            let mid = 0.5 * (a + b)
            let fMid = lsd(mid)
            if fMid < bestLSD { bestAlpha = mid; bestLSD = fMid }
        }
        return EnvelopeComparison(lsd: lsd(1), warp: bestAlpha, lsdAtWarp: bestLSD)
    }

    /// np.linspace(0.6, 1.6, 201).
    static let warpGrid: [Double] = (0..<201).map { 0.6 + Double($0) * (1.0 / 200) }

    /// Median over output frames of the level-free LSD (150...5000 Hz) of each frame's true envelope against the
    /// source's median frame envelope (nfft 2048, hop 1024, 40 iterations).
    static func framewiseEnvelopeLSD(source xs: ArraySlice<Float>, output y: ArraySlice<Float>, sampleRate: Double,
                                     f0max: Double = 360, nfft: Int = 2048, hop: Int = 1024) -> Double? {
        let fft = PowerFFT.cached(n: nfft)
        let lifter = CepstralLifter.cached(n: nfft, order: envelopeOrder(sampleRate: sampleRate, f0max: f0max))
        func envs(_ z: ArraySlice<Float>) -> [[Double]] {
            let frames = fft.stftPower(z, hop: hop).map { $0.map { $0 + 1e-20 } }
            let sums = frames.map { $0.reduce(0, +) }
            guard let top = sums.max() else { return [] }
            return zip(frames, sums).filter { $0.1 > 1e-8 * top }.map { trueEnvelope($0.0, lifter: lifter, iters: 40) }
        }
        let es = envs(xs), ey = envs(y)
        guard !es.isEmpty, !ey.isEmpty else { return nil }
        let band = (0..<fft.bins).filter {
            let f = Double($0) * sampleRate / Double(nfft)
            return f >= 150 && f <= 5000
        }
        let ms = band.map { b in median(es.map { $0[b] })! }
        let per: [Double] = ey.map { e in
            var d = band.indices.map { e[band[$0]] - ms[$0] }
            let m = d.reduce(0, +) / Double(d.count)
            for i in d.indices { d[i] -= m }
            return (d.reduce(0) { $0 + $1 * $1 } / Double(d.count)).squareRoot()
        }
        return median(per)
    }

    // MARK: - Jitter / shimmer from the signal's own marks

    struct Perturbation {
        /// Local jitter, percent: mean |T_i - T_{i-1}| / mean T.
        let jitterPct: Double
        /// Local shimmer, percent: mean |A_i - A_{i-1}| / mean A (`perturbation`: A = the RMS over one period centred on the mark).
        let shimmerPct: Double
        let periods: Int
        let meanPeriodFrames: Double
    }

    /// The pre-JITTER-EST estimator, kept only for the before/after truth table (`PitchMetricSelfTests`): cycles
    /// chained by normalised cross-correlation of one-period windows that are NOT anchored to the cycle (the first
    /// window starts at frame 0, each next one an integer lag later). A lag therefore averages the periods the
    /// window straddles, which biases local jitter low by an f0-dependent factor (BENCH-R31 (a)). Not on the gate path.
    static func perturbationUnanchored(_ x: ArraySlice<Float>, sampleRate: Double,
                             fmin: Double = 75, fmax: Double = 700) -> Perturbation? {
        let y = Array(x)
        let hop = Int(0.005 * sampleRate)
        let track = BakeoffMetrics.yinTrack(y, start: 0, end: y.count, sampleRate: sampleRate, hop: hop,
                                            fmin: fmin, fmax: fmax)
        let voiced = track.compactMap { p in p.f0.map { (frame: p.frame + 512, period: sampleRate / $0) } }
        guard voiced.count >= 10 else { return nil }
        func periodGuess(_ at: Int) -> Double {
            var best = voiced[0], dist = Int.max
            for v in voiced where abs(v.frame - at) < dist { dist = abs(v.frame - at); best = v }
            return best.period
        }
        let minP = sampleRate * 0.0001, maxP = sampleRate * 0.02
        var marks: [Double] = []
        var periods: [Double] = []
        var amps: [Double] = []
        var m = 0
        while true {
            let t = periodGuess(m)
            let w = Int(t.rounded())
            let lo = Int((0.75 * t).rounded(.down)), hi = Int((1.33 * t).rounded(.up))
            guard m + hi + w + 2 < y.count, lo > 2 else { break }
            // Normalised cross-correlation of [m, m+w) against [m+L, m+L+w).
            var e0 = 0.0
            for i in 0..<w { e0 += Double(y[m + i]) * Double(y[m + i]) }
            var r = [Double](repeating: -2, count: hi + 2)
            for lag in (lo - 1)...(hi + 1) {
                var c = 0.0, e1 = 0.0
                for i in 0..<w {
                    let a = Double(y[m + i]), b = Double(y[m + lag + i])
                    c += a * b; e1 += b * b
                }
                r[lag] = e0 > 0 && e1 > 0 ? c / (e0 * e1).squareRoot() : 0
            }
            var best = lo
            for lag in lo...hi where r[lag] > r[best] { best = lag }
            var p = Double(best)
            let a = r[best - 1], b = r[best], c = r[best + 1], den = a - 2 * b + c
            if den < 0 { p += 0.5 * (a - c) / den }
            if b > 0.5 {
                // Peak amplitude over the period.
                var amp = 0.0
                for i in m..<(m + best) { amp = max(amp, Double(abs(y[i]))) }
                marks.append(Double(m)); periods.append(p); amps.append(amp)
            } else {
                // A break in periodicity: do not pair across it.
                marks.append(Double(m)); periods.append(.nan); amps.append(.nan)
            }
            m += best
        }
        var dj = 0.0, sj = 0.0, nj = 0
        var ds = 0.0, ss = 0.0, ns = 0
        for i in 1..<max(1, periods.count) {
            let t0 = periods[i - 1], t1 = periods[i]
            guard t0.isFinite, t1.isFinite, t0 >= minP, t0 <= maxP, t1 >= minP, t1 <= maxP,
                  max(t0, t1) / min(t0, t1) <= 1.3 else { continue }
            dj += abs(t1 - t0); sj += 0.5 * (t0 + t1); nj += 1
            let a0 = amps[i - 1], a1 = amps[i]
            if a0 > 0, a1 > 0, max(a0, a1) / min(a0, a1) <= 1.6 {
                ds += abs(a1 - a0); ss += 0.5 * (a0 + a1); ns += 1
            }
        }
        guard nj >= 20, ns >= 20 else { return nil }
        return Perturbation(jitterPct: dj / sj * 100, shimmerPct: ds / ss * 100, periods: nj,
                            meanPeriodFrames: sj / Double(nj))
    }

    /// Cycle-anchored local jitter and shimmer: a point process of glottal-cycle marks, one per period, in the
    /// manner of Praat's cross-correlation point process. This is the estimator the jitter/shimmer gates use (lane
    /// JITTER-EST, 2026-11-28); `perturbationUnanchored` is the method it replaces, kept for the before/after table.
    ///
    /// Clean-room, from public sources only:
    /// - P. Boersma (1993), "Accurate short-term analysis of the fundamental frequency and the harmonics-to-noise
    ///   ratio of a sampled sound", IFA Proceedings 17: 97-110 (periodicity from the normalised autocorrelation of a
    ///   windowed frame; parabolic/sinc refinement of the lag).
    /// - Praat manual, "Sound & Pitch: To PointProcess (cc)": points are placed one local period apart inside each
    ///   voiced interval, starting from an absolute extremum of the waveform and finding each next point by
    ///   cross-correlation with the previous cycle, guided by the pitch contour.
    /// - Praat manual, "PointProcess: Get jitter (local)" / "Voice 2. Jitter": mean absolute difference of
    ///   consecutive intervals over the mean interval; intervals outside 0.1...20 ms are skipped, and a pair is skipped
    ///   when one interval exceeds the other by more than the period factor 1.3.
    /// - Praat manual, "Voice 3. Shimmer" / "Sound & PointProcess: Get shimmer (local)": mean absolute difference of
    ///   the amplitudes of consecutive periods over the mean amplitude, pairs beyond the amplitude factor 1.6 skipped.
    ///
    /// Method. The polarity is the sign of the larger absolute extremum of the segment (the glottal pulse side). The
    /// first mark is the extremum within one local period of the segment's middle; from each mark `m` with local
    /// period `T` (YIN, 5 ms hop) the next mark is `m` plus the lag of a normalised cross-correlation of the cycle
    /// around `m` (window `[m - T/8, m + T/2]`, anchored on the pulse and mostly after it, so the window neither
    /// straddles the next pulse nor carries much of the previous cycle's ringing) against the signal at lags
    /// `0.8T ... 1.25T`, refined to a sub-sample lag on the band-limited (windowed-sinc) interpolation of the waveform
    /// (lane BENCHWIN2; JITTER-EST took the waveform extremum near the prediction instead, which hops between peaks
    /// on a real voice). The period is the distance between consecutive marks. The cycle amplitude (BENCHWIN3) is the
    /// RMS of the signal over one period centred on the mark, `m - T1/2 ... m + T2/2` (T1, T2 the periods before and
    /// after it). It was the largest extremum within `+-T/8` of the mark, which reads a change of the cycle's waveform
    /// SHAPE at constant energy as shimmer: measured 3.4 ... 3.8x the generated shimmer on
    /// `testShimmerIsReadOnTheCycleEnergyNotOnItsWaveformShape` (this window: within 15 %), and on the recorded I
    /// 3.64 % where Praat reads 0.84 %, on I's r31 renders 2.9 ... 3.0 % where Praat reads 1.04 ... 1.20 %, so I's
    /// shimmer ratio read 0.75 ... 0.84 where Praat's reads 1.24 ... 1.43. Praat's own per-period amplitude is a Hann-
    /// windowed RMS over `m - 0.2 T1 ... m + 0.2 T2` (measured: that window reproduces Praat's "To AmplitudeTier
    /// (period)" values on Praat's cc points up to one constant, 0.958 +- 0.001, on the recorded I and M); it was not
    /// taken, because its unequal weighting inside the cycle still reads shape as shimmer (1.17 ... 1.93x on the same
    /// test's 0.35 ms cells, worst at 300 Hz), while one whole period's energy does not depend on where in the cycle the
    /// energy sits (a +-T/4 window reads 4.1 ... 4.7x on the test's 0.4 T cells).
    /// A cycle without a mark on both sides has no amplitude. Chains walk left and right of the
    /// first mark; a cycle whose correlation is below 0.5 breaks the chain (no
    /// pair is formed across a break). Nil when fewer than 20 usable period pairs are found.
    static func perturbation(_ x: ArraySlice<Float>, sampleRate: Double,
                             fmin: Double = 75, fmax: Double = 700) -> Perturbation? {
        let y = Array(x)
        guard y.count > 64 else { return nil }
        let hop = Int(0.005 * sampleRate)
        let track = BakeoffMetrics.yinTrack(y, start: 0, end: y.count, sampleRate: sampleRate, hop: hop,
                                            fmin: fmin, fmax: fmax)
        // Pitch frame centre: the YIN window is 1024 frames. The track only GUIDES the search (the nearest voiced
        // frame's period, as Praat's point process is guided by its pitch contour); breaks come from the correlation.
        let voiced = track.compactMap { p in p.f0.map { (frame: p.frame + 512, period: sampleRate / $0) } }
        guard let global = segmentPeriod(y, sampleRate: sampleRate, fmin: fmin, fmax: fmax) else { return nil }
        // YIN can lock to a multiple or a fraction of the period on a sharply pulsed signal (measured: 3T on a
        // jittered band-limited pulse train at 300 Hz); each local guide is folded by an integer factor to the octave
        // of the segment's autocorrelation period.
        // With no voiced YIN frame at all (measured: a pulse train with 1 % jitter at >= 150 Hz) the guide is the
        // segment period alone.
        func periodAt(_ at: Double) -> Double? {
            guard !voiced.isEmpty else { return global }
            var best = voiced[0], dist = Double.infinity
            for v in voiced where abs(Double(v.frame) - at) < dist { dist = abs(Double(v.frame) - at); best = v }
            var p = best.period, bestErr = Double.infinity
            for k in [1.0 / 4, 1.0 / 3, 0.5, 1, 2, 3, 4] {
                let e = abs(log(best.period * k / global))
                if e < bestErr { bestErr = e; p = best.period * k }
            }
            return bestErr < log(1.25) ? p : global
        }
        let hi = y.max() ?? 0, lo = y.min() ?? 0
        let sign: Float = hi >= -lo ? 1 : -1
        let z = y.map { $0 * sign }
        /// Band-limited value of `z` at fractional time `t`: Hann-windowed sinc over +-`halfTaps` samples.
        let halfTaps = 24
        func interp(_ t: Double) -> Double {
            let c = Int(t.rounded(.down))
            var v = 0.0
            for i in max(0, c - halfTaps + 1)...min(z.count - 1, c + halfTaps) {
                let d = t - Double(i)
                let w = 0.5 + 0.5 * cos(.pi * d / Double(halfTaps))
                v += Double(z[i]) * (abs(d) < 1e-9 ? 1 : sin(.pi * d) / (.pi * d)) * w
            }
            return v
        }
        /// Short (+-8 tap) Hann-windowed sinc of `z`, for the cross-correlation at a fractional lag.
        func interpShort(_ t: Double) -> Double {
            let c = Int(t.rounded(.down)), h = 8
            var v = 0.0
            for i in max(0, c - h + 1)...min(z.count - 1, c + h) {
                let d = t - Double(i)
                let w = 0.5 + 0.5 * cos(.pi * d / Double(h))
                v += Double(z[i]) * (abs(d) < 1e-9 ? 1 : sin(.pi * d) / (.pi * d)) * w
            }
            return v
        }
        /// Sub-sample extremum of `z` in the integer range [a, b]: the largest sample, then the maximum of the
        /// band-limited (sinc) interpolation within +-1 sample of it by golden-section search. A parabola through
        /// three samples is not enough on a sharp pulse: measured, it doubled local shimmer on a band-limited pulse
        /// train (the sampled peak of a pulse at a fractional time varies with that fraction).
        func peak(_ a: Int, _ b: Int) -> (pos: Double, amp: Double)? {
            let a = max(1, a), b = min(z.count - 2, b)
            guard a <= b else { return nil }
            var k = a
            for i in a...b where z[i] > z[k] { k = i }
            let g = (5.0.squareRoot() - 1) / 2
            var lo = Double(k) - 1, hi = Double(k) + 1
            var x1 = hi - g * (hi - lo), x2 = lo + g * (hi - lo)
            var f1 = interp(x1), f2 = interp(x2)
            for _ in 0..<24 {
                if f1 > f2 { hi = x2; x2 = x1; f2 = f1; x1 = hi - g * (hi - lo); f1 = interp(x1) }
                else { lo = x1; x1 = x2; f1 = f2; x2 = lo + g * (hi - lo); f2 = interp(x2) }
            }
            let t = 0.5 * (lo + hi)
            return (t, interp(t))
        }
        /// Next mark from `m` in direction `dir` (+1 right, -1 left): the sub-sample cross-correlation lag.
        func step(_ m: Double, _ dir: Int) -> (pos: Double, r: Double)? {
            guard let t = periodAt(m) else { return nil }
            let c = Int(m.rounded())
            // Window [m - T/8, m + T/2] (BENCHWIN2): a T/4 lead-in carries the previous cycle's formant ringing, so the
            // lag averages two periods (measured: a 200 Hz formant vowel read 0.85x its generated jitter with
            // [m - T/4, m + 3T/4], 0.97x with this window).
            let wa = Int((0.125 * t).rounded()), wb = Int((0.5 * t).rounded())
            let lo = Int((0.8 * t).rounded(.down)), hi = Int((1.25 * t).rounded(.up))
            guard c - wa >= 0, c + wb < z.count else { return nil }
            var e0 = 0.0
            for i in (c - wa)...(c + wb) { e0 += Double(z[i]) * Double(z[i]) }
            var rAt = [Double](repeating: -2, count: hi - lo + 1)
            var bestLag = lo, bestR = -2.0
            for lag in lo...hi {
                let s = c + dir * lag
                guard s - wa >= 0, s + wb < z.count else { continue }
                var cc = 0.0, e1 = 0.0
                for i in -wa...wb {
                    let a = Double(z[c + i]), b = Double(z[s + i])
                    cc += a * b; e1 += b * b
                }
                let r = e0 > 0 && e1 > 0 ? cc / (e0 * e1).squareRoot() : 0
                rAt[lag - lo] = r
                if r > bestR { bestR = r; bestLag = lag }
            }
            guard bestR > -2 else { return nil }
            // The next mark is the previous mark plus the sub-sample cross-correlation lag (BENCHWIN2): the maximum
            // of the correlation between the cycle at `c` and the band-limited (sinc-interpolated) signal at a
            // fractional lag, by golden-section search within +-1 sample of the best integer lag. NOT the waveform
            // extremum near the prediction: measured on the recorded study phonemes, a real voice has two or more
            // peaks of similar height per cycle and broad (nasal) peaks, and the extremum hopped between them
            // (periods 3.97 / 4.63 / 3.98 ms where Praat's cc points read 4.26 ... 4.35 ms), so the old marks read
            // the sources' jitter at 3.8x (A) to 11.5x (M) Praat's.
            func ncc(_ lag: Double) -> Double {
                var cc = 0.0, e1 = 0.0
                for i in -wa...wb {
                    let b = interpShort(Double(c + i) + Double(dir) * lag)
                    cc += Double(z[c + i]) * b; e1 += b * b
                }
                return e0 > 0 && e1 > 0 ? cc / (e0 * e1).squareRoot() : 0
            }
            // The three highest integer-lag maxima are each refined, and the best REFINED one wins: on a full-band
            // pulse the integer-lag correlation at the true lag falls to ~0.7 when the period's fractional part is
            // near half a sample (sinc(0.5) = 0.64), below a lag that aligns a cycle's second peak with its first
            // (measured: a two-peak pulse train at 200 Hz, 44.1 kHz, read 4.5x its jitter on the integer pick).
            var cands: [Int] = []
            for l in lo...hi where rAt[l - lo] > -2 {
                let r = rAt[l - lo]
                if (l == lo || r >= rAt[l - lo - 1]) && (l == hi || r >= rAt[l - lo + 1]) { cands.append(l) }
            }
            cands = Array(cands.sorted { rAt[$0 - lo] > rAt[$1 - lo] }.prefix(3))
            var lag = Double(bestLag)
            var refinedBest = -2.0
            for l in cands {
                guard l > lo, l < hi, c + dir * (l + 1) + wb + 8 < z.count, c + dir * (l + 1) - wa - 8 >= 0 else {
                    if rAt[l - lo] > refinedBest { refinedBest = rAt[l - lo]; lag = Double(l) }
                    continue
                }
                let g = (5.0.squareRoot() - 1) / 2
                var a = Double(l) - 1, b = Double(l) + 1
                var x1 = b - g * (b - a), x2 = a + g * (b - a)
                var f1 = ncc(x1), f2 = ncc(x2)
                for _ in 0..<20 {
                    if f1 > f2 { b = x2; x2 = x1; f2 = f1; x1 = b - g * (b - a); f1 = ncc(x1) }
                    else { a = x1; x1 = x2; f1 = f2; x2 = a + g * (b - a); f2 = ncc(x2) }
                }
                let r = max(f1, f2)
                if r > refinedBest { refinedBest = r; lag = 0.5 * (a + b) }
            }
            bestR = max(bestR, refinedBest)
            let pos = m + Double(dir) * lag
            // The chain ends where the old amplitude window (+-T/8 around the mark) would have left the signal, so the
            // marks, and the jitter read from them, are those of BENCHWIN2 exactly.
            let tol = max(1, Int((0.125 * t).rounded())), pc = Int(pos.rounded())
            guard max(1, pc - tol) <= min(z.count - 2, pc + tol) else { return nil }
            return (pos, bestR)
        }
        /// Cycle amplitude at mark `m` (shimmer, BENCHWIN3): RMS over one period centred on the mark,
        /// `m - t1/2 ... m + t2/2`, with fractional edge samples.
        func periodRMS(_ m: Double, _ t1: Double, _ t2: Double) -> Double? {
            let lo = m - 0.5 * t1, hi = m + 0.5 * t2
            let a = max(0, Int(lo.rounded(.up))), b = min(y.count - 1, Int(hi.rounded(.down)))
            guard a < b, a > 0, b < y.count - 1 else { return nil }
            var s = 0.0
            for i in a...b { s += Double(y[i]) * Double(y[i]) }
            // Fractional edge samples, so the window is exactly (t1 + t2) / 2 long.
            let fa = Double(a) - lo, fb = hi - Double(b)
            s += fa * Double(y[a - 1]) * Double(y[a - 1]) + fb * Double(y[b + 1]) * Double(y[b + 1])
            return (s / (hi - lo)).squareRoot()
        }
        // First mark: the extremum within one local period of the middle.
        let mid = Double(y.count / 2)
        guard let t0 = periodAt(mid),
              let first = peak(Int(mid - t0 / 2), Int(mid + t0 / 2)) else { return nil }
        // Marks as chains (a nil entry is a break).
        var right: [Double?] = [first.pos]
        var m = first.pos
        while let s = step(m, 1) {
            if s.r > 0.5, s.pos > m { right.append(s.pos) } else { right.append(nil) }
            m = s.pos
        }
        var left: [Double?] = []
        m = first.pos
        while let s = step(m, -1) {
            if s.r > 0.5, s.pos < m { left.append(s.pos) } else { left.append(nil) }
            m = s.pos
        }
        let marks = Array(left.reversed()) + right
        // Periods and amplitudes per cycle: interval k spans marks k...k+1; the amplitude of cycle k is the period RMS
        // at mark k, which needs the period before it too (marks k-1 ... k+1 all present).
        var periods: [Double] = [], amps: [Double] = []
        for k in 0..<(marks.count - 1) {
            if let a = marks[k], let b = marks[k + 1] {
                periods.append(b - a)
                if k > 0, let p = marks[k - 1], let r = periodRMS(a, a - p, b - a) { amps.append(r) } else { amps.append(.nan) }
            } else {
                periods.append(.nan); amps.append(.nan)
            }
        }
        let minP = sampleRate * 0.0001, maxP = sampleRate * 0.02
        var dj = 0.0, sj = 0.0, nj = 0
        var ds = 0.0, ss = 0.0, ns = 0
        for i in 1..<max(1, periods.count) {
            let t0 = periods[i - 1], t1 = periods[i]
            guard t0.isFinite, t1.isFinite, t0 >= minP, t0 <= maxP, t1 >= minP, t1 <= maxP,
                  max(t0, t1) / min(t0, t1) <= 1.3 else { continue }
            dj += abs(t1 - t0); sj += 0.5 * (t0 + t1); nj += 1
            let a0 = amps[i - 1], a1 = amps[i]
            if a0 > 0, a1 > 0, max(a0, a1) / min(a0, a1) <= 1.6 {
                ds += abs(a1 - a0); ss += 0.5 * (a0 + a1); ns += 1
            }
        }
        guard nj >= 20, ns >= 20 else { return nil }
        return Perturbation(jitterPct: dj / sj * 100, shimmerPct: ds / ss * 100, periods: nj,
                            meanPeriodFrames: sj / Double(nj))
    }

    /// The segment's dominant period (frames) from the normalised autocorrelation of the whole (1 ms-smoothed) segment (Boersma
    /// 1993: the autocorrelation of the signal divided by that of the window, here a rectangular window, so the
    /// correction is N / (N - lag)); the shortest lag reaching 0.9 of the highest peak, which avoids sub-harmonic
    /// (double-period) picks. Refined by a parabola. Nil when no peak exceeds 0.3.
    static func segmentPeriod(_ y: [Float], sampleRate: Double, fmin: Double, fmax: Double) -> Double? {
        let tmin = max(2, Int(sampleRate / fmax)), tmax = Int(sampleRate / fmin)
        let n = y.count - tmax - 1
        guard n > tmax else { return nil }
        // A 1 ms moving average first: a sharp pulse train with cycle-to-cycle jitter of a few samples would
        // otherwise decorrelate at the period lag (measured: no peak above 0.3 at 100 Hz, 0.5 % jitter).
        let box = max(1, Int(0.001 * sampleRate))
        var sm = [Float](repeating: 0, count: y.count)
        var acc: Float = 0
        for i in y.indices {
            acc += y[i]
            if i >= box { acc -= y[i - box] }
            sm[i] = acc
        }
        var r = [Float](repeating: 0, count: tmax + 2)
        sm.withUnsafeBufferPointer { b in
            vDSP_conv(b.baseAddress!, 1, b.baseAddress!, 1, &r, 1, vDSP_Length(tmax + 2), vDSP_Length(n))
        }
        guard r[0] > 0 else { return nil }
        let rn = r.map { Double($0 / r[0]) }
        var peaks: [Int] = []
        for l in max(tmin, 1)...tmax where rn[l] > rn[l - 1] && rn[l] >= rn[l + 1] && rn[l] > 0.3 { peaks.append(l) }
        guard let top = peaks.map({ rn[$0] }).max(), let l = peaks.first(where: { rn[$0] >= 0.9 * top }) else { return nil }
        let a = rn[l - 1], b = rn[l], c = rn[l + 1], den = a - 2 * b + c
        return Double(l) + (den < 0 ? 0.5 * (a - c) / den : 0)
    }

    // MARK: - F (unvoiced): candidate A's definitions

    /// Unvoiced grain hop of the shipped renderer: (0.005 fs).rounded() (240 at 48 kHz, 221 at 44.1 kHz).
    static func unvoicedHop(sampleRate: Double) -> Int { Int((0.005 * sampleRate).rounded()) }

    /// Power folded on `period` frames (20 bins): max / min in dB ("mod200", the grain-rate buzz).
    static func grainRateWobble(_ y: ArraySlice<Float>, period: Int) -> Double {
        let bins = 20
        var acc = [Double](repeating: 0, count: bins), cnt = [Double](repeating: 0, count: bins)
        let lo = y.startIndex
        for i in y.indices {
            let b = ((i - lo) % period) * bins / period
            acc[b] += Double(y[i]) * Double(y[i]); cnt[b] += 1
        }
        let p = zip(acc, cnt).map { $0 / max(1, $1) }
        guard let mx = p.max(), let mn = p.min(), mn > 0 else { return .infinity }
        return 10 * log10(mx / mn)
    }

    /// Normalised autocorrelation at a fractional (linearly interpolated) lag.
    static func acf(_ y: ArraySlice<Float>, lag: Double) -> Double {
        let l = Int(lag), f = lag - Double(l)
        var ab = 0.0, aa = 0.0, bb = 0.0
        var i = y.startIndex
        while i < y.endIndex - l - 1 {
            let a = Double(y[i])
            let b = (1 - f) * Double(y[i + l]) + f * Double(y[i + l + 1])
            ab += a * b; aa += a * a; bb += b * b
            i += 1
        }
        return aa > 0 && bb > 0 ? ab / (aa * bb).squareRoot() : 0
    }

    /// The comb lag of a grain stream re-reading resampled noise: hop * |1 - 1/pf| (frames).
    static func combLag(hop: Int, pitchFactor pf: Double) -> Double { Double(hop) * abs(1 - 1 / pf) }

    // MARK: - Clicks during sweeps

    /// Worst local click ratio: over 5 ms blocks, max |dx| in the block / p99.9 of |dx| over the +-100 ms around it
    /// (the block's own pitch context, so an upshifted stretch is not read as a click). The r17 gate reads 2.5.
    static func localClickRatio(_ x: [Float], from: Int, to: Int, sampleRate: Double) -> Double? {
        let block = Int(0.005 * sampleRate), ctx = Int(0.1 * sampleRate)
        guard to - from > 2 * ctx + block else { return nil }
        var d = [Float](repeating: 0, count: x.count)
        for i in max(1, from - ctx)..<min(x.count, to + ctx) { d[i] = abs(x[i] - x[i - 1]) }
        var worst = 0.0
        var b = from
        while b + block <= to {
            var mx: Float = 0
            for i in b..<(b + block) { mx = max(mx, d[i]) }
            let c0 = max(1, b - ctx), c1 = min(x.count, b + block + ctx)
            let typical = BakeoffMetrics.percentile(d[c0..<c1].map(Double.init), 99.9) ?? 0
            if typical > 0 { worst = max(worst, Double(mx) / typical) }
            b += block
        }
        return worst
    }

    // MARK: - Pitch track in cents (step response, trajectory lag, attack accuracy)

    /// YIN analysis window of the cents track, defined in TIME: 1024 frames at the 48 kHz reference (21.33 ms), so a
    /// time-defined measure (`pitch_step_90`, `traj_pitch_lag`, `traj_attack`) analyses the same span at every rate
    /// (lane BENCH-R31: a fixed 1024-frame window was 23.22 ms at 44.1 kHz). 48 kHz is unchanged, bit for bit.
    static let yinWindowSeconds = 1024.0 / 48_000

    /// `yinWindowSeconds` in frames at `sampleRate` (1024 at 48 kHz, 941 at 44.1 kHz).
    static func yinWindow(sampleRate: Double) -> Int { Int((yinWindowSeconds * sampleRate).rounded()) }

    /// YIN f0 track of `x[from..<to]` as (time of window centre, cents re `ref`); hop and window in seconds.
    static func centsTrack(_ x: [Float], from: Int, to: Int, ref: Double, sampleRate: Double, hopSeconds: Double,
                           fmin: Double = 75, fmax: Double = 700, levelRef: Float? = nil) -> [(t: Double, v: Double?)] {
        let window = yinWindow(sampleRate: sampleRate)
        return BakeoffMetrics.yinTrack(x, start: from, end: to, sampleRate: sampleRate,
                                       hop: max(1, Int(hopSeconds * sampleRate)), fmin: fmin, fmax: fmax,
                                       window: window, levelRef: levelRef).map { p in
            (t: (Double(p.frame) + 0.5 * Double(window)) / sampleRate, v: p.f0.map { cents($0, re: ref) })
        }
    }

    /// RMS pitch error of attack frames against `commanded(t - lag)`, minimised over causal lags `0...maxLag`
    /// (matching `traj_pitch_lag`'s 10 ms causal budget so steep strokes are not penalised for 5 ms buffer/smoother lag).
    static func causalAttackRMS(points: [(t: Double, v: Double)], commanded: (Double) -> Double,
                                maxLag: Double = 0.010, step: Double = 0.0005)
        -> (rms: Double, rmsAtZero: Double, lag: Double)? {
        guard !points.isEmpty else { return nil }
        func rmsAt(_ lag: Double) -> Double {
            var s = 0.0
            for p in points {
                let d = p.v - commanded(p.t - lag)
                s += d * d
            }
            return (s / Double(points.count)).squareRoot()
        }
        let r0 = rmsAt(0)
        var best = r0, bestLag = 0.0
        let steps = max(0, Int((maxLag / step).rounded()))
        for k in 1...max(1, steps) {
            let l = min(maxLag, Double(k) * step)
            let r = rmsAt(l)
            if r < best { best = r; bestLag = l }
        }
        return (best, r0, bestLag)
    }
}
