// TDPSOLA2RealtimeTests.swift
// PrimaeNativeTests — pitch bake-off phase 2, lane C1 "TDPSOLA2" (2026-11-23)
//
// Product gates 1, 2, 5 for the candidate (BAKEOFF.md; BAKEOFF-PITCH.md section 3), pure buffers:
//   - RT safety: zero allocations in `render` and the setters, every study source, default options, gamma 0.3 and
//     the r31 production options, under a rate + pitch + gate drive (the malloc hook of SonificationRealtimeTests);
//   - a soak: 60 s per source, finite, no subnormals, |y| <= 2, on the renderer production builds (r31: the
//     production options for the phonemes, `.r27` for the carrier);
//   - CPU: per-256-frame render time, voiced phonemes, a pitch trajectory at rate 1 and 2 (printed; the meaningful
//     numbers come from the Release-Study device run; a loose bound keeps the measurement non-vacuous).
// XCTest (the malloc hook is process-global and counts on one thread).

import XCTest
@testable import PrimaeNative

final class TDPSOLA2RealtimeTests: XCTestCase {

    static let sr = LiveSonificationKernel.referenceSampleRate
    static var variants: [(String, TDPSOLA2Options)] {
        [("default", .default), ("gamma0.3", C1Make.with { $0.formantGamma = 0.3 }), ("production", .production)]
    }

    func testRenderAndSettersAllocateNothing() throws {
        let sources = try StudySources.all()
        var renderers: [(String, TDPSOLA2)] = []
        for s in sources { for (v, o) in Self.variants { renderers.append(("\(s.name)/\(v)", C1Make.make(s, o))) } }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { out.deallocate() }
        guard RenderThreadAllocationCounter.install() else { return XCTFail("malloc_logger hook unavailable") }
        defer { RenderThreadAllocationCounter.uninstall() }
        for (label, r) in renderers {
            r.reset()
            let before = RenderThreadAllocationCounter.allocations
            for k in 0..<2000 {
                RenderThreadAllocationCounter.arm()
                r.setRate(Float(0.5 + 1.5 * (0.5 + 0.5 * sin(Double(k) * 0.01))))
                r.setPitchCents(Float(900 * sin(Double(k) * 0.013)))
                if k % 300 == 0 { r.setGate(true) }
                if k % 300 == 200 { r.setGate(false) }
                r.render(into: out, frames: k % 5 == 0 ? 512 : 256)
                RenderThreadAllocationCounter.disarm()
            }
            XCTAssertEqual(RenderThreadAllocationCounter.allocations - before, 0, "\(label): allocations on the render path")
        }
    }

    func testSoakIsFiniteAndDenormalFree() throws {
        let block = 256
        let blocks = Int(60 * Self.sr) / block
        let out = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { out.deallocate() }
        for s in try StudySources.all() {
            let r = SonificationRendererUnderTest.make(s)
            r.reset()
            var nonFinite = 0, subnormal = 0
            var peak: Float = 0
            for k in 0..<blocks {
                let t = Double(k * block) / Self.sr
                r.setRate(Float(1.25 + 0.75 * sin(t * 1.7)))
                r.setPitchCents(Float(600 * sin(t * 0.9)))
                r.setGate(t.truncatingRemainder(dividingBy: 3.0) < 2.4)
                r.render(into: out, frames: block)
                for i in 0..<block {
                    let v = out[i]
                    if !v.isFinite { nonFinite += 1 } else {
                        if SonificationMetrics.isSubnormal(v) { subnormal += 1 }
                        peak = max(peak, abs(v))
                    }
                }
            }
            XCTAssertEqual(nonFinite, 0, "\(s.name): non-finite samples")
            XCTAssertEqual(subnormal, 0, "\(s.name): subnormal samples")
            XCTAssertLessThanOrEqual(peak, 2, "\(s.name): peak \(peak)")
        }
    }

    /// Per-buffer CPU (µs per 256 frames): r27 (the shipped renderer through the candidate's `.r27`), default,
    /// gamma 0.3; a +-600 c triangle at 0.75 s per leg, at rate 1 and 2. Printed as `C1CPU ...` lines.
    func testCPUPerBuffer() throws {
        let block = 256
        let blocks = Int(6 * Self.sr) / block
        let out = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { out.deallocate() }
        var worstP99 = 0.0
        for name in StudySources.voicedNames + ["F_phoneme1"] {
            let s = try StudySources.load(name)
            for (v, o) in [("r27", TDPSOLA2Options.r27)] + Self.variants {
                let r = C1Make.make(s, o)
                for rate: Float in [1, 2] {
                    r.reset(); r.setRate(rate); r.setGate(true)
                    var t = [Double](); t.reserveCapacity(blocks)
                    for k in 0..<blocks {
                        let ts = Double(k * block) / Self.sr
                        let ph = ts.truncatingRemainder(dividingBy: 3.0)
                        r.setPitchCents(Float(ph < 0.75 ? 800 * ph : ph < 2.25 ? 600 - 800 * (ph - 0.75) : -600 + 800 * (ph - 2.25)))
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        r.render(into: out, frames: block)
                        t.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000)
                    }
                    t.sort()
                    let med = t[t.count / 2], p99 = t[t.count * 99 / 100], mx = t.last!
                    worstP99 = max(worstP99, p99)
                    print(String(format: "C1CPU %@ %@ rate %.0f: median %.1f us, p99 %.1f us, max %.1f us per 256 frames",
                                 name, v, rate, med, p99, mx))
                }
            }
        }
        // 256 frames = 5805 us of audio; a renderer must not come near it.
        XCTAssertLessThan(worstP99, 1000, "p99 render time \(worstP99) us per 256 frames")
    }
}
