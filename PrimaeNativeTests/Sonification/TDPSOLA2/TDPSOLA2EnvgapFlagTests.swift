// TDPSOLA2EnvgapFlagTests.swift
// PrimaeNativeTests — lane ENVGAP (2026-11-28): the env_lsd_vs_praat gap candidates behind TDPSOLA2Options.
//
// Items 9 (`wideUpshiftWindow`), 10 (`downshiftWindowScale`), 11 (`extremumPhaseAlign` + `extremumPhaseMinOffset`) and
// the diagnosis probe `markPhaseShift` are OFF in every shipped option set, and at their OFF values the renderer is
// bit for bit the r31 production renderer. `TDPSOLA2RenderHashTests` pins the default options' render hash; these pin
// production (the phoneme arm's set) against the same set with every ENVGAP flag spelled out at its OFF value, under
// shifted and unshifted drives, and show each flag does something when ON (so the identity is not vacuous). A flag
// ignored everywhere would pass the same-binary comparison, so production's render hashes are also PINNED to the
// pre-ENVGAP sources (612128f2), as `TDPSOLA2RenderHashTests` pins the default set's. The same comparison runs
// offline in `scripts/envgap_harness/HashMode.swift` (build_hash.sh, T2DIR = the pre-ENVGAP TDPSOLA2 sources).

import Testing
import Foundation
@testable import PrimaeNative

