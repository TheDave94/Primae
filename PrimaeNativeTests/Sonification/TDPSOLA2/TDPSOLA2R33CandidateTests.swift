// TDPSOLA2R33CandidateTests.swift
// PrimaeNativeTests — lane BENCHM17 (2026-11-28): the R33 candidate C3d-C5-M17 (items 11 + 15 + 17, r 0.25, from
// +450 c) behind TDPSOLA2Options.
//
// Items 15 (`repeatedPeriodDonor`), 16 (`upshiftCrossfade`) and 17 (`upshiftPowerCoherence` + `upshiftMinCents`) are
// OFF in every shipped option set, and spelled out at their OFF values they render bit for bit as production (the
// r31/r32 renderer; `TDPSOLA2EnvgapFlagTests` pins production's hashes to 612128f2). Each item ON changes the render
// it targets, and item 17's threshold leaves a +300 c upshift untouched. Finally the device renders of the packet's
// listening cells are pinned to the offline bench's (macOS, `scripts/envgap_harness/HashMode.swift` `listenMode`,
// HASH_LISTEN=1), so the 491/0 offline bench numbers describe the sound the iPad makes.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("R33 candidate: items 15-17 OFF in every shipped option set; device renders equal the offline bench's")
nonisolated struct TDPSOLA2R33CandidateTests {

    static func c3dc5(_ m17: Bool) -> TDPSOLA2Options {
        var o = TDPSOLA2Options.production
        o.extremumPhaseAlign = true; o.extremumPhaseMinOffset = 0.025; o.repeatedPeriodDonor = true
        if m17 { o.upshiftPowerCoherence = 0.25; o.upshiftMinCents = 450 }
        return o
    }

    static func render(_ ss: SonificationSource, _ o: TDPSOLA2Options, rate: Float, cents: Float) -> [Float] {
        SonificationDriver.steady(TDPSOLA2EnvgapFlagTests.make(ss, o), seconds: 1.5, rate: rate, cents: cents)
    }

    @Test("every shipped option set leaves items 15-17 at their OFF values")
    func shippedSetsAreOff() {
        for o in [TDPSOLA2Options.default, .production, .r27] {
            #expect(o.repeatedPeriodDonor == false)
            #expect(o.upshiftCrossfade == 1)
            #expect(o.upshiftPowerCoherence < 0)
            #expect(o.upshiftMinCents == 0)
        }
    }

    @Test("production with items 15-17 spelled out OFF renders bit for bit as production",
          arguments: ["A_phoneme1", "F_phoneme1", "I_phoneme1", "L_phoneme1", "M_phoneme1"])
    func offIsProduction(name: String) throws {
        let ss = try StudySources.load(name).sonificationSource
        var off = TDPSOLA2Options.production
        off.repeatedPeriodDonor = false; off.upshiftCrossfade = 1; off.upshiftPowerCoherence = -1
        off.upshiftMinCents = 450   // the threshold alone moves nothing
        for d in TDPSOLA2EnvgapFlagTests.drives + [(rate: Float(2), cents: Float(600)), (rate: 0.5, cents: 0)] {
            let yProd = SonificationDriver.steady(LiveSonificationAudio.makeRenderer(ss), seconds: 1.5, rate: d.rate, cents: d.cents)
            #expect(TDPSOLA2EnvgapFlagTests.same(yProd, Self.render(ss, off, rate: d.rate, cents: d.cents)),
                    "\(name) rate \(d.rate) cents \(d.cents): items 15-17 OFF differed from production")
        }
    }

    @Test("each item ON changes the render it targets; item 17 from +450 c leaves +300 c untouched")
    func onDiffers() throws {
        let l = try StudySources.load("L_phoneme1").sonificationSource
        let m = try StudySources.load("M_phoneme1").sonificationSource
        func prod(_ ss: SonificationSource, _ rate: Float, _ cents: Float) -> [Float] {
            SonificationDriver.steady(LiveSonificationAudio.makeRenderer(ss), seconds: 1.5, rate: rate, cents: cents)
        }
        var o15 = TDPSOLA2Options.production; o15.repeatedPeriodDonor = true
        #expect(!TDPSOLA2EnvgapFlagTests.same(prod(l, 0.5, 0), Self.render(l, o15, rate: 0.5, cents: 0)),
                "item 15 had no effect on L 0 c @0.5")
        var o16 = TDPSOLA2Options.production; o16.upshiftCrossfade = 0.5
        #expect(!TDPSOLA2EnvgapFlagTests.same(prod(m, 2, 600), Self.render(m, o16, rate: 2, cents: 600)),
                "item 16 had no effect on M +600 c @2")
        // Item 17 is measured against C3d-C5, the candidate it is added to.
        #expect(!TDPSOLA2EnvgapFlagTests.same(Self.render(m, Self.c3dc5(false), rate: 2, cents: 600),
                                              Self.render(m, Self.c3dc5(true), rate: 2, cents: 600)),
                "item 17 had no effect on M +600 c @2")
        #expect(TDPSOLA2EnvgapFlagTests.same(Self.render(m, Self.c3dc5(false), rate: 1, cents: 300),
                                             Self.render(m, Self.c3dc5(true), rate: 1, cents: 300)),
                "item 17 from +450 c changed M +300 c @1")
    }

    /// FNV-1a of a 2 s steady render per listening cell (packet R33, "Listening items") and variant: (44.1 kHz,
    /// C1Make's construction, gain 1; 48 kHz, the production file-rate path). Rendered offline on macOS by
    /// `HashMode.swift` `listenMode` (2026-11-28, tree 27d57664 + the bench commits); production's equal r31's and
    /// r32's sources' there.
    static let listenCells: [(letter: String, rate: Float, cents: Float, hashes: [String: (UInt64, UInt64)])] = [
        ("I", 0.5, 600, ["production": (0xeb0d256b59c17e41, 0xaf7c63281c0dc5da), "C3d-C5": (0xed07af7268dec375, 0x10e902a57c111b89),
                         "C3d-C5-M17": (0x9f36f5d115f51d2f, 0xd996a8fc23a8aec3)]),
        ("I", 1, 600, ["production": (0x8b8cfa4e65ce12fa, 0x8e114359327b25c9), "C3d-C5": (0xcc6d10595949cdb5, 0x64a66c1aa6dfcc03),
                       "C3d-C5-M17": (0x2b62ec0d06ab4ab7, 0xb036477cc27dd82d)]),
        ("I", 2, 600, ["production": (0xb177392f90cae128, 0x41a520363abf811d), "C3d-C5": (0x6ada58c122669e28, 0x3f2f4690a14c8ca8),
                       "C3d-C5-M17": (0xbbc5f5f9e393bb07, 0x584483ffee9704f1)]),
        ("L", 0.5, 0, ["production": (0x2902770604fffe3f, 0xfc482f30673f3076), "C3d-C5": (0x1b153953cc49cb9f, 0x337666a01cb72f0c),
                       "C3d-C5-M17": (0x1b153953cc49cb9f, 0x337666a01cb72f0c)]),
        ("L", 0.5, 300, ["production": (0x2a48a2b3936db236, 0x32f4fa87a0818be7), "C3d-C5": (0xf2890635313e1507, 0x868f784c69be65b8),
                         "C3d-C5-M17": (0xf2890635313e1507, 0x868f784c69be65b8)]),
        ("A", 0.5, 0, ["production": (0xe5d0a2223202e940, 0x2ef0454e781efd6a), "C3d-C5": (0x1ea194991b724e31, 0x1f749195ba7ac4ae),
                       "C3d-C5-M17": (0x1ea194991b724e31, 0x1f749195ba7ac4ae)]),
        ("M", 1, 600, ["production": (0x2c823d092922da6d, 0xe419865241fa90f0), "C3d-C5": (0x5f8e0b55715bd6f8, 0x3b29c6e32437ba24),
                       "C3d-C5-M17": (0x5d165bc0ba7bfbd7, 0xc84a1a99a9a31934)]),
        ("M", 2, 600, ["production": (0x4603fdce6ff63d99, 0xbe941eed8679f292), "C3d-C5": (0x2e32f40db44294a8, 0xec25baf8b92e8f78),
                       "C3d-C5-M17": (0xb68904c354d48065, 0x66314ed85aa56afd)]),
    ]

    static func fnv(_ r: TDPSOLA2, sampleRate sr: Double, rate: Float, cents: Float) -> UInt64 {
        r.reset(); r.setRate(rate); r.setPitchCents(cents); r.setGate(true)
        let total = Int(2.0 * sr)
        var out = [Float](repeating: 0, count: total)
        out.withUnsafeMutableBufferPointer { b in
            var pos = 0
            while pos < total { let n = min(256, total - pos); r.render(into: b.baseAddress! + pos, frames: n); pos += n }
        }
        var h: UInt64 = 0xcbf29ce484222325
        for v in out { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }
        return h
    }

    @Test("the listening cells render bit for bit as the offline bench (r32 production, C3d-C5, C3d-C5-M17; 44.1 and 48 kHz)",
          arguments: 0..<8)
    @MainActor func listeningCellHashes(cell: Int) throws {
        let c = Self.listenCells[cell]
        let url = try #require(PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(c.letter)",
                                                                                      name: "\(c.letter)_phoneme1", ext: "wav")))
        let raw = try SonificationSource.decodeMono(url: url, sampleRate: 44_100)
        let kind = SonificationSource.kind(forFileAt: url)
        let onset = PhonemeOnsets.onset(forFileNamed: url.lastPathComponent)
        let s48 = try #require(SonificationSource.load(url: url, gain: AudioEngine.loudnessGain(forFileAt: url), sampleRate: 48_000))
        let variants: [(String, TDPSOLA2Options)] = [("production", .production), ("C3d-C5", Self.c3dc5(false)),
                                                    ("C3d-C5-M17", Self.c3dc5(true))]
        for (vn, o) in variants {
            let t44 = TDPSOLA2(source: raw, sampleRate: 44_100, kind: kind, maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                               tuning: .default, options: o, onset: onset, outputGain: 1)
            let t48 = TDPSOLA2(source: s48.samples, sampleRate: s48.sampleRate, kind: s48.kind,
                               maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default, options: o,
                               onset: s48.onset, outputGain: s48.gain, file: s48.fileSource)
            let h44 = Self.fnv(t44, sampleRate: 44_100, rate: c.rate, cents: c.cents)
            let h48 = Self.fnv(t48, sampleRate: 48_000, rate: c.rate, cents: c.cents)
            let tag = "\(c.letter) \(c.rate) \(Int(c.cents)) \(vn)"
            print("R33LISTEN \(tag) 0x\(String(h44, radix: 16)) 0x\(String(h48, radix: 16))")
            #expect(h44 == c.hashes[vn]?.0, "\(tag) 44.1 kHz: 0x\(String(h44, radix: 16))")
            #expect(h48 == c.hashes[vn]?.1, "\(tag) 48 kHz: 0x\(String(h48, radix: 16))")
        }
    }
}
