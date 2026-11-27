// TDPSOLA2HarmonicNoise.swift
// PrimaeNative — pitch bake-off phase 2, candidate C1 "TDPSOLA2", item 4 (2026-11-23); the phoneme arm's renderer from protocol r31 (lane PITCHWIN, 2026-11-26)
//
// Harmonic/noise separation at init, after Stylianou 2001 (HNM) and Bailly 1999 (periodic modulation), as the
// prototype `method/psola_v2_proto.py` does it:
//   - the analysis grain g_i of mark i is the played source under a Hann window of +-T_i (T_i = the mark's period)
//     around the mark;
//   - h_i is the weighted mean (1, 2, 3, 2, 1) of the grains i-2 ... i+2, each aligned at its OWN mark. The prototype
//     rounds the marks; here the neighbours are read at sub-sample alignment (cubic), so the harmonics up to the top of
//     the band average in phase instead of losing up to half a sample of alignment;
//   - n_i = g_i - h_i (the aperiodic part: aspiration, jitter residue).
// The renderer plays h_i + n_j for a grain whose noise must not repeat (see TDPSOLA2, `spawnNext`).
//
// Storage: for every LOOP mark (the renderer only ever centres grains on those), H and N on an integer grid of
// 2R + 1 samples centred on round(mark), R = ceil(max period) + `pad`. The pad keeps a cubic or a band-limited read
// (up to 16 taps each side) inside the slot. Allocated once here; the render thread only reads it.

import Foundation

nonisolated final class TDPSOLA2HarmonicNoise: @unchecked Sendable {
    /// Extra samples each side of +-ceil(max period): cubic (2) + band-limited read at beta <= 2 (16) + rounding.
    static let pad = 22
    static let weights: [Double] = [1, 2, 3, 2, 1]

    let firstMark: Int
    let lastMark: Int
    /// Samples each side of round(mark).
    let radius: Int
    var slotLength: Int { 2 * radius + 1 }
    /// [H slot 0][N slot 0][H slot 1][N slot 1] ...
    let store: UnsafeMutablePointer<Float>
    let storeCount: Int
    var bytes: Int { storeCount * MemoryLayout<Float>.stride }

    /// `x` = the samples the renderer plays (after the loop seam and the pulse limiter); `marks`/`periods` = its marks.
    init(_ x: UnsafePointer<Float>, count: Int, marks: [Double], periods: [Double], first: Int, last: Int) {
        firstMark = first
        lastMark = last
        let tMax = periods.max() ?? 1
        radius = Int(tMax.rounded(.up)) + Self.pad
        let len = 2 * radius + 1
        let slots = max(0, last - first + 1)
        storeCount = max(1, 2 * slots * len)
        store = .allocate(capacity: storeCount)
        store.initialize(repeating: 0, count: storeCount)
        guard slots > 0 else { return }
        // Cubic (Catmull-Rom) read of x; 0 outside.
        func at(_ k: Int) -> Double { k >= 0 && k < count ? Double(x[k]) : 0 }
        func read(_ p: Double) -> Double {
            let fl = p.rounded(.down)
            let k = Int(fl)
            let t = p - fl
            if t == 0 { return at(k) }
            let y0 = at(k - 1), y1 = at(k), y2 = at(k + 1), y3 = at(k + 2)
            let c1 = 0.5 * (y2 - y0)
            let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
            let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
            return ((c3 * t + c2) * t + c1) * t + y1
        }
        // The analysis grain of mark q at offset d from that mark.
        func grain(_ q: Int, _ d: Double) -> Double {
            let t = periods[q]
            guard abs(d) < t else { return 0 }
            return read(marks[q] + d) * (0.5 + 0.5 * cos(Double.pi * d / t))
        }
        let wSum = Self.weights.reduce(0, +)
        var g = [Double](repeating: 0, count: len)
        for i in first...last {
            let mi = marks[i].rounded()
            let base = store + 2 * (i - first) * len
            for k in 0..<len {
                let d = mi + Double(k - radius) - marks[i]      // offset from mark i of this grid sample
                g[k] = grain(i, d)
                var h = 0.0
                for (w, q) in zip(Self.weights, (i - 2)...(i + 2)) {
                    h += w * grain(min(marks.count - 1, max(0, q)), d)
                }
                h /= wSum
                base[k] = Float(h)
                base[len + k] = Float(g[k] - h)
            }
        }
    }

    deinit { store.deallocate() }

    /// H slot of mark i (first...last).
    @inline(__always) func harmonic(_ i: Int) -> UnsafeMutablePointer<Float> { store + 2 * (i - firstMark) * slotLength }
    /// N slot of mark i.
    @inline(__always) func noise(_ i: Int) -> UnsafeMutablePointer<Float> { harmonic(i) + slotLength }
}
