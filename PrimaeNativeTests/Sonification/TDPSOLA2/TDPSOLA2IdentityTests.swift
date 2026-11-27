// TDPSOLA2IdentityTests.swift
// PrimaeNativeTests — pitch bake-off phase 2, lane C1 "TDPSOLA2" (2026-11-23)
//
// The candidate is a copy of the shipped renderer with items 1-6 behind options. These pin the copy:
//   - every option off (`TDPSOLA2Options.r27`) IS the shipped TDPSOLA, bit for bit, for every study source under a
//     drive that moves rate AND pitch (the phoneme arm is height-coupled from r26) with gate cycles and odd buffers;
//   - the carrier is untouched by every option (items 1-6 apply to phonemes only);
//   - with the default options, 0 cents at rate 1 is still the shipped output for every phoneme whose marks item 5
//     left alone (the H/N swap reads the source on a grain that continues its predecessor), and differs exactly
//     where item 5 moved the marks.

import Testing
import Foundation
@testable import PrimaeNative

nonisolated enum C1Make {
    static let sr = LiveSonificationKernel.referenceSampleRate
    /// As production builds TDPSOLA (`LiveSonificationAudio.makeRenderer`, at the test sources' gain 1), plus options.
    static func make(_ s: StudySource, _ o: TDPSOLA2Options = .default) -> TDPSOLA2 {
        TDPSOLA2(source: s.samples, sampleRate: sr, kind: s.kind, maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                 tuning: .default, options: o, onset: s.onset, outputGain: 1)
    }
    static var noEpochs: TDPSOLA2Options { var o = TDPSOLA2Options.default; o.gciSnap = false; return o }
    static func with(_ f: (inout TDPSOLA2Options) -> Void) -> TDPSOLA2Options { var o = TDPSOLA2Options.default; f(&o); return o }
}

