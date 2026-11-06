// TDPSOLABaseline.swift
// PrimaeNativeTests — r17, the OPT-T identity reference (2026-11-03)
//
// A FROZEN, renamed copy of the r17 TDPSOLA (TDPSOLA.swift + TDPSOLAAnalysis.swift) as it stood BEFORE
// lane OPT-T's low-level optimisation was rebased onto it: the F loudness correction and the documented
// period clamp included, smoothing tau 5 ms. `TDPSOLAIdentityTests` checks that the optimised renderer,
// at the same tuning, reproduces it bit for bit. Test-only; never edit it to follow the production file.

import Foundation
import Accelerate
import Synchronization
@testable import PrimaeNative

// TDPSOLABaseline.swift
// PrimaeNative
//
// Bake-off candidate "TDPSOLABaseline" (BAKEOFF.md; RULINGS L1/L2): one grain
// scheduler for all three arms.
//
//   .voicedPhoneme   TD-PSOLA. Grains are centred on pitch marks; output
//                    grain spacing = the source period at the chosen mark
//                    (divided by the pitch factor, 1 in the phoneme arm), so
//                    the pitch is the source's at ANY rate. Rate only moves
//                    the source read-head, which picks the nearest mark:
//                    rate < 1 repeats periods, rate > 1 skips them.
//   .unvoicedPhoneme WSOLA-lite. Fixed 5 ms hop, 10 ms grains; each new
//                    grain's source centre is searched within +/- half a hop
//                    of the read-head for the best normalised match with
//                    the natural continuation of the previous grain.
//   .carrier         Pitch-synchronous grains as in PSOLA, but each grain is
//                    READ at the pitch ratio (cubic Hermite interpolation)
//                    and spaced at period / ratio: the recorded carrier is
//                    transposed, not re-synthesised (L2).
//
// Windows are asymmetric raised-cosine halves whose widths equal the
// distance to the neighbouring grain, so overlapping halves sum to exactly
// 1: at rate 1 / 0 cents the output reproduces the source sample for
// sample (pinned by a test). The attack (source start to the first loop
// mark) is a single grain with a flat left side: it plays unmodified at
// rate 1, then hands over to the grain stream. The loop is
// [mark[attack], mark[loopEnd] + period) and wraps mark to mark.
//
// Real-time contract: `render` and the setters allocate nothing, take no
// lock, touch no Swift array or class reference (state lives behind
// UnsafeMutablePointers allocated in init), and read parameters from
// relaxed `Synchronization.Atomic<UInt32>` holding Float bit patterns.
// Rate and pitch are smoothed per sample (one-pole, tau 5 ms); the gate is
// a linear 2 ms ramp. Gate open from silence restarts at the source start
// on the FIRST sample of the next render call; gate open during a fade-out
// resumes without restarting.


