// SeamControls.swift
// PrimaeNativeTests — lane SEAM2 (2026-11-04): the seam meter's controls.
// A meter that cannot flag a known defect, or that flags a clean signal, says nothing:
//   steadyTone      a harmonic tone, constant level and spectrum  -> must NOT flag (wraps marked every 2 s)
//   levelStep       the same tone, +`db` dB after `at` seconds      -> must flag level, step ~ db
//   timbreStep      brighter harmonic mix after `at`, level kept    -> must flag timbre / centroid
//   sawtooth        gain falls `db` dB over each 2 s cycle, then resets -> the periodic drift-reset
import Foundation

nonisolated enum SeamControls {
    static let sr = 44100.0
    static let wraps2s: [Double] = [2, 4, 6, 8, 10]

    /// Tone at `f0` with harmonic amplitudes 1/k^`tilt` (k = 1...12), peak-normalised after the gain.
    static func tone(seconds: Double, f0: Double = 230, tilt: Double = 1.0, gain: (Double) -> Double = { _ in 1 },
                     tiltAt: ((Double) -> Double)? = nil) -> [Float] {
        let n = Int(seconds * sr)
        var y = [Float](repeating: 0, count: n)
        var norm: [Double: Double] = [:]
        func harmonicSum(_ t: Double, _ tl: Double) -> Double {
            var s = 0.0
            for k in 1...12 { s += sin(2 * Double.pi * f0 * Double(k) * t + Double(k)) / pow(Double(k), tl) }
            return s
        }
        for i in 0..<n {
            let t = Double(i) / sr
            let tl = tiltAt?(t) ?? tilt
            // Equal RMS for any tilt: sum of squared amplitudes / 2.
            let key = tl
            if norm[key] == nil { norm[key] = (1...12).reduce(0.0) { $0 + 1 / pow(Double($1), 2 * tl) / 2 }.squareRoot() }
            y[i] = Float(0.1 * gain(t) * harmonicSum(t, tl) / norm[key]!)
        }
        return y
    }

    static func steadyTone() -> [Float] { tone(seconds: 12) }
    static func levelStep(db: Double, at: Double) -> [Float] {
        tone(seconds: 12, gain: { $0 >= at ? pow(10, db / 20) : 1 })
    }
    static func timbreStep(at: Double) -> [Float] { tone(seconds: 12, tiltAt: { $0 >= at ? 0.4 : 1.4 }) }
    static func sawtooth(db: Double) -> [Float] {
        tone(seconds: 12, gain: { t in pow(10, -db * (t.truncatingRemainder(dividingBy: 2) / 2) / 20) })
    }
}
