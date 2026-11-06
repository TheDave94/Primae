// SonificationTestSupport.swift
// PrimaeNativeTests — protocol r17 regression suite (2026-11-03)
//
// Shared instruments for the live sonification engines: the study's real
// sources, a buffer driver that writes parameters BETWEEN render calls (the
// way the touch thread's atomics land at the next I/O callback), and the
// metrics. Pure buffers: no AVAudioEngine, so everything here runs on the
// simulator and therefore in CI.
//
// One engine (TDPSOLA; RULINGS 2026-11-03, the A/B is over), built exactly
// as production builds it (`SonificationRendererUnderTest.make`).

import Foundation
import AVFoundation
import Darwin
@testable import PrimaeNative

// MARK: - Renderer and sources

nonisolated enum SonificationRendererUnderTest {
    static func make(_ source: StudySource) -> TDPSOLA {
        LiveSonificationAudio.makeRenderer(source.sonificationSource)
    }
}

/// One shipped arm sound, decoded at the kernel rate exactly as production does.
nonisolated struct StudySource: Sendable, CustomStringConvertible {
    let name: String
    let samples: [Float]
    let kind: SourceKind
    var description: String { name }
    var sampleRate: Double { LiveSonificationKernel.sampleRate }
    /// R17D: the shipped file's recorded onset, exactly as `SonificationSource.load` attaches it.
    /// A derived probe source ("A_phoneme1+AM") keeps its file's onset: the derivation keeps the timing.
    var onset: RecordedOnset? {
        PhonemeOnsets.onset(forFileNamed: "\(name.split(separator: "+").first.map(String.init) ?? name).wav")
    }
    var sonificationSource: SonificationSource {
        SonificationSource(key: "test:\(name)", samples: samples, kind: kind, gain: 1, onset: onset)
    }
    var isCarrier: Bool { kind == .carrier }
}

nonisolated enum StudySources {
    /// The five study phonemes (A F I L M) and the spatial carrier.
    static let names = TrainedLetterSubset.studyLetters.map { "\($0)_phoneme1" } + ["spatial_carrier"]
    static let voicedNames = ["A_phoneme1", "I_phoneme1", "L_phoneme1", "M_phoneme1"]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: StudySource] = [:]

    static func load(_ name: String) throws -> StudySource {
        lock.lock(); defer { lock.unlock() }
        if let s = cache[name] { return s }
        let url: URL?
        if name == "spatial_carrier" {
            url = PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Sonification", name: name, ext: "wav"))
                ?? PrimaeBundle.audioURL(for: "Resources/Sonification/spatial_carrier.wav")
        } else {
            let letter = String(name.prefix(1))
            url = PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(letter)", name: name, ext: "wav"))
        }
        guard let url else { throw SupportError.missing(name) }
        let samples = try SonificationSource.decodeMono(url: url, sampleRate: LiveSonificationKernel.sampleRate)
        let s = StudySource(name: name, samples: samples, kind: SonificationSource.kind(forFileAt: url))
        cache[name] = s
        return s
    }

    static func all() throws -> [StudySource] { try names.map(load) }

    enum SupportError: Error { case missing(String) }
}

// MARK: - Driver

nonisolated struct ControlEvent {
    let time: Double          // seconds from render start
    var rate: Float? = nil
    var cents: Float? = nil
    var gate: Bool? = nil
}

nonisolated enum SonificationDriver {
    static let buffer = 256

    /// Renders `seconds` of output; each event is applied before the first
    /// buffer that starts at or after its time.
    static func render(_ r: any SonificationRenderer, seconds: Double, events: [ControlEvent],
                       sampleRate: Double = LiveSonificationKernel.sampleRate) -> [Float] {
        let total = Int(seconds * sampleRate)
        var out = [Float](repeating: 0, count: total)
        let sorted = events.sorted { $0.time < $1.time }
        var next = 0
        var pos = 0
        out.withUnsafeMutableBufferPointer { b in
            while pos < total {
                while next < sorted.count && Int((sorted[next].time * sampleRate).rounded(.up)) <= pos {
                    let e = sorted[next]
                    if let v = e.rate { r.setRate(v) }
                    if let v = e.cents { r.setPitchCents(v) }
                    if let v = e.gate { r.setGate(v) }
                    next += 1
                }
                let n = min(buffer, total - pos)
                r.render(into: b.baseAddress! + pos, frames: n)
                pos += n
            }
        }
        return out
    }

    /// Gate open at 0 with fixed rate and cents.
    static func steady(_ r: any SonificationRenderer, seconds: Double, rate: Float, cents: Float = 0) -> [Float] {
        r.reset()
        return render(r, seconds: seconds, events: [ControlEvent(time: 0, rate: rate, cents: cents, gate: true)])
    }

    /// The frame at which an event at `time` is applied.
    static func appliedFrame(_ time: Double, sampleRate: Double = LiveSonificationKernel.sampleRate) -> Int {
        let f = Int((time * sampleRate).rounded(.up))
        return ((f + buffer - 1) / buffer) * buffer
    }
}

