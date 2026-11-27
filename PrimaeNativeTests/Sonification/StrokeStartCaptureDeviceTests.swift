// StrokeStartCaptureDeviceTests.swift
// PrimaeNativeTests: lane PITCHWIN (2026-11-26) DEVICE INSTRUMENT (Primae-DeviceTests; fails on a simulator)
//
// Stroke starts and pitch extremes, captured from the real engine on the iPad: the real view model and touch path, the
// real `LiveSonificationAudio.production` voice, the real AVAudioEngine graph, recorded at the MAIN MIXER (the R20 rig's
// tap, `R20StereoRecorder`). Written so the same file compiles and runs unchanged on a build before the r31 renderer
// swap (main 60e69234) and after it, so the two captures are a baseline/after pair from one script.
//
// Per study letter (A F I L M, phoneme arm) and once for the spatial carrier (letter I, spatial arm), from silence:
//   h0...h4  pen-down at canvas height 0, 0.25, 0.5, 0.75, 1 (pitch +600, +300, 0, -300, -600 cents at the r26 span),
//            then the pen moves sideways at 150 pt/s (rate 1.0) for `holdSeconds`, and lifts; `gapSeconds` after.
//   stroke   pen-down at the letter's first stroke start, tracing the stroke at 150 pt/s for up to 1.2 s (the real
//            stroke start: real height, real pitch glide along the stroke); last, so a completed stroke changes nothing
//            before it.
// Pan is off (the bias would move the level between channels as the pen moves sideways), sound gating off (the pen is
// off the stroke in h0...h4), every R18 dimension off. The pen-down's capture frame (the tap's frame count at
// `beginTouch`) is written as a hint; the analysis finds the onset as the first audible sample after it.
// Files go to the app's tmp/pwcap (pulled with devicectl, removed by `testZ_removeStrokeStartCaptures`).
// The metrics are computed off the iPad from the WAVs (scratch analyser), so the instrument itself asserts only that it
// captured sound for every event.

import XCTest
import Foundation
import AVFoundation
import CoreGraphics
import QuartzCore
@testable import PrimaeNative

@MainActor enum StrokeStartRig {
    static let canvas = CGSize(width: 600, height: 600)
    static let heights: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
    static let holdSeconds = 1.6
    /// Longer than `StrokeTempo.maxGap` (3.0 s): a break, so the lift hold stays at its 0.8 s seed and every pen-down
    /// is from silence (hold + 0.4 s fade < gap). A gap of 1.2 s teaches the tempo a longer hold and the re-touch
    /// lands inside it (measured on the first run: no silence between events after the second).
    static let gapSeconds = 3.5
    static let speed: CGFloat = 150   // pt/s: rate 1.0 (`TouchDispatcher.mapVelocityToSpeed`)

