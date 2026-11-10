// TDPSOLA.swift
// PrimaeNative
//
// Bake-off candidate "TDPSOLA" (BAKEOFF.md; RULINGS L1/L2): one grain
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
//                    R17D (U1, RULINGS 2026-11-06): the unvoiced read-head
//                    is NOT time-stretched; it advances at rate 1 whatever
//                    the rate, so F plays at natural speed at every pen
//                    speed (a stretched noise re-reads half of each 10 ms
//                    grain ~5 ms later at rate 0.5: a comb buzz, RATE.md
//                    section 2). Voiced sources and the carrier keep the
//                    rate coupling.
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
// Rate and pitch are smoothed per sample (one-pole, `TDPSOLATuning`; 2 ms
// in production from r17, 5 ms at the bake-off tuning); the gate is a linear ramp (2 ms). Gate open from
// silence restarts at the source start on the FIRST sample of the next
// render call; gate open during a fade-out resumes without restarting.
//
// Optimisation notes (lane OPT-T, 2026-11-03; output bit-identical to the
// bake-off code; in r17 pinned against a frozen copy of the pre-OPT-T r17
// file by TDPSOLAIdentityTests): the render loop keeps its
// per-sample state in locals and writes it back once per buffer; constants
// are copied out of `self` before the loop (the compiler cannot prove the
// stores through `grains`/`state` leave the object alone, so it reloaded
// them per sample); index conversions avoid the trapping `Int(Double)`;
// grain spawning is out of line (rare, keeps the hot loop small); the
// unvoiced WSOLA search scores eight candidates per SIMD pass with exactly
// the scalar summation order and reads a precomputed energy table.

import Foundation
import Synchronization

/// The renderer's time constants. `.bakeoff` is the configuration benched and A/B'd in the bake-off
/// (2026-11-02/03); OPT-T measured the latency/quality curve of each knob (OPT-T.md).
nonisolated struct TDPSOLATuning: Sendable, Equatable {
    /// One-pole time constant of the rate and pitch smoothing, seconds (0 = no smoothing).
    var smoothingSeconds: Double
    /// Length of the linear gate ramp (open and close), seconds.
    var gateRampSeconds: Double
    /// Fixed grain hop of the unvoiced (WSOLA) mode, seconds; used when the renderer analyses its source.
    var unvoicedHopSeconds: Double
    /// TDQ (2026-11-03): a voiced phoneme's pulse whose >3 kHz energy exceeds this multiple of its neighbours' median
    /// is limited at init (`TDPSOLADeclick`); 0 = off (the bake-off and pre-TDQ r17 output, bit for bit).
    var pulseCrestCap: Double = 0
    /// SEAM2 (2026-11-04): the loop is prepared once at init so its end joins its start without a step in level or
    /// timbre: the head of the loop is an equal-power crossfade from the material that follows the (shortened) loop
    /// end. Seconds, rounded to whole pitch periods; 0 = off (the TDQ loop, bit for bit).
    var loopCrossfadeSeconds: Double = 0
    /// SEAM2: largest gain correction (dB, +-) of the gentle level flattening of the loop region; 0 = off.
    var loopFlattenDB: Double = 0

    static let bakeoff = TDPSOLATuning(smoothingSeconds: 0.005, gateRampSeconds: 0.002, unvoicedHopSeconds: 0.005,
                                       pulseCrestCap: 0)
    /// r17 production tuning (supervisor/David 2026-11-03, from lane OPT-T's curve): smoothing tau 2 ms
    /// (bake-off 5 ms; 1 ms NOT adopted). Pinned by `SonificationRegressionTests.tdpsolaTuningPinned`.
    /// SEAM2 (2026-11-04): loop crossfade 400 ms + level flattening within +-2 dB (`TDPSOLALoopSeam`; sweep in SEAM2.md).
    /// Pinned by `LoopSeamRegressionTests` / `SeamMeterControlTests`.
    static let `default` = TDPSOLATuning(smoothingSeconds: 0.002, gateRampSeconds: 0.002, unvoicedHopSeconds: 0.005,
                                         pulseCrestCap: 1.3, loopCrossfadeSeconds: 0.4, loopFlattenDB: 2)
}

