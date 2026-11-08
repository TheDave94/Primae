// R20CaptureDeviceTests.swift
// PrimaeNativeTests: lane R20 (2026-11-08) DEVICE INSTRUMENT, SKIPS ON THE SIMULATOR
//
// Listening captures of the r18 dimensions from the real engine on the iPad: the real view model and touch path, the real
// `LiveSonificationAudio.production` voice, the real AVAudioEngine graph, recorded at the MAIN MIXER (stereo, what the hardware
// is handed; a tap from test code, as `LiveSonificationOnsetDeviceTests`). Scripted, deterministic pen on letter I (the study's
// simplest stroke): `ScriptKind` says what the pen does when; each capture is one dimension ON against the same script, in each
// sound arm. Run once per build (`variant`: r19 = before, r20 = after) so the files can be compared A/B.
//
// WHY NOT `PopCaptureUITests`: it enrols a child through the rail (writes the app container's enrolment store), which the iPad
// holding David's data must not receive, and a synthetic touch carries no Pencil force, so pressure could not be heard at all.
// Files go to the app's tmp/r20cap (pulled with devicectl, removed by `testZ_removeCaptures`).

import XCTest
import Foundation
import AVFoundation
import CoreGraphics
import QuartzCore
@testable import PrimaeNative

/// The minutes-long device instruments (onset runs, listening captures: they write into the app container's tmp) run only when asked:
/// `TEST_RUNNER_R20_INSTRUMENTS=1 xcodebuild test ...` (xcodebuild hands it to the test host as `R20_INSTRUMENTS`).
nonisolated var r20InstrumentsEnabled: Bool { ProcessInfo.processInfo.environment["R20_INSTRUMENTS"] == "1" }

private nonisolated let r20CapIsSim: Bool = {
    #if targetEnvironment(simulator)
    return true
    #else
    return false
    #endif
}()

nonisolated final class R20StereoRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var l: [Float] = [], r: [Float] = []
    private(set) var sr: Double = 48000
    init() { l.reserveCapacity(48000 * 12); r.reserveCapacity(48000 * 12) }
    func append(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard let d = buffer.floatChannelData else { return }
        let c1 = buffer.format.channelCount > 1 ? d[1] : d[0]
        lock.withLock {
            sr = buffer.format.sampleRate
            l.append(contentsOf: UnsafeBufferPointer(start: d[0], count: n))
            r.append(contentsOf: UnsafeBufferPointer(start: c1, count: n))
        }
    }
    func writeFloatWAV(to url: URL) throws {
        let (a, b, rate) = lock.withLock { (l, r, sr) }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = a.count * 2 * 4
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(3); u16(2)
        u32(UInt32(rate)); u32(UInt32(rate) * 8); u16(8); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        var inter = [Float](repeating: 0, count: a.count * 2)
        for i in 0..<a.count { inter[2 * i] = a[i]; inter[2 * i + 1] = b[i] }
        inter.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }
}