@Suite("C1 TDPSOLA2: the copy is the shipped renderer where it should be")
nonisolated struct TDPSOLA2IdentityTests {

    struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
    }

    /// (buffers, frames per buffer, rate, cents, gate): fixed rates, pitch extremes at two rates, gate cycles (a
    /// re-open inside the fade included), then a seeded random walk of rate AND cents with odd buffer sizes.
    static func script(sampleRate sr: Double) -> [(Int, Int, Float, Float, Bool)] {
        let B = 256
        var rng = LCG(s: 2026_11_23)
        var sc: [(Int, Int, Float, Float, Bool)] = []
        for rt in [Float(0.5), 1, 2] { sc.append((Int(0.6 * sr) / B, B, rt, 0, true)) }
        for c in [Float(-1200), -600, -300, 300, 600, 1200] {
            sc.append((Int(0.3 * sr) / B, B, 0.5, c, true))
            sc.append((Int(0.3 * sr) / B, B, 1.7, c, true))
        }
        for _ in 0..<3 { sc.append((Int(0.25 * sr) / B, B, 1, 300, true)); sc.append((Int(0.08 * sr) / B, B, 1, 300, false)) }
        sc.append((1, B, 1, 0, true)); sc.append((1, B, 1, 0, false)); sc.append((1, B, 1, -450, true))
        let sizes = [1, 37, 255, 256, 300, 512]
        for _ in 0..<700 {
            let rt = Float(0.5 + 1.5 * rng.next())
            let c = Float(-700 + 1400 * rng.next())
            let g = rng.next() > 0.04
            sc.append((1 + Int(rng.next() * 3), sizes[Int(rng.next() * Double(sizes.count)) % sizes.count], rt, c, g))
        }
        return sc
    }

    static func drive(_ r: any SonificationRenderer, _ sc: [(Int, Int, Float, Float, Bool)]) -> [Float] {
        var out: [Float] = []
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { buf.deallocate() }
        r.reset()
        for (nb, frames, rt, c, g) in sc {
            r.setRate(rt); r.setPitchCents(c); r.setGate(g)
            for _ in 0..<nb {
                r.render(into: buf, frames: frames)
                out.append(contentsOf: UnsafeBufferPointer(start: buf, count: frames))
            }
        }
        return out
    }

    static func firstDifference(_ a: [Float], _ b: [Float]) -> Int? {
        if a.count != b.count { return min(a.count, b.count) }
        return a.indices.first { a[$0].bitPattern != b[$0].bitPattern }
    }

    @Test("every option off is the shipped TDPSOLA, bit for bit, under a rate + pitch + gate drive",
          arguments: StudySources.names)
    func r27OptionsAreTheShippedRenderer(name: String) throws {
        let s = try StudySources.load(name)
        let sc = Self.script(sampleRate: C1Make.sr)
        let shipped = Self.drive(SonificationRendererUnderTest.makeR28(s), sc)
        let c1 = Self.drive(C1Make.make(s, .r27), sc)
        #expect(shipped.count > 400_000, "precondition: the drive is long (\(shipped.count))")
        let d = Self.firstDifference(shipped, c1)
        #expect(d == nil, "\(name): first difference at frame \(d ?? -1)")
    }

    @Test("the carrier is untouched by the default options (items 1-6 are phoneme-only)")
    func carrierUntouched() throws {
        let s = try StudySources.load("spatial_carrier")
        let sc = Self.script(sampleRate: C1Make.sr)
        let shipped = Self.drive(SonificationRendererUnderTest.makeR28(s), sc)
        let g = C1Make.with { $0.formantGamma = 0.5 }
        for o in [TDPSOLA2Options.default, g] {
            let d = Self.firstDifference(shipped, Self.drive(C1Make.make(s, o), sc))
            #expect(d == nil, "carrier, gamma \(o.formantGamma): first difference at frame \(d ?? -1)")
        }
    }

    @Test("default options at 0 cents / rate 1: the shipped output wherever item 5 kept the marks",
          arguments: ["A_phoneme1", "F_phoneme1", "I_phoneme1", "L_phoneme1", "M_phoneme1"])
    func zeroCentsRateOne(name: String) throws {
        let s = try StudySources.load(name)
        let shipped = SonificationDriver.steady(SonificationRendererUnderTest.makeR28(s), seconds: 3, rate: 1, cents: 0)
        // Items 1-4 and 6 (gamma 0) leave 0 cents / rate 1 bit-identical.
        let d0 = Self.firstDifference(shipped, SonificationDriver.steady(C1Make.make(s, C1Make.noEpochs), seconds: 3,
                                                                         rate: 1, cents: 0))
        #expect(d0 == nil, "\(name) without item 5: first difference at frame \(d0 ?? -1)")
        // Item 5 changes it exactly where it moved the marks.
        let r = C1Make.make(s)
        let moved = r.epochReport?.applied ?? false
        let d = Self.firstDifference(shipped, SonificationDriver.steady(r, seconds: 3, rate: 1, cents: 0))
        #expect((d == nil) == !moved, "\(name): marks moved \(moved), first difference \(d ?? -1); \(r.epochReport?.reason ?? "-")")
    }
}

@Suite("C1 TDPSOLA2: the device renders what the lane's macOS driver rendered")
nonisolated struct TDPSOLA2RenderHashTests {
    /// FNV-1a of a 2 s render (default options, rate 0.8, +450 c, gain 1), computed by the lane's macOS driver (-O and
    /// -Onone alike, 2026-11-23). Equal on the iPad = the harness WAVs (rendered on macOS) are what the device plays.
    /// I re-recorded 2026-11-26 (lane PITCHWIN): c534dac2 (item 5's snap keeps the declared attack end) moved I's render
    /// from 0x784ed7c9d50a04ee; the macOS driver at that commit and later renders 0x627436734ddf5942, as the iPad does.
    static let expected: [String: UInt64] = ["A_phoneme1": 0x95b25a3e6fab38d8, "F_phoneme1": 0xef0be5da24eb9951,
                                             "I_phoneme1": 0x627436734ddf5942]

    @Test("render hash equals the macOS driver's", arguments: ["A_phoneme1", "F_phoneme1", "I_phoneme1"])
    func hashMatches(name: String) throws {
        let y = C1Metrics.steady(C1Make.make(try StudySources.load(name)), seconds: 2.0, rate: 0.8, cents: 450)
        let h = C1Metrics.hash(y)
        print("C1HASH \(name) \(String(h, radix: 16))")
        #expect(h == Self.expected[name], "\(name): \(String(h, radix: 16))")
    }
}
