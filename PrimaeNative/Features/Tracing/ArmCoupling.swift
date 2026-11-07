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
//   rate   ← point velocity in pt/s (`TouchDispatcher.mapVelocityToSpeed`),
//            or a constant 1.0 when `rateCouplingEnabled` is off (r18)
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
        /// The pen/dot height's pitch offset in cents. Non-nil in the arms
        /// `PitchCoupling.scope` drives: by default (r17) the spatial arm
        /// only; R18DIM slice 2 adds "both" (the phoneme is pitch-shifted
        /// through TD-PSOLA) and "off". The name is kept for the shared
        /// call sites; it no longer implies the spatial arm.
        let spatialPitchCents: Float?
        /// R18 slices 4+5: nil unless a Klang-Dimensionen distance/direction
        /// switch is on (then r17's parameters are unchanged and nothing extra is written).
        let strokeTone: StrokeTone?
        /// R18 slice 6 (Pencil pressure -> loudness): linear output gain, 1 = unchanged (off, a finger, or no force data).
        var pressureGain: Float
        /// R18DIM slice 7: amplitude roughness 0...1 from the pen's dysfluency (0 unless the switch is on).
        var roughness: Float

        init(speed: Float, horizontalBias: Float, spatialPitchCents: Float?, strokeTone: StrokeTone? = nil,
             pressureGain: Float = 1, roughness: Float = 0) {
            self.speed = speed
            self.horizontalBias = horizontalBias
            self.spatialPitchCents = spatialPitchCents
            self.strokeTone = strokeTone
            self.pressureGain = pressureGain
            self.roughness = roughness
        }
    }

    /// The playback rate for a pen/dot velocity. With the r18 "Tempo folgt
    /// dem Stift" switch off it is 1.0 whatever the velocity; used by the
    /// coupling and by the lift's frozen tail, so neither can leak a rate.
    static func speed(forVelocity v: CGFloat, rateCouplingEnabled: Bool) -> Float {
        rateCouplingEnabled ? TouchDispatcher.mapVelocityToSpeed(v) : 1.0
    }

    /// R18 slice 6: the strength of the force -> loudness coupling. A normalised force of 1 plays at full level,
    /// 0+ at `rangeDB` below it, linear in dB between. Tunable at the try-out session (slice 8), then frozen.
    enum PressureLoudness {
        static let rangeDB: Float = 18

        /// `force` is the Pencil's normalised force (`force / maximumPossibleForce`); nil or <= 0 means no force data
        /// (a finger, exactly as `FreeWritePhaseRecorder` reads it) and leaves the level unchanged.
        static func gain(forForce force: CGFloat?, enabled: Bool,
                         rangeDB: Float = PressureLoudness.rangeDB) -> Float {
            guard enabled, let force, force > 0 else { return 1 }
            let f = Float(min(1, max(0, force)))
            return powf(10, -rangeDB * (1 - f) / 20)
        }
    }

    static func parameters(canvasNormalized p: CGPoint,
                           velocity: CGFloat,
                           azimuthBias: CGFloat = 0,
                           panningEnabled: Bool,
                           rateCouplingEnabled: Bool,
                           arm: PilotAudioCondition,
                           pitch: PitchCoupling = .default,
                           strokeTone: StrokeTone? = nil,
                           force: CGFloat? = nil,
                           pressureLoudnessEnabled: Bool = false,
                           pressureRangeDB: Float = PressureLoudness.rangeDB,
                           dysfluency: Float = 0,
                           roughnessEnabled: Bool = false) -> Parameters {
        let speed = speed(forVelocity: velocity, rateCouplingEnabled: rateCouplingEnabled)
        let rawBias = panningEnabled ? (p.x * 2.0 - 1.0) + azimuthBias : 0
        let bias = Float(max(-1.0, min(1.0, rawBias)))
        let cents = pitch.cents(forNormalizedY: p.y, arm: arm)
        let rough: Float = roughnessEnabled && dysfluency.isFinite ? max(0, min(1, dysfluency)) : 0
        return Parameters(speed: speed, horizontalBias: bias, spatialPitchCents: cents, strokeTone: strokeTone,
                          pressureGain: PressureLoudness.gain(forForce: force, enabled: pressureLoudnessEnabled,
                                                              rangeDB: pressureRangeDB),
                          roughness: rough)
    }

    static func apply(_ p: Parameters, to audio: AudioControlling) {
        applyRateAndPan(p, to: audio)
        if let cents = p.spatialPitchCents {
            audio.setSpatialPitch(cents: cents)
        }
        applyStrokeTone(p, to: audio)
        applyPressureGain(p, to: audio)
    }

    /// R18 slices 4+5: level, low-pass and mute for the live voice; a no-op
    /// when both switches are off (`strokeTone == nil`).
    static func applyStrokeTone(_ p: Parameters, to audio: AudioControlling) {
        guard let tone = p.strokeTone else { return }
        audio.setStrokeLevel(gainDB: tone.levelDB)
        audio.setStrokeLowpass(cutoffHz: tone.lowpassHz)
        audio.setStrokeMute(tone.muted)
    }

    /// R18 slice 6. Separate from `applyRateAndPan` so the lift's frozen tail keeps the last level.
    static func applyPressureGain(_ p: Parameters, to audio: AudioControlling) {
        audio.setPressureGain(p.pressureGain)
    }

    /// Rate and pan only. The pen's path writes the spatial pitch
    /// separately, at most once per display frame (ruling B18, 2026-11-02:
    /// a pitch write on every coalesced touch sample was the likely source
    /// of the spatial arm's ~30 ms later onset, AUDIO-4); see
    /// `TouchDispatcher.writeSpatialPitchPerFrame`.
    static func applyRateAndPan(_ p: Parameters, to audio: AudioControlling) {
        audio.setAdaptivePlayback(speed: p.speed, horizontalBias: p.horizontalBias)
        audio.setRoughness(p.roughness)
    }
}
