// R20StageSupport.swift
// PrimaeNativeTests: lane R20 (audio stage measurement, 2026-11-08)
//
// Instruments for the r18 kernel stages (stroke tone: gain + low-pass + mute; pressure gain; roughness): an offline
// driver that renders in the I/O call sizes the iPad really uses, and measurements that read time constants, clicks and
// costs off the RENDERED OUTPUT, never off the code. The reference is a second kernel that renders the identical
// sound with every stage off (r17 path, bit-exact: `StrokeToneKernelTests.defaultsBitIdentical`), so
// `ratio = on / off` is the stage's own transfer, sample for sample.
//
// Call sizes (MEASURED, env3/raw/env3/*/rt.tsv on the iPad: 235 frames x 15310 calls, 236 x 3828; meta.txt ioBuffer
// 0.005333 s, session 48 kHz): the source node runs at 44.1 kHz behind the main mixer's sample-rate converter, so
// one 256-frame hardware buffer is 235.2 source frames per call. `Pattern.ipad` reproduces that sequence.

import Foundation
import CoreGraphics
@testable import PrimaeNative

nonisolated enum R20 {
    static let sr = LiveSonificationKernel.sampleRate

    enum Pattern: CustomStringConvertible {
        case ipad
        case fixed(Int)
        var description: String {
            switch self { case .ipad: return "ipad(235.2)"; case .fixed(let n): return "fixed\(n)" }
        }
        /// Frames of render call `k`.
        func size(_ k: Int) -> Int {
            switch self {
            case .ipad: return Int((Double(k + 1) * 235.2).rounded(.down)) - Int((Double(k) * 235.2).rounded(.down))
            case .fixed(let n): return n
            }
        }
        var seconds: Double {
            switch self { case .ipad: return 235.2 / R20.sr; case .fixed(let n): return Double(min(n, 512)) / R20.sr }
        }
    }

    /// Renders one study sound through a kernel in `pattern`-sized calls; parameters are written BETWEEN calls, as the touch
    /// thread's atomics land at the next I/O callback.
    final class Driver {
        let kernel: LiveSonificationKernel
        let pattern: Pattern
        private(set) var y: [Float] = []
        private(set) var starts: [Int] = []
        private var k = 0

        init(source: StudySource, pattern: Pattern = .ipad, open: Bool = true,
             make: () -> LiveSonificationKernel = { LiveSonificationKernel() }) {
            kernel = make()
            self.pattern = pattern
            let (a, b) = LiveSonificationAudio.makeRendererPair(source.sonificationSource)
            let slot = kernel.register(a, twin: b, gain: 1)!
            if open { kernel.open(slot: slot, fadeInFrames: 0) }
            self.slot = slot
        }
        let slot: UInt32
        var count: Int { y.count }

        func run(_ seconds: Double) {
            let target = y.count + Int((seconds * R20.sr).rounded())
            while y.count < target {
                let n = pattern.size(k); k += 1
                let base = y.count
                // the kernel renders any larger request as chunks of `chunkFrames`: a stage's state changes per chunk
                var c = 0
                while c < n { starts.append(base + c); c += LiveSonificationKernel.chunkFrames }
                y.append(contentsOf: repeatElement(0, count: n))
                y.withUnsafeMutableBufferPointer { _ = kernel.render(into: $0.baseAddress! + base, frames: n) }
            }
        }
    }

    // MARK: Statistics

    static func percentile(_ v: [Double], _ q: Double) -> Double {
        guard !v.isEmpty else { return 0 }
        let s = v.sorted(); return s[min(s.count - 1, Int(Double(s.count - 1) * q))]
    }
    static func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }

    // MARK: Time constants read from output

    struct TC { var tau63: Double?; var t90: Double?; var t99: Double?; var tMinus60: Double? }

    /// First time (ms) a rising progress series reaches `level`, interpolated.
    static func crossing(_ pts: [(ms: Double, p: Double)], _ level: Double) -> Double? {
        var prev: (ms: Double, p: Double)?
        for q in pts {
            if q.p >= level {
                if let p0 = prev, q.p > p0.p { return p0.ms + (q.ms - p0.ms) * (level - p0.p) / (q.p - p0.p) }
                return q.ms
            }
            prev = q
        }
        return nil
    }

    static func tc(_ pts: [(ms: Double, p: Double)], tMinus60: Double? = nil) -> TC {
        TC(tau63: crossing(pts, 0.632), t90: crossing(pts, 0.9), t99: crossing(pts, 0.99), tMinus60: tMinus60)
    }

    /// Gain-type step at sample `n0` (a stage that multiplies the signal): progress of y_on/y_off from `g0` to `g1`.
    /// Only samples where the reference is well away from a zero crossing carry a ratio.
    static func gainProgress(on: [Float], off: [Float], step n0: Int, g0: Double, g1: Double, span: Double)
        -> (pts: [(ms: Double, p: Double)], tMinus60: Double?) {
        let end = min(on.count, n0 + Int(span * sr))
        var peak: Float = 0
        for i in n0..<end { peak = max(peak, abs(off[i])) }
        var out: [(Double, Double)] = []
        var m60: Double?
        for i in n0..<end where abs(off[i]) > 0.3 * peak {
            let r = Double(on[i]) / Double(off[i])
            out.append((Double(i - n0) / sr * 1000, (r - g0) / (g1 - g0)))
            if g1 == 0, m60 == nil, abs(r) < 1e-3 { m60 = Double(i - n0) / sr * 1000 }
        }
        return (out, m60)
    }

    /// The one-pole low-pass' cutoff per render call, fitted from the output: with the unfiltered signal `x` (= `off`) and the
    /// filtered `z` (= `on`, level stage neutral), z[i] - z[i-1] = a (x[i] - z[i-1]) with `a` constant over a call.
    static func cutoffTrack(on: [Float], off: [Float], starts: [Int], from n0: Int)
        -> [(ms: Double, hz: Double)] {
        var out: [(Double, Double)] = []
        for b in 0..<starts.count {
            let s = starts[b], e = b + 1 < starts.count ? starts[b + 1] : on.count
            guard s >= n0, s > 0 else { continue }
            var num = 0.0, den = 0.0
            for i in s..<e {
                let d = Double(off[i]) - Double(on[i - 1])
                num += (Double(on[i]) - Double(on[i - 1])) * d
                den += d * d
            }
            guard den > 1e-12 else { continue }
            let a = min(0.999999, max(1e-9, num / den))
            out.append((Double(s + (e - s) / 2 - n0) / sr * 1000, -log(1 - a) * sr / (2 * Double.pi)))
        }
        return out
    }

    /// Progress of a log-domain cutoff track from `f0` to `f1`.
    static func cutoffProgress(_ track: [(ms: Double, hz: Double)], f0: Double, f1: Double) -> [(ms: Double, p: Double)] {
        track.map { ($0.ms, (log(f0) - log($0.hz)) / (log(f0) - log(f1))) }
    }

    /// The roughness stage's depth per render call: 1 - on/off = d(i) h(i), h = 0.5 - 0.5 cos(2 pi ph), `ph` replayed
    /// exactly as the kernel advances it (Float, from 0 at the first call of the stage).
    static func depthTrack(on: [Float], off: [Float], starts: [Int], from n0: Int, rateHz: Float) -> [(ms: Double, d: Double)] {
        var ph: Float = 0
        let step = rateHz / Float(sr)
        var out: [(Double, Double)] = []
        for b in 0..<starts.count {
            let s = starts[b], e = b + 1 < starts.count ? starts[b + 1] : on.count
            guard s >= n0 else { continue }
            var num = 0.0, den = 0.0
            for i in s..<e {
                let h = Double(0.5 - 0.5 * cos(2 * Float.pi * ph))
                ph += step; if ph >= 1 { ph -= 1 }
                guard abs(off[i]) > 1e-3 else { continue }
                let r = 1 - Double(on[i]) / Double(off[i])
                num += r * h; den += h * h
            }
            if den > 1e-9 { out.append((Double(s + (e - s) / 2 - n0) / sr * 1000, num / den)) }
        }
        return out
    }

    // MARK: Clicks (PopMeter)

    struct Click { var splatterDB: Double; var slopeDB: Double; var deltaRatio: Double }

    static func maxDelta(_ y: [Float], _ a: Int, _ b: Int) -> Float {
        var m: Float = 0
        for i in max(1, a)..<min(y.count, b) { m = max(m, abs(y[i] - y[i - 1])) }
        return m
    }

    /// The window `[n0, n0 + window)` of `y` against the steady reference `steady` (the same sound, no stage, no transition).
    static func click(_ y: [Float], steady: [Float], at n0: Int, window: Double) -> Click {
        let ref = PopMeter.reference(steady, hp: PopMeter.highPass(steady, sr: sr), sr: sr)
        let hp = PopMeter.highPass(y, sr: sr)
        let m = PopMeter.onset(y, hp: hp, at: n0, sr: sr, ref: ref, window: window)
        let w = Int(window * sr)
        let steadyDelta = maxDelta(steady, Int(0.3 * sr), steady.count)
        return Click(splatterDB: m.splatterDB, slopeDB: m.slopeDB,
                     deltaRatio: Double(maxDelta(y, n0, n0 + w) / max(steadyDelta, 1e-9)))
    }
}

