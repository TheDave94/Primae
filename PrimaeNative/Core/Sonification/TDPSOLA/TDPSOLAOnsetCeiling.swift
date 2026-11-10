// TDPSOLAOnsetCeiling.swift
// PrimaeNative
//
// Lane ONSET-CEILING (audit 2026-11-10, protocol r22). Init-time (never on the render thread) ceiling for the
// recorded onset of a phoneme file, at the gain the kernel plays it at.
//
// Why. R17D restores a file's recorded onset after the TDQ pulse limiter ("a recorded onset plays as recorded",
// ONSET.md section 7.3), and AE-2 measures the loudness gain on the LOOP part only. A's onset carries one glottal
// pulse louder than its loop: file peak -4.01 dBFS (file samples 2671-2692, 60.6-61.0 ms), gain +5.92 dB, so the
// kernel played it at +1.91 dBFS: 10 samples over digital full scale on every pen-down from silence, the same at every
// rate (the onset plays at rate 1), and on the iPad's main mixer up to +0.09 dBFS once the pan passes about 0.19.
// Measured offline through these sources (onset-ceiling/REPORT.md): F, I, L, M and the carrier stay below full scale
// at rates 0.8, 1 and 1.25 and the carrier at +-530 and +-1200 cents (peaks x gain: F -1.48, I -10.04, L -10.88,
// M -11.07, carrier -12.00 dBFS), so A's onset pulse is the only sample over it.
//
// What. Only samples whose value x gain exceeds the ceiling are touched. They are grouped (samples closer than two
// tapers form one group); each group gets one smooth gain dip: flat at ceiling / (group peak x gain) across the group,
// raised-cosine tapers of `taper` samples on each side, 1 outside. Overlapping dips take the smaller gain. Every sample
// outside a dip is returned bit for bit; a buffer with nothing over the ceiling is returned unchanged.
//
// Shipped values (A at its gain 1.9767): ceiling -0.5 dBFS at the kernel output (a constant-power pan at full
// deflection passes the kernel level to one channel, so neither channel can exceed it); taper 190 samples (4.3 ms,
// about one pitch period of A at 233 Hz). A's dip spans file samples 2481-2896 (9.4 ms), 2.41 dB deep across
// 2671-2706; nothing else in any study file changes.

import Foundation

nonisolated enum TDPSOLAOnsetCeiling {
    /// Highest output level a recorded onset may reach after the file's loudness gain, dBFS.
    static let ceilingDBFS: Double = -0.5
    /// Length of each raised-cosine taper of the dip, seconds (190 samples at 44.1 kHz: one period of A's 233 Hz).
    static let taperSeconds: Double = 0.0043

    /// `ceilingDBFS` as a linear level (0.94406).
    static var ceiling: Float { Float(pow(10, ceilingDBFS / 20)) }

    /// `taperSeconds` in samples at `sampleRate`.
    static func taperFrames(sampleRate: Double) -> Int { max(1, Int((taperSeconds * sampleRate).rounded())) }

    /// `x` with every sample in `range` whose `|x| * gain` exceeds `ceiling` brought to the ceiling by a smooth local
    /// gain dip (see the file header). Returns `x` itself when nothing in `range` exceeds the ceiling, or `gain` or
    /// `ceiling` is not a positive finite number.
    static func limit(_ x: [Float], gain: Float, ceiling: Float, taper: Int, in range: Range<Int>) -> [Float] {
        guard gain.isFinite, gain > 0, ceiling.isFinite, ceiling > 0, !x.isEmpty else { return x }
        let lo = max(0, range.lowerBound), hi = min(x.count, range.upperBound)
        guard lo < hi else { return x }
        let g = Double(gain), c = Double(ceiling), t = max(1, taper)
        // Groups of over-ceiling samples: [first, last] and the group's peak |x|.
        var groups: [(first: Int, last: Int, peak: Double)] = []
        for i in lo..<hi {
            let v = abs(Double(x[i]))
            guard v * g > c else { continue }
            if let last = groups.last, i - last.last <= 2 * t {
                groups[groups.count - 1] = (last.first, i, max(last.peak, v))
            } else {
                groups.append((i, i, v))
            }
        }
        guard !groups.isEmpty else { return x }
        // The dip's gain per sample (1 = untouched); only the samples it covers are written.
        var env: [Int: Double] = [:]
        for grp in groups {
            // A hair under the exact ratio, so the Float product cannot round back over the ceiling.
            let floor = c / (grp.peak * g) * (1 - 1e-6)
            for i in max(0, grp.first - t)...min(x.count - 1, grp.last + t) {
                let d = i < grp.first ? grp.first - i : (i > grp.last ? i - grp.last : 0)
                let w = d == 0 ? 1 : 0.5 + 0.5 * cos(Double.pi * Double(d) / Double(t + 1))
                let e = 1 - (1 - floor) * w
                env[i] = min(env[i] ?? 1, e)
            }
        }
        var y = x
        for (i, e) in env where e < 1 { y[i] = Float(Double(x[i]) * e) }
        return y
    }
}
