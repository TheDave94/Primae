// PitchScenarios.swift
// PrimaeNativeTests — pitch bake-off harness (BENCH-P 2026-11-23; r31 integer-loop windows, lane BENCH-R31 2026-11-28)
//
// The scenarios of BAKEOFF-PITCH.md section 4.1, for the five study phonemes (A F I L M) at rates 0.5 / 1 / 2:
//   pitch_<c>@<r>            held pitch c in {0, -600, -300, +300, +600} cents; voiced scenarios stay open long enough
//                            for an integer number of whole PLAYED loops >= 1.8 s after 0.6 s settling (the loop
//                            SEAM2 plays, shortened by its crossfade: A 1.546 s, so 1 loop @0.5 ≈ 3.09 s, 2 loops @1
//                            ≈ 3.09 s, 3 loops @2 ≈ 2.32 s; lane BENCHWIN), eliminating partial-loop timbral/jitter bias.
//   step_pitch_<a>to<b>@<r>  pitch step 0 -> +600, 0 -> -600, +600 -> -600 at 1.0 s
//   sweep_pm600_0.75s@<r>    triangle sweep 0 -> +600 (0.75 s) -> -600 (2.25 s) -> 0 (3.0 s)
//   traj_<L>_height          letter's strokes.json at child speed (200 pt/s), 120 Hz writes, r26 height coupling
//   gate_cycle               onset / re-onset scenario at 0 cents, rate 1

import CoreGraphics
import Foundation
@testable import PrimaeNative

enum PitchScenarios {

    /// 0 first: the level-vs-cents and shifted-F0 rows are relative to the 0-cent render of the same candidate and rate.
    static let cents: [Float] = [0, -600, -300, 300, 600]
    static let rates: [Float] = [0.5, 1, 2]
    static let heldSeconds = 2.5          // default open duration (unvoiced / synthetic)
    static let tailSeconds = 0.3
    /// Default analysis region when no voiced loop length is known (unvoiced / synthetic 2.5 s buffers).
    static let heldRegion: (from: Double, to: Double) = (0.6, 2.4)
    /// Minimum voiced held analysis span; actual span rounds UP to an integer number of whole loops at rate `r`.
    static let heldAnalysisMinSeconds = 1.8
    static let stepTime = 1.0
    static let steps: [(from: Float, to: Float)] = [(0, 600), (0, -600), (600, -600)]
    static let sweepSeconds = 3.0
    static let sweepPeak: Float = 600
    static let sweepRiseSeconds = 0.75
    /// The r26 phoneme-arm coupling: both arms, one octave (+-600).
    static let heightCoupling = PitchCoupling(scope: .both, spanCents: 1200)

    static func label(_ v: Float) -> String { BakeoffScenarios.label(v) }
    static func rateLabel(_ r: Float) -> String { String(format: "%g", Double(r)) }

    /// Integer-loop analysis window duration >= 1.8 s for a voiced source at `rate`.
    /// Falls back to `heldRegion.to - heldRegion.from` (1.8 s) when `loopSeconds` is nil.
    static func heldAnalysisDuration(rate r: Float, loopSeconds: Double?) -> Double {
        guard let loop = loopSeconds, loop > 0, r > 0 else { return heldRegion.to - heldRegion.from }
        let oneLoopAtRate = loop / Double(r)
        let k = max(1, Int(ceil(heldAnalysisMinSeconds / oneLoopAtRate)))
        return Double(k) * oneLoopAtRate
    }

    /// The phase-1 triangle: cents at time t (seconds since the gate opened).
    static func sweepCents(_ t: Double) -> Float {
        let s = Double(sweepPeak) / sweepRiseSeconds   // 800 c/s
        if t < sweepRiseSeconds { return Float(s * t) }
        if t < sweepSeconds - sweepRiseSeconds { return Float(Double(sweepPeak) - s * (t - sweepRiseSeconds)) }
        return Float(-Double(sweepPeak) + s * (t - (sweepSeconds - sweepRiseSeconds)))
    }

