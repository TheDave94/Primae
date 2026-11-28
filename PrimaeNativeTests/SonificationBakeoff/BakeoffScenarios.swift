// BakeoffScenarios.swift
// PrimaeNativeTests — sonification bake-off harness (BENCH lane, 2026-11-02)
//
// A scenario is a timed list of parameter writes (rate, pitch cents, gate)
// applied to a renderer between 256-frame render calls, i.e. the way a
// touch-thread write lands at the next I/O callback.
//
// Families (BAKEOFF.md / the BENCH brief):
//   rate_<r>         fixed rate r in {0.5, 0.75, 1, 1.5, 2}, pitch 0
//   pitch_<c>        carrier only: fixed cents in {-1200, -700, 0, +700, +1200}, rate 1
//   step_rate_<a>to<b>   rate step at 0.6 s (phonemes + carrier)
//   step_pitch_0to<c>    carrier only: pitch step at 0.6 s
//   gate_cycle       open / close / reopen / close, rate 1
//   traj_<L>_<profile>   real-trajectory drive from the letter's strokes.json
//                    at child speed, parameters written at 120 Hz
//
// Trajectories reproduce the app's mapping, not an approximation of it:
// velocity (pt/s) -> EMA with TouchDispatcher's alpha 0.22 ->
// `TouchDispatcher.mapVelocityToSpeed`; height ->
// `SpatialSonification.pitchCents(forNormalizedY:)` (carrier only; the
// phoneme arm gets no pitch drive, ArmCoupling). Two stated
// approximations: the letter's normalised y stands in for the canvas's
// normalised y (the glyph box fills ~the canvas height), and the letter is
// drawn in a 600 pt box (a 13-inch canvas, ~70 % fill). The playback
// activation threshold and the B17/B18 lift/throttle refinements are not
// modelled: the gate opens at the stroke's first sample.

import CoreGraphics
import Foundation
@testable import PrimaeNative

struct BakeoffEvent {
    enum Kind { case rate(Float), cents(Float), gate(Bool) }
    let time: Double
    let kind: Kind
}

struct BakeoffScenario {
    enum Family {
        case fixedRate(Float)
        case fixedPitch(Float)
        case rateStep(from: Float, to: Float, at: Double)
        case pitchStep(to: Float, at: Double)
        case gateCycle
        case trajectory(letter: String, profile: String, commandedRate: [(t: Double, v: Double)],
                        commandedCents: [(t: Double, v: Double)])
        // Pitch bake-off, phase 2 (PitchScenarios).
        case heldPitch(cents: Float, rate: Float)
        case pitchStepRated(from: Float, to: Float, at: Double, rate: Float)
        case pitchSweep(rate: Float, commandedCents: [(t: Double, v: Double)])
    }
    let name: String
    let family: Family
    let duration: Double
    let events: [BakeoffEvent]

    /// Gate-open intervals (seconds) implied by the events.
    var openIntervals: [(open: Double, close: Double)] {
        var out: [(Double, Double)] = []
        var openAt: Double?
        for e in events {
            if case .gate(let g) = e.kind {
                if g, openAt == nil { openAt = e.time }
                if !g, let o = openAt { out.append((o, e.time)); openAt = nil }
            }
        }
        if let o = openAt { out.append((o, duration)) }
        return out
    }
}

enum BakeoffScenarios {

    static let gateOpenTime = 0.05
    static let fixedRates: [Float] = [0.5, 0.75, 1, 1.5, 2]
    static let carrierCents: [Float] = [-1200, -700, 0, 700, 1200]
    static let stepTime = 0.6

    static func standard(for source: BakeoffSource, includeTrajectories: Bool,
                         trajectoryLetters: [String]) throws -> [BakeoffScenario] {
        var out: [BakeoffScenario] = []
        let loopSeconds = Double(source.samples.count) / source.sampleRate
        for r in fixedRates {
            // At least ~1.6 output loops (a seam inside the render) and 1.5 s.
            let d = gateOpenTime + max(1.5, min(8, 1.6 * loopSeconds / Double(r)))
            out.append(BakeoffScenario(name: "rate_\(label(r))", family: .fixedRate(r), duration: d,
                                       events: [.init(time: 0, kind: .rate(r)), .init(time: 0, kind: .cents(0)),
                                                .init(time: gateOpenTime, kind: .gate(true))]))
        }
        if source.kind == .carrier {
            for c in carrierCents {
                out.append(BakeoffScenario(name: "pitch_\(label(c))", family: .fixedPitch(c), duration: 1.5,
                                           events: [.init(time: 0, kind: .rate(1)), .init(time: 0, kind: .cents(c)),
                                                    .init(time: gateOpenTime, kind: .gate(true))]))
            }
            for c: Float in [700, -700] {
                out.append(BakeoffScenario(name: "step_pitch_0to\(label(c))", family: .pitchStep(to: c, at: stepTime),
                                           duration: stepTime + 0.9,
                                           events: [.init(time: 0, kind: .rate(1)), .init(time: 0, kind: .cents(0)),
                                                    .init(time: gateOpenTime, kind: .gate(true)),
                                                    .init(time: stepTime, kind: .cents(c))]))
            }
        }
        for (a, b): (Float, Float) in [(1, 2), (1, 0.5)] {
            out.append(BakeoffScenario(name: "step_rate_\(label(a))to\(label(b))",
                                       family: .rateStep(from: a, to: b, at: stepTime), duration: stepTime + 0.9,
                                       events: [.init(time: 0, kind: .rate(a)), .init(time: 0, kind: .cents(0)),
                                                .init(time: gateOpenTime, kind: .gate(true)),
                                                .init(time: stepTime, kind: .rate(b))]))
        }
        out.append(BakeoffScenario(name: "gate_cycle", family: .gateCycle, duration: 1.5,
                                   events: [.init(time: 0, kind: .rate(1)), .init(time: 0, kind: .cents(0)),
                                            .init(time: gateOpenTime, kind: .gate(true)),
                                            .init(time: 0.55, kind: .gate(false)),
                                            .init(time: 0.75, kind: .gate(true)),
                                            .init(time: 1.25, kind: .gate(false))]))
        if includeTrajectories {
            let letters: [String] = source.kind == .carrier ? trajectoryLetters : [source.letter].compactMap { $0 }
            for letter in letters {
                let strokes = try BakeoffSources.strokes(letter: letter)
                for profile in SpeedProfile.allCases {
                    out.append(trajectory(letter: letter, strokes: strokes, profile: profile,
                                          drivePitch: source.kind == .carrier))
                }
            }
        }
        return out
    }

