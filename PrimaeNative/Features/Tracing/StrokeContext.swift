// StrokeContext.swift
// PrimaeNative
//
// R18 slices 4 and 5 (sonification dimensions): what the sound may know about
// WHERE the pen is relative to the reference letter, and WHICH WAY it moves.
//
//   distance  -> darker and quieter sound   (switch `distanceToneEnabled`)
//   direction -> mute when moving backwards (switch `directionMuteEnabled`)
//
// Both read only geometry that is already public: `StrokeTracker.definition`
// (the checkpoint polylines in cell fractions, radius in cell-height units),
// `radiusMultiplier` and `soundGateRadiusFactor`. StrokeTracker.swift is not
// touched. The functions here are pure so the mapping is tested at seam A
// without a view model; `TracingViewModel.strokeToneParameters` and the
// pen's `StrokeMovementTracker` feed them.

import CoreGraphics
import Foundation

/// The output of the two dimensions for the live voice. `nil` in
/// `ArmCoupling.Parameters` = neither switch is on = r17 (nothing is written).
struct StrokeTone: Equatable, Sendable {
    /// The low-pass value that means "no filter" (the kernel skips the stage).
    static let bypassHz: Float = LiveSonificationKernel.toneBypassHz
    /// Distance dimension: at the gate edge (1 gate radius) and beyond.
    static let farLevelDB: Float = -12
    static let farCutoffHz: Float = 800
    /// Direction dimension: the movement/stroke cosine below which the pen is
    /// "going backwards". -0.25 = more than ~105 degrees against the stroke;
    /// a sideways wobble (cosine near 0) stays audible.
    static let backwardCosine: Float = -0.25
    /// Pen travel (in gate radii) that makes a movement direction; shorter
    /// steps keep the previous direction (sample jitter is not a reversal).
    static let minimumStepGateRadii: CGFloat = 0.1

    var levelDB: Float = 0
    var lowpassHz: Float = bypassHz
    var muted: Bool = false

    static let neutral = StrokeTone()

    /// The pure mapping. `context == nil` (no reference geometry, or free
    /// writing where the letter is no mask) gives the neutral tone.
    static func make(context: StrokeContext?, distanceEnabled: Bool, directionEnabled: Bool,
                     distanceFarLevelDB: Float = StrokeTone.farLevelDB,
                     distanceFarCutoffHz: Float = StrokeTone.farCutoffHz,
                     directionBackwardCosine: Float = StrokeTone.backwardCosine) -> StrokeTone? {
        guard distanceEnabled || directionEnabled else { return nil }
        guard let context else { return .neutral }
        var tone = StrokeTone()
        if distanceEnabled {
            let t = min(1, max(0, context.normalizedDistance))
            tone.levelDB = distanceFarLevelDB * t
            // Log-interpolated: equal steps in octaves, bypass exactly on the stroke.
            tone.lowpassHz = t == 0 ? bypassHz
                : exp(log(bypassHz) + (log(distanceFarCutoffHz) - log(bypassHz)) * t)
        }
        if directionEnabled, context.normalizedDistance <= 1,
           let c = context.directionCosine, c < directionBackwardCosine {
            tone.muted = true
        }
        return tone
    }
}

struct StrokeContext: Equatable, Sendable {
    /// Distance to the nearest reference stroke in units of the sound-gate
    /// radius (0 = on the stroke, 1 = at the gate's edge).
    let normalizedDistance: Float
    /// Cosine between the pen's movement and the nearest stroke's direction
    /// of writing (+1 forwards, -1 backwards); nil without a movement.
    let directionCosine: Float?