@Suite("ENVGAP flags: OFF in every shipped option set, bit-identical when off")
nonisolated struct TDPSOLA2EnvgapFlagTests {

    static let drives: [(rate: Float, cents: Float)] = [(0.8, 450), (1, -600), (2, 600), (0.5, -300), (1, 0)]

    static func make(_ ss: SonificationSource, _ o: TDPSOLA2Options) -> TDPSOLA2 {
        TDPSOLA2(source: ss.samples, sampleRate: ss.sampleRate, kind: ss.kind,
                 maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default,
                 options: o, onset: ss.onset, outputGain: ss.gain, file: ss.fileSource)
    }

    static func same(_ a: [Float], _ b: [Float]) -> Bool { a.elementsEqual(b) { $0.bitPattern == $1.bitPattern } }

    /// FNV-1a of a 2 s production render (C1Make's construction with `.production`: 44.1 kHz, gain 1, 256-frame
    /// buffers) per drive in `hashDrives`, rendered by the pre-ENVGAP sources at 612128f2 (ENVGAP's macOS driver,
    /// 2026-11-28). Equal here = production is bit for bit what r31 shipped.
    static let hashDrives: [(rate: Float, cents: Float)] = [(0.8, 450), (1, -600), (2, 600), (0.5, 0), (1, 600), (0.5, -300)]
    static let productionHashes: [String: [UInt64]] = [
        "A_phoneme1": [0xf09cc797f2ef2181, 0xc54873aa354fa5ca, 0x123d083b38545566, 0xe5d0a2223202e940, 0x296f7423e5b70c92, 0x233988c6907db9ed],
        "F_phoneme1": [0xf4eb7f6822c6347b, 0x5b93d5a113230d4f, 0x6c53fb89a0602617, 0x9a0307c0929454af, 0x6c53fb89a0602617, 0xa4db837060195d45],
        "I_phoneme1": [0xd6f0f60c133be8b8, 0x6a23db6eb4314822, 0xb177392f90cae128, 0x890d328a5a5741e3, 0x8b8cfa4e65ce12fa, 0xb159f5c12663f051],
        "L_phoneme1": [0xcc6db6cbb01b9545, 0xf955ed8e5e657102, 0xe8995e1eb9b532f0, 0x2902770604fffe3f, 0x0d9e2dfe0f3b7132, 0xa6fe6287594e296c],
        "M_phoneme1": [0x2f36c7384c65781d, 0x8d31a4258df9dbff, 0x4603fdce6ff63d99, 0xc14dd3c82024a347, 0x2c823d092922da6d, 0x1473b217a908ba68],
    ]

    static func steadyHash(_ r: TDPSOLA2, rate: Float, cents: Float) -> UInt64 {
        r.reset(); r.setRate(rate); r.setPitchCents(cents); r.setGate(true)
        let total = Int(2.0 * LiveSonificationKernel.referenceSampleRate)
        var out = [Float](repeating: 0, count: total)
        out.withUnsafeMutableBufferPointer { b in
            var pos = 0
            while pos < total { let n = min(256, total - pos); r.render(into: b.baseAddress! + pos, frames: n); pos += n }
        }
        var h: UInt64 = 0xcbf29ce484222325
        for v in out { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        return h
    }

    @Test("production's render hashes equal the pre-ENVGAP sources' (r31, 612128f2)",
          arguments: ["A_phoneme1", "F_phoneme1", "I_phoneme1", "L_phoneme1", "M_phoneme1"])
    func productionHashesPinned(name: String) throws {
        let s = try StudySources.load(name)
        for (k, d) in Self.hashDrives.enumerated() {
            let r = TDPSOLA2(source: s.samples, sampleRate: LiveSonificationKernel.referenceSampleRate, kind: s.kind,
                             maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default,
                             options: .production, onset: s.onset, outputGain: 1)
            let h = Self.steadyHash(r, rate: d.rate, cents: d.cents)
            #expect(h == Self.productionHashes[name]?[k], "\(name) rate \(d.rate) cents \(d.cents): \(String(h, radix: 16))")
        }
    }

    @Test("every shipped option set leaves the ENVGAP flags at their OFF values")
    func shippedSetsAreOff() {
        for o in [TDPSOLA2Options.default, .production, .r27] {
            #expect(o.wideUpshiftWindow == false)
            #expect(o.downshiftWindowScale == 1)
            #expect(o.markPhaseShift == 0)
            #expect(o.extremumPhaseAlign == false)
            #expect(o.extremumPhaseMinOffset == 0)
        }
    }

    @Test("production with every ENVGAP flag spelled out OFF renders bit for bit as production",
          arguments: ["A_phoneme1", "F_phoneme1", "I_phoneme1", "L_phoneme1", "M_phoneme1"])
    func offIsProduction(name: String) throws {
        let ss = try StudySources.load(name).sonificationSource
        var off = TDPSOLA2Options.production
        off.wideUpshiftWindow = false; off.downshiftWindowScale = 1; off.markPhaseShift = 0
        off.extremumPhaseAlign = false; off.extremumPhaseMinOffset = 0.025   // the guard alone moves nothing
        for d in Self.drives {
            let yProd = SonificationDriver.steady(LiveSonificationAudio.makeRenderer(ss), seconds: 1.5, rate: d.rate, cents: d.cents)
            let yOff = SonificationDriver.steady(Self.make(ss, off), seconds: 1.5, rate: d.rate, cents: d.cents)
            #expect(Self.same(yProd, yOff), "\(name) rate \(d.rate) cents \(d.cents): OFF flags differed from production")
        }
    }

    @Test("each flag ON changes the shifted render it targets (the identity above is not vacuous)")
    func onDiffers() throws {
        let i = try StudySources.load("I_phoneme1").sonificationSource
        let a = try StudySources.load("A_phoneme1").sonificationSource
        func differs(_ ss: SonificationSource, _ f: (inout TDPSOLA2Options) -> Void, rate: Float, cents: Float) -> Bool {
            var o = TDPSOLA2Options.production; f(&o)
            let yProd = SonificationDriver.steady(LiveSonificationAudio.makeRenderer(ss), seconds: 1.5, rate: rate, cents: cents)
            return !Self.same(yProd, SonificationDriver.steady(Self.make(ss, o), seconds: 1.5, rate: rate, cents: cents))
        }
        #expect(differs(i, { $0.wideUpshiftWindow = true }, rate: 1, cents: 600), "item 9 had no effect on I +600")
        #expect(differs(a, { $0.downshiftWindowScale = 0.85 }, rate: 1, cents: -600), "item 10 had no effect on A -600")
        #expect(differs(i, { $0.extremumPhaseAlign = true }, rate: 1, cents: 600), "item 11 had no effect on I +600")
        #expect(differs(i, { $0.markPhaseShift = 0.05 }, rate: 1, cents: 600), "the phase probe had no effect on I +600")
    }
}