nonisolated final class TDPSOLABaseline: SonificationRenderer, @unchecked Sendable {
    static var candidateName: String { "TDPSOLABaseline" }

    let kind: SourceKind
    let sampleRate: Double
    let maxFramesPerRender: Int
    /// Init-time analysis, exposed for tests and the bench report.
    let analysis: TDPSOLABaselineAnalysis

    // MARK: parameters (any thread)
    private let rateBits = Atomic<UInt32>(Float(1).bitPattern)
    private let centsBits = Atomic<UInt32>(Float(0).bitPattern)
    private let gateBits = Atomic<UInt32>(0)
    private let resetToken = Atomic<UInt32>(0)

    // MARK: render-thread storage (allocated once)
    private struct Grain {
        var outCenter: Double   // output time of the grain centre (samples since start)
        var leftW: Double       // output samples
        var rightW: Double      // output samples (provisional until the next grain spawns)
        var srcCenter: Double   // source position of the centre
        var inc: Double         // source samples per output sample inside the grain
        var period: Double      // source period at srcCenter (or the fixed hop)
        var flatLeft: Bool      // the attack grain: weight 1 left of the centre
        var corr: Float = 1     // unvoiced: normalised correlation with the grain before (WSOLA score)
    }
    private struct State {
        var playing = false
        var now = 0.0           // output samples since the gate opened from silence
        var s = 0.0             // source read-head (continuous, wrapped into the loop)
        var attackActive = false
        var attackCenter = 0.0
        var rate: Float = 1
        var cents: Float = 0
        var gateGain: Float = 0
        var gateTarget: Float = 0
        var grainCount = 0
        var cursor = 0          // mark index cursor for nearest-mark search
        var appliedReset: UInt32 = 0
    }
    private static let guardFrames = 4096
    private static let maxGrains = 8
    private static let windowSize = 1024
    private let srcBase: UnsafeMutablePointer<Float>   // includes guard zeros
    private let src: UnsafeMutablePointer<Float>       // srcBase + guardFrames
    private let count: Int
    private let marks: UnsafeMutablePointer<Double>
    private let periods: UnsafeMutablePointer<Double>
    private let markCount: Int
    private let window: UnsafeMutablePointer<Float>    // raised-cosine half, 0...1 -> 1...0
    private let grains: UnsafeMutablePointer<Grain>
    private let state: UnsafeMutablePointer<State>
    private let smoothCoef: Float
    private let gateStep: Float
    private let loopStart: Double
    private let loopEnd: Double
    private let loopLen: Double
    private let hop: Double
    // Scalars copied out of `analysis` so the render path never copies a struct holding arrays (ARC).
    private let isVoiced: Bool
    private let isCarrier: Bool
    private let attackIndex: Int
    private let loopEndIndex: Int
    private let onsetFrame: Double

    convenience init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int) {
        self.init(source: source, sampleRate: sampleRate, kind: kind, maxFramesPerRender: maxFramesPerRender,
                  analysis: TDPSOLABaselineAnalysis.analyse(source, sampleRate: sampleRate, kind: kind))
    }

    /// Reuses an analysis already computed for `source` (tests and the bench build many renderers per source).
    init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int, analysis a: TDPSOLABaselineAnalysis) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.maxFramesPerRender = maxFramesPerRender
        analysis = a
        count = source.count
        let g = Self.guardFrames
        srcBase = .allocate(capacity: count + 2 * g)
        srcBase.initialize(repeating: 0, count: count + 2 * g)
        let body = srcBase + g
        src = body
        let n = count
        source.withUnsafeBufferPointer { b in
            if let p = b.baseAddress { body.update(from: p, count: n) }
        }
        markCount = a.marks.count
        marks = .allocate(capacity: max(1, markCount))
        periods = .allocate(capacity: max(1, markCount))
        for i in 0..<markCount { (marks + i).initialize(to: a.marks[i]); (periods + i).initialize(to: a.periods[i]) }
        window = .allocate(capacity: Self.windowSize + 2)
        for i in 0...(Self.windowSize + 1) {
            let u = min(1.0, Double(i) / Double(Self.windowSize))
            (window + i).initialize(to: Float(0.5 + 0.5 * cos(Double.pi * u)))
        }
        grains = .allocate(capacity: Self.maxGrains)
        state = .allocate(capacity: 1)
        state.initialize(to: State())
        smoothCoef = Float(1 - exp(-1 / (0.005 * sampleRate)))
        gateStep = Float(1 / max(1, (0.002 * sampleRate).rounded()))
        loopStart = a.loopStart
        loopEnd = a.loopEnd
        loopLen = max(1, a.loopEnd - a.loopStart)
        hop = Double(a.unvoicedHop)
        isVoiced = a.isVoiced
        isCarrier = kind == .carrier
        attackIndex = a.attackIndex
        loopEndIndex = a.loopEndIndex
        onsetFrame = Double(a.onset)
    }

    deinit {
        srcBase.deallocate(); marks.deallocate(); periods.deallocate()
        window.deallocate(); grains.deallocate()
        state.deinitialize(count: 1); state.deallocate()
    }

    // MARK: SonificationRenderer

    func setRate(_ rate: Float) {
        rateBits.store(min(2, max(0.5, rate.isFinite ? rate : 1)).bitPattern, ordering: .relaxed)
    }
    func setPitchCents(_ cents: Float) {
        centsBits.store(min(1200, max(-1200, cents.isFinite ? cents : 0)).bitPattern, ordering: .relaxed)
    }
    func setGate(_ open: Bool) { gateBits.store(open ? 1 : 0, ordering: .relaxed) }

    func reset() {
        gateBits.store(0, ordering: .relaxed)
        _ = resetToken.wrappingAdd(1, ordering: .relaxed)
    }

    /// Onset is immediate (first sample of the next render). A parameter
    /// change reaches the output at the next grain: at most one grain
    /// spacing (the longest period, doubled for a carrier at -1200 cents,
    /// or the fixed hop), plus the 5 ms smoothing.
    var claimedLatencyFrames: Int {
        let smoothing = 0.005 * sampleRate
        if !isVoiced { return Int((hop + smoothing).rounded(.up)) }
        return Int(((isCarrier ? 2 : 1) * maxPeriod + smoothing).rounded(.up))
    }
    private var maxPeriod: Double { analysis.periods.max() ?? 0 }

    func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let st = state
        let token = resetToken.load(ordering: .relaxed)
        if token != st.pointee.appliedReset {
            st.pointee = State()
            st.pointee.appliedReset = token
        }
        let gateOpen = gateBits.load(ordering: .relaxed) != 0
        let rateTarget = Float(bitPattern: rateBits.load(ordering: .relaxed))
        let centsTarget = Float(bitPattern: centsBits.load(ordering: .relaxed))
        st.pointee.gateTarget = gateOpen ? 1 : 0
        if gateOpen && !st.pointee.playing { startPlayback() }

        var i = 0
        while i < frames {
            guard st.pointee.playing else { out[i] = 0; i += 1; continue }
            // Control smoothing (snap when converged: no denormal tails).
            var r = st.pointee.rate
            r += (rateTarget - r) * smoothCoef
            if abs(rateTarget - r) < 1e-6 { r = rateTarget }
            st.pointee.rate = r
            var c = st.pointee.cents
            c += (centsTarget - c) * smoothCoef
            if abs(centsTarget - c) < 1e-4 { c = centsTarget }
            st.pointee.cents = c

            let now = st.pointee.now
            // Spawn the next grain when the latest one reaches its centre.
            while grains[st.pointee.grainCount - 1].outCenter <= now { spawnNext() }

            // Overlap-add. For the unvoiced (WSOLA) path the weights are also
            // summed, for the loudness correction below.
            var y: Float = 0
            var wSum: Float = 0
            var w2Sum: Float = 0
            var rMin: Float = 1
            var gi = 0
            while gi < st.pointee.grainCount {
                let g = grains[gi]
                let x = now - g.outCenter
                var w: Float = 0
                if x < 0 {
                    if g.flatLeft {
                        w = 1
                    } else if -x < g.leftW {
                        w = windowAt(-x / g.leftW)
                    }
                    if w > 0 { y += w * read(g.srcCenter + x * g.inc) }
                    gi += 1
                } else if x < g.rightW {
                    w = windowAt(x / g.rightW)
                    y += w * read(g.srcCenter + x * g.inc)
                    gi += 1
                } else if gi < st.pointee.grainCount - 1 {
                    // Retire (never the latest grain: its right width is provisional).
                    var k = gi
                    while k < st.pointee.grainCount - 1 { grains[k] = grains[k + 1]; k += 1 }
                    st.pointee.grainCount -= 1
                } else {
                    gi += 1
                }
                if w > 0 { wSum += w; w2Sum += w * w; if g.corr < rMin { rMin = g.corr } }
            }
            // R17 hardening (ENG.md "F: mild amplitude modulation at the 200 Hz
            // grain rate"): raised-cosine halves sum to 1 in AMPLITUDE, which keeps
            // the level only when the overlapping grains are the same signal. On
            // noise (F) off rate 1 the WSOLA match is poor, the two grains are
            // nearly uncorrelated, and their power sums to w^2 + (1-w)^2: a -3 dB
            // dip at every crossover (~-1.8 dB on average). The expected power of
            // the overlap is w2Sum + r * (wSum^2 - w2Sum), r the grains'
            // normalised correlation (the WSOLA score, clamped to [0, 1]); dividing
            // by its root restores the level for any r. When every overlapping
            // grain matched (r >= 0.999: the natural continuation at rate 1, which
            // scores exactly 1) nothing is changed, so rate 1 stays sample-exact.
            // Voiced (PSOLA) grains carry corr = 1 and are never touched.
            if rMin < 0.999 && wSum > 0 {
                let r = max(0, rMin)
                let p = w2Sum + r * (wSum * wSum - w2Sum)
                if p > 1e-6 { y *= wSum / p.squareRoot() }
            }

            // Gate ramp.
            var gg = st.pointee.gateGain
            if gg < st.pointee.gateTarget { gg = min(st.pointee.gateTarget, gg + gateStep) }
            else if gg > st.pointee.gateTarget { gg = max(st.pointee.gateTarget, gg - gateStep) }
            st.pointee.gateGain = gg
            out[i] = y * gg
            if gg == 0 && st.pointee.gateTarget == 0 { st.pointee.playing = false }

            // Advance the read-head: unmodified (rate 1) through the attack.
            var s = st.pointee.s
            if st.pointee.attackActive {
                s += 1
                if now + 1 >= st.pointee.attackCenter { st.pointee.attackActive = false }
            } else {
                s += Double(r)
            }
            if s >= loopEnd { s -= loopLen }
            st.pointee.s = s
            st.pointee.now = now + 1
            i += 1
        }
    }

    // MARK: render-thread helpers

    @inline(__always) private func windowAt(_ u: Double) -> Float {
        let p = u * Double(Self.windowSize)
        let k = Int(p)
        if k >= Self.windowSize { return 0 }
        let t = Float(p - Double(k))
        return window[k] + (window[k + 1] - window[k]) * t
    }

    /// Cubic Hermite (Catmull-Rom) read; outside the source it reads guard zeros.
    @inline(__always) private func read(_ pos: Double) -> Float {
        let lim = Double(Self.guardFrames - 4)
        let p = min(Double(count) + lim, max(-lim, pos))
        let fl = p.rounded(.down)
        let k = Int(fl)
        let t = Float(p - fl)
        if t == 0 { return src[k] }
        let y0 = src[k - 1], y1 = src[k], y2 = src[k + 1], y3 = src[k + 2]
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + y1
    }

    @inline(__always) private func wrap(_ v: Double) -> Double {
        var w = v
        while w >= loopEnd { w -= loopLen }
        while w < loopStart { w += loopLen }
        return w
    }

    private func startPlayback() {
        let st = state
        let onset = onsetFrame
        let center: Double
        let period: Double
        if isVoiced {
            center = marks[attackIndex]
            period = periods[attackIndex]
            st.pointee.cursor = attackIndex
        } else {
            center = loopStart
            period = hop
        }
        let tA = center - onset
        grains[0] = Grain(outCenter: tA, leftW: 0, rightW: period, srcCenter: center,
                          inc: 1, period: period, flatLeft: true)
        st.pointee.grainCount = 1
        st.pointee.now = 0
        st.pointee.s = onset
        st.pointee.attackActive = tA > 0
        st.pointee.attackCenter = tA
        st.pointee.playing = true
        // Parameters start at their targets (no glide from a stale value on onset).
        st.pointee.rate = Float(bitPattern: rateBits.load(ordering: .relaxed))
        st.pointee.cents = Float(bitPattern: centsBits.load(ordering: .relaxed))
    }

    private func spawnNext() {
        let st = state
        let n = st.pointee.grainCount
        if n >= Self.maxGrains {   // cannot happen with <= 2 live grains; stay safe
            var k = 0
            while k < n - 1 { grains[k] = grains[k + 1]; k += 1 }
            st.pointee.grainCount = n - 1
        }
        let li = st.pointee.grainCount - 1
        let last = grains[li]
        let pf = exp2(Double(st.pointee.cents) / 1200)
        let spacing: Double
        let inc: Double
        if !isVoiced {
            spacing = hop; inc = 1
        } else if isCarrier {
            spacing = last.period / pf; inc = pf
        } else {
            spacing = last.period / pf; inc = 1
        }
        let tN = last.outCenter + spacing
        grains[li].rightW = spacing
        let dt = tN - st.pointee.now
        let sPred = wrap(st.pointee.s + Double(st.pointee.rate) * dt)
        let center: Double
        let period: Double
        var corr: Float = 1
        if isVoiced {
            let m = nearestMark(sPred)
            center = marks[m]; period = periods[m]
        } else {
            let pick = wsolaPick(previous: last.srcCenter, target: sPred)
            center = pick.center; corr = pick.score
            period = hop
        }
        grains[st.pointee.grainCount] = Grain(outCenter: tN, leftW: spacing, rightW: spacing,
                                              srcCenter: center, inc: inc, period: period, flatLeft: false,
                                              corr: corr)
        st.pointee.grainCount += 1
    }

    private func nearestMark(_ pos: Double) -> Int {
        let st = state
        let first = attackIndex, last = loopEndIndex
        var c = st.pointee.cursor
        if c < first || c > last || pos < marks[c] - periods[c] { c = first }
        while c < last && marks[c + 1] <= pos { c += 1 }
        st.pointee.cursor = c
        if c == last {
            // Beyond the last loop mark: closer to the loop end (== loop start) or to the last mark?
            return pos - marks[last] > 0.5 * periods[last] ? first : last
        }
        return (pos - marks[c]) <= (marks[c + 1] - pos) ? c : c + 1
    }

    /// WSOLA: integer source centre within +/- hop/2 of `target` whose left half best
    /// continues the previous grain's right half (normalised cross-correlation), and that
    /// correlation (the loudness correction in `render` uses it).
    private func wsolaPick(previous: Double, target: Double) -> (center: Double, score: Float) {
        let h = Int(hop)
        let tol = h / 2
        let prev = Int(previous.rounded())
        var natural = prev + h
        if Double(natural) >= loopEnd { natural -= Int(loopLen.rounded()) }
        let lo = Int(loopStart.rounded(.up)), hi = Int(loopEnd.rounded(.down)) - 1
        let centre = Int(target.rounded())
        var best = min(hi, max(lo, centre))
        var bestScore = -2.0
        var eA = 0.0
        var j = 0
        while j < h { let v = Double(src[prev + j]); eA += v * v; j += 2 }
        if abs(natural - centre) <= tol && natural >= lo && natural <= hi {
            best = natural; bestScore = wsolaScore(prev: prev, cand: natural, h: h, eA: eA)
        }
        var cand = max(lo, centre - tol)
        let end = min(hi, centre + tol)
        while cand <= end {
            let sc = wsolaScore(prev: prev, cand: cand, h: h, eA: eA)
            if sc > bestScore { bestScore = sc; best = cand }
            cand += 1
        }
        return (Double(best), Float(max(-1, min(1, bestScore))))
    }

    @inline(__always) private func wsolaScore(prev: Int, cand: Int, h: Int, eA: Double) -> Double {
        var c = 0.0, eB = 0.0
        var j = 0
        while j < h {
            let b = Double(src[cand - h + j])
            c += Double(src[prev + j]) * b; eB += b * b; j += 2
        }
        let d = (eA * eB).squareRoot()
        return d > 1e-12 ? c / d : 0
    }
}

