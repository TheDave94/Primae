// PitchGates.swift
// PrimaeNativeTests — pitch bake-off harness (BENCH-P 2026-11-23; r31 gate-method fixes, lane BENCH-R31 2026-11-28)
//
// The pitch-specific acceptance gates of BAKEOFF-PITCH.md section 3 as predicates over metric values, updated in r31
// (lane BENCH-R31, docs/DECISIONS.md):
//   - Matched-rate Praat PSOLA references (48 kHz & 44.1 kHz, Praat 7.0.02, measured by the exact same interior-Hann
//     `PitchMetrics.envelopeDB` without `boundary='zeros'`), shifted cells (`c != 0`) only.
//   - Per-cell `env_lsd_vs_praat` stays at 1.2 x Praat (`lsdFactor = 1.2`, unchanged); per-letter mean shifted LSD
//     (`env_lsd_letter_vs_praat <= 1.2 x` Praat per-letter mean) is added as an additional aggregate gate.
//   - Seed-spread aggregation metadata (`Spread`: min, max, passCount, total) attached when gated on median-of-N.

import Foundation

enum PitchGates {

    struct Spread {
        let min: Double
        let max: Double
        let passCount: Int
        let total: Int
    }

    struct Result {
        let gate: String
        let value: Double
        let threshold: String
        let pass: Bool
        var spread: Spread? = nil
        /// Re-evaluates this gate's predicate on an aggregated statistic (e.g. median of 8 seeds).
        let predicate: (Double) -> Bool

        init(gate: String, value: Double, threshold: String, pass: Bool, spread: Spread? = nil,
             predicate: ((Double) -> Bool)? = nil) {
            self.gate = gate
            self.value = value
            self.threshold = threshold
            self.pass = pass
            self.spread = spread
            self.predicate = predicate ?? { _ in pass }
        }
    }

    // MARK: thresholds (BAKEOFF-PITCH section 3 + r31 BENCH-R31)

    /// F0 accuracy: voiced, |error| <= 5 cents at +-300 / +-600 (re 0 c render * pf) and 0 c (re source), rates 0.5/1/2.
    static let f0ToleranceCents = 5.0
    /// Envelope held: warp alpha within pf^gamma +- 0.03 (gamma 0 = strict preservation).
    static let warpTolerance = 0.03
    /// Envelope distance: LSD <= 1.2 x Praat PSOLA's matched-rate reference (per-cell AND per-letter mean).
    static let lsdFactor = 1.2
    /// Micro-variation: output jitter and shimmer within x0.6 ... x1.6 of the source's.
    static let microVariationRange: ClosedRange<Double> = 0.6...1.6
    /// Level flatness: steady RMS within +-1.5 dB of the 0-cent render.
    static let levelToleranceDB = 1.5
    /// F: grain-rate wobble <= 1 dB; level within 0.3 dB (down) / 1.2 dB (up); comb ACF < 0.1.
    static let fWobbleDB = 1.0
    static let fLevelDownDB = 0.3
    static let fLevelUpDB = 1.2
    static let fCombACF = 0.1
    /// Pitch control lag: a step reaches 90 % within 15 ms; trajectory pitch lag <= 10 ms.
    static let step90MS = 15.0
    static let trajectoryLagMS = 10.0
    /// Clicks at pitch steps and during sweeps: ratio <= 2.5 (the r17 bench gate).
    static let clickRatio = 2.5

    /// Praat 7.0.02 PSOLA (`To Manipulation: 0.01, 75, 600` -> `Multiply frequencies` -> `Get resynthesis (overlap-add)`)
    /// long-term true-envelope LSD (dB, 150-5000 Hz, interior Hann windows without `boundary='zeros'`) on the 48 kHz
    /// resampled study sources (`SonificationSource.load(..., sampleRate: 48_000)`), shifted cells (`c != 0`) only.
    static let praatLSD48k: [String: [Int: Double]] = [
        "A": [-600: 1.009, -300: 1.525, 300: 1.096, 600: 1.336],
        "I": [-600: 1.977, -300: 3.258, 300: 3.624, 600: 4.327],
        "L": [-600: 1.269, -300: 1.978, 300: 2.553, 600: 3.335],
        "M": [-600: 1.698, -300: 1.717, 300: 2.165, 600: 2.166],
    ]

    /// Same Praat 7.0.02 calibration at 44.1 kHz (native asset rate, interior Hann windows without `boundary='zeros'`).
    static let praatLSD44k: [String: [Int: Double]] = [
        "A": [-600: 0.958, -300: 1.516, 300: 1.164, 600: 1.376],
        "I": [-600: 2.140, -300: 3.325, 300: 3.565, 600: 4.352],
        "L": [-600: 1.460, -300: 2.146, 300: 2.713, 600: 3.557],
        "M": [-600: 1.745, -300: 1.588, 300: 2.133, 600: 2.137],
    ]

    /// Matched-rate Praat reference table (48 kHz or 44.1 kHz).
    static func praatTable(sampleRate: Double) -> [String: [Int: Double]]? {
        if abs(sampleRate - 48_000) < 100 { return praatLSD48k }
        if abs(sampleRate - 44_100) < 100 { return praatLSD44k }
        return nil
    }

    /// Matched-rate Praat reference for `(letter, cents)`. Nil for `cents == 0` (live loop prep + rate wrapping are not
    /// compared against offline unlooped Praat identity) or unknown letter/rate.
    static func praatLSD(letter: String, cents: Int, sampleRate: Double) -> Double? {
        guard cents != 0 else { return nil }
        return praatTable(sampleRate: sampleRate)?[letter]?[cents]
    }