// MARK: - Metrics

nonisolated enum SonificationMetrics {
    static func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        var s = 0.0
        for v in x { s += Double(v) * Double(v) }
        return (s / Double(x.count)).squareRoot()
    }

    static func dB(_ a: Double, _ ref: Double) -> Double { a <= 0 || ref <= 0 ? -300 : 20 * log10(a / ref) }

    /// Frames from `from` to the END of the first 5 ms window (hop 16) whose
    /// RMS is >= -20 dB re `steady`; nil when never.
    static func onsetFrames(_ y: [Float], from: Int, steadyRMS: Double, sampleRate: Double) -> Int? {
        let w = Int(0.005 * sampleRate)
        var i = from
        while i + w <= y.count {
            if dB(rms(y[i..<(i + w)]), steadyRMS) >= -20 { return i + w - from }
            i += 16
        }
        return nil
    }

    static func firstNonZero(_ y: [Float], from: Int) -> Int? {
        var i = from
        while i < y.count { if abs(y[i]) > 1e-6 { return i - from }; i += 1 }
        return nil
    }

    static func maxDelta(_ y: [Float], _ range: Range<Int>) -> Float {
        var m: Float = 0
        let lo = max(1, range.lowerBound), hi = min(y.count, range.upperBound)
        guard lo < hi else { return 0 }
        for i in lo..<hi { m = max(m, abs(y[i] - y[i - 1])) }
        return m
    }

    /// f0 (Hz) of `x[from..<from+window]`: normalised autocorrelation over
    /// 70-500 Hz, the FIRST local maximum within 90 % of the best (no
    /// sub-harmonic picks), parabola-refined.
    static func f0(_ x: [Float], from: Int, window: Int = 4096, sampleRate: Double) -> Double? {
        guard from >= 0, from + window + Int(sampleRate / 70) + 2 <= x.count else { return nil }
        let minLag = Int(sampleRate / 500), maxLag = Int(sampleRate / 70)
        var e0 = 0.0
        for i in 0..<window { e0 += Double(x[from + i]) * Double(x[from + i]) }
        guard e0 > 1e-9 else { return nil }
        var r = [Double](repeating: 0, count: maxLag + 2)
        for lag in (minLag - 1)...(maxLag + 1) {
            var c = 0.0, e1 = 0.0
            for i in 0..<window {
                let a = Double(x[from + i]), b = Double(x[from + i + lag])
                c += a * b; e1 += b * b
            }
            r[lag] = e1 > 0 ? c / (e0 * e1).squareRoot() : 0
        }
        var best = -2.0
        for lag in minLag...maxLag { best = max(best, r[lag]) }
        guard best > 0.3 else { return nil }
        for lag in minLag...maxLag where r[lag] >= 0.9 * best && r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1] {
            let a = r[lag - 1], b = r[lag], c = r[lag + 1]
            let d = a - 2 * b + c
            let off = d != 0 ? 0.5 * (a - c) / d : 0
            return sampleRate / (Double(lag) + off)
        }
        return nil
    }

    /// Median f0 over five windows spread through [from, to).
    static func medianF0(_ x: [Float], from: Int, to: Int, sampleRate: Double) -> Double? {
        let window = 4096
        let span = to - from - window - Int(sampleRate / 70) - 2
        guard span > 0 else { return nil }
        let values = (0..<5).compactMap { k in f0(x, from: from + span * k / 4, window: window, sampleRate: sampleRate) }
        guard values.count >= 3 else { return nil }
        return values.sorted()[values.count / 2]
    }

    /// Frequency (Hz) of a tonal signal by hysteresis zero crossings with
    /// linear interpolation, over [from, to).
    static func zeroCrossingFrequency(_ y: [Float], from: Int, to: Int, sampleRate: Double) -> Double? {
        var peak: Float = 0
        for i in from..<to { peak = max(peak, abs(y[i])) }
        guard peak > 1e-4 else { return nil }
        let th = 0.2 * peak
        var armed = false
        var times: [Double] = []
        var lastNeg = from
        for i in (from + 1)..<to {
            if y[i] < -th { armed = true; lastNeg = i }
            if armed && y[i] > th {
                // the zero crossing between lastNeg and i
                var k = lastNeg
                while k < i && !(y[k] <= 0 && y[k + 1] > 0) { k += 1 }
                if k < i {
                    let a = y[k], b = y[k + 1]
                    times.append(Double(k) + Double(-a / (b - a)))
                }
                armed = false
            }
        }
        guard times.count > 10 else { return nil }
        return Double(times.count - 1) * sampleRate / (times.last! - times.first!)
    }

    static func cents(_ f: Double, _ ref: Double) -> Double { 1200 * log2(f / ref) }

    static func isSubnormal(_ v: Float) -> Bool { v != 0 && abs(v) < Float.leastNormalMagnitude }

    /// 40 block RMS values over the render: the golden fingerprint.
    static func fingerprint(_ y: [Float], blocks: Int = 40) -> [Double] {
        let n = y.count / blocks
        return (0..<blocks).map { rms(y[($0 * n)..<(($0 + 1) * n)]) }
    }
}

