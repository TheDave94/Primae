// TDPSOLAIdentityTests.swift
// PrimaeNativeTests — r17, lane OPT-T's identity check rebased onto the r17 file (2026-11-03)
//
// Lane OPT-T optimised TDPSOLA's render path (state in locals, out-of-line grain spawning, an energy
// table and an 8-wide SIMD WSOLA search) and claimed bit-identical output. Its patch was written
// against the bake-off file; r17 had already changed that file (the F loudness correction, the period
// clamp note). This test pins the rebase: the production `TDPSOLA` at the bake-off tuning (tau 5 ms,
// the tuning the frozen copy hard-codes) reproduces `TDPSOLABaseline` — the pre-OPT-T r17 file, frozen
// — bit for bit, for every shipped source, at 44.1 and 48 kHz, over fixed rates, pitch extremes, gate
// cycles (a re-open inside the fade included) and a seeded random walk with odd buffer sizes.
//
// In Debug-Study the SIMD search is compiled out (it allocates in -Onone); the Release-Study run of this
// suite is the one that checks the SIMD path.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("r17 TDPSOLA: OPT-T rebase is bit-identical")
nonisolated struct TDPSOLAIdentityTests {

    struct LCG {
        var s: UInt64
        mutating func next() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(1 << 53)
        }
    }

    /// (buffers, frames per buffer, rate, cents, gate)
    static func script(kind: SourceKind, sampleRate sr: Double) -> [(Int, Int, Float, Float, Bool)] {
        let B = 256
        var rng = LCG(s: 12345)
        var sc: [(Int, Int, Float, Float, Bool)] = []
        for rt in [Float(0.5), 0.75, 1, 1.5, 2] { sc.append((Int(1.0 * sr) / B, B, rt, 0, true)) }
        for c in [Float(-1200), -700, 0, 700, 1200] {
            sc.append((Int(0.4 * sr) / B, B, 0.5, kind == .carrier ? c : 0, true))
            sc.append((Int(0.4 * sr) / B, B, 2, kind == .carrier ? c : 0, true))
        }
        for _ in 0..<4 { sc.append((Int(0.3 * sr) / B, B, 1, 0, true)); sc.append((Int(0.1 * sr) / B, B, 1, 0, false)) }
        sc.append((1, B, 1, 0, true)); sc.append((1, B, 1, 0, false)); sc.append((1, B, 1, 0, true))
        let sizes = [1, 37, 255, 256, 300, 512]
        for _ in 0..<1200 {
            let rt = Float(0.5 + 1.5 * rng.next())
            let c = kind == .carrier ? Float(-1200 + 2400 * rng.next()) : 0
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

    @Test("TDPSOLA (bake-off tuning) == the frozen pre-OPT-T r17 TDPSOLA, bit for bit",
          arguments: StudySources.names, [44_100.0, 48_000.0])
    func optimisedIsBitIdenticalToBaseline(name: String, sampleRate: Double) throws {
        let src = try StudySources.load(name)
        let sc = Self.script(kind: src.kind, sampleRate: sampleRate)
        let opt = TDPSOLA(source: src.samples, sampleRate: sampleRate, kind: src.kind,
                          maxFramesPerRender: 512, tuning: .bakeoff)
        let base = TDPSOLABaseline(source: src.samples, sampleRate: sampleRate, kind: src.kind, maxFramesPerRender: 512)
        // R17D U1: the unvoiced path (F) is no longer time-stretched; it plays at rate 1 whatever the rate. The frozen
        // copy still stretches, so it is driven at rate 1 for an unvoiced source: everything else is bit for bit.
        let baseScript = opt.analysis.isVoiced ? sc : sc.map { ($0.0, $0.1, Float(1), $0.3, $0.4) }
        let a = Self.drive(opt, sc), b = Self.drive(base, baseScript)
        #expect(a.count == b.count)
        var differing = 0, first = -1
        for i in 0..<min(a.count, b.count) where a[i].bitPattern != b[i].bitPattern {
            differing += 1
            if first < 0 { first = i }
        }
        #expect(differing == 0, "\(name) @\(Int(sampleRate)): \(differing) of \(a.count) samples differ, first at \(first)")
        #expect(a.contains { $0 != 0 }, "\(name): the drive rendered silence; the comparison would be vacuous")
    }
}