    static func held(cents c: Float, rate r: Float, loopSeconds: Double? = nil) -> BakeoffScenario {
        let winDur = heldAnalysisDuration(rate: r, loopSeconds: loopSeconds)
        let openSeconds = loopSeconds != nil ? max(heldSeconds, heldRegion.from + winDur + 0.15) : heldSeconds
        return BakeoffScenario(name: "pitch_\(label(c))@\(rateLabel(r))", family: .heldPitch(cents: c, rate: r),
                               duration: openSeconds + tailSeconds,
                               events: [.init(time: 0, kind: .rate(r)), .init(time: 0, kind: .cents(c)),
                                        .init(time: 0, kind: .gate(true)), .init(time: openSeconds, kind: .gate(false))])
    }

    static func step(from a: Float, to b: Float, rate r: Float) -> BakeoffScenario {
        BakeoffScenario(name: "step_pitch_\(label(a))to\(label(b))@\(rateLabel(r))",
                        family: .pitchStepRated(from: a, to: b, at: stepTime, rate: r), duration: stepTime + 1.0,
                        events: [.init(time: 0, kind: .rate(r)), .init(time: 0, kind: .cents(a)),
                                 .init(time: 0, kind: .gate(true)), .init(time: stepTime, kind: .cents(b))])
    }

    static func sweep(rate r: Float, sampleRate: Double) -> BakeoffScenario {
        var events: [BakeoffEvent] = [.init(time: 0, kind: .rate(r)), .init(time: 0, kind: .gate(true))]
        var curve: [(t: Double, v: Double)] = []
        let dt = Double(BakeoffRunner.bufferFrames) / sampleRate
        var k = 0
        while Double(k) * dt < sweepSeconds {
            // Exactly at a buffer start, so it lands before that buffer (as the phase-1 driver set it).
            let t = Double(k * BakeoffRunner.bufferFrames) / sampleRate
            let c = sweepCents(t)
            events.append(.init(time: t, kind: .cents(c)))
            curve.append((t, Double(c)))
            k += 1
        }
        events.append(.init(time: sweepSeconds, kind: .gate(false)))
        return BakeoffScenario(name: "sweep_pm600_0.75s@\(rateLabel(r))", family: .pitchSweep(rate: r, commandedCents: curve),
                               duration: sweepSeconds + tailSeconds, events: events)
    }

    static let gateCycle = BakeoffScenario(
        name: "gate_cycle", family: .gateCycle, duration: 1.5,
        events: [.init(time: 0, kind: .rate(1)), .init(time: 0, kind: .cents(0)),
                 .init(time: BakeoffScenarios.gateOpenTime, kind: .gate(true)),
                 .init(time: 0.55, kind: .gate(false)), .init(time: 0.75, kind: .gate(true)),
                 .init(time: 1.25, kind: .gate(false))])

    /// The pen tracing `letter` at child speed with the r26 height coupling (phoneme arm).
    static func heightTrajectory(letter: String, strokes: LetterStrokes) -> BakeoffScenario {
        let base = BakeoffScenarios.trajectory(letter: letter, strokes: strokes, profile: .steady, drivePitch: false,
                                               centsForY: { y in
            heightCoupling.cents(forNormalizedY: CGFloat(y), arm: .phoneme) ?? 0
        })
        return BakeoffScenario(name: "traj_\(letter)_height", family: base.family, duration: base.duration,
                               events: base.events)
    }

    /// Every pitch scenario for one phoneme source (`letter` drives its own trajectory; `loopSeconds` sizes held runs).
    static func standard(letter: String?, sampleRate: Double, rates: [Float] = PitchScenarios.rates,
                         includeTrajectory: Bool = true, loopSeconds: Double? = nil) throws -> [BakeoffScenario] {
        var out: [BakeoffScenario] = []
        for r in rates {
            for c in cents { out.append(held(cents: c, rate: r, loopSeconds: loopSeconds)) }
            for s in steps { out.append(step(from: s.from, to: s.to, rate: r)) }
            out.append(sweep(rate: r, sampleRate: sampleRate))
        }
        out.append(gateCycle)
        if includeTrajectory, let letter {
            out.append(heightTrajectory(letter: letter, strokes: try BakeoffSources.strokes(letter: letter)))
        }
        return out
    }
}
