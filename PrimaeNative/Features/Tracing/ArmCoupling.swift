// ArmCoupling.swift
// PrimaeNative
//
// THE ONE MAPPING from a moving point to the sound arms' coupling
// parameters — used by the child's pen (`TouchDispatcher`) AND by the
// observe animation's dot (`TracingViewModel.handleGuideFrame`), so the two
// cannot drift (ruling 2026-10-05, D9 reversal; David: "When the letter
// drawing is shown the audio is not tracked like it is when I draw the
// letter myself.").
//
//   rate   ← point velocity in pt/s (`TouchDispatcher.mapVelocityToSpeed`)
//   pan    ← canvas x, when `panningEnabled` (plus the Pencil azimuth bias)
//   pitch  ← canvas y, SPATIAL ARM ONLY (`SpatialSonification.pitchCents`)
//
// The phoneme arm never gets a pitch drive, exactly as before: the arms are
// matched on rate + pan and differ in pitch-drive + sound identity (§2.6).

import CoreGraphics

enum ArmCoupling {
    struct Parameters: Equatable {
        let speed: Float
        let horizontalBias: Float
        /// Non-nil only in the spatial arm.
        let spatialPitchCents: Float?
    }

    static func parameters(canvasNormalized p: CGPoint,
                           velocity: CGFloat,
                           azimuthBias: CGFloat = 0,
                           panningEnabled: Bool,
                           arm: PilotAudioCondition) -> Parameters {
        let speed = TouchDispatcher.mapVelocityToSpeed(velocity)
        let rawBias = panningEnabled ? (p.x * 2.0 - 1.0) + azimuthBias : 0
        let bias = Float(max(-1.0, min(1.0, rawBias)))
        let cents = arm == .spatial ? SpatialSonification.pitchCents(forNormalizedY: p.y) : nil
        return Parameters(speed: speed, horizontalBias: bias, spatialPitchCents: cents)
    }

    static func apply(_ p: Parameters, to audio: AudioControlling) {
        applyRateAndPan(p, to: audio)
        if let cents = p.spatialPitchCents {
            audio.setSpatialPitch(cents: cents)
        }
    }

    /// Rate and pan only. The pen's path writes the spatial pitch
    /// separately, at most once per display frame (ruling B18, 2026-11-02:
    /// a pitch write on every coalesced touch sample was the likely source
    /// of the spatial arm's ~30 ms later onset, AUDIO-4); see
    /// `TouchDispatcher.writeSpatialPitchPerFrame`.
    static func applyRateAndPan(_ p: Parameters, to audio: AudioControlling) {
        audio.setAdaptivePlayback(speed: p.speed, horizontalBias: p.horizontalBias)
    }
}
