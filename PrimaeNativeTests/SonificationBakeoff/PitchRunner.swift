// PitchRunner.swift
// PrimaeNativeTests — pitch bake-off harness (BENCH-P 2026-11-23; r31 gate-method & seed-spread updates, lane BENCH-R31)
//
// Turns one render (or an 8-seed spread of renders) of a PitchScenarios scenario into metric rows (bench.csv) and
// gate rows (gates.csv).
//
// r31 updates (lane BENCH-R31):
//   - Per-cell xor seed derivation (`cellSeedXor`): seed 0 is always 0 (exact shipping production hash); seeds 1..<8
//     XOR `baseSeedXors[i]` with FNV-1a of `source|scenario`, so no two cells share the same noise sequence.
//   - Seed-spread gating (`aggregateSeedSpread`): gates on the MEDIAN of N seeds (robust against finite-window Monte
//     Carlo tail outliers from item 4 without shrinking the pass band as N grows), while recording `seed_count`,
//     `seed_pass`, `seed_min`, `seed_max` on every gate row.
//   - Voiced held window: integer number of whole PLAYED loops >= 1.8 s (`PitchScenarios.heldAnalysisDuration`, loop
//     length from the renderer's own `TDPSOLA2.playedLoop`, lane BENCHWIN), eliminating
//     partial-loop timbral and jitter bias at @0.5 and @2.
//   - Shifted `f0_within_5c`: compares `c != 0` against the candidate's own 0-cent render F0 * pf (measuring the
//     shifter rather than A's -3.3 c loop-vs-steadyRange offset), while `c == 0` stays gated against `ref.f0`.
//   - `env_warp`: signal-own-F0 cepstral order + continuous golden-section refinement.
//   - `env_lsd_vs_praat`: matched-rate Praat reference without `boundary='zeros'`, shifted `c != 0` only (`<= 1.4x`),
//     paired with per-letter mean shifted LSD (`env_lsd_letter_vs_praat <= 1.2x`).
//   - `traj_attack`: measured over the actual recorded attack (`0 .. attackEndFrame/sr`, excluding the +50 ms loop
//     tail) at causal lag `0...10 ms` (matching `traj_pitch_lag`).

import Foundation
@testable import PrimaeNative

struct PitchGateRow {
    let candidate: String
    let source: String
    let scenario: String
    let result: PitchGates.Result

    static let header = "candidate,source,scenario,gate,value,threshold,pass,seed_count,seed_pass,seed_min,seed_max"
    var csv: String {
        func fmt(_ x: Double) -> String { x.isFinite ? String(format: "%.6g", x) : "nan" }
        let sp = result.spread
        let n = sp?.total ?? 1
        let pc = sp?.passCount ?? (result.pass ? 1 : 0)
        let lo = sp?.min ?? result.value
        let hi = sp?.max ?? result.value
        return "\(candidate),\(source),\(scenario),\(result.gate),\(fmt(result.value)),\(result.threshold),\(result.pass ? "PASS" : "FAIL"),\(n),\(pc),\(fmt(lo)),\(fmt(hi))"
    }
}

/// Per-source references (computed once at the source's sample rate).
final class PitchSourceRef {
    let source: BakeoffSource
    let steady: ArraySlice<Float>
    let f0: Double?
    /// Fixed-order (f0max 360 Hz) true envelope for matched-order LSD comparisons against Praat.
    let envelope: (f: [Double], e: [Double])
    /// Signal-own-F0 true envelope for scale-covariant warp (`env_warp`) comparisons.
    let ownF0Envelope: (f: [Double], e: [Double])
    let perturbation: PitchMetrics.Perturbation?
    /// Level of each candidate's 0-cent held render per rate (and seed suffix), for level-vs-cents.
    var zeroLevels: [String: Double] = [:]
    /// Median F0 of each candidate's 0-cent held render per rate (and seed suffix), for shifted F0 accuracy.
    var zeroF0s: [String: Double] = [:]

    var isVoiced: Bool { source.kind == .voicedPhoneme }

    init(_ source: BakeoffSource) {
        self.source = source
        let sr = source.sampleRate
        steady = source.samples[source.steadyRange]
        let tr = BakeoffMetrics.yinTrack(Array(steady), start: 0, end: steady.count, sampleRate: sr,
                                         hop: Int(0.005 * sr), fmin: 75, fmax: 700)
        f0 = BakeoffMetrics.medianF0(tr)
        let ltas = PitchMetrics.ltas(steady, sampleRate: sr)
        envelope = PitchMetrics.envelopeDB(ltas: ltas, sampleRate: sr, f0max: 360)
        ownF0Envelope = PitchMetrics.envelopeDB(ltas: ltas, sampleRate: sr, f0max: f0 ?? 360)
        perturbation = source.kind == .voicedPhoneme ? PitchMetrics.perturbation(steady, sampleRate: sr) : nil
    }
}