    /// "0.5", "1", "2" for rates; "+700", "-1200", "0" for cents (>= 100 in magnitude).
    static func label(_ v: Float) -> String {
        abs(v) >= 100 ? String(format: "%+d", Int(v)) : String(format: "%g", Double(v))
    }

    // MARK: - Trajectories

    enum SpeedProfile: String, CaseIterable {
        /// LetterTracer.childSpeed: a slow, steady 200 pt/s.
        case steady
        /// Child-like: each stroke starts slow (50 pt/s) and swings
        /// 50...350 pt/s with a 0.8 s period (accelerate, decelerate).
        case varying

        func speed(at t: Double) -> Double {
            switch self {
            case .steady: return 200
            case .varying: return 200 * (1 + 0.75 * sin(2 * .pi * t / 0.8 - .pi / 2))
            }
        }
    }

    static let letterBoxPoints: Double = 600
    static let parameterRate: Double = 120
    static let penUpSeconds = 0.3
    static let velocityAlpha: Double = 0.22

    /// `centsForY` (pitch phase 2): the height -> cents mapping to drive (normalised y, 0 = top); nil = the r17
    /// rule (the carrier's two-octave mapping when `drivePitch`, else 0).
    static func trajectory(letter: String, strokes: LetterStrokes, profile: SpeedProfile,
                           drivePitch: Bool, centsForY: ((Double) -> Float)? = nil) -> BakeoffScenario {
        var events: [BakeoffEvent] = []
        var rateCurve: [(t: Double, v: Double)] = []
        var centsCurve: [(t: Double, v: Double)] = []
        var t = gateOpenTime
        let dt = 1 / parameterRate
        for stroke in strokes.strokes {
            let pts = stroke.checkpoints.map { CGPoint(x: $0.x * letterBoxPoints, y: $0.y * letterBoxPoints) }
            guard pts.count >= 2 else { continue }
            var cum: [Double] = [0]
            for i in 1..<pts.count { cum.append(cum[i - 1] + Double(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))) }
            let total = cum.last!
            func point(at s: Double) -> CGPoint {
                let s = min(max(0, s), total)
                var i = 1
                while i < cum.count - 1 && cum[i] < s { i += 1 }
                let seg = cum[i] - cum[i - 1]
                let f = seg > 0 ? (s - cum[i - 1]) / seg : 0
                return CGPoint(x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f,
                               y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * f)
            }
            var s = 0.0, local = 0.0
            var prev = point(at: 0)
            var smoothed = 0.0
            var first = true
            while s < total {
                s += profile.speed(at: local) * dt
                local += dt
                let p = point(at: s)
                let v = Double(hypot(p.x - prev.x, p.y - prev.y)) / dt
                smoothed = first ? v : smoothed + velocityAlpha * (v - smoothed)
                prev = p
                let rate = TouchDispatcher.mapVelocityToSpeed(CGFloat(smoothed))
                let cents = centsForY.map { $0(Double(p.y / letterBoxPoints)) }
                    ?? (drivePitch ? SpatialSonification.pitchCents(forNormalizedY: p.y / letterBoxPoints) : 0)
                events.append(.init(time: t, kind: .rate(rate)))
                events.append(.init(time: t, kind: .cents(cents)))
                rateCurve.append((t, Double(rate)))
                centsCurve.append((t, Double(cents)))
                if first { events.append(.init(time: t, kind: .gate(true))); first = false }
                t += dt
            }
            events.append(.init(time: t, kind: .gate(false)))
            t += penUpSeconds
        }
        return BakeoffScenario(name: "traj_\(letter)_\(profile.rawValue)",
                               family: .trajectory(letter: letter, profile: profile.rawValue,
                                                   commandedRate: rateCurve, commandedCents: centsCurve),
                               duration: t + 0.05, events: events)
    }

    /// Piecewise-constant lookup of a commanded curve (the value written last at or before `t`).
    static func commanded(_ curve: [(t: Double, v: Double)], at t: Double) -> Double {
        guard !curve.isEmpty else { return 0 }
        var lo = 0, hi = curve.count - 1
        if t < curve[0].t { return curve[0].v }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if curve[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return curve[lo].v
    }
}
