// PressureLoudnessTests.swift
// PrimaeNativeTests — R18 slice 6 (Klang-Dimensionen: Pencil pressure -> loudness)
//
// Seam A: ArmCoupling.parameters / PressureLoudness.gain (pure).
// Seam B: StudyComparisonConfiguration.nonDefaultStamp + reset.
// Seam C: LiveSonificationKernel offline render.
// Wiring: the pen path reaches AudioControlling.setPressureGain (through a recording double, so an inert
// switch is a RED test, not a green suite).

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
fileprivate final class GainRecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var gains: [Float] = []
    private(set) var isPlaying = false
    func loadAudioFile(named: String, autoplay: Bool) {}
    func play() { isPlaying = true }
    func stop() { isPlaying = false }
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func setPressureGain(_ gain: Float) { gains.append(gain) }
}

@Suite("r18 slice 6: pencil pressure to loudness") @MainActor
struct PressureLoudnessTests {

    private let mid = CGPoint(x: 0.5, y: 0.5)
    private func gain(_ force: CGFloat?, _ on: Bool, _ arm: PilotAudioCondition = .phoneme) -> Float {
        ArmCoupling.parameters(canvasNormalized: mid, velocity: 150, panningEnabled: true, rateCouplingEnabled: true, arm: arm,
                               force: force, pressureLoudnessEnabled: on).pressureGain
    }

    // MARK: Seam A

    @Test("off (the default): every force, and none, leaves the level at 1")
    func offIsUnity() {
        for f: CGFloat? in [nil, 0, 0.05, 0.5, 1, 5] { #expect(gain(f, false) == 1, "force \(String(describing: f))") }
        #expect(StudyComparisonSettings.pressureLoudnessEnabledDefault == false)
    }

    @Test("on: a finger (no force, or zero) is unchanged")
    func fingerUnchanged() {
        #expect(gain(nil, true) == 1)
        #expect(gain(0, true) == 1)
    }

    @Test("on: high force is louder than low force, full force is unity, lightest is rangeDB down")
    func monotoneAndEndpoints() {
        #expect(gain(0.9, true) > gain(0.1, true))
        #expect(abs(gain(1, true) - 1) < 1e-6)
        #expect(abs(gain(2, true) - 1) < 1e-6, "force beyond 1 clamps")
        let floor = powf(10, -ArmCoupling.PressureLoudness.rangeDB / 20)
        #expect(abs(gain(0.0001, true) - floor) < 1e-3)
        var prev: Float = 0
        for f in stride(from: CGFloat(0.01), through: 1, by: 0.01) {
            let g = gain(f, true); #expect(g >= prev); prev = g
        }
    }

    @Test("on: both sound arms get the identical gain; the other parameters are untouched by the switch")
    func armsMatchedAndRestUntouched() {
        for f: CGFloat in [0.2, 0.7] { #expect(gain(f, true, .phoneme) == gain(f, true, .spatial)) }
        let on = ArmCoupling.parameters(canvasNormalized: mid, velocity: 300, panningEnabled: true, rateCouplingEnabled: true, arm: .spatial,
                                        force: 0.3, pressureLoudnessEnabled: true)
        let off = ArmCoupling.parameters(canvasNormalized: mid, velocity: 300, panningEnabled: true, rateCouplingEnabled: true, arm: .spatial,
                                         force: 0.3, pressureLoudnessEnabled: false)
        #expect(on.speed == off.speed && on.horizontalBias == off.horizontalBias
                && on.spatialPitchCents == off.spatialPitchCents)
        // r17 call shape (no force arguments at all) is the default.
        let r17 = ArmCoupling.parameters(canvasNormalized: mid, velocity: 300, panningEnabled: true, rateCouplingEnabled: true, arm: .spatial)
        #expect(r17 == off)
    }

    // MARK: Seam B

    @Test("stamp: nothing at the default, exactly pressureLoudnessEnabled=true when on")
    func stamp() {
        var c = StudyComparisonConfiguration.defaults
        #expect(c.nonDefaultStamp == nil)
        c.pressureLoudnessEnabled = true
        #expect(c.nonDefaultStamp == "pressureLoudnessEnabled=true")
    }

    @Test("resetToDefaults clears the switch, and reports the change")
    func reset() throws {
        let suite = "r18s6-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(true, forKey: StudyComparisonSettings.pressureLoudnessEnabledKey)
        #expect(StudyComparisonSettings.configuration(in: d).pressureLoudnessEnabled)
        #expect(StudyComparisonSettings.resetToDefaults(in: d))
        #expect(StudyComparisonSettings.configuration(in: d).pressureLoudnessEnabled == false)
    }

    @Test("a session's stamp carries the switch when it is on")
    func sessionStamp() {
        var deps = TracingDependencies.stub
        #expect(TracingViewModel(deps).comparisonConfigurationStamp == nil)
        deps.pressureLoudnessEnabled = true
        #expect(TracingViewModel(deps).comparisonConfigurationStamp == "pressureLoudnessEnabled=true")
    }

    // MARK: Wiring (pen path -> audio)

    private func drive(_ vm: TracingViewModel, pencilForce: CGFloat?) {
        let canvas = CGSize(width: 400, height: 400)
        if pencilForce != nil { vm.pencilDidTouchDown() } else { vm.fingerDidTouchDown() }
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 50, y: 200)
        vm.beginTouch(at: p, t: t)
        for _ in 0..<15 {
            t += 0.001; p.x += 10
            if let f = pencilForce { vm.pencilPressure = f }
            vm.updateTouch(at: p, t: t, canvasSize: canvas)
        }
    }

