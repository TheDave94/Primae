// TDPSOLA2.swift
// PrimaeNative — pitch bake-off phase 2, candidate C1 "TDPSOLA2" (2026-11-23); the phoneme arm's renderer from protocol r31 (lane PITCHWIN, 2026-11-26)
//
// An upgrade of the shipped r27 renderer (`TDPSOLA`, which this file copies and leaves untouched) for a pitch-shifted
// phoneme arm. BAKEOFF-PITCH.md section 2 C1, items 1-6, each behind its own option in `TDPSOLA2Options` so the bench
// can A/B them. With every option off (`TDPSOLA2Options.r27`) the output is the shipped TDPSOLA's, bit for bit
// (pinned by TDPSOLA2Tests). Written from published descriptions only (Charpentier & Moulines 1989/1990,
// Stylianou 2001, Bailly 1999, Drugman et al. 2009/2019); no restricted source was read.
//
//   1. `unvoicedResample` (r27 candidate A, 5dcc4b4f, as is): off 0 cents the unvoiced (F) read-head advances at
//      the pitch ratio, each grain continues the previous grain's resampled read, and grains are read through a
//      Kaiser-windowed sinc at min(1, 1/pf): the stream is a continuous band-limited resample of the loop.
//   2. `voicedWindowCap` (r27 candidate B, a601f528, generalised): the two halves that cross over between voiced
//      grains a -> b get the width min(spacing, T_a / beta_a, T_b / beta_b) (output samples), so no grain half
//      reaches past ONE source period of its own mark (Charpentier & Moulines' echo condition), on downshift AND on
//      upshift and with the formant ratio beta of item 6. Exactly at pf == 1 and beta == 1 the width stays the
//      spacing, so 0 cents is the shipped output bit for bit (with uneven periods min(T_a, T_b) would otherwise
//      differ from the spacing T_a by a fraction of a sample). Candidate B's own form, min(spacing, T) per side at
//      pf < 1, is the same thing for even periods.
//   3. `pulseDensityExponent` e: a voiced grain spawned at pf < 1 is scaled by pf^-e (e = 0.5: the energy per second
//      a downshift loses by playing fewer pulses). Per grain, from the smoothed cents, so it is smoothed with the
//      pitch. The attack grain (played unmodified) is never scaled. 0 = off. With gamma (item 6) the exponent is
//      e (1 - gamma): a grain read at beta lasts 1/beta longer, so only pf^(1 - gamma) of the power is lost.
//   4. `harmonicNoiseSwap` (`TDPSOLA2HarmonicNoise`): a voiced grain that does NOT continue the previous grain's mark
//      (a period PSOLA repeats on upshift / rate < 1, or skips on downshift / rate > 1) plays h_i + n_j, j drawn from
//      the loop marks within +-8 of i excluding the last 2 noise picks (xorshift64*, seeded per source, re-seeded at
//      every onset), re-windowed from the analysis Hann to the synthesis window. A grain that continues its
//      predecessor (the natural next mark, the loop wrap included) plays the source itself: its own noise IS the
//      continuation, h_i + n_i == g_i, and the direct read keeps 0 cents / rate 1 bit-identical. The prototype swaps
//      on every grain; that differs only on those natural grains.
//   5. `gciSnap` (`TDPSOLA2Epochs`): the marks are snapped to SEDREAMS-style glottal closure instants at init,
//      under a jitter guard (`gciJitterGuard`, 1.2 = +20 %) that keeps the old marks for a source the snap would make
//      more irregular. The snapped marks feed everything (loop seam, pulse limiter, grains), so the renderer stays
//      self-consistent (0 cents / rate 1 reproduces its own prepared loop) but its prepared loop is not the shipped
//      one: goldens differ for a source whose marks moved (`epochReport` says which).
//   7. `shiftedAttack` (lane C3, supervisor ruling 2026-11-24: the phoneme arm is pitched throughout): the voiced
//      attack is PSOLA'd too. One flat grain plays the recorded samples from the onset to the first mark that has a
//      source period of recorded material to its left and from which the source is periodic (`attackFirstMark`; the
//      periodicity condition from r31, lane PITCHWIN: I's breathy pre-voicing is 14 marks long): the pre-voicing
//      transient and the first pulse, as recorded. From there every attack mark is a grain spaced at T / pf, read in the attack's own timing
//      (the read-head advances at 1 through the attack, as the shipped attack does), so the attack keeps its length
//      and transient and follows the pitch. Off (the default) = the shipped unshifted attack.
//      `attackFlatF0` (with item 7): the attack's grains are spaced at the loop's median period instead of the
//      attack's own periods, so the attack plays at the
//      steady F0 x pf: its natural onset glide (I starts ~100 c sharp, A sags ~100 c, MEASURED lane C3) would
//      otherwise read as pitch error against the commanded height. Off = the attack keeps its own intonation x pf.
//   6. `formantGamma` g: each voiced grain is READ at beta = pf^g around its mark (band-limited, as item 1) and spaced
//      at T / pf: g = 0 is PSOLA (formants held), g = 1 is the carrier branch (formants move with the pitch).
//      Praat's "Change gender" construction. Default 0 (protocol question P2).
//   8. `levelCalibration` (lane PITCHWIN, 2026-11-26, the fix for the bake-off's level-gate failures): a residual
//      gain per grain from a table measured once per source at init (`LevelTable`), so a held phoneme keeps its
//      0-cent level at every pitch. Exactly 1 at 0 cents. Voiced AND unvoiced: item 1's band-limited read drops F's
//      energy above the new Nyquist on upshift (F +600 c -0.94 dB re 0 c, offline; on the iPad the F stroke start's
//      level rose 0.40 dB across its steady window as the pitch glided down), and the table holds that too.
//
// PRODUCTION (protocol r31, lane PITCHWIN 2026-11-26): `LiveSonificationAudio.makeRenderer` builds every phoneme with
// `TDPSOLA2Options.production` (items 1-5, item 7 at the steady F0, item 8; gamma 0) and the spatial carrier with
// `.r27` (the r17-r28 TDPSOLA output, bit for bit). Chosen from the 2026-11-25 iPad bench (docs/DECISIONS.md,
// "Phoneme pitch shift: TDPSOLA2 (protocol r31)").
//
// Everything else (attack, loop seam, TDQ limiter, recorded onset, gate, smoothing, the carrier branch, the
// real-time contract) is the shipped renderer's; see TDPSOLA.swift for those notes.