/// What the scripted pen does, as arrays at 1 kHz: arc position along the stroke (as a fraction of its length), lateral offset in
/// gate radii (toward +x, away from the reference stroke) and Pencil force (nil = a finger).
nonisolated struct R20PenScript {
    var seconds: Double
    var s: [Double]          // fraction of the stroke length
    var lateral: [Double]    // gate radii
    var force: [Double?]
    var notes: [String]

    enum Kind: String, CaseIterable { case control, distance, direction, pressure, roughness, all }

    static func make(_ kind: Kind) -> R20PenScript {
        func build(_ seconds: Double, _ start: Double, speed: (Double) -> Double, lateral lat: (Double) -> Double = { _ in 0 },
                   force f: ((Double) -> Double)? = nil, notes: [String]) -> R20PenScript {
            let n = Int(seconds * 1000)
            var s = [Double](repeating: start, count: n), lt = [Double](repeating: 0, count: n), fo = [Double?](repeating: nil, count: n)
            var pos = start
            for k in 0..<n {
                let t = Double(k) / 1000
                pos = min(0.97, max(0.03, pos + speed(t) / 1000))
                s[k] = pos; lt[k] = lat(t); fo[k] = f?(t)
            }
            return R20PenScript(seconds: seconds, s: s, lateral: lt, force: fo, notes: notes)
        }
        func ramp(_ t: Double, _ a: Double, _ b: Double, _ v0: Double, _ v1: Double) -> Double {
            t <= a ? v0 : t >= b ? v1 : v0 + (v1 - v0) * (t - a) / (b - a)
        }
        let v = 0.25   // stroke lengths per second (about 75-90 pt/s)
        switch kind {
        case .distance:
            return build(3.4, 0.08, speed: { _ in v * 0.9 },
                         lateral: { t in t < 1.7 ? ramp(t, 0.5, 1.5, 0, 1) : ramp(t, 2.0, 3.0, 1, 0) },
                         notes: ["0.0-0.5 s on the stroke", "0.5-1.5 s drifts away to one gate radius", "1.5-2.0 s stays far (full effect: -12 dB, 800 Hz)", "2.0-3.0 s returns to the stroke", "3.0-3.4 s on the stroke"])
        case .direction:
            return build(3.6, 0.22, speed: { t in t < 1.0 ? 0.3 : t < 1.9 ? -0.3 : 0.3 }, notes: ["0.0-1.0 s along the stroke", "1.0-1.9 s BACKWARDS along it (the mute)", "1.9-3.6 s along it again"])
        case .pressure:
            return build(3.8, 0.08, speed: { _ in v * 0.8 }, force: { t in
                t < 0.4 ? 1.0 : t < 1.6 ? ramp(t, 0.4, 1.6, 1.0, 0.15) : t < 1.9 ? 0.15 : t < 1.925 ? 1.0 : t < 2.5 ? 1.0 : ramp(t, 2.5, 3.1, 1.0, 0.5) },
                         notes: ["0.0-0.4 s full force", "0.4-1.6 s force eases to 0.15 (18 dB softer at the lightest)", "1.6-1.9 s light", "1.9 s a jab back to full force in 25 ms", "2.5-3.1 s eases to 0.5"])
        case .roughness:
            var gos: [(Double, Double)] = []
            for c in 0..<5 { gos.append((0.8 + 0.4 * Double(c), 0.8 + 0.4 * Double(c) + 0.18)) }
            return build(3.7, 0.08, speed: { t in gos.contains { t >= $0.0 && t < $0.1 } ? v * 0.02 : v }, notes: ["0.0-0.8 s steady", "0.8-2.8 s five stop-and-go cycles (0.18 s nearly still, 0.22 s moving)", "2.8-3.7 s steady"])
        case .control, .all:
            return build(5.0, 0.06, speed: { t in
                t < 1.6 ? v * 0.8 : t < 2.5 ? -0.28 : t < 3.0 ? 0.28 : (t >= 3.2 && t < 3.38) || (t >= 3.6 && t < 3.78) || (t >= 4.0 && t < 4.18) ? v * 0.02 : v * 0.9 },
                         lateral: { t in t < 1.6 ? (t < 0.8 ? ramp(t, 0.2, 0.8, 0, 1) : ramp(t, 1.0, 1.5, 1, 0)) : 0 },
                         force: { t in t < 3.0 ? ramp(t, 0.2, 2.5, 1.0, 0.25) : ramp(t, 3.0, 4.6, 0.25, 1.0) },
                         notes: ["0.2-1.5 s the pen drifts one gate radius off the stroke and back (distance)", "1.6-2.5 s BACKWARDS along the stroke (direction mute)", "force eases 1.0 -> 0.25 until 3.0 s, back to 1.0 by 4.6 s (Pencil pressure)", "3.2, 3.6, 4.0 s: three stop-and-go stalls (roughness)"])
        }
    }
}

