// PitchCoupling.swift
// PrimaeNative
//
// R18DIM slice 2 (2026-11-06): "height -> pitch" as a proctor switch with
// three states and a shared range. Before r18 the pen's height drove the
// carrier's pitch in the SPATIAL arm only, over a fixed 220-880 Hz span. Now
// the proctor chooses the scope (off / spatial arm only / both sound arms)
// and the span, and both arms are driven through the same `ArmCoupling`
// mapping, so the pen and the observe dot agree.
//
// DEFAULT = r17 EXACTLY: scope `.spatialOnly`, span 2400 cents (two octaves,
// +-1200 around the source's own pitch = 220-880 Hz for the 440 Hz carrier).
//
// "Both arms" pitch-shifts the PHONEME through the live kernel's TD-PSOLA
// path (`LiveSonificationKernel.setPitchCents`, 0.5x-2x, clamped to +-1200
// cents). The offset is relative to the recording's own pitch, so the span is
// in cents, not Hz; a narrower span keeps a shifted phoneme recognisable.

import CoreGraphics
import Foundation

enum PitchScope: String, CaseIterable, Equatable {
    case off
    case spatialOnly
    case both

    /// Whether the pen's height drives pitch in `arm`.
    func applies(to arm: PilotAudioCondition) -> Bool {
        switch self {
        case .off: return false
        case .spatialOnly: return arm == .spatial
        case .both: return arm == .spatial || arm == .phoneme
        }
    }
}

struct PitchCoupling: Equatable {
    /// The r17 span: two octaves, 220-880 Hz around a 440 Hz source.
    static let defaultSpanCents = 2400
    /// Narrowest / widest span a proctor can store (half an octave .. two octaves).
    static let spanRange = 600...2400

    var scope: PitchScope = .spatialOnly
    var spanCents: Int = PitchCoupling.defaultSpanCents

    static let `default` = PitchCoupling()

    static func clampedSpan(_ cents: Int) -> Int {
        max(spanRange.lowerBound, min(spanRange.upperBound, cents))
    }

    /// Cents offset for the pen at normalized height `y` (0 = top), or nil
    /// when the scope does not drive `arm`. At the default span this is
    /// exactly `SpatialSonification.pitchCents(forNormalizedY:)`.
    func cents(forNormalizedY y: CGFloat, arm: PilotAudioCondition) -> Float? {
        guard scope.applies(to: arm) else { return nil }
        return SpatialSonification.pitchCents(forNormalizedY: y, spanCents: Self.clampedSpan(spanCents))
    }
}