    nonisolated static var directory: URL { URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pwcap") }

    private static func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(max(0, s) * 1e9)) }

    private static func point(_ pts: [CGPoint], length: CGFloat, frac: Double) -> CGPoint {
        let s = CGFloat(frac) * length
        var acc: CGFloat = 0
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

    /// One capture: `letter` loaded, `arm`, the five heights then the stroke start.
    static func capture(letter: String, arm: PilotAudioCondition) async throws {
        let box = ThrowawayDefaults()
        let host = SoundEnvelope.makeHostEngine()
        let voice = LiveSonificationAudio.production(host: host, fadeOutSeconds: SoundEnvelope.fadeOutSeconds)
        let output = try XCTUnwrap(Mirror(reflecting: voice).descendant("output") as? SourceNodeOutput)
        let av = try XCTUnwrap(output.node.engine, "the live node is not attached to the host's graph")
        let rec = R20StereoRecorder()
        av.stop()
        let mixer = av.mainMixerNode
        try mixer.installAudioTap(onBus: 0, bufferSize: 512, format: mixer.outputFormat(forBus: 0)) { [rec] b, _ in rec.append(b) }
        output.startIfNeeded()
        await host.startGate.settle()
        XCTAssertTrue(av.isRunning, "\(letter) \(arm): the host engine is not running after the start gate settled")
        defer { mixer.removeTap(onBus: 0); av.stop() }

        var deps = TracingDependencies.stubReading(comparisonDefaults: box.defaults).with(audio: voice)
        deps.repo = LetterRepository(resources: BundleLetterResourceProvider(), cache: NullLetterCache())
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = arm
        deps.trainedSubset = TrainedLetterSubset.allSubsets.first { !$0.letters.contains(letter) } ?? TrainedLetterSubset.allSubsets[0]
        deps.observeCueFallbackSeconds = 3600
        deps.observeCueEndToPresentationSeconds = 3600
        deps.soundGatingEnabled = false
        deps.panningEnabled = false
        deps.distanceToneEnabled = false
        deps.directionMuteEnabled = false
        deps.pressureLoudnessEnabled = false
        deps.dysfluencyRoughness = false
        let vm = TracingViewModel(deps)
        vm.canvasSize = Self.canvas
        vm.loadLetter(name: letter)
        vm.phaseController.resume(at: .guided)
        let cell = vm.grid.activeCell.frame
        let fr = (cell.width > 0 && cell.height > 0) ? cell : CGRect(origin: .zero, size: Self.canvas)
        let cps = vm.strokeTracker.definition?.strokes.first?.checkpoints ?? []
        let path = cps.map { CGPoint(x: fr.minX + CGFloat($0.x) * fr.width, y: fr.minY + CGFloat($0.y) * fr.height) }
        XCTAssertGreaterThan(path.count, 1, "\(letter): no stroke to trace")
        var length: CGFloat = 0
        for i in 1..<path.count { length += hypot(path[i].x - path[i-1].x, path[i].y - path[i-1].y) }
        await Self.sleep(1.5)

        var events: [[String: Any]] = []
        func run(_ name: String, seconds: Double, pose: (Double) -> CGPoint) async {
            let hint = rec.frameCount
            let t0 = CACurrentMediaTime()
            vm.beginTouch(at: pose(0), t: t0)
            let start = CACurrentMediaTime()
            while true {
                await Self.sleep(1.0 / 120.0)
                let now = CACurrentMediaTime()
                let t = now - start
                if t >= seconds { break }
                vm.updateTouch(at: pose(t), t: now, canvasSize: Self.canvas)
            }
            vm.endTouch()
            let p0 = pose(0)
            events.append(["name": name, "hintFrame": hint, "seconds": seconds,
                           "x": Double(p0.x), "y": Double(p0.y), "normalizedY": Double(p0.y / Self.canvas.height)])
            await Self.sleep(Self.gapSeconds)
        }
        for (k, h) in Self.heights.enumerated() {
            let y = h * Self.canvas.height
            await run("h\(k)", seconds: Self.holdSeconds) { t in CGPoint(x: 150 + Self.speed * CGFloat(t), y: y) }
        }
        let strokeSeconds = min(1.2, Double(length * 0.97 / Self.speed))
        await run("stroke", seconds: strokeSeconds) { t in
            Self.point(path, length: length, frac: min(0.97, Double(Self.speed) * t / Double(length)))
        }

        XCTAssertGreaterThan(rec.peak, 0.001, "\(letter) \(arm): the capture is silent")
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let name = "\(arm)_\(letter)"
        try rec.writeFloatWAV(to: Self.directory.appendingPathComponent(name + ".wav"))
        // The conversion chain (PITCHWIN r31): session rate, the mixer's output, and the output node's input
        // (the mixer -> output connection) and output (hardware); equal rates = no conversion after the renderer.
        let rates: [String: Double] = ["session": AVAudioSession.sharedInstance().sampleRate,
                                       "mixerOut": mixer.outputFormat(forBus: 0).sampleRate,
                                       "outputIn": av.outputNode.inputFormat(forBus: 0).sampleRate,
                                       "outputHW": av.outputNode.outputFormat(forBus: 0).sampleRate,
                                       "node": output.format.sampleRate]
        let info: [String: Any] = ["letter": letter, "arm": "\(arm)", "sampleRate": rec.sr, "frames": rec.frameCount, "rates": rates,
                                   "strokeLength": Double(length), "events": events]
        let json = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: Self.directory.appendingPathComponent(name + ".json"))
        print("PWCAP \(name) frames=\(rec.frameCount) peak=\(rec.peak) events=\(events.count) rates=\(rates)")
    }
}

final class StrokeStartCaptureDeviceTests: XCTestCase {
    override func setUpWithError() throws {
        try r20RequireDevice()
    }
    @MainActor func testCap_A() async throws { try await StrokeStartRig.capture(letter: "A", arm: .phoneme) }
    @MainActor func testCap_F() async throws { try await StrokeStartRig.capture(letter: "F", arm: .phoneme) }
    @MainActor func testCap_I() async throws { try await StrokeStartRig.capture(letter: "I", arm: .phoneme) }
    @MainActor func testCap_L() async throws { try await StrokeStartRig.capture(letter: "L", arm: .phoneme) }
    @MainActor func testCap_M() async throws { try await StrokeStartRig.capture(letter: "M", arm: .phoneme) }
    @MainActor func testCap_spatial() async throws { try await StrokeStartRig.capture(letter: "I", arm: .spatial) }
}

/// Run ALONE after the captures are pulled: removes them from the app container.
final class StrokeStartCaptureCleanupDeviceTests: XCTestCase {
    func testZ_removeStrokeStartCaptures() throws {
        try? FileManager.default.removeItem(at: StrokeStartRig.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: StrokeStartRig.directory.path))
    }
}