@MainActor enum R20CaptureRig {
    /// `r19` = the tree before R20, `r20` = after; edited per build clone.
    static let variant = "VARIANT"
    static let canvas = CGSize(width: 600, height: 600)

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1e9)) }

    nonisolated static var directory: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("r20cap") }

    private static func point(_ pts: [CGPoint], length: CGFloat, frac: Double) -> CGPoint {
        var s = CGFloat(frac) * length, acc: CGFloat = 0
        for i in 1..<pts.count {
            let seg = hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y)
            if acc + seg >= s, seg > 0 {
                let f = (s - acc) / seg
                return CGPoint(x: pts[i-1].x + f * (pts[i].x - pts[i-1].x), y: pts[i-1].y + f * (pts[i].y - pts[i-1].y))
            }
            acc += seg
        }
        return pts.last!
    }

    /// One capture: dimension `kind` ON (control = all off), arm, script; `configure` runs on the voice before it sounds.
    static func capture(_ kind: R20PenScript.Kind, arm: PilotAudioCondition, tag: String? = nil,
                            configure: (LiveSonificationAudio) -> Void = { _ in }) async throws {
        let script = R20PenScript.make(kind)
        let box = ThrowawayDefaults()
        let host = SoundEnvelope.makeHostEngine()
        let voice = LiveSonificationAudio.production(host: host, fadeOutSeconds: SoundEnvelope.fadeOutSeconds)
        configure(voice)
        let output = try XCTUnwrap(Mirror(reflecting: voice).descendant("output") as? SourceNodeOutput)
        let av = try XCTUnwrap(output.node.engine, "the live node is not attached to the host's graph")
        let rec = R20StereoRecorder()
        av.stop()
        let mixer = av.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 512, format: mixer.outputFormat(forBus: 0)) { [rec] b, _ in rec.append(b) }
        output.startIfNeeded()
        defer { mixer.removeTap(onBus: 0); av.stop() }

        var deps = TracingDependencies.stubReading(comparisonDefaults: box.defaults).with(audio: voice)
        deps.repo = LetterRepository(resources: BundleLetterResourceProvider(), cache: NullLetterCache())
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = arm
        deps.trainedSubset = TrainedLetterSubset.allSubsets.first { !$0.letters.contains("I") } ?? TrainedLetterSubset.allSubsets[0]
        deps.observeCueFallbackSeconds = 3600
        deps.observeCueEndToPresentationSeconds = 3600
        deps.soundGatingEnabled = false
        deps.distanceToneEnabled = kind == .distance || kind == .all
        deps.directionMuteEnabled = kind == .direction || kind == .all
        deps.pressureLoudnessEnabled = kind == .pressure || kind == .all
        deps.dysfluencyRoughness = kind == .roughness || kind == .all
        let vm = TracingViewModel(deps)
        vm.canvasSize = Self.canvas
        vm.loadLetter(name: "I")
        vm.phaseController.resume(at: .guided)
        let cell = vm.grid.activeCell.frame
        let fr = (cell.width > 0 && cell.height > 0) ? cell : CGRect(origin: .zero, size: Self.canvas)
        let cps = vm.strokeTracker.definition?.strokes.first?.checkpoints ?? []
        let path = cps.map { CGPoint(x: fr.minX + CGFloat($0.x) * fr.width, y: fr.minY + CGFloat($0.y) * fr.height) }
        XCTAssertGreaterThan(path.count, 1, "no stroke to trace")
        var length: CGFloat = 0
        for i in 1..<path.count { length += hypot(path[i].x - path[i-1].x, path[i].y - path[i-1].y) }
        let gatePt = vm.strokeGateRadius() * fr.height
        await Self.sleep(1.5)

        func pose(_ t: Double) -> (CGPoint, CGFloat?) {
            let k = min(script.s.count - 1, max(0, Int(t * 1000)))
            var p = Self.point(path, length: length, frac: script.s[k])
            p.x += CGFloat(script.lateral[k]) * gatePt
            return (p, script.force[k].map { CGFloat($0) })
        }
        let usePencil = script.force.contains { $0 != nil }
        let (p0, f0) = pose(0)
        if usePencil { vm.pencilDidTouchDown(); vm.pencilPressure = f0 }
        let t0 = CACurrentMediaTime()
        vm.beginTouch(at: p0, t: t0)
        await Self.sleep(0.05)
        let start = CACurrentMediaTime()
        while true {
            await Self.sleep(1.0 / 120.0)
            let now = CACurrentMediaTime()
            let t = now - start
            if t >= script.seconds { break }
            let (p, f) = pose(t)
            if usePencil { vm.pencilPressure = f }
            vm.updateTouch(at: p, t: now, canvasSize: Self.canvas)
        }
        vm.endTouch()
        await Self.sleep(1.4)
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let name = "\(Self.variant)_\(arm)_\(kind.rawValue)\(tag.map { "_" + $0 } ?? "")"
        try rec.writeFloatWAV(to: Self.directory.appendingPathComponent(name + ".wav"))
        let info = "stroke length \(Int(length)) pt, gate radius \(Int(gatePt)) pt, script \(script.seconds) s\n" + script.notes.joined(separator: "\n") + "\n"
        try info.write(to: Self.directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        print("R20 CAPTURE \(name) frames=\(Int(rec.sr * (script.seconds + 3))) length=\(Int(length)) gate=\(Int(gatePt))")
    }
}

final class R20CaptureDeviceTests: XCTestCase {
    override func setUpWithError() throws {
        if r20CapIsSim { throw XCTSkip("device instrument: AVAudioEngine does not run on the simulator") }
        if !r20InstrumentsEnabled { throw XCTSkip("listening captures: run with TEST_RUNNER_R20_INSTRUMENTS=1") }
    }
    @MainActor func testCap_0_control() async throws { for a in [PilotAudioCondition.phoneme, .spatial] { try await R20CaptureRig.capture(.control, arm: a) } }
    @MainActor func testCap_1_distance() async throws { for a in [PilotAudioCondition.phoneme, .spatial] { try await R20CaptureRig.capture(.distance, arm: a) } }
    @MainActor func testCap_2_direction() async throws { for a in [PilotAudioCondition.phoneme, .spatial] { try await R20CaptureRig.capture(.direction, arm: a) } }
    @MainActor func testCap_3_pressure() async throws { for a in [PilotAudioCondition.phoneme, .spatial] { try await R20CaptureRig.capture(.pressure, arm: a) } }
    @MainActor func testCap_4_roughness() async throws { for a in [PilotAudioCondition.phoneme, .spatial] { try await R20CaptureRig.capture(.roughness, arm: a) } }
    @MainActor func testCap_5_all() async throws { for a in [PilotAudioCondition.phoneme, .spatial] { try await R20CaptureRig.capture(.all, arm: a) } }
}