import Foundation
import Synchronization
import os

/// The C1 tuning flags. `default` is the candidate as specified (items 1-5 on, gamma 0); `r27` is the shipped
/// renderer.
nonisolated struct TDPSOLA2Options: Sendable, Hashable {
    /// Item 1: unvoiced F as a band-limited resample (r27 candidate A).
    var unvoicedResample = true
    /// Item 2: voiced grain halves capped at one source period (r27 candidate B, generalised).
    var voicedWindowCap = true
    /// Item 3: voiced pulse-density gain exponent; pf < 1 grains x pf^-e. 0 = off. (Default per David, P4.)
    var pulseDensityExponent: Double = 0.5
    /// Item 4: harmonic/noise split with a noise swap on repeated / skipped periods.
    var harmonicNoiseSwap = true
    /// Item 5: snap the marks to GCIs at init.
    var gciSnap = true
    /// Item 5's guard: keep the old marks when the snap raises the marks' period jitter above this multiple.
    var gciJitterGuard: Double = 1.2
    /// Item 5, lane C1 addition: when the snap is refused, still move every mark by the median GCI offset (one
    /// constant phase shift: the marks' own jitter, hence the guard's measure, is unchanged) ...
    var gciPhaseFallback = true
    /// ... but only when that offset is at least this fraction of the median period: a mark set within it already
    /// sits at the closures within the detector's own spread, and is kept bit for bit.
    var gciPhaseMinOffset: Double = 0.15
    /// Item 6: partial formant co-shift, beta = pf^gamma. 0 = off (P2).
    var formantGamma: Double = 0
    /// Item 7 (lane C3): the voiced attack follows the pitch (epoch-wise PSOLA from the first full period). Off = r27.
    var shiftedAttack = false
    /// Item 7: the shifted attack at the steady F0 instead of its own intonation contour.
    var attackFlatF0 = true
    /// Item 8 (lane PITCHWIN, 2026-11-26): the residual level table. Measured once per source at init (see
    /// `LevelTable`), so a held phoneme (voiced or F) plays at its 0-cent level at every pitch. Off = items 1-7 only.
    var levelCalibration = false

    static let `default` = TDPSOLA2Options()
    /// The phoneme arm's renderer from protocol r31: the bake-off's "TDPSOLA2-sa" (items 1-5, the shifted attack at the
    /// steady F0, gamma 0) plus item 8.
    static let production: TDPSOLA2Options = {
        var o = TDPSOLA2Options()
        o.shiftedAttack = true
        o.levelCalibration = true
        return o
    }()
    static let r27 = TDPSOLA2Options(unvoicedResample: false, voicedWindowCap: false, pulseDensityExponent: 0,
                                     harmonicNoiseSwap: false, gciSnap: false, formantGamma: 0)
}

