// HashFlags.swift — the ENVGAP flags spelled out at their OFF values (must hash as the pre-ENVGAP production), and ON
// (must differ: the identity is not vacuous). Compiled only against the modified TDPSOLA2.
@testable import PrimaeNative
nonisolated enum EnvgapHash {
    static func prod(_ f: (inout TDPSOLA2Options) -> Void) -> TDPSOLA2Options { var o = TDPSOLA2Options.production; f(&o); return o }
    static let offVariants: [(String, TDPSOLA2Options)] = [
        ("production-flags-off", prod { $0.wideUpshiftWindow = false; $0.downshiftWindowScale = 1; $0.markPhaseShift = 0
                                        $0.extremumPhaseAlign = false; $0.extremumPhaseMinOffset = 0.025 }),
        ("production-guard-only", prod { $0.extremumPhaseMinOffset = 0.025 }),
        ("production-envgapA-off", prod { $0.seamAlignLag = 0; $0.seamAlignSlope = 0.004; $0.seamAlignFade = 0.25
                                          $0.seamCrossfadeSeconds = 0 }),
        ("production-envgapA-params-only", prod { $0.seamAlignSlope = 0.008; $0.seamAlignFade = 0.1 }),
        ("ON-item13-align", prod { $0.seamAlignLag = 0.5 }),
        ("ON-item14-xf0.2", prod { $0.seamCrossfadeSeconds = 0.2 }),
        ("ON-item9-wide", prod { $0.wideUpshiftWindow = true }),
        ("ON-item10-k0.85", prod { $0.downshiftWindowScale = 0.85 }),
        ("ON-item11-xphase", prod { $0.extremumPhaseAlign = true }),
        ("ON-probe-0.05", prod { $0.markPhaseShift = 0.05 }),
        // Lane MCELL: items 16-17 at their OFF values (and the threshold alone) hash as production; ON must differ.
        ("production-mcell-off", prod { $0.upshiftCrossfade = 1; $0.upshiftPowerCoherence = -1; $0.upshiftMinCents = 0 }),
        ("production-mcell-min-only", prod { $0.upshiftMinCents = 300 }),
        ("ON-item16-c0.5", prod { $0.upshiftCrossfade = 0.5 }),
        ("ON-item17-r0.25", prod { $0.upshiftPowerCoherence = 0.25 }),
        // Lane BENCHM17: item 15 OFF hashes as production, ON differs; the two R33 candidates as the harness builds them.
        ("production-item15-off", prod { $0.repeatedPeriodDonor = false }),
        ("ON-item15-pdonor", prod { $0.repeatedPeriodDonor = true }),
        ("ON-C3d-C5", prod { $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025; $0.repeatedPeriodDonor = true }),
        ("ON-C3d-C5-M17", prod { $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025; $0.repeatedPeriodDonor = true
                                 $0.upshiftPowerCoherence = 0.25; $0.upshiftMinCents = 450 }),
    ]
    /// Lane BENCHM17: the R33 candidates for the listening-cell hashes (`listenMode`).
    static let listenVariants: [(String, TDPSOLA2Options)] = [
        ("C3d-C5", prod { $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025; $0.repeatedPeriodDonor = true }),
        ("C3d-C5-M17", prod { $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025; $0.repeatedPeriodDonor = true
                              $0.upshiftPowerCoherence = 0.25; $0.upshiftMinCents = 450 }),
    ]
}
