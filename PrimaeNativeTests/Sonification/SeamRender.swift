// SeamRender.swift
// PrimaeNativeTests — lane SEAM2 (2026-11-04): renders a TDPSOLA renderer at a steady rate and marks the loop
// wraps from the renderer's own read-head (`debugReadHead`, `debugLoopBounds`), not from a model of it.
import Foundation
#if canImport(PrimaeNative)
@testable import PrimaeNative
#endif

nonisolated struct SeamRendered {
    var samples: [Float]
    var wraps: [Double]     // seconds, the instant the read-head crossed the loop end
    var entry: Double       // seconds, when the read-head first reached the loop start (after the attack)
    var minHeadAfterEntry = Double.infinity   // the read-head never goes back into the attack once the loop is entered
}

nonisolated enum SeamRender {
    /// `seconds` of a steady stroke (gate open, pitch 0) at `rate`, rendered in 64-frame blocks.
    static func steady(_ r: TDPSOLA, rate: Float, seconds: Double = 12) -> SeamRendered {
        let sr = r.sampleRate
        r.reset(); r.setRate(rate); r.setPitchCents(0); r.setGate(true)
        var y = [Float](repeating: 0, count: Int(seconds * sr))
        var wraps: [Double] = []
        var entry = 0.0
        var prev = 0.0
        var minHead = Double.infinity
        var buf = [Float](repeating: 0, count: 64)
        let bounds = r.debugLoopBounds
        var i = 0
        while i < y.count {
            let m = min(64, y.count - i)
            buf.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, frames: m) }
            for k in 0..<m { y[i + k] = buf[k] }
            let s = r.debugReadHead
            if s < prev - 1 {
                wraps.append((Double(i) + (bounds.end - prev) / Double(rate)) / sr)
            } else if entry == 0 && s >= bounds.start && prev < bounds.start {
                entry = Double(i) / sr
            }
            if entry > 0 { minHead = min(minHead, s) }
            prev = s
            i += m
        }
        return SeamRendered(samples: y, wraps: wraps, entry: entry, minHeadAfterEntry: minHead)
    }
}