/// Offline kernel renders in the iPad's call sizes (235/236 frames), written as mono float WAVs next to the captures: the step changes
/// of the stages heard in isolation, r19-compatible API only so the same file runs in the r19 baseline build. SKIPS ON THE SIMULATOR
/// only in the sense that the pull/cleanup is a device act; the render itself is the same code on any machine.
nonisolated enum R20Offline {
    /// `events`: (seconds, action) applied before the first call that starts at or after that time.
    static func render(_ source: String, seconds: Double,
                       make: () -> LiveSonificationKernel = { LiveSonificationKernel() },
                       events: [(Double, (LiveSonificationKernel) -> Void)]) throws -> [Float] {
        let src = try StudySources.load(source)
        let kernel = make()
        let (a, b) = LiveSonificationAudio.makeRendererPair(src.sonificationSource)
        let slot = kernel.register(a, twin: b, gain: 1)!
        kernel.open(slot: slot, fadeInFrames: 0)
        let sr = LiveSonificationKernel.sampleRate
        let total = Int(seconds * sr)
        var y = [Float](), k = 0
        var pending = events.sorted { $0.0 < $1.0 }
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { buf.deallocate() }
        while y.count < total {
            while let e = pending.first, Double(y.count) / sr >= e.0 { e.1(kernel); pending.removeFirst() }
            let n = Int((Double(k + 1) * 235.2).rounded(.down)) - Int((Double(k) * 235.2).rounded(.down)); k += 1
            _ = kernel.render(into: buf, frames: n)
            y.append(contentsOf: UnsafeBufferPointer(start: buf, count: n))
        }
        return y
    }

    static func write(_ y: [Float], name: String) throws {
        let dir = R20CaptureRig.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate: UInt32 = 44_100, bytes = y.count * 4
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(3); u16(1); u32(rate); u32(rate * 4); u16(4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        y.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: dir.appendingPathComponent(name + ".wav"))
    }
}

final class R20OfflineListeningDeviceTests: XCTestCase {
    static let sources = ["spatial_carrier", "I_phoneme1"]
    override func setUpWithError() throws {
        if !r20InstrumentsEnabled { throw XCTSkip("listening captures: run with TEST_RUNNER_R20_INSTRUMENTS=1") }
    }
    private func name(_ kind: String, _ src: String) -> String { "\(R20CaptureRig.variant)_off_\(kind)_\(src)" }

    /// A mute on at 0.6 s and off at 1.4 s (the direction mute's gain path), 2.4 s.
    func testOff_1_muteCycle() throws {
        for s in Self.sources {
            try R20Offline.write(try R20Offline.render(s, seconds: 2.4, events: [(0.6, { $0.setStrokeMute(true) }), (1.4, { $0.setStrokeMute(false) })]),
                                 name: name("mute", s))
        }
    }
    /// The low-pass at 800 Hz from the start, JUMPING open to 20 kHz at 1.0 s (the pen back on the stroke), 2.0 s; and the mirror, closing at 1.0 s.
    func testOff_2_cutoffJumps() throws {
        for s in Self.sources {
            try R20Offline.write(try R20Offline.render(s, seconds: 2.0, events: [(0.0, { $0.setStrokeLowpass(cutoffHz: 800) }), (1.0, { $0.setStrokeLowpass(cutoffHz: 20_000) })]),
                                 name: name("open", s))
            try R20Offline.write(try R20Offline.render(s, seconds: 2.0, events: [(1.0, { $0.setStrokeLowpass(cutoffHz: 800) })]), name: name("close", s))
        }
    }
    /// The pressure gain falling 18 dB at 0.8 s and coming back at 1.6 s (a pen pressed lightly, then hard), 2.4 s.
    func testOff_3_pressureJumps() throws {
        for s in Self.sources {
            try R20Offline.write(try R20Offline.render(s, seconds: 2.4, events: [(0.8, { $0.setPressureGain(0.126) }), (1.6, { $0.setPressureGain(1) })]),
                                 name: name("pressure", s))
        }
    }
}

/// Run ALONE (`-only-testing:.../R20CaptureCleanupDeviceTests`) after the captures are pulled: removes them from the app container.
final class R20CaptureCleanupDeviceTests: XCTestCase {
    /// Removes the captures from the app container once they are pulled.
    func testZ_removeCaptures() throws {
        try? FileManager.default.removeItem(at: R20CaptureRig.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: R20CaptureRig.directory.path))
    }
}