nonisolated final class TDPSOLA2: SonificationRenderer, @unchecked Sendable {
    static var candidateName: String { "TDPSOLA2" }
    private static let log = Logger(subsystem: "de.flamingistan.primae", category: "TDPSOLA2")

    let kind: SourceKind
    let tuning: TDPSOLATuning
    let options: TDPSOLA2Options
    let sampleRate: Double
    let maxFramesPerRender: Int
    /// The analysis the renderer plays (after item 5, when it applied).
    let analysis: TDPSOLAAnalysis
    /// The analysis as computed (before item 5).
    let coarseAnalysis: TDPSOLAAnalysis
    /// The loudness gain the kernel plays this source at (the onset ceiling's input).
    let outputGain: Float
    /// Item 5's outcome (nil when the option is off or the source is not a voiced phoneme).
    let epochReport: TDPSOLA2Epochs.Report?
    /// Item 4's bank (nil when off / not a voiced phoneme); kept alive here, never touched by the render thread.
    private let hnBank: TDPSOLA2HarmonicNoise?
    /// Init-time bytes of item 4's bank (memory gate).
    var harmonicNoiseBytes: Int { hnBank?.bytes ?? 0 }

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
        var spacingPeriod = 0.0 // voiced phoneme: the period the NEXT grain is spaced by (item 7 attack: flattened)
        var corr: Float = 1     // unvoiced: normalised correlation with the grain before (WSOLA score)
        var bandCut: Double = 0 // > 0 = read band-limited at this cutoff (x source Nyquist); 0 = cubic
        var mark: Int = -1      // voiced: the mark index the grain is centred on
        var gain: Float = 1     // item 3
        // Item 4: >= 0 = play h(mark) + n(noise) re-windowed; -1 = read the source.
        var noise: Int = -1
        var hBase: Int = 0      // offset of h(mark)'s slot in the bank
        var nBase: Int = 0      // offset of n(noise)'s slot
        var hFrac: Double = 0   // slot position of the mark: radius + mark - round(mark)
        var nFrac: Double = 0
        var anaInv: Double = 0  // 1 / period(mark): the analysis Hann's half-width
    }
    private struct State {
        var playing = false
        var now = 0.0
        var s = 0.0
        var attackActive = false
        var attackCenter = 0.0
        var rate: Float = 1
        var cents: Float = 0
        var gateGain: Float = 0
        var gateTarget: Float = 0
        var grainCount = 0
        var cursor = 0
        var appliedReset: UInt32 = 0
        var rng: UInt64 = 0     // item 4
        var recent0 = -1        // item 4: the last two noise picks
        var recent1 = -1
        var lowMark = 0         // item 7: the lowest mark nearestMark may pick (the attack's first mark, then attackIndex)
    }
    private static let guardFrames = 4096
    private static let maxGrains = 8
    private static let windowSize = 1024
    private let srcBase: UnsafeMutablePointer<Float>
    private let src: UnsafeMutablePointer<Float>
    private let count: Int
    private let marks: UnsafeMutablePointer<Double>
    private let periods: UnsafeMutablePointer<Double>
    /// Item 7: the spacing period per mark (`spacingPeriods`); == periods when the item is off.
    private let spacingP: UnsafeMutablePointer<Double>
    private let markCount: Int
    private let window: UnsafeMutablePointer<Float>
    private let grains: UnsafeMutablePointer<Grain>
    private let state: UnsafeMutablePointer<State>
    private let smoothCoef: Float
    private let gateStep: Float
    private let loopStart: Double
    private let loopEnd: Double
    private let loopLen: Double
    private let hop: Double
    private let isVoiced: Bool
    private let isCarrier: Bool
    /// A voiced PHONEME (PSOLA branch; not the carrier): items 2-4 and 6 apply.
    private let isVoicedPhoneme: Bool
    private let holdsNaturalRate: Bool
    private let attackIndex: Int
    private let loopEndIndex: Int
    private let onsetFrame: Double
    private let readHi: Double
    private let wsolaEnergy: UnsafeMutablePointer<Double>
    private let sincTable: UnsafeMutablePointer<Float>
    // Option scalars (the render path never reads the struct).
    private let optResample: Bool
    private let optCap: Bool
    private let optDensity: Double
    private let optGamma: Double
    private let optShiftAttack: Bool
    /// Item 7: the mark the flat attack grain is centred on (attackIndex when the item is off).
    let attackFirstMark: Int
    // Item 4 bank, copied out of `hnBank` (no class reference on the render thread).
    private let hnOn: Bool
    private let hnStore: UnsafeMutablePointer<Float>
    private let hnFirst: Int
    private let hnSlot: Int
    private let hnRadius: Double
    private let rngSeed: UInt64
    // Item 8: the residual level gain per `LevelTable.grid` point (all 1 when off), read by `spawnNext`.
    private let optLevel: Bool
    private let levelTable: UnsafeMutablePointer<Float>

    convenience init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int) {
        self.init(source: source, sampleRate: sampleRate, kind: kind, maxFramesPerRender: maxFramesPerRender,
                  tuning: .default, options: .default)
    }

    /// As production builds TDPSOLA (`LiveSonificationAudio.makeRenderer`), plus the options.
    /// r31 (PITCHWIN): `file` is the recording at its own rate when `source` is a resample of it. A voiced source is
    /// then analysed THERE (pitch marks, item 5's glottal closures, item 7's first periodic mark) and the result is
    /// scaled to `sampleRate` (`TDPSOLAAnalysis.scaled`), so the grains sit where they sit at the file's rate and the
    /// renderer reads them from the resampled buffer. An unvoiced source keeps its analysis at `sampleRate`.
    convenience init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int,
                     tuning: TDPSOLATuning, options: TDPSOLA2Options, onset: RecordedOnset? = nil,
                     outputGain: Float = 1, file: SonificationSource.FileSource? = nil) {
        if let file, file.sampleRate > 0, file.sampleRate != sampleRate,
           case let fa = TDPSOLAAnalysis.analyse(file.samples, sampleRate: file.sampleRate, kind: kind,
                                                 unvoicedHopSeconds: tuning.unvoicedHopSeconds, onset: file.onset),
           fa.isVoiced {
            let r = sampleRate / file.sampleRate
            let hop = max(16, Int((tuning.unvoicedHopSeconds * sampleRate).rounded()))
            let (fr, report) = Self.refined(file.samples, sampleRate: file.sampleRate, analysis: fa, kind: kind,
                                            options: options)
            var firstMark: Int? = nil
            if options.shiftedAttack && kind != .carrier {
                let prep = Self.prepared(file.samples, sampleRate: file.sampleRate, analysis: fr, kind: kind,
                                         tuning: tuning, outputGain: outputGain)
                firstMark = Self.attackFirstMark(fr, samples: prep.played)
            }
            self.init(source: source, sampleRate: sampleRate, kind: kind, maxFramesPerRender: maxFramesPerRender,
                      analysis: fa.scaled(by: r, unvoicedHop: hop), tuning: tuning, options: options,
                      outputGain: outputGain, refined: (fr.scaled(by: r, unvoicedHop: hop), report),
                      firstMark: firstMark)
            return
        }
        self.init(source: source, sampleRate: sampleRate, kind: kind, maxFramesPerRender: maxFramesPerRender,
                  analysis: TDPSOLAAnalysis.analyse(source, sampleRate: sampleRate, kind: kind,
                                                    unvoicedHopSeconds: tuning.unvoicedHopSeconds, onset: onset),
                  tuning: tuning, options: options, outputGain: outputGain)
    }

    /// A second renderer of the same source for the kernel's crossover voice (`LiveSonificationAudio.makeRendererPair`):
    /// the same analysis, item 5's marks and item 8's table, without repeating the refinement or the measurement.
    /// `source` is the samples this renderer was built from. Init only.
    func twin(source: [Float]) -> TDPSOLA2 {
        TDPSOLA2(source: source, sampleRate: sampleRate, kind: kind, maxFramesPerRender: maxFramesPerRender,
                 analysis: coarseAnalysis, tuning: tuning, options: options, outputGain: outputGain,
                 refined: (analysis, epochReport), firstMark: attackFirstMark)
    }

    init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int, analysis a0: TDPSOLAAnalysis,
         tuning: TDPSOLATuning = .default, options: TDPSOLA2Options = .default, outputGain: Float = 1,
         refined: (analysis: TDPSOLAAnalysis, report: TDPSOLA2Epochs.Report?)? = nil, firstMark: Int? = nil) {
        self.kind = kind
        self.tuning = tuning
        self.options = options
        self.sampleRate = sampleRate
        self.maxFramesPerRender = maxFramesPerRender
        self.outputGain = outputGain
        coarseAnalysis = a0
        // Item 5: the marks, snapped (or kept by the guard). Everything below reads `a`.
        var a = a0
        if let refined {
            a = refined.analysis
            epochReport = refined.report
        } else {
            let r = Self.refined(source, sampleRate: sampleRate, analysis: a0, kind: kind, options: options)
            a = r.0
            epochReport = r.1
        }
        analysis = a
        // Shipped TDPSOLA init from here (SEAM2, TDQ, recorded onset, onset ceiling), on `a`.
        let prep = Self.prepared(source, sampleRate: sampleRate, analysis: a, kind: kind, tuning: tuning,
                                 outputGain: outputGain)
        let played = prep.played
        let effLoopEnd = prep.loopEnd, effLoopEndIndex = prep.loopEndIndex
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
        spacingP = .allocate(capacity: max(1, markCount))
        let sp = TDPSOLA2.spacingPeriods(a, flatAttack: options.shiftedAttack && options.attackFlatF0
                                            && a.isVoiced && kind != .carrier)
        for i in 0..<markCount { (spacingP + i).initialize(to: sp[i]) }
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
        isVoicedPhoneme = a.isVoiced && kind != .carrier
        holdsNaturalRate = !a.isVoiced && kind != .carrier
        attackIndex = a.attackIndex
        loopEndIndex = effLoopEndIndex
        onsetFrame = Double(a.onset)
        readHi = Double(count) + Double(Self.guardFrames - 4)
        sincTable = TDPSOLA2Sinc.makeTable()
        optResample = options.unvoicedResample
        optCap = options.voicedWindowCap
        optDensity = options.pulseDensityExponent
        // 0...1: beta <= 2 keeps every band-limited read of a bank slot inside its pad (TDPSOLA2HarmonicNoise.pad).
        optGamma = min(1, max(0, options.formantGamma.isFinite ? options.formantGamma : 0))
        optShiftAttack = options.shiftedAttack && a.isVoiced && kind != .carrier
        attackFirstMark = optShiftAttack ? (firstMark ?? TDPSOLA2.attackFirstMark(a, samples: played)) : a.attackIndex
        if a.isVoiced {
            wsolaEnergy = .allocate(capacity: 1)
            wsolaEnergy.initialize(to: 0)
        } else {
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
        // Item 4: the bank, from the samples the renderer plays.
        if options.harmonicNoiseSwap && isVoicedPhoneme && effLoopEndIndex > a.attackIndex {
            let bank = TDPSOLA2HarmonicNoise(body, count: n, marks: a.marks, periods: a.periods,
                                             first: a.attackIndex, last: effLoopEndIndex)
            hnBank = bank
            hnOn = true
            hnStore = bank.store
            hnFirst = bank.firstMark
            hnSlot = bank.slotLength
            hnRadius = Double(bank.radius)
        } else {
            hnBank = nil
            hnOn = false
            hnStore = srcBase   // never read
            hnFirst = 0
            hnSlot = 0
            hnRadius = 0
        }
        // Per-source seed: FNV-1a over the played samples' bit patterns (deterministic, never 0).
        var hsh: UInt64 = 0xcbf29ce484222325
        for v in played { hsh = (hsh ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        rngSeed = hsh == 0 ? 0x9E3779B97F4A7C15 : hsh
        optLevel = options.levelCalibration && kind != .carrier
            && (a.isVoiced ? effLoopEndIndex > a.attackIndex : effLoopEnd > a.loopStart)
        levelTable = .allocate(capacity: LevelTable.count)
        levelTable.initialize(repeating: 1, count: LevelTable.count)
        if optLevel {
            var mh: UInt64 = 0xcbf29ce484222325
            for m in a.marks { mh = (mh ^ m.bitPattern) &* 0x100000001b3 }
            let key = LevelTable.Key(samples: rngSeed, marks: mh, options: options, tuning: tuning)
            let t = LevelTable.cached(key) { self.measureLevelTable() }
            for k in 0..<LevelTable.count { levelTable[k] = t[k] }
        }
    }

    /// Item 8: the residual level gains, measured on this renderer. Each grid point renders the held note at rate 1
    /// from a fresh onset and compares the RMS of the loop's first 0.4 s (from 0.1 s after the attack) with the
    /// 0-cent render of the same output span: the read-head advances at the same rate at every pitch, so the spans
    /// read the same source material and the ratio is the shifter's level change alone. F's read-head advances at
    /// the pitch ratio instead (item 1), so its spans read different stretches of one stationary fricative loop; held
    /// F then measured within 0.1 dB of 0 cents at +-300 / +-600 c (lane PITCHWIN, macOS driver). Init only
    /// (allocates); the renderer is returned to its fresh state afterwards.
    private func measureLevelTable() -> [Float] {
        // Voiced: from the attack mark; unvoiced (F, no attack marks): from the loop start.
        let tLoop = isVoiced ? Int((marks[attackIndex] - onsetFrame).rounded(.up)) : Int((loopStart - onsetFrame).rounded(.up))
        let lo = tLoop + Int(0.1 * sampleRate), hi = lo + Int(0.4 * sampleRate)
        var buf = [Float](repeating: 0, count: hi)
        func level(_ cents: Double) -> Double {
            reset()
            setRate(1); setPitchCents(Float(cents)); setGate(true)
            var pos = 0
            buf.withUnsafeMutableBufferPointer { b in
                while pos < hi {
                    let n = min(LevelTable.renderFrames, hi - pos, maxFramesPerRender)
                    render(into: b.baseAddress! + pos, frames: n)
                    pos += n
                }
            }
            var e = 0.0
            for i in lo..<hi { e += Double(buf[i]) * Double(buf[i]) }
            return (e / Double(hi - lo)).squareRoot()
        }
        let l0 = level(0)
        var t = [Float](repeating: 1, count: LevelTable.count)
        if l0 > 0 {
            for k in 0..<LevelTable.count where k != LevelTable.zeroIndex {
                let l = level(LevelTable.cents(k))
                if l > 0 { t[k] = Float(min(LevelTable.maxGain, max(1 / LevelTable.maxGain, l0 / l))) }
            }
        }
        // Back to the state of a fresh renderer (determinism: a cached table and a measured one play alike).
        setGate(false); setRate(1); setPitchCents(0)
        resetToken.store(0, ordering: .relaxed)
        state.pointee = State()
        return t
    }

    /// Item 8: the residual gain at `cents` (linear between grid points; exactly 1 at 0 cents).
    @inline(__always) private func levelGain(_ cents: Double) -> Float {
        let x = (min(LevelTable.maxCents, max(-LevelTable.maxCents, cents)) + LevelTable.maxCents) / LevelTable.step
        let i = min(LevelTable.count - 2, Int(x))
        let f = Float(x - Double(i))
        return levelTable[i] * (1 - f) + levelTable[i + 1] * f
    }

    /// Item 8's table, read off the render thread (tests, the bench report).
    var levelTableValues: [Float] { Array(UnsafeBufferPointer(start: levelTable, count: LevelTable.count)) }

    /// Item 5: `a0`'s marks snapped to glottal closures (or kept by the guard), with the outcome; `a0` unchanged and no
    /// report when the option is off or the source is not a voiced phoneme.
    static func refined(_ source: [Float], sampleRate: Double, analysis a0: TDPSOLAAnalysis, kind: SourceKind,
                        options: TDPSOLA2Options) -> (TDPSOLAAnalysis, TDPSOLA2Epochs.Report?) {
        guard options.gciSnap && kind == .voicedPhoneme && a0.isVoiced else { return (a0, nil) }
        var r = TDPSOLA2Epochs.refine(source, sampleRate: sampleRate, analysis: a0, guardRatio: options.gciJitterGuard)
        if !r.report.applied && options.gciPhaseFallback {
            var p = TDPSOLA2Epochs.refine(source, sampleRate: sampleRate, analysis: a0,
                                          guardRatio: options.gciJitterGuard, phaseOnly: true)
            if p.report.applied && abs(p.report.medianOffset) >= options.gciPhaseMinOffset * a0.medianPeriod {
                p.report.reason = "phase-aligned by the median GCI offset (snap refused: \(r.report.reason))"
                p.report.snapRefused = r.report
                r = p
            } else if p.report.applied {
                r.report.reason += String(format: "; median GCI offset %.1f < %.2f x period: marks kept",
                                          p.report.medianOffset, options.gciPhaseMinOffset)
                r.report.medianOffset = p.report.medianOffset
            }
        }
        Self.log.info("""
            GCI snap \(r.report.applied ? "applied" : "kept old marks", privacy: .public): \
            \(r.report.reason, privacy: .public); jitter \(r.report.jitterBefore) -> \(r.report.jitterAfter); \
            matched \(r.report.matched)/\(r.report.markCount)
            """)
        return (r.analysis, r.report)
    }

    /// The played source (the shipped TDPSOLA init: SEAM2, TDQ, recorded onset, onset ceiling) and its loop end.
    static func prepared(_ source: [Float], sampleRate: Double, analysis a: TDPSOLAAnalysis, kind: SourceKind,
                         tuning: TDPSOLATuning, outputGain: Float) -> (played: [Float], loopEnd: Double, loopEndIndex: Int) {
        var played = source
        var effLoopEnd = a.loopEnd, effLoopEndIndex = a.loopEndIndex
        let preBlend = a.recordedOnset?.preBlendPeriods ?? TDPSOLALoopSeam.preBlendMarks
        if kind != .carrier, let prep = TDPSOLALoopSeam.prepare(played, sampleRate: sampleRate, analysis: a,
                                                                 crossfade: tuning.loopCrossfadeSeconds,
                                                                 flattenDB: tuning.loopFlattenDB,
                                                                 preBlendMarks: preBlend) {
            played = prep.samples; effLoopEnd = prep.loopEnd; effLoopEndIndex = prep.loopEndIndex
        }
        if kind != .carrier {
            let preTDQ = played
            played = TDPSOLADeclick.process(played, sampleRate: sampleRate, analysis: a, cap: tuning.pulseCrestCap)
            if a.recordedOnset != nil {
                TDPSOLA.keepRecordedOnset(&played, preTDQ, a, preBlend: preBlend)
                played = TDPSOLAOnsetCeiling.limit(played, gain: outputGain, ceiling: TDPSOLAOnsetCeiling.ceiling,
                                                   taper: TDPSOLAOnsetCeiling.taperFrames(sampleRate: sampleRate),
                                                   in: 0..<Int(a.loopStart))
            }
        }
        return (played, effLoopEnd, effLoopEndIndex)
    }

    /// Item 7: the first mark with one source period of recorded material between the onset and it, and from which
    /// the source is periodic (the flat grain keeps the pre-voicing transient as recorded); never past the attack index.
    /// Periodic = the period ending at the mark and the period before it correlate at `attackVoicedNCC` or more, at
    /// this mark and the next `attackVoicedRun - 1`. Lane PITCHWIN (2026-11-26): without it I's first mark is its
    /// breathy pre-voicing (marks 0-13 correlate below 0.3, MEASURED), and PSOLA on noise there respaced the breath
    /// into a buzz that LoopXDiagnosisTests' detector heard as a loop artefact at 51 ms.
    static func attackFirstMark(_ a: TDPSOLAAnalysis, samples x: [Float]) -> Int {
        guard a.isVoiced, !a.marks.isEmpty else { return a.attackIndex }
        var m = 0
        while m < a.attackIndex && a.marks[m] < Double(a.onset) + a.periods[m] { m += 1 }
        func periodic(_ k: Int) -> Bool {
            let t = Int(a.periods[k].rounded()), c = Int(a.marks[k].rounded())
            guard t > 0, c - t >= 0, c + t <= x.count else { return false }
            var xy = 0.0, xx = 0.0, yy = 0.0
            for j in 0..<t { let p = Double(x[c - t + j]), q = Double(x[c + j]); xy += p * q; xx += p * p; yy += q * q }
            return xy >= attackVoicedNCC * (xx * yy).squareRoot() && xx * yy > 0
        }
        while m < a.attackIndex && !(m..<min(a.marks.count, m + attackVoicedRun)).allSatisfy(periodic) { m += 1 }
        return m
    }
    static let attackVoicedNCC = 0.5
    static let attackVoicedRun = 3

    /// Item 7: the period each mark's grain is spaced by. The analysis' own periods, except (flatAttack) the attack's
    /// marks: the loop's median period. No jitter is carried in the attack: the attack marks' period-to-period spread is
    /// mostly mark error (carrying it, clamped +-10 %, measured 12-16 c attack RMS on I/L/M against 3-5 c without).
    static func spacingPeriods(_ a: TDPSOLAAnalysis, flatAttack: Bool) -> [Double] {
        var p = a.periods
        guard flatAttack, a.isVoiced, a.attackIndex > 0, a.loopEndIndex >= a.attackIndex else { return p }
        let loop = Array(a.periods[a.attackIndex...a.loopEndIndex]).sorted()
        let steady = loop[loop.count / 2]
        for i in 0..<a.attackIndex { p[i] = steady }
        return p
    }

    /// The samples the renderer plays (the prepared copy: SEAM2, TDQ, recorded onset). Off the render thread.
    var playedSamples: [Float] { Array(UnsafeBufferPointer(start: src, count: count)) }
    /// True while a note is sounding (render thread or single-threaded tests).
    var isPlaying: Bool { state.pointee.playing }

    deinit {
        sincTable.deallocate()
        srcBase.deallocate(); marks.deallocate(); periods.deallocate(); spacingP.deallocate(); levelTable.deallocate()
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

    var claimedLatencyFrames: Int {
        let smoothing = tuning.smoothingSeconds * sampleRate
        if !isVoiced { return Int((hop + smoothing).rounded(.up)) }
        return Int(((isCarrier ? 2 : 1) * maxPeriod + smoothing).rounded(.up))
    }
    private var maxPeriod: Double { analysis.periods.max() ?? 0 }

    var debugReadHead: Double { state.pointee.s }
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

        let coef = smoothCoef, step = gateStep
        let lEnd = loopEnd, lLen = loopLen
        let g = grains, x0 = src, w = window, hi = readHi
        let naturalRate = holdsNaturalRate
        let resampleF = naturalRate && optResample
        let gateTarget = st.pointee.gateTarget
        let attackCenter = st.pointee.attackCenter
        var rate = st.pointee.rate, cents = st.pointee.cents
        // Item 1: the unvoiced read-head advances at the pitch ratio. exp2(0) == 1 exactly.
        var pfHead = resampleF ? exp2(Double(cents) / 1200) : 1
        var gg = st.pointee.gateGain
        var now = st.pointee.now, s = st.pointee.s
        var attackActive = st.pointee.attackActive
        var n = st.pointee.grainCount
        var playing = true
        var settled = rate == rateTarget && cents == centsTarget

        var i = 0
        while i < frames {
            if !settled {
                var r = rate
                r += (rateTarget - r) * coef
                if abs(rateTarget - r) < 1e-6 { r = rateTarget }
                rate = r
                var c = cents
                c += (centsTarget - c) * coef
                if abs(centsTarget - c) < 1e-4 { c = centsTarget }
                cents = c
                if resampleF { pfHead = exp2(Double(c) / 1200) }
                settled = r == rateTarget && c == centsTarget
            }
            let r = rate, c = cents

            while g[n - 1].outCenter <= now {
                n = spawnNext(count: n, now: now, s: s, rate: r, cents: c, inAttack: attackActive)
            }

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
                    if wt > 0 { y += grainSample(gr, x, wt, x0, hi) }
                    if wt > 0 { wSum += wt; w2Sum += wt * wt; if gr.corr < rMin { rMin = gr.corr } }
                    gi += 1
                } else if x < gr.rightW {
                    wt = Self.windowAt(w, x / gr.rightW)
                    y += grainSample(gr, x, wt, x0, hi)
                    if wt > 0 { wSum += wt; w2Sum += wt * wt; if gr.corr < rMin { rMin = gr.corr } }
                    gi += 1
                } else if gi < n - 1 {
                    var k = gi
                    while k < n - 1 { g[k] = g[k + 1]; k += 1 }
                    n -= 1
                } else {
                    gi += 1
                }
            }

            // r17 F loudness correction (see TDPSOLA).
            if rMin < 0.999 && wSum > 0 {
                let r = max(0, rMin)
                let p = w2Sum + r * (wSum * wSum - w2Sum)
                if p > 1e-6 { y *= wSum / p.squareRoot() }
            }

            if gg != gateTarget {
                if gg < gateTarget { gg = min(gateTarget, gg + step) }
                else { gg = max(gateTarget, gg - step) }
            }
            out[i] = y * gg
            if gg == 0 && gateTarget == 0 { playing = false }

            if attackActive {
                s += 1
                if now + 1 >= attackCenter { attackActive = false }
            } else {
                s += naturalRate ? pfHead : Double(r)
            }
            if s >= lEnd { s -= lLen }
            now += 1
            i += 1
            if !playing {
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

    /// One grain's weighted contribution at output offset `x` (window weight `wt` > 0 or the caller's 0).
    /// With every option off this is `wt * read(...)`, the shipped expression (gain 1, cubic read).
    @inline(__always) private func grainSample(_ gr: Grain, _ x: Double, _ wt: Float,
                                               _ x0: UnsafeMutablePointer<Float>, _ hi: Double) -> Float {
        if gr.noise >= 0 {
            // Item 4: (h_i + n_j) re-windowed from the analysis Hann (+-T_i) to the synthesis window.
            let d = x * gr.inc
            let u = abs(d) * gr.anaInv
            if !(u < 1) { return 0 }
            let a = Self.windowAt(window, u)
            if a < 1e-3 { return 0 }
            let hp = hnStore + gr.hBase, np = hnStore + gr.nBase
            let v: Float
            if gr.bandCut > 0 {
                v = TDPSOLA2Sinc.read(hp, sincTable, gr.hFrac + d, gr.bandCut)
                    + TDPSOLA2Sinc.read(np, sincTable, gr.nFrac + d, gr.bandCut)
            } else {
                v = Self.cubic(hp, gr.hFrac + d) + Self.cubic(np, gr.nFrac + d)
            }
            return ((wt * gr.gain) / a) * v
        }
        let p = gr.srcCenter + x * gr.inc
        let v = gr.bandCut > 0 ? readBandLimited(p, gr.bandCut) : Self.read(x0, hi, p)
        return (wt * gr.gain) * v
    }

    @inline(__always) private static func floorInt(_ v: Double) -> Int { TDPSOLA2Sinc.floorInt(v) }

    @inline(__always) private static func windowAt(_ window: UnsafeMutablePointer<Float>, _ u: Double) -> Float {
        let p = u * Double(Self.windowSize)
        if !(p < Double(Self.windowSize)) { return 0 }
        let k = floorInt(p)
        let t = Float(p - Double(k))
        return window[k] + (window[k &+ 1] - window[k]) * t
    }

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

    /// Cubic read inside a bank slot (the caller keeps `pos` inside the slot's pad).
    @inline(__always) private static func cubic(_ b: UnsafeMutablePointer<Float>, _ pos: Double) -> Float {
        let fl = pos.rounded(.down)
        let k = floorInt(fl)
        let t = Float(pos - fl)
        if t == 0 { return b[k] }
        let y0 = b[k &- 1], y1 = b[k], y2 = b[k &+ 1], y3 = b[k &+ 2]
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * t + c2) * t + c1) * t + y1
    }

    /// Item 1 / 6: band-limited read of the played source (candidate A's clamp, then the shared kernel).
    @inline(__always) private func readBandLimited(_ pos: Double, _ cut: Double) -> Float {
        let lim = Double(Self.guardFrames - 4 - 2 * TDPSOLA2Sinc.zeros - 2)
        let p = min(readHi - Double(2 * TDPSOLA2Sinc.zeros + 2), max(-lim, pos))
        return TDPSOLA2Sinc.read(src, sincTable, p, cut)
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
            center = marks[attackFirstMark]
            period = periods[attackFirstMark]
            st.pointee.cursor = attackFirstMark
            st.pointee.lowMark = attackFirstMark
        } else {
            center = loopStart
            period = hop
        }
        let tA = center - onset
        grains[0] = Grain(outCenter: tA, leftW: 0, rightW: period, srcCenter: center,
                          inc: 1, period: period, flatLeft: true, mark: isVoiced ? attackFirstMark : -1)
        grains[0].spacingPeriod = isVoiced ? spacingP[attackFirstMark] : period
        st.pointee.grainCount = 1
        st.pointee.now = 0
        st.pointee.s = onset
        // The read-head advances at 1 until the attack index's mark (item 7 or not: the attack keeps its timing).
        let tEnd = isVoiced ? marks[attackIndex] - onset : tA
        st.pointee.attackActive = tEnd > 0
        st.pointee.attackCenter = tEnd
        st.pointee.playing = true
        st.pointee.rate = Float(bitPattern: rateBits.load(ordering: .relaxed))
        st.pointee.cents = Float(bitPattern: centsBits.load(ordering: .relaxed))
        // Item 4: every onset replays the same noise draws (determinism).
        st.pointee.rng = rngSeed
        st.pointee.recent0 = -1
        st.pointee.recent1 = -1
    }

    @inline(never) private func spawnNext(count n0: Int, now: Double, s: Double, rate: Float, cents: Float,
                                          inAttack: Bool) -> Int {
        var n = n0
        if n >= Self.maxGrains {
            var k = 0
            while k < n - 1 { grains[k] = grains[k + 1]; k += 1 }
            n -= 1
        }
        let li = n - 1
        let last = grains[li]
        let pf = exp2(Double(cents) / 1200)
        // Item 6: the voiced grain's read ratio. exp2(0) == 1: gamma 0 or 0 cents leaves beta at exactly 1.
        let beta = isVoicedPhoneme && optGamma != 0 ? exp2(optGamma * Double(cents) / 1200) : 1
        let spacing: Double
        let inc: Double
        if !isVoiced {
            spacing = hop; inc = pf
        } else if isCarrier {
            spacing = last.period / pf; inc = pf
        } else {
            spacing = last.spacingPeriod / pf; inc = beta
        }
        let tN = last.outCenter + spacing
        let dt = tN - now
        // Item 7: inside a shifted attack the read-head runs at 1 and has not reached the loop (no wrap).
        let sPred = optShiftAttack && inAttack
            ? s + dt : wrap(s + (holdsNaturalRate ? (optResample ? pf : 1) : Double(rate)) * dt)
        let center: Double
        let period: Double
        var corr: Float = 1
        var bandCut = 0.0
        var mark = -1
        if isVoiced {
            mark = nearestMark(sPred)
            center = marks[mark]; period = periods[mark]
            if isVoicedPhoneme && beta != 1 { bandCut = min(1, 1 / beta) }
        } else {
            if optResample {
                let pick = (pf != 1 || last.inc != 1) ? resampledContinuation(previous: last, inc: inc)
                                                      : wsolaPick(previous: last.srcCenter, target: sPred)
                center = pick.center; corr = pick.score
                if pf != 1 { bandCut = min(1, 1 / inc) }
            } else {
                let pick = wsolaPick(previous: last.srcCenter, target: sPred)
                center = pick.center; corr = pick.score
            }
            period = hop
        }
        // Item 2: the halves crossing over between `last` and the new grain, at most one source period of either.
        var halfW = spacing
        if optCap && isVoicedPhoneme && (pf != 1 || beta != 1 || last.spacingPeriod != last.period) {
            halfW = min(spacing, min(last.period / last.inc, period / inc))
        }
        grains[li].rightW = halfW
        var gr = Grain(outCenter: tN, leftW: halfW, rightW: halfW,
                       srcCenter: center, inc: inc, period: period, flatLeft: false,
                       corr: corr, bandCut: bandCut, mark: mark)
        gr.spacingPeriod = mark >= 0 ? spacingP[mark] : period
        // Item 3: pulse-density gain on downshift.
        // With gamma a grain is read at beta and so lasts 1/beta longer: the power lost is pf / beta = pf^(1 - gamma),
        // and the compensation pf^(-e (1 - gamma)) is 1 at gamma 1 (the carrier branch: a resample, nothing lost).
        if isVoicedPhoneme && optDensity > 0 && pf < 1 { gr.gain = Float(pow(pf, -optDensity * (1 - optGamma))) }
        // Item 8: the residual level gain (1 at 0 cents, so 0 cents is unchanged bit for bit).
        if optLevel { gr.gain *= levelGain(Double(cents)) }
        // Item 4: a repeated or skipped period plays its harmonic part with another period's noise.
        if hnOn && isVoicedPhoneme {
            let natural = last.mark >= 0 && mark == (last.mark == loopEndIndex ? attackIndex : last.mark + 1)
            let st = state
            var pick = mark
            // Item 7: an attack mark (before the bank's first) plays the source.
            if !natural && mark >= hnFirst {
                pick = drawNoise(around: mark)
                let mi = marks[mark].rounded(), nj = marks[pick].rounded()
                gr.noise = pick
                gr.hBase = 2 * (mark - hnFirst) * hnSlot
                gr.nBase = 2 * (pick - hnFirst) * hnSlot + hnSlot
                gr.hFrac = hnRadius + (marks[mark] - mi)
                gr.nFrac = hnRadius + (marks[pick] - nj)
                gr.anaInv = 1 / periods[mark]
            }
            st.pointee.recent1 = st.pointee.recent0
            st.pointee.recent0 = pick
        }
        grains[n] = gr
        return n + 1
    }

    /// Item 4: a mark within +-8 of `m` (inside the loop), not one of the last two picks; xorshift64*.
    private func drawNoise(around m: Int) -> Int {
        let st = state
        let lo = max(attackIndex, m - 8), hi = min(loopEndIndex, m + 8)
        let r0 = st.pointee.recent0, r1 = st.pointee.recent1
        var c = 0
        var j = lo
        while j <= hi { if j != r0 && j != r1 { c += 1 }; j += 1 }
        guard c > 0 else { return m }
        var x = st.pointee.rng
        x ^= x >> 12; x ^= x << 25; x ^= x >> 27
        st.pointee.rng = x
        var k = Int((x &* 2685821657736338717) >> 33) % c
        j = lo
        while j <= hi {
            if j != r0 && j != r1 { if k == 0 { return j }; k -= 1 }
            j += 1
        }
        return m
    }

    private func nearestMark(_ pos: Double) -> Int {
        let st = state
        // Item 7: inside a shifted attack the search starts at the attack's first mark; the loop wraps to attackIndex.
        let first = optShiftAttack ? min(st.pointee.lowMark, attackIndex) : attackIndex, last = loopEndIndex
        var c = st.pointee.cursor
        if c < first || c > last || pos < marks[c] - periods[c] { c = first }
        while c < last && marks[c + 1] <= pos { c += 1 }
        st.pointee.cursor = c
        if c >= attackIndex { st.pointee.lowMark = attackIndex }
        if c == last {
            return pos - marks[last] > 0.5 * periods[last] ? attackIndex : last
        }
        return (pos - marks[c]) <= (marks[c + 1] - pos) ? c : c + 1
    }

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
        let a = src + prev
        let eTab = wsolaEnergy
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

    /// Item 1 (candidate A as is): the centre whose read at `inc` continues the previous grain's read, and the
    /// normalised correlation of the two overlapping halves as played.
    private func resampledContinuation(previous p: Grain, inc: Double) -> (center: Double, score: Float) {
        let h = hop
        var c = p.srcCenter + h * 0.5 * (p.inc + inc)
        if c - h * inc >= loopEnd { c -= loopLen }
        let x0 = src, hi = readHi
        var num = 0.0, eA = 0.0, eB = 0.0
        var x = 0.0
        while x < h {
            let a = Double(p.bandCut > 0 ? readBandLimited(p.srcCenter + x * p.inc, p.bandCut)
                                         : Self.read(x0, hi, p.srcCenter + x * p.inc))
            let b = Double(readBandLimited(c + (x - h) * inc, min(1, 1 / inc)))
            num += a * b; eA += a * a; eB += b * b
            x += 2
        }
        let d = (eA * eB).squareRoot()
        return (c, Float(max(-1, min(1, d > 1e-12 ? num / d : 0))))
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

/// Item 8 (lane PITCHWIN, 2026-11-26): the grid and the per-process cache of the residual level table.
///
/// Why a residual: item 3's pf^-1/2 restores the pulses a downshift drops, but two other items change a grain's
/// energy too, and pf^-1/2 does not see them (MEASURED, macOS driver = iPad bench, held, rate 1): item 2 caps a
/// downshifted grain at one source period, so neighbouring grains no longer meet (-0.4 to -1.0 dB at -300 / -600 c
/// on every voiced letter); item 5 centres I's grains on its glottal closures, and a narrow upshift window there
/// holds less of the period's energy than one at the waveform-consistent mark (I +600: -0.86 -> -1.51 dB, the two
/// level-gate failures of the 2026-11-25 bench). The table measures what the renderer does instead of modelling it.
nonisolated enum LevelTable {
    static let maxCents = 1200.0
    static let step = 100.0
    static let count = 25
    static let zeroIndex = 12
    /// A grid point's gain is clamped to +-6 dB (a measurement that far off is not a level fix).
    static let maxGain: Double = 2
    static let renderFrames = 256

    static func cents(_ k: Int) -> Double { Double(k) * step - maxCents }

    struct Key: Hashable, Sendable {
        let samples: UInt64
        let marks: UInt64
        let options: TDPSOLA2Options
        let tuning: [Double]

        init(samples: UInt64, marks: UInt64, options: TDPSOLA2Options, tuning t: TDPSOLATuning) {
            self.samples = samples
            self.marks = marks
            self.options = options
            tuning = [t.smoothingSeconds, t.gateRampSeconds, t.unvoicedHopSeconds, t.pulseCrestCap,
                      t.loopCrossfadeSeconds, t.loopFlattenDB]
        }
    }

    private static let cache = Mutex<[Key: [Float]]>([:])

    /// The table for `key`, measured by `measure` on the first request (renderers of one source share it: the twin,
    /// a rebuilt slot, the tests). Init only.
    static func cached(_ key: Key, measure: () -> [Float]) -> [Float] {
        if let t = cache.withLock({ $0[key] }) { return t }
        let t = measure()
        cache.withLock { $0[key] = t }
        return t
    }

    /// Tests only: forget every table, so the next renderer measures its own.
    static func removeAllForTesting() { cache.withLock { $0.removeAll() } }
}