    /// - point/movement: cell fractions (the tracker's frame); `movement` is
    ///   the displacement over the last real step, nil if there is none.
    /// - aspect: cell width / height. Distances are in cell-height units on
    ///   both axes, exactly as `StrokeTracker.update` measures them.
    /// - gateRadius: `checkpointRadius * radiusMultiplier * soundGateRadiusFactor`.
    static func measure(point p: CGPoint, movement: CGVector?, aspect: CGFloat,
                        definition: LetterStrokes, gateRadius: CGFloat) -> StrokeContext? {
        guard gateRadius > 0, gateRadius.isFinite, p.x.isFinite, p.y.isFinite else { return nil }
        let k: CGFloat = (aspect.isFinite && aspect > 0) ? aspect : 1
        let px = p.x * k, py = p.y
        var best = CGFloat.greatestFiniteMagnitude
        var tangent: (CGFloat, CGFloat)?
        for stroke in definition.strokes {
            let cps = stroke.checkpoints
            guard !cps.isEmpty else { continue }
            if cps.count == 1 {
                let d = hypot(px - cps[0].x * k, py - cps[0].y)
                if d < best { best = d; tangent = nil }
                continue
            }
            for i in 0..<(cps.count - 1) {
                let ax = cps[i].x * k, ay = cps[i].y
                let bx = cps[i + 1].x * k, by = cps[i + 1].y
                let vx = bx - ax, vy = by - ay
                let len2 = vx * vx + vy * vy
                let t = len2 > 0 ? min(1, max(0, ((px - ax) * vx + (py - ay) * vy) / len2)) : 0
                let d = hypot(px - (ax + t * vx), py - (ay + t * vy))
                if d < best {
                    best = d
                    // Direction of writing over a short chord around the segment (smooths a jittery pair).
                    let lo = max(0, i - 1), hi = min(cps.count - 1, i + 2)
                    tangent = ((cps[hi].x - cps[lo].x) * k, cps[hi].y - cps[lo].y)
                }
            }
        }
        guard best.isFinite, best < CGFloat.greatestFiniteMagnitude else { return nil }
        var cosine: Float?
        if let m = movement, let t = tangent {
            let mx = m.dx * k, my = m.dy
            let ml = hypot(mx, my), tl = hypot(t.0, t.1)
            if ml > 1e-9, tl > 1e-9 { cosine = Float((mx * t.0 + my * t.1) / (ml * tl)) }
        }
        return StrokeContext(normalizedDistance: Float(best / gateRadius), directionCosine: cosine)
    }
}

/// The pen's movement direction across samples: the displacement since the
/// anchor once it is at least `minimumStepGateRadii` long, else the last one.
struct StrokeMovementTracker: Equatable, Sendable {
    private var anchor: CGPoint?
    private var last: CGVector?

    mutating func reset() { anchor = nil; last = nil }

    mutating func movement(to p: CGPoint, aspect: CGFloat, gateRadius: CGFloat) -> CGVector? {
        guard let a = anchor else { anchor = p; return nil }
        let k: CGFloat = (aspect.isFinite && aspect > 0) ? aspect : 1
        let dx = p.x - a.x, dy = p.y - a.y
        if hypot(dx * k, dy) >= StrokeTone.minimumStepGateRadii * gateRadius {
            last = CGVector(dx: dx, dy: dy)
            anchor = p
        }
        return last
    }
}

extension TracingViewModel {
    /// The stroke tone for a point in cell fractions (nil when both switches
    /// are off). Free writing has no mask (r6) and no reference to be near:
    /// neutral there, as without reference geometry.
    func strokeToneParameters(cellPoint p: CGPoint, movement: CGVector?) -> StrokeTone? {
        guard distanceToneEnabled || directionMuteEnabled else { return nil }
        let tracker = strokeTracker
        let frame = grid.activeCell.frame
        let aspect: CGFloat = frame.width > 0 && frame.height > 0 ? frame.width / frame.height : 1
        var context: StrokeContext?
        if phaseController.currentPhase != .freeWrite, let definition = tracker.definition {
            context = StrokeContext.measure(point: p, movement: movement, aspect: aspect, definition: definition,
                                            gateRadius: strokeGateRadius())
        }
        return StrokeTone.make(context: context, distanceEnabled: distanceToneEnabled,
                               directionEnabled: directionMuteEnabled,
                               distanceFarLevelDB: Float(distanceToneFarLevelDB),
                               distanceFarCutoffHz: Float(distanceToneFarCutoffHz),
                               directionBackwardCosine: Float(directionMuteBackwardCosine))
    }

    /// The sound gate's radius in cell-height units (what `isNearStroke` tests).
    func strokeGateRadius() -> CGFloat {
        let t = strokeTracker
        return (t.definition?.checkpointRadius ?? 0) * t.radiusMultiplier * t.soundGateRadiusFactor
    }
}
