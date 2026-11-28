// BakeoffCandidates.swift
// PrimaeNativeTests — sonification bake-off harness (r17, pitch phase 2, lane BENCH-R31)
//
// Registered renderer candidates for the pitch and r17 benches. Lives in the test target (not Core/Sonification/)
// so production carries zero bench plumbing. Every renderer conforms to `SonificationRenderer`, unchanged.
// Renderers do NOT apply `source.gain`; the bench applies it to exported WAVs, as the kernel applies it at the mixer.

import Foundation
@testable import PrimaeNative

nonisolated struct BakeoffCandidate: Sendable {
    /// Unique; the bench's `candidate` column and renders folder (`<renders root>/<name>/<L>__<cents>c.wav`).
    let name: String
    /// Whether this candidate's voiced output depends on item 4's noise seed (drives the 8-seed spread in pitch mode).
    let isSeedDependent: Bool
    /// Builds a fresh renderer for one (source, scenario, seedXor). Runs off the render thread; may allocate.
    /// When `template` is supplied (same source, seed > 0), a TDPSOLA2 candidate reuses its invariant analysis/GCIs
    /// (`coarseAnalysis`, `analysis`, `epochReport`, `attackFirstMark`), producing the bit-identical renderer faster.
    let makeSeeded: @Sendable (
        _ source: SonificationSource,
        _ maxFramesPerRender: Int,
        _ seedXor: UInt64,
        _ template: TDPSOLA2?
    ) -> any SonificationRenderer

    var make: @Sendable (_ source: SonificationSource, _ maxFramesPerRender: Int) -> any SonificationRenderer {
        { s, n in makeSeeded(s, n, 0, nil) }
    }

    init(name: String, isSeedDependent: Bool = false,
         make: @escaping @Sendable (SonificationSource, Int) -> any SonificationRenderer) {
        self.name = name
        self.isSeedDependent = isSeedDependent
        self.makeSeeded = { s, n, _, _ in make(s, n) }
    }

    init(name: String, isSeedDependent: Bool,
         makeSeeded: @escaping @Sendable (SonificationSource, Int, UInt64, TDPSOLA2?) -> any SonificationRenderer) {
        self.name = name
        self.isSeedDependent = isSeedDependent
        self.makeSeeded = makeSeeded
    }

    /// A conformer registered through the protocol's own init (no onset, no gain), at `source.sampleRate`.
    static func protocolInit<T: SonificationRenderer & SendableMetatype>(_ type: T.Type, name: String? = nil)
        -> BakeoffCandidate {
        BakeoffCandidate(name: name ?? T.candidateName) { s, maxFrames in
            T(source: s.samples, sampleRate: s.sampleRate, kind: s.kind, maxFramesPerRender: maxFrames)
        }
    }

    /// The r28 engine (protocol r17–r28): TDPSOLA2 with every option off (`.r27`), built at `source.sampleRate`
    /// with `file: s.fileSource` (bit-identical to shipped TDPSOLA; `ProductionRendererTests.carrierIsTheR28Renderer`).
    static let ours = BakeoffCandidate(name: "ours") { s, _ in
        TDPSOLA2(source: s.samples, sampleRate: s.sampleRate, kind: s.kind,
                 maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default, options: .r27,
                 onset: s.onset, outputGain: s.gain, file: s.fileSource)
    }

    /// Protocol r31 production renderer: `LiveSonificationAudio.makeRenderer(s)` at `seedXor == 0`, and the same
    /// production options with `noiseSeedXor = seedXor` across the bench's seed spread.
    static let r31 = BakeoffCandidate(name: "r31", isSeedDependent: true) { s, _, seedXor, template in
        if seedXor == 0 && template == nil { return LiveSonificationAudio.makeRenderer(s) }
        var o = TDPSOLA2Options.production
        o.noiseSeedXor = seedXor
        if let t = template {
            return TDPSOLA2(source: s.samples, sampleRate: s.sampleRate, kind: s.kind,
                            maxFramesPerRender: LiveSonificationKernel.chunkFrames, analysis: t.coarseAnalysis,
                            tuning: .default, options: o, outputGain: s.gain,
                            refined: (t.analysis, t.epochReport), firstMark: t.attackFirstMark)
        }
        return TDPSOLA2(source: s.samples, sampleRate: s.sampleRate, kind: s.kind,
                        maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default, options: o,
                        onset: s.onset, outputGain: s.gain, file: s.fileSource)
    }

    /// The listening anchor: linear-interpolation varispeed (pitch and rate coupled by construction).
    static let naive = BakeoffCandidate.protocolInit(NaiveResampleRenderer.self)

    /// Control: production options with formant co-shift gamma = 0.3 (must fail env_warp and env_lsd gates).
    static let g03 = tdpsola2("TDPSOLA2-g0.3", base: .production) { $0.formantGamma = 0.3 }
}

nonisolated enum BakeoffCandidates {
    /// Default candidate set: the controls (`ours`, `NaiveResample`, `TDPSOLA2-g0.3`) and r31 production (`r31`).
    static let all: [BakeoffCandidate] = [
        .ours,
        .naive,
        .g03,
        .r31,
    ]
}

nonisolated extension BakeoffCandidate {
    /// TDPSOLA2 built as production builds it (at `source.sampleRate`, with `file: source.fileSource`), with `base`
    /// modified by `edit` and optional `noiseSeedXor` support for seed-spread runs.
    static func tdpsola2(_ name: String, base: TDPSOLA2Options = .default,
                         _ edit: @escaping @Sendable (inout TDPSOLA2Options) -> Void) -> BakeoffCandidate {
        var check = base; edit(&check)
        let seeded = check.harmonicNoiseSwap
        return BakeoffCandidate(name: name, isSeedDependent: seeded) { s, maxFrames, seedXor, template in
            var o = base
            edit(&o)
            o.noiseSeedXor = seedXor
            if let t = template {
                return TDPSOLA2(source: s.samples, sampleRate: s.sampleRate, kind: s.kind,
                                maxFramesPerRender: maxFrames, analysis: t.coarseAnalysis, tuning: .default,
                                options: o, outputGain: s.gain, refined: (t.analysis, t.epochReport),
                                firstMark: t.attackFirstMark)
            }
            return TDPSOLA2(source: s.samples, sampleRate: s.sampleRate, kind: s.kind,
                            maxFramesPerRender: maxFrames, tuning: .default, options: o, onset: s.onset,
                            outputGain: s.gain, file: s.fileSource)
        }
    }
}
