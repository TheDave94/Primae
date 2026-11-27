// TDPSOLA2Sinc.swift
// PrimaeNative — pitch bake-off phase 2, candidate C1 "TDPSOLA2" (2026-11-23); the phoneme arm's renderer from protocol r31 (lane PITCHWIN, 2026-11-26)
//
// The band-limited interpolator of r27 candidate A (branch t3/tdpsola-pitch-candidates, 5dcc4b4f): a Kaiser-windowed
// sinc, beta 8, 8 zero crossings, tabulated at 256 entries per unit and read with linear interpolation between
// entries. Factored out of the renderer so the unvoiced F branch (item 1), the formant co-shift gamma (item 6), the
// harmonic/noise bank reads and the init-time 16 kHz decimation of the epoch refinement (item 5) share ONE kernel.
//
// Real-time contract: `read` allocates nothing and touches no Swift array (the table is an UnsafeMutablePointer
// owned by the caller and filled once, off the render thread, by `makeTable`).

import Foundation

nonisolated enum TDPSOLA2Sinc {
    static let zeros = 8
    static let res = 256
    static let beta = 8.0
    static var tableCount: Int { zeros * res + 2 }

    /// The tabulated kernel, sinc(t) * Kaiser(t / zeros), t = i / res. Caller owns (and deallocates) the pointer.
    static func makeTable() -> UnsafeMutablePointer<Float> {
        let tn = tableCount
        let p = UnsafeMutablePointer<Float>.allocate(capacity: tn)
        for i in 0..<tn {
            let t = Double(i) / Double(res)
            let r = t / Double(zeros)
            let sinc = t == 0 ? 1 : sin(Double.pi * t) / (Double.pi * t)
            let win = r < 1 ? besselI0(beta * (1 - r * r).squareRoot()) / besselI0(beta) : 0
            (p + i).initialize(to: Float(sinc * win))
        }
        return p
    }

    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0, k = 1.0
        while term > 1e-12 * sum { term *= (x / (2 * k)) * (x / (2 * k)); sum += term; k += 1 }
        return sum
    }

    /// floor(v) without the trapping `Int(Double)` (see TDPSOLA.floorInt). Exact for |v| < 2^51.
    @inline(__always) static func floorInt(_ v: Double) -> Int {
        let fl = v.rounded(.down)
        return Int(truncatingIfNeeded: (fl + 0x1.8p52).bitPattern) &- Int(truncatingIfNeeded: (0x1.8p52 as Double).bitPattern)
    }

    /// Band-limited read of `base` at fractional `pos`, low-passed at `cut` x the Nyquist of `base` (unity DC gain).
    /// The caller guarantees base[floor(pos - zeros/cut) ... floor(pos + zeros/cut)] is readable.
    @inline(__always) static func read(_ base: UnsafePointer<Float>, _ table: UnsafePointer<Float>,
                                       _ pos: Double, _ cut: Double) -> Float {
        let half = Double(zeros) / cut
        var k = floorInt(pos - half) &+ 1
        let kEnd = floorInt(pos + half)
        let scale = cut * Double(res)
        var acc: Float = 0
        while k <= kEnd {
            let u = abs(Double(k) - pos) * scale
            let i = floorInt(u)
            let f = Float(u - Double(i))
            acc += base[k] * (table[i] + (table[i &+ 1] - table[i]) * f)
            k &+= 1
        }
        return acc * Float(cut)
    }
}
