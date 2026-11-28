// NaiveResampleRenderer.swift
// PrimaeNative
//
// Bake-off candidate "NaiveResample": linear-interpolation varispeed of
// the looped source. Rate and pitch are NOT independent here: the read
// increment is `rate * 2^(cents/1200)`, so a faster rate also raises the
// pitch (the "chipmunk" coupling every other candidate exists to avoid).
// It is the listening ANCHOR of the blind test and the trivially
// low-latency reference of the objective bench (no analysis, no look-ahead:
// claimed latency 0 frames).
//
// Gate: a linear 2 ms gain ramp both ways (click-free). When the ramp has
// fully closed, the read position returns to the source start, so a gate
// that opens after a full close starts the source from the top (the same
// convention as the AppleTimePitch adapter).
// Parameter smoothing: one-pole on the read increment, 5 ms time constant.

import Foundation
import Synchronization
@testable import PrimaeNative

nonisolated final class NaiveResampleRenderer: SonificationRenderer {
    static var candidateName: String { "NaiveResample" }

    private let source: UnsafeMutablePointer<Float>
    private let count: Int
    private let smoothing: Double
    private let gainStep: Float

    private let rateTarget = Atomic<UInt32>(Float(1).bitPattern)
    private let centsTarget = Atomic<UInt32>(Float(0).bitPattern)
    private let gateTarget = Atomic<Bool>(false)

    // Render-thread state.
    private var position: Double = 0
    private var increment: Double = 1
    private var gain: Float = 0

    let claimedLatencyFrames: Int = 0

    init(source: [Float], sampleRate: Double, kind: SourceKind, maxFramesPerRender: Int) {
        count = max(source.count, 1)
        // One guard sample past the end (a copy of the first) so the
        // interpolation at the seam never reads out of bounds.
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: count + 1)
        storage.initialize(repeating: 0, count: count + 1)
        source.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress { storage.update(from: base, count: buf.count) }
        }
        storage[count] = storage[0]
        self.source = storage
        smoothing = 1 - exp(-1 / (0.005 * sampleRate))
        gainStep = 1 / Float(max(1, (0.002 * sampleRate).rounded()))
    }

    deinit { source.deallocate() }

    func setRate(_ rate: Float) { rateTarget.storeFloat(min(max(rate, 0.25), 4)) }
    func setPitchCents(_ cents: Float) { centsTarget.storeFloat(min(max(cents, -2400), 2400)) }
    func setGate(_ open: Bool) { gateTarget.store(open, ordering: .relaxed) }

    func render(into out: UnsafeMutablePointer<Float>, frames: Int) {
        let open = gateTarget.load(ordering: .relaxed)
        let target = Double(rateTarget.loadFloat()) * pow(2, Double(centsTarget.loadFloat()) / 1200)
        let end = Double(count)
        for i in 0..<frames {
            if gain <= 0 && !open {
                // Fully closed: park at the top, snap the increment.
                position = 0
                increment = target
                out[i] = 0
                continue
            }
            if gain <= 0 { increment = target }
            increment += (target - increment) * smoothing
            let index = Int(position)
            let frac = Float(position - Double(index))
            let a = source[index], b = source[index + 1]
            gain = open ? min(1, gain + gainStep) : max(0, gain - gainStep)
            out[i] = (a + (b - a) * frac) * gain
            position += increment
            if position >= end { position -= end }
        }
    }

    func reset() {
        rateTarget.storeFloat(1)
        centsTarget.storeFloat(0)
        gateTarget.store(false, ordering: .relaxed)
        position = 0
        increment = 1
        gain = 0
    }
}