    @Test("pen path: switch on + Pencil force 0.4 writes that gain to the audio; a finger writes 1")
    func penPathReachesAudio() {
        var deps = TracingDependencies.stub.with(audioCondition: .phoneme)
        deps.pressureLoudnessEnabled = true
        let a = GainRecordingAudio()
        let pencilVM = TracingViewModel(deps.with(audio: a))
        drive(pencilVM, pencilForce: 0.4)
        let want = ArmCoupling.PressureLoudness.gain(forForce: 0.4, enabled: true)
        #expect(!a.gains.isEmpty && a.gains.contains { abs($0 - want) < 1e-6 }, "gains \(a.gains)")

        let b = GainRecordingAudio()
        drive(TracingViewModel(deps.with(audio: b)), pencilForce: nil)
        #expect(!b.gains.isEmpty && b.gains.allSatisfy { $0 == 1 }, "finger gains \(b.gains)")
    }

    @Test("pen path: switch off writes only unity even for a hard Pencil press")
    func penPathOffIsUnity() {
        let a = GainRecordingAudio()
        drive(TracingViewModel(TracingDependencies.stub.with(audioCondition: .spatial).with(audio: a)), pencilForce: 0.1)
        #expect(a.gains.allSatisfy { $0 == 1 }, "gains \(a.gains)")
    }

    // MARK: Seam C

    private func rendered(_ gain: Float?) throws -> [Float] {
        let src = try StudySources.load("A_phoneme1")
        let rig = LiveSonificationKernelTests.Rig(sources: [src])
        if let gain { rig.kernel.setPressureGain(gain) }
        rig.kernel.open(slot: rig.slots["A_phoneme1"]!, fadeInFrames: 0)
        return rig.render(0.6)
    }

    @Test("kernel: default is byte-identical to r17 (setter never called == setter(1))")
    func kernelDefaultByteIdentical() throws {
        let a = try rendered(nil), b = try rendered(1)
        #expect(a.count == b.count && a.elementsEqual(b))
    }

    @Test("kernel: the gain scales the render (low force quieter than high force)")
    func kernelScales() throws {
        let unity = try rendered(1)
        let low = try rendered(ArmCoupling.PressureLoudness.gain(forForce: 0.1, enabled: true))
        let high = try rendered(ArmCoupling.PressureLoudness.gain(forForce: 0.9, enabled: true))
        let tail = Int(0.3 * LiveSonificationKernel.sampleRate)...
        let rU = SonificationMetrics.rms(unity[tail]), rL = SonificationMetrics.rms(low[tail]), rH = SonificationMetrics.rms(high[tail])
        #expect(rL < rH && rH <= rU * 1.0001)
        let want = ArmCoupling.PressureLoudness.gain(forForce: 0.1, enabled: true)
        #expect(abs(rL / rU - Double(want)) < 0.01, "ratio \(rL / rU) vs \(want)")
    }

    @Test("kernel: a mid-stream gain change is ramped, not a step")
    func kernelRamps() throws {
        let src = try StudySources.load("spatial_carrier")
        let rig = LiveSonificationKernelTests.Rig(sources: [src])
        rig.kernel.open(slot: rig.slots["spatial_carrier"]!, fadeInFrames: 0)
        _ = rig.render(0.3)
        rig.kernel.setPressureGain(0.125)
        let y = rig.render(0.1)
        // Each 256-frame buffer ramps over its own length: the first buffer after the write is not yet at the target.
        let first = SonificationMetrics.rms(y[0..<256]), settled = SonificationMetrics.rms(y[(y.count - 2048)...])
        #expect(first > settled * 1.5, "first buffer \(first) vs settled \(settled)")
    }
}
