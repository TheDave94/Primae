// SonificationRealtimeTests.swift
// PrimaeNativeTests — protocol r17 regression suite (2026-11-03)
//
// Real-time safety and long-run stability of the live sonification path,
// pure buffers (BAKEOFF.md product gates 1 and 5):
//   - zero allocations on the render thread: the renderer's `render` and
//     setters, AND the kernel's `render` (the code the source node runs);
//   - a soak: finite output, no subnormals, bounded level, for every shipped
//     source.
// XCTest, not Swift Testing: the malloc hook is process-global and counts on
// one thread; XCTest cases run serially, before the Swift Testing run.

import XCTest
@testable import PrimaeNative

final class SonificationRealtimeTests: XCTestCase {

    static let sr = LiveSonificationKernel.sampleRate

    func testAllocationCounterSeesAnAllocation() throws {
        guard RenderThreadAllocationCounter.install() else {
            return XCTFail("malloc_logger hook unavailable: the RT-safety instrument is blind")
        }
        defer { RenderThreadAllocationCounter.uninstall() }
        RenderThreadAllocationCounter.arm()
        let a = [Float](repeating: 1, count: 4096)
        RenderThreadAllocationCounter.disarm()
        XCTAssertEqual(a.count, 4096)
        XCTAssertGreaterThan(RenderThreadAllocationCounter.allocations, 0, "the counter did not see a 16 KB array")
    }

    /// Every source: a trajectory drive with gate cycles, counted
    /// around each `render` and each setter call.
    func testRenderersAllocateNothing() throws {
        let sources = try StudySources.all()
        let renderers = sources.map { (label: $0.name, r: SonificationRendererUnderTest.make($0)) }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { out.deallocate() }
        guard RenderThreadAllocationCounter.install() else { return XCTFail("malloc_logger hook unavailable") }
        defer { RenderThreadAllocationCounter.uninstall() }
        for (label, r) in renderers {
            r.reset()
            let before = RenderThreadAllocationCounter.allocations
            for k in 0..<2000 {
                let rate = Float(0.5 + 1.5 * (0.5 + 0.5 * sin(Double(k) * 0.01)))
                let cents = Float(1200 * sin(Double(k) * 0.013))
                RenderThreadAllocationCounter.arm()
                r.setRate(rate)
                r.setPitchCents(cents)
                if k % 300 == 0 { r.setGate(true) }
                if k % 300 == 200 { r.setGate(false) }
                r.render(into: out, frames: 256)
                RenderThreadAllocationCounter.disarm()
            }
            XCTAssertEqual(RenderThreadAllocationCounter.allocations - before, 0, "\(label): allocations on the render path")
        }
    }

    /// The kernel as the source node runs it: open, steer, crossover restart, duck, fade, switch slot.
    func testKernelRenderAllocatesNothing() throws {
        let sources = try StudySources.all()
        let kernel = LiveSonificationKernel()
        var slots: [UInt32] = []
        for s in sources {
            let (r, twin) = LiveSonificationAudio.makeRendererPair(s.sonificationSource)
            slots.append(kernel.register(r, twin: twin, gain: 1)!)
        }
        let out = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
        defer { out.deallocate() }
        guard RenderThreadAllocationCounter.install() else { return XCTFail("malloc_logger hook unavailable") }
        defer { RenderThreadAllocationCounter.uninstall() }
        var commands = 0
        for k in 0..<4000 {
            // Commands land between render calls (main thread in production).
            switch k % 97 {
            case 0: kernel.open(slot: slots[(k / 97) % slots.count], fadeInFrames: 0); commands += 1
            case 40: kernel.open(slot: slots[(k / 97 + 1) % slots.count], fadeInFrames: 441); commands += 1
            case 55: kernel.open(slot: slots[(k / 97) % slots.count], fadeInFrames: 0); commands += 1
            case 70: kernel.close(fadeOutFrames: 2000); commands += 1
            case 80: kernel.close(fadeOutFrames: 0); commands += 1
            default: break
            }
            kernel.setRate(Float(0.5 + 1.5 * (0.5 + 0.5 * sin(Double(k) * 0.02))))
            kernel.setPitchCents(Float(1200 * sin(Double(k) * 0.017)))
            RenderThreadAllocationCounter.arm()
            kernel.render(into: out, frames: k % 7 == 0 ? 4096 : 256)
            RenderThreadAllocationCounter.disarm()
        }
        XCTAssertGreaterThan(kernel.starts, 50, "the drive did not exercise restarts (\(commands) commands)")
        XCTAssertEqual(RenderThreadAllocationCounter.allocations, 0, "allocations in the kernel's render")
    }

    /// 60 s of audio per source: a looped varying drive with pen
    /// lifts. Every sample finite, none subnormal, |y| <= 2.
    func testSoakIsFiniteAndDenormalFree() throws {
        let sources = try StudySources.all()
        let block = 256
        let blocks = Int(60 * Self.sr) / block
        let out = UnsafeMutablePointer<Float>.allocate(capacity: block)
        defer { out.deallocate() }
        do {
            for s in sources {
                let r = SonificationRendererUnderTest.make(s)
                r.reset()
                var nonFinite = 0, subnormal = 0
                var peak: Float = 0
                for k in 0..<blocks {
                    let t = Double(k * block) / Self.sr
                    r.setRate(Float(1.25 + 0.75 * sin(t * 1.7)))
                    r.setPitchCents(s.isCarrier ? Float(1200 * sin(t * 0.9)) : 0)
                    let phase = t.truncatingRemainder(dividingBy: 3.0)
                    r.setGate(phase < 2.4)
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
    }
}
