// EnvgapCandidates.swift — ENVGAP lane candidates + one-item ablations of r31 production (harness only).
import Foundation
@testable import PrimaeNative

nonisolated enum EnvgapCandidates {
    /// One-item ablations of `TDPSOLA2Options.production` (diagnosis only; never a shipping candidate).
    static let ablations: [BakeoffCandidate] = [
        .tdpsola2("abl-noCap", base: .production) { $0.voicedWindowCap = false },
        .tdpsola2("abl-noHN", base: .production) { $0.harmonicNoiseSwap = false },
        .tdpsola2("abl-noGCI", base: .production) { $0.gciSnap = false },
        .tdpsola2("abl-noPD", base: .production) { $0.pulseDensityExponent = 0 },
        .tdpsola2("abl-noLevel", base: .production) { $0.levelCalibration = false },
        .tdpsola2("abl-noAttack", base: .production) { $0.shiftedAttack = false },
    ]
    static let kappaSweep: [BakeoffCandidate] = [0.3, 0.5, 0.7, 0.85].map { k in
        BakeoffCandidate.tdpsola2(String(format: "C2-k%.2f", k), base: .production) { $0.downshiftWindowScale = k }
    }
    static let phaseSweep: [BakeoffCandidate] = [-0.1, -0.05, -0.025, 0.025, 0.05, 0.075, 0.1].map { d in
        BakeoffCandidate.tdpsola2(String(format: "P-%+.3f", d), base: .production) { $0.markPhaseShift = d }
    }
    static let candidates: [BakeoffCandidate] = [
        .tdpsola2("C1-wide", base: .production) { $0.wideUpshiftWindow = true },
        .tdpsola2("C3-xphase", base: .production) { $0.extremumPhaseAlign = true },
        .tdpsola2("C3-xphase-d", base: .production) { $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025 },
        // Lane BENCHWIN2: item 15 (repeated-period donor) alone, and with C3d.
        .tdpsola2("C5-pdonor", base: .production) { $0.repeatedPeriodDonor = true },
        .tdpsola2("C3d-C5", base: .production) {
            $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025; $0.repeatedPeriodDonor = true
        },
        // Lane BENCHWIN4: C3d-C5 + item 9 (wide upshift windows), for M +600 c's shimmer_ratio (the inter-pulse half
        // of each output cycle carries the excess cycle-energy variation when upshift grains are cut to the spacing).
        .tdpsola2("C3d-C5-C1w", base: .production) {
            $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025; $0.repeatedPeriodDonor = true
            $0.wideUpshiftWindow = true
        },
    ]
    /// Lane MCELL: C3d-C5 + item 16 (steeper upshift cross-fade, fraction c) or item 17 (upshift power normalisation,
    /// coherence r), for M +600 c @2's shimmer_ratio without widening the window (item 9).
    static func c3dc5(_ name: String, _ f: @escaping (inout TDPSOLA2Options) -> Void) -> BakeoffCandidate {
        .tdpsola2(name, base: .production) {
            $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025; $0.repeatedPeriodDonor = true; f(&$0)
        }
    }
    static let mcell: [BakeoffCandidate] = [0.25, 0.5, 0.75].map { c in
        c3dc5(String(format: "M16-c%.2f", c)) { $0.upshiftCrossfade = c }
    } + [0, 0.25, 0.5].map { r in
        c3dc5(String(format: "M17-r%.2f", r)) { $0.upshiftPowerCoherence = r }
    } + [0.25, 0.5].map { r in
        c3dc5(String(format: "M17-r%.2f-u450", r)) { $0.upshiftPowerCoherence = r; $0.upshiftMinCents = 450 }
    }
    static let all: [BakeoffCandidate] = ablations + kappaSweep + phaseSweep + candidates + mcell
}
