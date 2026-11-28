// TDPSOLA2EnvgapAFlagTests.swift
// PrimaeNativeTests — lane ENVGAP-A (2026-11-28): A's env_lsd_vs_praat floor, the loop-preparation candidates.
//
// Items 13 (`seamAlignLag`, with `seamAlignSlope` / `seamAlignFade`) and 14 (`seamCrossfadeSeconds`) change how SEAM2
// prepares a voiced phoneme's loop (`TDPSOLALoopSeam.Blend`). They are OFF in every shipped option set, and OFF they
// leave the prepared loop, and so every render, bit for bit as r31 shipped it: production's render hashes stay pinned
// to the pre-ENVGAP sources (612128f2, `TDPSOLA2EnvgapFlagTests.productionHashes`) with the items spelled out OFF and
// with only their parameters (inert while the item is off) set. Each item ON changes A's prepared loop, so the
// identity is not vacuous. The same comparison runs offline in `scripts/envgap_harness/HashMode.swift`.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("ENVGAP-A flags: OFF in every shipped option set, bit-identical when off")
nonisolated struct TDPSOLA2EnvgapAFlagTests {

    static let names = ["A_phoneme1", "F_phoneme1", "I_phoneme1", "L_phoneme1", "M_phoneme1"]

    static func make(_ s: StudySource, _ o: TDPSOLA2Options) -> TDPSOLA2 {
        TDPSOLA2(source: s.samples, sampleRate: LiveSonificationKernel.referenceSampleRate, kind: s.kind,
                 maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default,
                 options: o, onset: s.onset, outputGain: 1)
    }

    static func same(_ a: [Float], _ b: [Float]) -> Bool { a.elementsEqual(b) { $0.bitPattern == $1.bitPattern } }

    @Test("every shipped option set leaves items 13 and 14 OFF, so SEAM2 runs as shipped")
    func shippedSetsAreOff() {
        for o in [TDPSOLA2Options.default, .production, .r27] {
            #expect(o.seamAlignLag == 0)
            #expect(o.seamCrossfadeSeconds == 0)
            #expect(o.seamBlend == TDPSOLALoopSeam.Blend.shipped)
        }
    }

    @Test("production with items 13 and 14 spelled OFF (and their inert parameters set) hashes as r31 (612128f2)",
          arguments: names)
    func offIsPinnedProduction(name: String) throws {
        let s = try StudySources.load(name)
        var off = TDPSOLA2Options.production
        off.seamAlignLag = 0; off.seamCrossfadeSeconds = 0
        off.seamAlignSlope = 0.008; off.seamAlignFade = 0.1   // read only when item 13 is on
        #expect(off.seamBlend == TDPSOLALoopSeam.Blend.shipped)
        for (k, d) in TDPSOLA2EnvgapFlagTests.hashDrives.enumerated() {
            let h = TDPSOLA2EnvgapFlagTests.steadyHash(Self.make(s, off), rate: d.rate, cents: d.cents)
            #expect(h == TDPSOLA2EnvgapFlagTests.productionHashes[name]?[k],
                    "\(name) rate \(d.rate) cents \(d.cents): \(String(h, radix: 16))")
        }
    }

    @Test("the shipped blend passed explicitly prepares the same loop as SEAM2's default arguments", arguments: names)
    func shippedBlendIsDefault(name: String) throws {
        let s = try StudySources.load(name)
        let r = Self.make(s, .production)
        let a = r.analysis
        let t = TDPSOLATuning.default
        let pre = a.recordedOnset?.preBlendPeriods ?? TDPSOLALoopSeam.preBlendMarks
        let d = TDPSOLALoopSeam.prepare(s.samples, sampleRate: r.sampleRate, analysis: a, crossfade: t.loopCrossfadeSeconds,
                                        flattenDB: t.loopFlattenDB, preBlendMarks: pre)
        let e = TDPSOLALoopSeam.prepare(s.samples, sampleRate: r.sampleRate, analysis: a, crossfade: t.loopCrossfadeSeconds,
                                        flattenDB: t.loopFlattenDB, preBlendMarks: pre, blend: .shipped)
        #expect(d?.loopEnd == e?.loopEnd)
        #expect(Self.same(d?.samples ?? [], e?.samples ?? []))
    }

    @Test("each item ON changes A's prepared loop (the identity above is not vacuous); item 14 leaves F alone")
    func onDiffers() throws {
        let a = try StudySources.load("A_phoneme1")
        let prod = Self.make(a, .production)
        var o13 = TDPSOLA2Options.production; o13.seamAlignLag = 0.5
        var o14 = TDPSOLA2Options.production; o14.seamCrossfadeSeconds = 0.2
        let r13 = Self.make(a, o13), r14 = Self.make(a, o14)
        #expect(!Self.same(prod.playedSamples, r13.playedSamples), "item 13 did not change A's prepared loop")
        #expect(r13.debugLoopBounds.end == prod.debugLoopBounds.end, "item 13 moved the loop end")
        #expect(r14.debugLoopBounds.end > prod.debugLoopBounds.end, "item 14 did not lengthen A's loop")
        #expect(!Self.same(prod.playedSamples, r14.playedSamples), "item 14 did not change A's prepared loop")
        let f = try StudySources.load("F_phoneme1")
        #expect(Self.same(Self.make(f, .production).playedSamples, Self.make(f, o14).playedSamples),
                "item 14 changed the unvoiced F")
    }
}