nonisolated final class TDPSOLA: SonificationRenderer, @unchecked Sendable {
    static var candidateName: String { "TDPSOLA" }

    let kind: SourceKind
    let tuning: TDPSOLATuning
    let sampleRate: Double
    let maxFramesPerRender: Int
    /// Init-time analysis, exposed for tests and the bench report.
    let analysis: TDPSOLAAnalysis

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
    /// U1 (R17D): the unvoiced phoneme's read-head ignores the rate (natural speed at every pen speed).
    private let holdsNaturalRate: Bool
    private let attackIndex: Int
    private let loopEndIndex: Int
    private let onsetFrame: Double
    private let readHi: Double
    /// Unvoiced only: eB(c) = sum over even j < hop of src[c - hop + j]^2, summed in the same order as
    /// `wsolaScore`, for every integer centre in the loop (bit-identical to computing it per search).
    private let wsolaEnergy: UnsafeMutablePointer<Double>

    convenience init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int) {
        self.init(source: source, sampleRate: sampleRate, kind: kind, maxFramesPerRender: maxFramesPerRender,
                  tuning: .default)
    }

    /// `onset` (R17D): the file's declared attack end (`PhonemeOnsets`); nil = the analysis' own -3 dB rule.
    /// `outputGain` (r22): the loudness gain the kernel plays this renderer at (`SonificationSource.gain`); it sets
    /// where the recorded onset's ceiling lies (`TDPSOLAOnsetCeiling`).
    convenience init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int,
                     tuning: TDPSOLATuning, onset: RecordedOnset? = nil, outputGain: Float = 1) {
        self.init(source: source, sampleRate: sampleRate, kind: kind, maxFramesPerRender: maxFramesPerRender,
                  analysis: TDPSOLAAnalysis.analyse(source, sampleRate: sampleRate, kind: kind,
                                                    unvoicedHopSeconds: tuning.unvoicedHopSeconds, onset: onset),
                  tuning: tuning, outputGain: outputGain)
    }

    /// Reuses an analysis already computed for `source` (tests and the bench build many renderers per source).
    /// The unvoiced hop is the analysis's own; `tuning.unvoicedHopSeconds` is not consulted here.
    init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int, analysis a: TDPSOLAAnalysis,
         tuning: TDPSOLATuning = .default, outputGain: Float = 1) {
        self.kind = kind
        self.tuning = tuning
        self.sampleRate = sampleRate
        self.maxFramesPerRender = maxFramesPerRender
        analysis = a
        // SEAM2 first, TDQ second (ENV3, 2026-11-05): the loop is prepared once so that its end joins its start without a
        // step (carrier: a steady tone), THEN the isolated strong glottal pulses of the prepared copy are limited. The
        // crossfade of the loop head can build a pulse of its own at the wrap (measured on A: 2.4x its neighbours,
        // 1.3x without the seam); limiting before the blend (as r17 did) could not see it.
        var played = source
        var effLoopEnd = a.loopEnd, effLoopEndIndex = a.loopEndIndex
        let preBlend = a.recordedOnset?.preBlendPeriods ?? TDPSOLALoopSeam.preBlendMarks
        if kind != .carrier, let prep = TDPSOLALoopSeam.prepare(played, sampleRate: sampleRate, analysis: a,
                                                                 crossfade: tuning.loopCrossfadeSeconds,
                                                                 flattenDB: tuning.loopFlattenDB,
                                                                 preBlendMarks: preBlend) {
            played = prep.samples; effLoopEnd = prep.loopEnd; effLoopEndIndex = prep.loopEndIndex
        }
        // TDQ: the renderer plays a copy with the recording's isolated strong pulses limited (init only).
        if kind != .carrier {
            let preTDQ = played
            played = TDPSOLADeclick.process(played, sampleRate: sampleRate, analysis: a, cap: tuning.pulseCrestCap)
            // R17D (ONSET.md section 7.3): a recorded onset plays as recorded. The limiter is for the loop's isolated
            // pulses; on the onset it rewrites the glottal (A) or breathy (I) start. The onset up to the first ENV3
            // pre-blend period (voiced) / the loop start (unvoiced) is put back, with a 64-sample linear hand-over
            // into the limited copy (the lane's `ONSET_KEEP`).
            if a.recordedOnset != nil {
                Self.keepRecordedOnset(&played, preTDQ, a, preBlend: preBlend)
                // r22 (lane ONSET-CEILING): ... except where it would pass digital full scale at the gain the
                // kernel plays it at. A's onset pulse (file -4.01 dBFS, gain +5.92 dB) reached +1.91 dBFS; the samples
                // over -0.5 dBFS get one smooth local dip (2.41 dB, 9.4 ms), everything else stays as recorded.
                played = TDPSOLAOnsetCeiling.limit(played, gain: outputGain, ceiling: TDPSOLAOnsetCeiling.ceiling,
                                                   taper: TDPSOLAOnsetCeiling.taperFrames(sampleRate: sampleRate),
                                                   in: 0..<Int(a.loopStart))
            }
        }
        count = source.count
        let g = Self.guardFrames
        srcBase = .allocate(capacity: count + 2 * g)
        srcBase.initialize(repeating: 0, count: count + 2 * g)
        let body = srcBase + g
        src = body
        let n = count
        played.withUnsafeBufferPointer { b in
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
        smoothCoef = tuning.smoothingSeconds > 0 ? Float(1 - exp(-1 / (tuning.smoothingSeconds * sampleRate))) : 1
        gateStep = Float(1 / max(1, (tuning.gateRampSeconds * sampleRate).rounded()))
        loopStart = a.loopStart
        loopEnd = effLoopEnd
        loopLen = max(1, effLoopEnd - a.loopStart)
        hop = Double(a.unvoicedHop)
        isVoiced = a.isVoiced
        isCarrier = kind == .carrier
        holdsNaturalRate = !a.isVoiced && kind != .carrier
        attackIndex = a.attackIndex
        loopEndIndex = effLoopEndIndex
        onsetFrame = Double(a.onset)
        readHi = Double(count) + Double(Self.guardFrames - 4)
        if a.isVoiced {
            wsolaEnergy = .allocate(capacity: 1)
            wsolaEnergy.initialize(to: 0)
        } else {
            // Indexed by source centre; the search reads centres in [loopStart, loopEnd).
            let h = Int(Double(a.unvoicedHop)), cap = count + 1
            wsolaEnergy = .allocate(capacity: cap)
            wsolaEnergy.initialize(repeating: 0, count: cap)
            let lo = max(0, Int(a.loopStart.rounded(.up))), hi = min(count, Int(effLoopEnd.rounded(.down)))
            var c = lo
            while c < hi {
                var e = 0.0, j = 0
                while j < h { let v = Double(body[c - h + j]); e += v * v; j += 2 }
                wsolaEnergy[c] = e
                c += 1
            }
        }
    }

    /// R17D: `played` with the samples before the onset's end restored from `pre` (see init).
    static func keepRecordedOnset(_ played: inout [Float], _ pre: [Float], _ a: TDPSOLAAnalysis, preBlend: Int) {
        let e = a.isVoiced ? Int(a.marks[max(0, a.attackIndex - preBlend)]) : Int(a.loopStart)
        for i in 0..<min(e, played.count, pre.count) {
            let w = i < e - 64 ? Float(1) : Float(e - i) / 64
            played[i] = w * pre[i] + (1 - w) * played[i]
        }
    }

    deinit {
        srcBase.deallocate(); marks.deallocate(); periods.deallocate()
        window.deallocate(); grains.deallocate(); wsolaEnergy.deallocate()
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
    /// or the fixed hop), plus the smoothing time constant.
    var claimedLatencyFrames: Int {
        let smoothing = tuning.smoothingSeconds * sampleRate
        if !isVoiced { return Int((hop + smoothing).rounded(.up)) }
        return Int(((isCarrier ? 2 : 1) * maxPeriod + smoothing).rounded(.up))
    }
    private var maxPeriod: Double { analysis.periods.max() ?? 0 }

    /// SEAM2: the source read-head (single-threaded benches and tests only; the render thread owns it).
    /// Lets the seam meter mark the loop wraps from the renderer itself.
    var debugReadHead: Double { state.pointee.s }
    /// The loop bounds the renderer wraps at (source samples).
    var debugLoopBounds: (start: Double, end: Double) { (loopStart, loopEnd) }

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
        guard st.pointee.playing else {
            out.update(repeating: 0, count: frames)
            return
        }

        // OPT-T: the per-sample state lives in locals (registers) for the whole
        // buffer and is written back once; the render-path constants are copied
        // out of `self` so the loop does not reload them after every store
        // through `grains`/`state` (the compiler cannot prove those stores do not
        // alias the object). Same arithmetic, same order: bit-identical output.
        let coef = smoothCoef, step = gateStep
        let lEnd = loopEnd, lLen = loopLen
        let g = grains, x0 = src, w = window, hi = readHi
        let naturalRate = holdsNaturalRate
        let gateTarget = st.pointee.gateTarget
        let attackCenter = st.pointee.attackCenter
        var rate = st.pointee.rate, cents = st.pointee.cents
        var gg = st.pointee.gateGain
        var now = st.pointee.now, s = st.pointee.s
        var attackActive = st.pointee.attackActive
        var n = st.pointee.grainCount
        var playing = true
        var settled = rate == rateTarget && cents == centsTarget

        var i = 0
        while i < frames {
            // Control smoothing (snap when converged: no denormal tails). Once both values sit exactly on
            // their targets the update is the identity (target - r == 0), so it is skipped: in steady state
            // this removes the loop's longest dependency chain (sub, mul, add, compare per sample).
            if !settled {
                var r = rate
                r += (rateTarget - r) * coef
                if abs(rateTarget - r) < 1e-6 { r = rateTarget }
                rate = r
                var c = cents
                c += (centsTarget - c) * coef
                if abs(centsTarget - c) < 1e-4 { c = centsTarget }
                cents = c
                settled = r == rateTarget && c == centsTarget
            }
            let r = rate, c = cents

            // Spawn the next grain when the latest one reaches its centre.
            while g[n - 1].outCenter <= now { n = spawnNext(count: n, now: now, s: s, rate: r, cents: c) }

            // Overlap-add. For the unvoiced (WSOLA) path the weights are also
            // summed, for the loudness correction below.
            var y: Float = 0
            var wSum: Float = 0
            var w2Sum: Float = 0
            var rMin: Float = 1
            var gi = 0
            while gi < n {
                let gr = g[gi]
                let x = now - gr.outCenter
                var wt: Float = 0
                if x < 0 {
                    if gr.flatLeft {
                        wt = 1
                    } else if -x < gr.leftW {
                        wt = Self.windowAt(w, -x / gr.leftW)
                    }
                    if wt > 0 { y += wt * Self.read(x0, hi, gr.srcCenter + x * gr.inc) }
                    if wt > 0 { wSum += wt; w2Sum += wt * wt; if gr.corr < rMin { rMin = gr.corr } }
                    gi += 1
                } else if x < gr.rightW {
                    wt = Self.windowAt(w, x / gr.rightW)
                    y += wt * Self.read(x0, hi, gr.srcCenter + x * gr.inc)
                    if wt > 0 { wSum += wt; w2Sum += wt * wt; if gr.corr < rMin { rMin = gr.corr } }
                    gi += 1
                } else if gi < n - 1 {
                    // Retire (never the latest grain: its right width is provisional).
                    var k = gi
                    while k < n - 1 { g[k] = g[k + 1]; k += 1 }
                    n -= 1
                } else {
                    gi += 1
                }
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

            // Gate ramp. Tested for equality first so the steady state (gate fully open) is one predictable
            // branch instead of a compare-and-select chain the compiler builds on the loop-carried `gg`.
            if gg != gateTarget {
                if gg < gateTarget { gg = min(gateTarget, gg + step) }
                else { gg = max(gateTarget, gg - step) }
            }
            out[i] = y * gg
            if gg == 0 && gateTarget == 0 { playing = false }

            // Advance the read-head: unmodified (rate 1) through the attack.
            if attackActive {
                s += 1
                if now + 1 >= attackCenter { attackActive = false }
            } else {
                s += naturalRate ? 1 : Double(r)
            }
            if s >= lEnd { s -= lLen }
            now += 1
            i += 1
            if !playing {
                // Closed and the ramp is done: the rest of the buffer is silence.
                if i < frames { (out + i).update(repeating: 0, count: frames - i) }
                break
            }
        }
        st.pointee.rate = rate
        st.pointee.cents = cents
        st.pointee.gateGain = gg
        st.pointee.now = now
        st.pointee.s = s
        st.pointee.attackActive = attackActive
        st.pointee.grainCount = n
        st.pointee.playing = playing
    }

    // MARK: render-thread helpers

    /// floor(v) as an Int without the trapping `Int(Double)` conversion (whose range checks are three
    /// compare-and-branch pairs per call on the hot path). Exact for |v| < 2^51: adding 1.5 * 2^52 puts
    /// the integer in the low mantissa bits. Callers pass values clamped far inside that range.
    @inline(__always) private static func floorInt(_ v: Double) -> Int {
        let fl = v.rounded(.down)
        return Int(truncatingIfNeeded: (fl + 0x1.8p52).bitPattern) &- Int(truncatingIfNeeded: (0x1.8p52 as Double).bitPattern)
    }

    /// `u` in [0, 1) by the callers' branches; >= 1 reads 0.
    @inline(__always) private static func windowAt(_ window: UnsafeMutablePointer<Float>, _ u: Double) -> Float {
        let p = u * Double(Self.windowSize)
        if !(p < Double(Self.windowSize)) { return 0 }
        let k = floorInt(p)          // == Int(p) for 0 <= p < windowSize
        let t = Float(p - Double(k))
        return window[k] + (window[k &+ 1] - window[k]) * t
    }

    /// Cubic Hermite (Catmull-Rom) read; outside the source it reads guard zeros.
    /// `hi` = Double(count) + guardFrames - 4 (precomputed; same value the clamp always used).
    @inline(__always) private static func read(_ src: UnsafeMutablePointer<Float>, _ hi: Double, _ pos: Double) -> Float {
        let lim = Double(Self.guardFrames - 4)
        let p = min(hi, max(-lim, pos))
        let fl = p.rounded(.down)
        let k = floorInt(fl)
        let t = Float(p - fl)
        if t == 0 { return src[k] }
        let y0 = src[k &- 1], y1 = src[k], y2 = src[k &+ 1], y3 = src[k &+ 2]
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

    /// Spawns the grain after the latest one; returns the new grain count. `now`, `s`, `rate`, `cents`
    /// are the render loop's current values (the loop keeps them in registers).
    @inline(never) private func spawnNext(count n0: Int, now: Double, s: Double, rate: Float, cents: Float) -> Int {
        var n = n0
        if n >= Self.maxGrains {   // cannot happen with <= 2 live grains; stay safe
            var k = 0
            while k < n - 1 { grains[k] = grains[k + 1]; k += 1 }
            n -= 1
        }
        let li = n - 1
        let last = grains[li]
        let pf = exp2(Double(cents) / 1200)
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
        let dt = tN - now
        let sPred = wrap(s + (holdsNaturalRate ? 1 : Double(rate)) * dt)
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
        grains[n] = Grain(outCenter: tN, leftW: spacing, rightW: spacing,
                          srcCenter: center, inc: inc, period: period, flatLeft: false,
                          corr: corr)
        return n + 1
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
        // OPT-T: eight candidates at once. Each SIMD lane accumulates exactly the
        // scalar sum (same j order, separate multiply and add: Swift does not
        // contract to FMA), and the lanes are compared in ascending candidate
        // order with the same strict `>`: the pick is bit-identical to the scalar
        // search, at about a quarter of the work.
        let a = src + prev
        let eTab = wsolaEnergy
        // r17: the SIMD pass is Release-only. In -Onone (Debug-Study, the CI test build) SIMD4's generic
        // operators allocate on every call (render thread); the scalar loop below scores the same candidates
        // in the same order with the same sums, so both builds pick the same centre (OPT-T's identity claim).
        #if !DEBUG
        while cand + 7 <= end {
            let b0 = src + (cand &- h)
            var c0 = SIMD4<Double>(repeating: 0), c1 = SIMD4<Double>(repeating: 0)
            var j = 0
            while j < h {
                let av = SIMD4<Double>(repeating: Double(a[j]))
                let p = UnsafeRawPointer(b0 + j)
                let f0 = p.loadUnaligned(as: SIMD4<Float>.self)
                let f1 = p.loadUnaligned(fromByteOffset: 16, as: SIMD4<Float>.self)
                c0 = c0 + av * SIMD4<Double>(f0)
                c1 = c1 + av * SIMD4<Double>(f1)
                j &+= 2
            }
            for k in 0..<4 {
                let d = (eA * eTab[cand &+ k]).squareRoot()
                let sc = d > 1e-12 ? c0[k] / d : 0
                if sc > bestScore { bestScore = sc; best = cand &+ k }
            }
            for k in 0..<4 {
                let d = (eA * eTab[cand &+ 4 &+ k]).squareRoot()
                let sc = d > 1e-12 ? c1[k] / d : 0
                if sc > bestScore { bestScore = sc; best = cand &+ 4 &+ k }
            }
            cand &+= 8
        }
        #endif
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
