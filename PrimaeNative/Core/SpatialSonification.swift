// SpatialSonification.swift
// PrimaeNative
//
// Constants + pure mapping for the pilot's spatial-2D-sonification arm
// (`PilotAudioCondition.spatial`): as the pen traces, vertical canvas
// position drives the carrier tone's PITCH and horizontal position
// drives stereo PAN (pan is the pre-existing shared coupling in
// TouchDispatcher.updateAdaptivePlayback — this file only owns the
// pitch axis and the carrier asset reference). Headphone delivery;
// from r14 a session runs only with a headphone route (every arm from
// r16), and the proctor sees a stop screen without one.
//
// Pitch mapping (David's acoustics spec, decided 2026-07-06):
//   range 220–880 Hz (A3–A5, two octaves), TOP of canvas = 880 Hz,
//   bottom = 220 Hz, CONTINUOUS glide (not quantized), LINEAR-IN-CENTS
//   so equal screen distance = equal perceived pitch change. The
//   carrier is authored at 440 Hz (the geometric mean), so the cents
//   offset spans exactly ±1200 — half the AVAudioUnitTimePitch ±2400
//   range, comfortable headroom.
// That was the r1-r25 study mapping. From R18DIM the span is a proctor
// setting (`PitchCoupling`; scope off / spatial only / both sound arms),
// and from protocol r26 the study default is 1200 cents (±600, about
// 311–622 Hz for the carrier) applied in BOTH sound arms. The engine is
// the live TDPSOLA kernel from r17 (clamp ±1200), not AVAudioUnitTimePitch.

import CoreGraphics
import Foundation

enum SpatialSonification {
    /// Seamlessly-looped neutral carrier: band-limited triangle,
    /// 440 Hz, mono 44.1 kHz, integer cycle count (gapless WAV — MP3
    /// encoder padding would click at the loop seam). Steady, no
    /// vibrato: triangle over sine because the richer odd-harmonic
    /// series makes the pitch glide easier to track for children.
    /// Path shape matches the letter-audio convention (bundle-root
    /// relative, resolved by `PrimaeBundle.audioURL(for:)`).
    static let carrierToneFile = "Resources/Sonification/spatial_carrier.wav"

    /// Where the carrier resolves, or `nil` when it is not bundled.
    ///
    /// Through the engine's own lookup, `PrimaeBundle.audioURL(for:)`. It
    /// used to be a hand-rolled copy of the engine's `[Bundle.main,
    /// Bundle.module]` loop, so the precondition and the engine could
    /// disagree about where the file is, and `Bundle.module`'s
    /// `fatalError`-on-unresolved accessor sat on the study-startup path.
    /// Its missing case is a `nil` return, never a trap.
    ///
    /// The spatial arm's stimulus AND its demonstration are this one file;
    /// the engine only logs a warning when it is missing, so a study
    /// session checks it up front (ruling C1-6, 2026-09-05).
    static func carrierToneURL() -> URL? {
        PrimaeBundle.audioURL(for: carrierToneFile)
    }

    /// Authored frequency of the carrier file, Hz. Pitch offsets are
    /// cents relative to this.
    static let carrierBaseHz: Double = 440

    /// Full mapped span in cents: two octaves, 220–880 Hz.
    static let centsSpan: Float = 2400

    /// Normalized canvas Y (0 = top, UIKit convention) → cents offset
    /// from the 440 Hz carrier. Top = +1200 (880 Hz), mid = 0, bottom
    /// = −1200 (220 Hz). Linear in cents; input clamped to [0, 1].
    static func pitchCents(forNormalizedY y: CGFloat) -> Float {
        let clamped = max(0.0, min(1.0, y))
        return Float(1200.0 - 2400.0 * clamped)
    }

    /// R18DIM: the same mapping over a narrower span (`PitchCoupling`),
    /// centred on 0: top = +span/2, bottom = -span/2. At 2400 this is the
    /// function above, value for value.
    static func pitchCents(forNormalizedY y: CGFloat, spanCents: Int) -> Float {
        if spanCents == Int(centsSpan) { return pitchCents(forNormalizedY: y) }
        let clamped = max(0.0, min(1.0, y))
        let half = Double(spanCents) / 2
        return Float(half - Double(spanCents) * clamped)
    }
}