    /// Mean of the four shifted Praat references (`-600, -300, +300, +600`) for `letter` at `sampleRate`.
    static func praatLetterMeanLSD(letter: String, sampleRate: Double) -> Double? {
        guard let map = praatTable(sampleRate: sampleRate)?[letter], !map.isEmpty else { return nil }
        return map.values.reduce(0, +) / Double(map.count)
    }

    // MARK: predicates

    static func f0(errorCents e: Double) -> Result {
        let p: (Double) -> Bool = { $0.isFinite && abs($0) <= f0ToleranceCents }
        return Result(gate: "f0_within_5c", value: e, threshold: "|e| <= \(f0ToleranceCents)", pass: p(e), predicate: p)
    }

    static func warp(alpha: Double, pitchFactor pf: Double, gamma: Double = 0) -> Result {
        let target = pow(pf, gamma)
        let p: (Double) -> Bool = { $0.isFinite && abs($0 - target) <= warpTolerance + 1e-9 }
        return Result(gate: "env_warp", value: alpha, threshold: String(format: "%.3f +- %.2f", target, warpTolerance),
                      pass: p(alpha), predicate: p)
    }

    /// Per-cell shifted envelope LSD (`<= 1.2 x` matched-rate Praat). Nil for `cents == 0` or unknown ref.
    static func envelopeLSD(_ lsd: Double, letter: String, cents: Int,
                            sampleRate: Double = BakeoffSources.pitchSampleRate) -> Result? {
        guard let ref = praatLSD(letter: letter, cents: cents, sampleRate: sampleRate) else { return nil }
        let bound = lsdFactor * ref
        let p: (Double) -> Bool = { $0.isFinite && $0 <= bound }
        return Result(gate: "env_lsd_vs_praat", value: lsd, threshold: String(format: "<= %.3f", bound),
                      pass: p(lsd), predicate: p)
    }

    /// Per-letter mean shifted envelope LSD (`<= 1.2 x` matched-rate Praat per-letter mean).
    static func envelopeLetterMeanLSD(_ meanLSD: Double, letter: String,
                                      sampleRate: Double = BakeoffSources.pitchSampleRate) -> Result? {
        guard let ref = praatLetterMeanLSD(letter: letter, sampleRate: sampleRate) else { return nil }
        let bound = lsdFactor * ref
        let p: (Double) -> Bool = { $0.isFinite && $0 <= bound }
        return Result(gate: "env_lsd_letter_vs_praat", value: meanLSD, threshold: String(format: "<= %.3f", bound),
                      pass: p(meanLSD), predicate: p)
    }

    static func microVariation(_ name: String, ratio: Double) -> Result {
        let p: (Double) -> Bool = { $0.isFinite && microVariationRange.contains($0) }
        return Result(gate: name, value: ratio, threshold: "0.6 ... 1.6", pass: p(ratio), predicate: p)
    }

    static func level(reZeroDB d: Double) -> Result {
        let p: (Double) -> Bool = { $0.isFinite && abs($0) <= levelToleranceDB }
        return Result(gate: "level_flat", value: d, threshold: "|d| <= \(levelToleranceDB)", pass: p(d), predicate: p)
    }

    static func fWobble(_ dB: Double) -> Result {
        let p: (Double) -> Bool = { $0.isFinite && $0 <= fWobbleDB }
        return Result(gate: "f_wobble", value: dB, threshold: "<= \(fWobbleDB)", pass: p(dB), predicate: p)
    }

    static func fLevel(reZeroDB d: Double, cents: Float) -> Result {
        let bound = cents < 0 ? fLevelDownDB : fLevelUpDB
        let p: (Double) -> Bool = { $0.isFinite && abs($0) <= bound }
        return Result(gate: "f_level", value: d, threshold: "|d| <= \(bound)", pass: p(d), predicate: p)
    }

    static func fComb(_ r: Double) -> Result {
        let p: (Double) -> Bool = { $0.isFinite && abs($0) < fCombACF }
        return Result(gate: "f_comb", value: r, threshold: "|r| < \(fCombACF)", pass: p(r), predicate: p)
    }

    static func step90(ms: Double?) -> Result {
        let p: (Double) -> Bool = { $0.isFinite && $0 <= step90MS }
        let v = ms ?? .nan
        return Result(gate: "pitch_step_90", value: v, threshold: "<= \(step90MS) ms", pass: p(v), predicate: p)
    }

    /// Attack pitch error on the height trajectory (over the recorded attack `0 .. attackEndFrame/sr`, evaluated at
    /// causal lag `0...10 ms`), gated with the steady F0 tolerance (5 cents). Unmeasured (nil) fails.
    static func attack(rmsCents: Double?) -> Result {
        let p: (Double) -> Bool = { $0.isFinite && $0 <= f0ToleranceCents }
        let v = rmsCents ?? .nan
        return Result(gate: "traj_attack", value: v, threshold: "<= \(f0ToleranceCents) cents", pass: p(v), predicate: p)
    }

    static func trajectoryLag(ms: Double?) -> Result {
        let p: (Double) -> Bool = { $0.isFinite && $0 <= trajectoryLagMS }
        let v = ms ?? .nan
        return Result(gate: "traj_pitch_lag", value: v, threshold: "<= \(trajectoryLagMS) ms", pass: p(v), predicate: p)
    }

    static func clicks(_ name: String, ratio: Double) -> Result {
        let p: (Double) -> Bool = { $0.isFinite && $0 <= clickRatio }
        return Result(gate: name, value: ratio, threshold: "<= \(clickRatio)", pass: p(ratio), predicate: p)
    }
}
