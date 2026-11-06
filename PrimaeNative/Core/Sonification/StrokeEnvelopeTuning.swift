// StrokeEnvelopeTuning.swift
// PrimaeNative

import Foundation

/// ENV3 (2026-11-05) constants that live in the kernel layer (`LiveSonificationKernel.Ramps.production`), kept beside the envelope's.
nonisolated enum ENV3Tuning {
    /// Glide of a pitch jump (> 300 cents in one command) while a voice sounds, i.e. a spatial stroke that starts far in y
    /// from where the previous one ended inside the lift hold (F's second stroke). Chosen from the sweep in ENV3.md.
    static let pitchGlideSeconds: Double = 0.040
}