/// A deterministic generator for the synthetic strokes (as `PopCaptureUITests.RNG`).
nonisolated struct R20RNG {
    var s: UInt64
    mutating func next() -> Double {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return Double(s >> 11) / Double(1 << 53)
    }
    mutating func normal() -> Double {
        let u1 = max(next(), 1e-12), u2 = next()
        return (-2 * log(u1)).squareRoot() * cos(2 * Double.pi * u2)
    }
}

/// The pen on the real touch path (view model + dispatcher), driving the direction mute.
@MainActor enum R20Pen {
    @MainActor static func makeVM(audio: R20ToneAudio) -> TracingViewModel {
        var deps = TracingDependencies.stub.with(audioCondition: .phoneme).with(audio: audio)
        deps.directionMuteEnabled = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 400, height: 400)
        vm.strokeTracker.load(LetterStrokes(letter: "T", checkpointRadius: 0.1, strokes: [
            StrokeDefinition(id: 1, checkpoints: (0...16).map { Checkpoint(x: 0.1 + 0.05 * CGFloat($0), y: 0.5) })
        ]))
        return vm
    }

    /// A pen at 150 pt/s, sampled at 120 Hz, drifting backwards along a horizontal reference stroke in a zig-zag that keeps it
    /// inside the gate; its heading against the stroke is `base` degrees + `wobble` degrees x sin(2 pi 0.7 t) + position jitter
    /// `sigma` pt. cos(104.48 deg) = -0.25, the mute threshold. Returns toggles/s, the ideal crossings/s, flickers (<100 ms).
    @MainActor static func chatter(base: Double, wobble: Double, sigma: Double, seconds: Double = 10, seed: UInt64 = 7, margin: Float? = nil)
        -> (toggles: Double, crossings: Double, flickers: Int, mutedFraction: Double, mutes: [Bool]) {
        let audio = R20ToneAudio()
        let vm = makeVM(audio: audio)
        if let margin { vm.touchDispatcher.directionReleaseMarginCosine = margin }
        let canvas = CGSize(width: 400, height: 400)
        var rng = R20RNG(s: seed)
        let hz = 120.0, speed = 150.0
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 360, y: 200)
        vm.beginTouch(at: p, t: t)
        var sign = 1.0
        var ideal: [Bool] = []
        for i in 0..<Int(seconds * hz) {
            let time = Double(i) / hz
            let theta = (base + wobble * sin(2 * Double.pi * 0.7 * time)) * Double.pi / 180
            if p.y > 260 { sign = -1 } else if p.y < 140 { sign = 1 }
            p.x += CGFloat(speed / hz * cos(theta) + sigma * rng.normal())
            p.y += CGFloat(speed / hz * sin(theta) * sign + sigma * rng.normal())
            t += 1 / hz
            vm.updateTouch(at: p, t: t, canvasSize: canvas)
            ideal.append(cos(theta) < Double(StrokeTone.backwardCosine))
        }
        let m = audio.mutes
        var toggles = 0, flickers = 0, runStart = 0
        for i in 1..<m.count where m[i] != m[i - 1] {
            toggles += 1
            if runStart > 0, i - runStart < Int(0.1 * hz) { flickers += 1 }   // an interior run shorter than 100 ms
            runStart = i
        }
        var crossings = 0
        for i in 1..<ideal.count where ideal[i] != ideal[i - 1] { crossings += 1 }
        let on = m.filter { $0 }.count
        return (Double(toggles) / seconds, Double(crossings) / seconds, flickers, m.isEmpty ? 0 : Double(on) / Double(m.count), m)
    }

    /// Forward 1 s, back 1 s, forward 1 s at 150 pt/s, 120 Hz, no jitter: ms from each reversal to the mute / the unmute.
    @MainActor static func reversalLatency(margin: Float) -> (mute: Double?, unmute: Double?) {
        let audio = R20ToneAudio()
        let vm = makeVM(audio: audio)
        vm.touchDispatcher.directionReleaseMarginCosine = margin
        let canvas = CGSize(width: 400, height: 400)
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 100, y: 200)
        vm.beginTouch(at: p, t: t)
        var dir: CGFloat = 1
        var muteAt: Double?, unmuteAt: Double?
        for i in 0..<360 {
            let time = Double(i) / 120
            if i == 120 { dir = -1 }
            if i == 240 { dir = 1 }
            p.x += dir * 150 / 120
            t += 1 / 120
            let before = audio.mutes.count
            vm.updateTouch(at: p, t: t, canvasSize: canvas)
            if audio.mutes.count > before, let m = audio.mutes.last {
                if m, muteAt == nil, i >= 120 { muteAt = (time - 1.0) * 1000 }
                if !m, muteAt != nil, unmuteAt == nil, i >= 240 { unmuteAt = (time - 2.0) * 1000 }
            }
        }
        return (muteAt, unmuteAt)
    }

}

@MainActor
final class R20ToneAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var mutes: [Bool] = []
    func loadAudioFile(named: String, autoplay: Bool) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func setStrokeMute(_ muted: Bool) { mutes.append(muted) }
}
