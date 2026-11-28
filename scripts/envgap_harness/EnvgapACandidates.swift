// EnvgapACandidates.swift — lane ENVGAP-A loop-preparation candidates (items 13-14, harness only).
import Foundation
@testable import PrimaeNative

nonisolated enum EnvgapACandidates {
    /// The ENVGAP-A presets (name -> edit of `TDPSOLA2Options.production`).
    static let presets: [(String, @Sendable (inout TDPSOLA2Options) -> Void)] = [
        ("C14-xf0.2", { $0.seamCrossfadeSeconds = 0.2 }),
        ("C14-xf0.1", { $0.seamCrossfadeSeconds = 0.1 }),
        ("C13+14-xf0.2", { $0.seamCrossfadeSeconds = 0.2; $0.seamAlignLag = 0.5 }),
        ("C13-align0.5", { $0.seamAlignLag = 0.5 }),
        // With ENVGAP's item 11 I fix (C3-xphase-d), which these items do not replace.
        ("C3d+14-xf0.2", { $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025; $0.seamCrossfadeSeconds = 0.2 }),
        ("C3d+13+14-xf0.2", { $0.extremumPhaseAlign = true; $0.extremumPhaseMinOffset = 0.025
                              $0.seamCrossfadeSeconds = 0.2; $0.seamAlignLag = 0.5 }),
    ]
    /// Applies the named preset to `o` ("production" or unknown = unchanged).
    static func apply(_ name: String, to o: inout TDPSOLA2Options) {
        presets.first { $0.0 == name }?.1(&o)
    }
    static let all: [BakeoffCandidate] = presets.map { p in BakeoffCandidate.tdpsola2(p.0, base: .production, p.1) }
}