enum PitchRunner {

    struct Output {
        var rows: [BakeoffRow] = []
        var gates: [PitchGateRow] = []
    }

    /// 8-seed spread constants. Seed 0 is 0 (exact shipping production hash); seeds 1..<8 are XORed with a per-cell
    /// FNV-1a hash so every `(source, scenario)` cell draws an independent sequence.
    static let baseSeedXors: [UInt64] = [
        0,
        12_345,
        987_654_321,
        0x1357_9BDF_2468_ACE0,
        0xCAFE_BABE_1234_5678,
        0xDEAD_BEEF_8765_4321,
        0x5555_AAAA_3333_CCCC,
        0x9E37_79B9_7F4A_7C15,
    ]

    /// Deterministic FNV-1a hash of a string (for per-cell xor seed derivation).
    static func fnv1a(_ text: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in text.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    /// Derives the noise-seed XOR constant for one `(source, scenario, seedIndex)` cell.
    /// Seed 0 is always 0 (exact production seed); seeds > 0 XOR `baseSeedXors` with the cell hash so seeds differ
    /// across both seeds and cells.
    static func cellSeedXor(source: String, scenario: String, seedIndex: Int) -> UInt64 {
        guard seedIndex > 0 else { return 0 }
        let base = seedIndex < baseSeedXors.count
            ? baseSeedXors[seedIndex]
            : UInt64(seedIndex) &* 0x9E37_79B9_7F4A_7C15
        let cell = fnv1a("\(source)|\(scenario)")
        let x = base ^ cell
        return x == 0 ? base : x
    }

    /// Aggregates `N` per-seed `Output`s for the same `(candidate, source, scenario)` into one spread-gated `Output`:
    /// metrics take the median across seeds; gates evaluate their predicate on the MEDIAN of the `N` per-seed values
    /// and attach `(min, max, passCount, total)` for auditability.
    static func aggregateSeedSpread(_ outputs: [Output]) -> Output {
        guard let first = outputs.first else { return Output() }
        if outputs.count == 1 { return first }
        var out = Output()
        // Aggregate rows in seed-0 order, preserving any seed-0-only rows (e.g. framewise LSD).
        for row0 in first.rows {
            let vals = outputs.compactMap { o in
                o.rows.first(where: { $0.metric == row0.metric })?.value
            }.filter(\.isFinite)
            let med = PitchMetrics.median(vals) ?? row0.value
            out.rows.append(BakeoffRow(candidate: row0.candidate, source: row0.source, kind: row0.kind,
                                       sampleRate: row0.sampleRate, scenario: row0.scenario, metric: row0.metric,
                                       value: med, unit: row0.unit))
        }
        // Aggregate gates in seed-0 order.
        for g0 in first.gates {
            let matching = outputs.compactMap { o in o.gates.first(where: { $0.result.gate == g0.result.gate })?.result }
            let vals = matching.map(\.value)
            let finite = vals.filter(\.isFinite)
            let med = finite.count == matching.count ? (PitchMetrics.median(finite) ?? .nan) : .nan
            let lo = finite.min() ?? .nan
            let hi = finite.max() ?? .nan
            let passCount = matching.filter(\.pass).count
            let aggPass = g0.result.predicate(med)
            let aggResult = PitchGates.Result(
                gate: g0.result.gate, value: med, threshold: g0.result.threshold, pass: aggPass,
                spread: PitchGates.Spread(min: lo, max: hi, passCount: passCount, total: matching.count),
                predicate: g0.result.predicate)
            out.gates.append(PitchGateRow(candidate: g0.candidate, source: g0.source, scenario: g0.scenario,
                                          result: aggResult))
        }
        return out
    }

    /// Frames of a voiced held render that the held-pitch gates measure: from `heldRegion.from` for a whole number of
    /// played loops at `rate` (`PitchScenarios.heldAnalysisDuration`), clipped to the render. Shared with the offline
    /// harness's render dump so a dumped window is exactly the gated one.
    static func heldWindow(count: Int, sampleRate sr: Double, rate r: Float, loopSeconds: Double?) -> Range<Int> {
        func frame(_ t: Double) -> Int { min(count, max(0, Int(t * sr))) }
        let winFrom = PitchScenarios.heldRegion.from
        let winDur = PitchScenarios.heldAnalysisDuration(rate: r, loopSeconds: loopSeconds)
        let winTo = min(Double(count) / sr, winFrom + winDur)
        return frame(winFrom)..<frame(winTo)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    static func rows(candidate: String, render: BakeoffRender, ref: PitchSourceRef, scenario: BakeoffScenario,
                     gamma: Double = 0, zeroKeySuffix: String = "", computeFramewiseLSD: Bool = true) -> Output {
        let source = ref.source
        let sr = source.sampleRate
        let x = render.samples
        var out = Output()
        func add(_ metric: String, _ value: Double?, _ unit: String) {
            guard let value else { return }
            out.rows.append(BakeoffRow(candidate: candidate, source: source.name, kind: source.kindLabel,
                                       sampleRate: Int(sr), scenario: scenario.name, metric: metric,
                                       value: value, unit: unit))
        }
        func gate(_ r: PitchGates.Result?) {
            guard let r else { return }
            out.gates.append(PitchGateRow(candidate: candidate, source: source.name, scenario: scenario.name, result: r))
        }
        func frame(_ t: Double) -> Int { min(x.count, max(0, Int(t * sr))) }
        // Separate the actual recorded attack (`0 .. attackEndFrame/sr`) from the settled-trajectory start (+50 ms).
        // Synthetic sources without a recorded onset fall back to 50 ms for the attack window.
        let rawAttack = source.onset.map { Double($0.attackEndFrame) / sr } ?? 0.05
        let settledAttack = rawAttack + 0.05

        switch scenario.family {
        case .heldPitch(let c, let r):
            let pf = pow(2, Double(c) / 1200)
            let key = "\(candidate)@\(PitchScenarios.rateLabel(r))\(zeroKeySuffix)"
            if ref.isVoiced {
                let y = x[heldWindow(count: x.count, sampleRate: sr, rate: r, loopSeconds: source.loopSeconds)]
                let level = PitchMetrics.rmsDB(y)
                add("level_db", level, "dBFS")
                if c == 0 { ref.zeroLevels[key] = level }
                if let z = ref.zeroLevels[key] {
                    add("level_re_0c_db", level - z, "dB")
                    if c != 0 { gate(PitchGates.level(reZeroDB: level - z)) }
                }
                let tr = BakeoffMetrics.yinTrack(Array(y), start: 0, end: y.count, sampleRate: sr,
                                                 hop: Int(0.005 * sr), fmin: 75, fmax: 700)
                let f0s = tr.compactMap(\.f0).sorted()
                let measuredF0 = BakeoffMetrics.medianF0(tr)
                if let f = measuredF0, let s = ref.f0 {
                    add("f0_hz", f, "Hz")
                    // Only adopt the candidate's 0-cent F0 as the shifted baseline when 0 c itself is within +-5 c of
                    // the source (so rate-coupled varispeed or grossly detuned renderers cannot hide behind their own
                    // 0-cent error on shifted cells).
                    if c == 0, abs(PitchMetrics.cents(f, re: s)) <= PitchGates.f0ToleranceCents { ref.zeroF0s[key] = f }
                    let target = c == 0 ? s : (ref.zeroF0s[key] ?? s) * pf
                    let err = PitchMetrics.cents(f, re: target)
                    add("f0_err_c", err, "cents")
                    gate(PitchGates.f0(errorCents: err))
                    if f0s.count >= 4 {
                        let p5 = f0s[Int(0.05 * Double(f0s.count - 1))]
                        let p95 = f0s[Int(0.95 * Double(f0s.count - 1))]
                        add("f0_p95_p05_c", PitchMetrics.cents(p95, re: p5), "cents")
                    }
                }
                let yLTAS = PitchMetrics.ltas(y, sampleRate: sr)
                let envFixed = PitchMetrics.envelopeDB(ltas: yLTAS, sampleRate: sr, f0max: 360)
                let cmpLSD = PitchMetrics.envelopeCompare(f: envFixed.f, source: ref.envelope.e, output: envFixed.e,
                                                          refine: false)
                let envOwn = PitchMetrics.envelopeDB(ltas: yLTAS, sampleRate: sr, f0max: measuredF0 ?? 360)
                let cmpWarp = PitchMetrics.envelopeCompare(f: envOwn.f, source: ref.ownF0Envelope.e, output: envOwn.e,
                                                           refine: true)
                add("env_warp", cmpWarp.warp, "ratio")
                add("env_lsd_db", cmpLSD.lsd, "dB")
                add("env_lsd_warped_db", cmpWarp.lsdAtWarp, "dB")
                gate(PitchGates.warp(alpha: cmpWarp.warp, pitchFactor: pf, gamma: gamma))
                if let letter = source.letter {
                    gate(PitchGates.envelopeLSD(cmpLSD.lsd, letter: letter, cents: Int(c), sampleRate: sr))
                }
                if computeFramewiseLSD {
                    add("env_lsd_frame_db",
                        PitchMetrics.framewiseEnvelopeLSD(source: ref.steady, output: y, sampleRate: sr), "dB")
                }
                if let p = PitchMetrics.perturbation(y, sampleRate: sr) {
                    add("jitter_pct", p.jitterPct, "%")
                    add("shimmer_pct", p.shimmerPct, "%")
                    if let sp = ref.perturbation {
                        let jr = p.jitterPct / sp.jitterPct
                        let srRatio = p.shimmerPct / sp.shimmerPct
                        add("jitter_ratio", jr, "x")
                        add("shimmer_ratio", srRatio, "x")
                        gate(PitchGates.microVariation("jitter_ratio", ratio: jr))
                        gate(PitchGates.microVariation("shimmer_ratio", ratio: srRatio))
                    }
                }
            } else {
                // F (unvoiced): candidate A's gates (0.3 ... 2.4 s).
                let y = x[frame(0.3)..<frame(PitchScenarios.heldRegion.to)]
                let level = PitchMetrics.rmsDB(y)
                add("level_db", level, "dBFS")
                if c == 0 { ref.zeroLevels[key] = level }
                if let z = ref.zeroLevels[key] {
                    add("level_re_0c_db", level - z, "dB")
                    if c != 0 { gate(PitchGates.fLevel(reZeroDB: level - z, cents: c)) }
                }
                let hop = PitchMetrics.unvoicedHop(sampleRate: sr)
                let wobble = PitchMetrics.grainRateWobble(y, period: hop)
                add("f_wobble_db", wobble, "dB")
                if c != 0 { gate(PitchGates.fWobble(wobble)) }
                if c != 0 {
                    let acf = PitchMetrics.acf(y, lag: PitchMetrics.combLag(hop: hop, pitchFactor: pf))
                    add("f_comb_acf", acf, "r")
                    if c > 0 { gate(PitchGates.fComb(acf)) }
                }
                let env = PitchMetrics.envelopeDB(y, sampleRate: sr)
                let cmp = PitchMetrics.envelopeCompare(f: env.f, source: ref.envelope.e, output: env.e,
                                                       lo: 500, hi: 16_000)
                add("env_warp", cmp.warp, "ratio")
                add("env_lsd_db", cmp.lsd, "dB")
            }

        case .pitchStepRated(let a, let b, let at, _):
            let stepFrame = BakeoffRunner.appliedFrame(at, sampleRate: sr)
            let stepT = Double(stepFrame) / sr
            if ref.isVoiced, let s = ref.f0 {
                let series = PitchMetrics.centsTrack(x, from: stepFrame - Int(0.4 * sr),
                                                     to: min(x.count, stepFrame + Int(0.8 * sr)),
                                                     ref: s, sampleRate: sr, hopSeconds: 0.001)
                    .compactMap { p in p.v.map { (t: p.t, v: $0) } }
                if let r = BakeoffMetrics.stepResponse(series, stepTime: stepT) {
                    add("pitch_step_delay10_ms", r.delayTo10 * 1000, "ms")
                    add("pitch_step_delay90_ms", r.delayTo90 * 1000, "ms")
                    add("pitch_step_rise_ms", r.rise10to90 * 1000, "ms")
                    gate(PitchGates.step90(ms: r.delayTo90 * 1000))
                } else {
                    gate(PitchGates.step90(ms: nil))
                }
                if let pre = PitchMetrics.median(series.filter { $0.t >= stepT - 0.3 && $0.t <= stepT - 0.05 }.map(\.v)) {
                    add("cents_err_before_step", pre - Double(a), "cents")
                }
                if let post = PitchMetrics.median(series.filter { $0.t >= stepT + 0.4 && $0.t <= stepT + 0.75 }.map(\.v)) {
                    add("cents_err_after_step", post - Double(b), "cents")
                }
            }
            if let cr = PitchMetrics.localClickRatio(x, from: stepFrame - Int(0.05 * sr), to: stepFrame + Int(0.3 * sr),
                                                     sampleRate: sr) {
                add("step_click_ratio", cr, "x")
                gate(PitchGates.clicks("step_click", ratio: cr))
            }

        case .pitchSweep(_, let commanded):
            if let cr = PitchMetrics.localClickRatio(x, from: frame(0.05), to: frame(PitchScenarios.sweepSeconds - 0.05),
                                                     sampleRate: sr) {
                add("sweep_click_ratio", cr, "x")
                gate(PitchGates.clicks("sweep_click", ratio: cr))
            }
            if ref.isVoiced, let s = ref.f0 {
                let lag = trackingLag(x, from: frame(max(0.05, settledAttack)), to: frame(PitchScenarios.sweepSeconds),
                                      ref: s, sr: sr, commanded: commanded)
                add("traj_pitch_lag_ms", lag.map { $0.lag * 1000 }, "ms")
                add("traj_pitch_rms_cents", lag?.rmsAtLag, "cents")
                gate(PitchGates.trajectoryLag(ms: lag.map { $0.lag * 1000 }))
            }

        case .trajectory(_, _, _, let commanded) where scenario.name.hasSuffix("_height"):
            var worstClick = 0.0
            var times: [Double] = [], measured: [Double?] = []
            var attackPts: [(t: Double, v: Double)] = []
            for iv in scenario.openIntervals {
                let o = BakeoffRunner.appliedFrame(iv.open, sampleRate: sr)
                let cl = min(x.count, BakeoffRunner.appliedFrame(iv.close, sampleRate: sr))
                if let cr = PitchMetrics.localClickRatio(x, from: o + Int(0.03 * sr), to: cl - Int(0.01 * sr), sampleRate: sr) {
                    worstClick = max(worstClick, cr)
                }
                if ref.isVoiced, let s = ref.f0 {
                    let settled = o + Int(settledAttack * sr)
                    if settled < cl {
                        for p in PitchMetrics.centsTrack(x, from: settled, to: cl, ref: s, sampleRate: sr,
                                                         hopSeconds: 0.0025) {
                            times.append(p.t); measured.append(p.v)
                        }
                    }
                    let attackEnd = o + Int(rawAttack * sr)
                    for p in PitchMetrics.centsTrack(x, from: o, to: min(cl, attackEnd + PitchMetrics.yinWindow(sampleRate: sr)), ref: s, sampleRate: sr,
                                                     hopSeconds: 0.0025) where p.t * sr < Double(attackEnd) {
                        if let v = p.v { attackPts.append((p.t, v)) }
                    }
                }
            }
            add("traj_click_ratio", worstClick, "x")
            gate(PitchGates.clicks("traj_click", ratio: worstClick))
            if ref.isVoiced {
                let lag = BakeoffMetrics.trackingLag(times: times,
                                                     commanded: { BakeoffScenarios.commanded(commanded, at: $0) },
                                                     measured: measured)
                add("traj_pitch_lag_ms", lag.map { $0.lag * 1000 }, "ms")
                add("traj_pitch_rms_cents", lag?.rmsAtLag, "cents")
                add("traj_pitch_rms_cents_zero_lag", lag?.rmsAtZero, "cents")
                let atk = PitchMetrics.causalAttackRMS(points: attackPts,
                                                       commanded: { BakeoffScenarios.commanded(commanded, at: $0) },
                                                       maxLag: PitchGates.trajectoryLagMS / 1000.0)
                add("traj_attack_rms_cents", atk?.rms, "cents")
                add("traj_attack_rms_cents_zero_lag", atk?.rmsAtZero, "cents")
                add("traj_attack_lag_ms", atk.map { $0.lag * 1000 }, "ms")
                gate(PitchGates.attack(rmsCents: atk?.rms))
                gate(PitchGates.trajectoryLag(ms: lag.map { $0.lag * 1000 }))
            }

        default:
            break
        }
        return out
    }

    static func trackingLag(_ x: [Float], from: Int, to: Int, ref: Double, sr: Double,
                            commanded: [(t: Double, v: Double)]) -> (lag: Double, rmsAtLag: Double, rmsAtZero: Double)? {
        let tr = PitchMetrics.centsTrack(x, from: from, to: to, ref: ref, sampleRate: sr, hopSeconds: 0.0025)
        return BakeoffMetrics.trackingLag(times: tr.map(\.t), commanded: { BakeoffScenarios.commanded(commanded, at: $0) },
                                          measured: tr.map(\.v))
    }
}