// MARK: - Rate-step instrument (RVF, ported)

/// The RVF lane's AM-envelope instrument (latency-2026-11-02/RVF.md), ported
/// to this suite: a voiced phoneme amplitude-modulated in SOURCE time at
/// 20 Hz; the output envelope's AM phase says which source time is playing,
/// whatever the pitch does. The primary read-out is the HINGE: where the
/// straight-line fits of source position before ([-0.3, -0.05] s) and after
/// ([+0.2, +0.4] s) the step intersect. A pure delay D reads D; a first-order
/// lag tau reads tau. Validity: both fitted slopes must equal the commanded
/// rates within 3 %.
nonisolated enum RateStepProbe {
    static let fm = 20.0, depth = 0.6
    static let gateOpen = 0.05, stepTime = 0.5, duration = 1.05

    static func modulate(_ x: [Float], sampleRate sr: Double) -> [Float] {
        var y = x
        for i in y.indices { y[i] = x[i] * Float(1 + depth * sin(2 * .pi * fm * Double(i) / sr)) }
        return y
    }

    /// The ideal time-scale modifier: the unmodulated source at its own rate,
    /// times the AM at the commanded position (stepped instantly, `lag` late).
    static func ideal(_ x: [Float], from a: Double, to b: Double, lag: Double, sampleRate sr: Double) -> [Float] {
        let total = Int(duration * sr)
        var y = [Float](repeating: 0, count: total)
        let open = SonificationDriver.appliedFrame(gateOpen, sampleRate: sr)
        let step = SonificationDriver.appliedFrame(stepTime, sampleRate: sr) + Int(lag * sr)
        var pos = 0.0
        for i in open..<total {
            let k = (i - open) % x.count
            y[i] = x[k] * Float(1 + depth * sin(2 * .pi * fm * pos / sr))
            pos += i < step ? Double(a) : Double(b)
        }
        return y
    }

    struct Result { let hinge: Double; let preSlope: Double; let postSlope: Double }

    static func measure(_ y: [Float], sampleRate sr: Double) -> Result? {
        let open = SonificationDriver.appliedFrame(gateOpen, sampleRate: sr)
        let st = Double(SonificationDriver.appliedFrame(stepTime, sampleRate: sr)) / sr
        let track = positionTrack(y, from: open, to: y.count, sampleRate: sr)
        let rel = track.map { (t: $0.t - st, p: $0.p) }
        guard let l0 = lineFit(rel.filter { $0.t >= -0.3 && $0.t <= -0.05 }),
              let l1 = lineFit(rel.filter { $0.t >= 0.2 && $0.t <= 0.4 }),
              abs(l1.slope - l0.slope) > 1e-6 else { return nil }
        return Result(hinge: (l0.intercept - l1.intercept) / (l1.slope - l0.slope),
                      preSlope: l0.slope, postSlope: l1.slope)
    }

    static func lineFit(_ pts: [(t: Double, p: Double)]) -> (slope: Double, intercept: Double)? {
        guard pts.count > 10 else { return nil }
        let n = Double(pts.count)
        let mx = pts.reduce(0.0) { $0 + $1.t } / n, my = pts.reduce(0.0) { $0 + $1.p } / n
        var sxy = 0.0, sxx = 0.0
        for q in pts { sxy += (q.t - mx) * (q.p - my); sxx += (q.t - mx) * (q.t - mx) }
        guard sxx > 0 else { return nil }
        let b = sxy / sxx
        return (b, my - b * mx)
    }

    /// Source position (seconds, unwrapped) per 1 ms of output (RVF fine20Hz settings).
    static func positionTrack(_ y: [Float], from: Int, to: Int, sampleRate sr: Double) -> [(t: Double, p: Double)] {
        let hop = max(1, Int(0.001 * sr)), half = Int(0.010 * sr) / 2
        var centres: [Int] = [], env: [Double] = []
        var c = from + half
        while c + half <= to {
            var s = 0.0
            for j in (c - half)..<(c + half) { s += Double(y[j]) * Double(y[j]) }
            env.append((s / Double(2 * half)).squareRoot()); centres.append(c); c += hop
        }
        let n = env.count
        guard n > 64 else { return [] }
        let m = 50
        var d = [Double](repeating: 0, count: n)
        for k in 0..<n {
            let lo = max(0, k - m), hi = min(n - 1, k + m)
            var acc = 0.0
            for j in lo...hi { acc += env[j] }
            let mean = acc / Double(hi - lo + 1)
            d[k] = mean > 1e-12 ? env[k] / mean - 1 : 0
        }
        let mu = d.reduce(0, +) / Double(n)
        for k in 0..<n { d[k] -= mu }
        var cosT = [Double](repeating: 0, count: n), sinT = [Double](repeating: 0, count: n)
        for k in 0..<n { cosT[k] = cos(2 * .pi * Double(k) / Double(n)); sinT[k] = sin(2 * .pi * Double(k) / Double(n)) }
        var xr = [Double](repeating: 0, count: n), xi = [Double](repeating: 0, count: n)
        for k in 0...(n / 2) {
            var r = 0.0, im = 0.0
            for j in 0..<n { let idx = (j * k) % n; r += d[j] * cosT[idx]; im -= d[j] * sinT[idx] }
            let w: Double = (k == 0 || (n % 2 == 0 && k == n / 2)) ? 1 : 2
            xr[k] = r * w; xi[k] = im * w
        }
        var out: [(t: Double, p: Double)] = []
        var prev: Double?
        var offset = 0.0
        let trim = 80
        for j in 0..<n {
            var zr = 0.0, zi = 0.0
            for k in 0...(n / 2) where xr[k] != 0 || xi[k] != 0 {
                let idx = (j * k) % n
                zr += xr[k] * cosT[idx] - xi[k] * sinT[idx]
                zi += xr[k] * sinT[idx] + xi[k] * cosT[idx]
            }
            var ph = atan2(zi, zr)
            if let p = prev {
                while ph + offset - p > .pi { offset -= 2 * .pi }
                while ph + offset - p < -.pi { offset += 2 * .pi }
            }
            ph += offset
            prev = ph
            if j >= trim && j < n - trim { out.append((t: Double(centres[j]) / sr, p: ph / (2 * .pi * fm))) }
        }
        return out
    }

    /// Drives `r` through the probe: gate open at 0.05 s at rate `a`, step to `b` at 0.5 s.
    static func render(_ r: any SonificationRenderer, from a: Float, to b: Float) -> [Float] {
        r.reset()
        return SonificationDriver.render(r, seconds: duration, events: [
            ControlEvent(time: 0, rate: a, cents: 0),
            ControlEvent(time: gateOpen, gate: true),
            ControlEvent(time: stepTime, rate: b),
        ])
    }
}

