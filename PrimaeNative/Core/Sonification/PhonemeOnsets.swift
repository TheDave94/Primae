// PhonemeOnsets.swift
// PrimaeNative
//
// R17D (RULINGS 2026-11-05 "phoneme onset + loop", 2026-11-06 "rate decisions
// delegated"): every study phoneme file is now ONSET + LOOP. The file starts
// with the recording's own onset (a one-shot part that plays once, as
// recorded, at rate 1), crossfades into the loop material, and from the
// attack end on is the sustained part the renderer loops.
//
// The attack end cannot be found from the samples: the renderer's own rule
// (first 10 ms frame within -3 dB of the median level, TDPSOLAAnalysis) ends
// inside the onset's rise. So each file's attack end is declared here, beside
// the assets, in samples at 44.1 kHz from the file start. The values are the
// ones the files were built with (onset/ONSET.md section 4: A, I, L, M;
// floop/FLOOP.md section 2: F = F_ONSET1 + L5) and are pinned to the files'
// sha256 by `PhonemeOnsetTests`, so a new recording cannot ship with a stale
// hint.
//
// What the hint drives (ONSET.md section 7):
//   - TDPSOLAAnalysis: the loop starts at the first pitch mark (voiced) or
//     sample (unvoiced) at or after it; everything before plays once.
//   - TDPSOLA init: the TDQ pulse limiter leaves the onset as recorded, and the
//     ENV3 pre-blend into the loop start is `preBlendPeriods` long (the last
//     half of the onset, at most 100 ms, in pitch periods) instead of 2.
//   - AE-2 loudness: the steady level is measured on the loop part only (an
//     onset louder than the loop would otherwise turn the whole file down).
// A file without an entry (the spatial carrier, any non-study file) is
// unchanged: the renderer's own attack rule, pre-blend 2, whole-file loudness.

import Foundation

/// A recorded onset at the start of a phoneme file.
nonisolated struct RecordedOnset: Sendable, Equatable {
    /// End of the onset = start of the loop part, in samples at 44.1 kHz from the file start.
    let attackEndFrame: Int
    /// ENV3 pre-blend length into the loop start, in pitch periods (voiced files only).
    let preBlendPeriods: Int
}

nonisolated enum PhonemeOnsets {
    /// File name -> its recorded onset. Values from the lanes' build logs
    /// (`onset/logs/build.json`, `floop/logs/build.json`); pre-blend from ONSET.md section 5.
    static let table: [String: RecordedOnset] = [
        "A_phoneme1.wav": RecordedOnset(attackEndFrame: 18601, preBlendPeriods: 23),
        "F_phoneme1.wav": RecordedOnset(attackEndFrame: 7887, preBlendPeriods: 2),
        "I_phoneme1.wav": RecordedOnset(attackEndFrame: 4250, preBlendPeriods: 12),
        "L_phoneme1.wav": RecordedOnset(attackEndFrame: 5800, preBlendPeriods: 16),
        "M_phoneme1.wav": RecordedOnset(attackEndFrame: 6737, preBlendPeriods: 17),
    ]

    /// The recorded onset of the file named `fileName` (last path component), nil when it has none.
    static func onset(forFileNamed fileName: String) -> RecordedOnset? { table[fileName] }
}