// TDPSOLABaselineAnalysis.swift
// PrimaeNative
//
// Init-time (off the render thread) analysis for the TDPSOLABaseline bake-off
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


nonisolated struct TDPSOLABaselineAnalysis: Sendable {
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

    var f0: Double { medianPeriod > 0 ? 1 / medianPeriod : 0 } // cycles per sample

    static func analyse(_ source: [Float], sampleRate sr: Double, kind: SourceKind) -> TDPSOLABaselineAnalysis {
        let n = source.count
        let hop5 = max(16, Int((0.005 * sr).rounded()))
        return source.withUnsafeBufferPointer { buf -> TDPSOLABaselineAnalysis in
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
                return TDPSOLABaselineAnalysis(onset: onset, isVoiced: false, voicedFraction: fraction,
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
                return TDPSOLABaselineAnalysis(onset: onset, isVoiced: false, voicedFraction: fraction,
                                       medianPeriod: 0, marks: [], periods: [], attackIndex: 0,
                                       loopEndIndex: 0, loopStart: lo,
                                       loopEnd: max(lo + Double(hop5), Double(n - 3 * hop5 - 4)),
                                       unvoicedHop: hop5)
            }
            return TDPSOLABaselineAnalysis(onset: onset, isVoiced: true, voicedFraction: fraction,
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