// MARK: - Allocation counter (BakeoffProductGates, ported)

/// Counts malloc-family allocations on ONE thread while armed, via libmalloc's
/// `malloc_logger` hook. Everything the callback touches is allocated before
/// the hook is installed.
enum RenderThreadAllocationCounter {
    typealias LoggerFn = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// [0] allocations, [1] frees, [2] armed flag.
    nonisolated(unsafe) static let slots: UnsafeMutablePointer<Int> = {
        let p = UnsafeMutablePointer<Int>.allocate(capacity: 3)
        p.initialize(repeating: 0, count: 3)
        return p
    }()
    nonisolated(unsafe) static let thread: UnsafeMutablePointer<pthread_t?> = {
        let p = UnsafeMutablePointer<pthread_t?>.allocate(capacity: 1)
        p.initialize(to: nil)
        return p
    }()
    nonisolated(unsafe) static let hook: UnsafeMutablePointer<LoggerFn?>? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return sym.assumingMemoryBound(to: LoggerFn?.self)
    }()

    nonisolated private static let logger: LoggerFn = { type, _, _, _, _, _ in
        let s = RenderThreadAllocationCounter.slots
        guard s[2] == 1, let t = RenderThreadAllocationCounter.thread.pointee,
              pthread_equal(pthread_self(), t) != 0 else { return }
        if type & 2 != 0 { s[0] += 1 }   // MALLOC_LOG_TYPE_ALLOCATE
        if type & 4 != 0 { s[1] += 1 }   // MALLOC_LOG_TYPE_DEALLOCATE
    }

    static func install() -> Bool {
        _ = slots; _ = thread
        guard let hook, hook.pointee == nil else { return false }
        thread.pointee = pthread_self()
        slots[0] = 0; slots[1] = 0; slots[2] = 0
        hook.pointee = logger
        return true
    }
    static func uninstall() { slots[2] = 0; hook?.pointee = nil }
    @inline(__always) static func arm() { slots[2] = 1 }
    @inline(__always) static func disarm() { slots[2] = 0 }
    static var allocations: Int { slots[0] }
}
