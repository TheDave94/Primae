// DysfluencyRoughnessTests.swift
// PrimaeNativeTests — R18DIM slice 7 (dysfluency -> amplitude roughness)
//
// Seam A: ArmCoupling.parameters carries the roughness (switch off = 0, as r17).
// Meter: a jerky scripted stroke yields events, a smooth one none.
// Seam B: the stamp names the switch only when it is on.
// Seam C: the live kernel's offline render is rough at roughness 1, untouched at 0, and never steps.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite("R18DIM s7 dysfluency roughness")
@MainActor struct DysfluencyRoughnessTests {

    // MARK: Meter

    /// One scripted stroke: speed(t) pt/s sampled at 120 Hz for `seconds`.
    static func roughnessAfter(_ seconds: Double, speed: (Double) -> Double) -> Float {
        var m = DysfluencyMeter()
        var t = 0.0
        while t < seconds { t += 1.0 / 120; m.add(t: t, distance: speed(t) / 120) }
        return m.roughness(at: t)
    }

    @Test("a steady stroke and a smooth bell-shaped stroke have no stop-start events")
    func smoothIsSmooth() {
        #expect(Self.roughnessAfter(1.5) { _ in 200 } == 0)
        #expect(Self.roughnessAfter(1.5) { 200 * sin(Double.pi * $0 / 1.5) + 40 } == 0)
        #expect(Self.roughnessAfter(1.5) { _ in 30 } == 0, "a slow steady writer is not dysfluent")
    }

    @Test("stop-and-go (speed collapses to near zero four times a second) saturates")
    func jerkyIsRough() {
        let r = Self.roughnessAfter(1.5) { t in Int(t * 6) % 2 == 0 ? 220 : 10 }   // 6 half-cycles/s: 3 stops/s
        #expect(r >= 0.99, "roughness \(r)")
        let one = Self.roughnessAfter(0.6) { t in t > 0.3 && t < 0.4 ? 5 : 220 }
        #expect(one > 0 && one < 1, "a single stop is a partial roughness: \(one)")
    }

    @Test("the window forgets: events older than a second no longer count")
    func windowForgets() {
        var m = DysfluencyMeter()
        var t = 0.0
        while t < 1.0 { t += 1.0 / 120; m.add(t: t, distance: (Int(t * 6) % 2 == 0 ? 220 : 10) / 120.0) }
        #expect(m.roughness(at: t) > 0.5)
        #expect(m.roughness(at: t + 1.5) == 0)
    }

    // MARK: Seam A

    @Test("ArmCoupling: roughness is 0 unless the switch is on, identical in both sound arms, clamped")
    func couplingCarriesRoughness() {
        let p = CGPoint(x: 0.5, y: 0.5)
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let off = ArmCoupling.parameters(canvasNormalized: p, velocity: 100, panningEnabled: true, rateCouplingEnabled: true, arm: arm, dysfluency: 1, roughnessEnabled: false)
            #expect(off.roughness == 0)
            let on = ArmCoupling.parameters(canvasNormalized: p, velocity: 100, panningEnabled: true, rateCouplingEnabled: true, arm: arm, dysfluency: 0.6, roughnessEnabled: true)
            #expect(on.roughness == 0.6)
            #expect(ArmCoupling.parameters(canvasNormalized: p, velocity: 100, panningEnabled: true, rateCouplingEnabled: true, arm: arm, dysfluency: 7, roughnessEnabled: true).roughness == 1)
        }
        let a = ArmCoupling.parameters(canvasNormalized: p, velocity: 100, panningEnabled: true, rateCouplingEnabled: true, arm: .phoneme, dysfluency: 0.6, roughnessEnabled: true)
        let b = ArmCoupling.parameters(canvasNormalized: p, velocity: 100, panningEnabled: true, rateCouplingEnabled: true, arm: .spatial, dysfluency: 0.6, roughnessEnabled: true)
        #expect(a.roughness == b.roughness && a.speed == b.speed && a.horizontalBias == b.horizontalBias)
        // r17 default call shape is untouched
        #expect(ArmCoupling.parameters(canvasNormalized: p, velocity: 100, panningEnabled: true, rateCouplingEnabled: true, arm: .spatial).roughness == 0)
    }

    // MARK: Seam B

    @Test("the stamp names dysfluencyRoughness only when on; nothing at defaults")
    func stamp() {
        #expect(StudyComparisonConfiguration.defaults.dysfluencyRoughness == false)
        #expect(StudyComparisonConfiguration.defaults.nonDefaultStamp == nil)
        var c = StudyComparisonConfiguration()
        c.dysfluencyRoughness = true
        #expect(c.nonDefaultStamp == "dysfluencyRoughness=true")
    }

    @Test("a slow, wobbling writer (peak below the guard) has no stop-start events; the same wobble above it does")
    func peakGuardHolds() {
        let slow = Self.roughnessAfter(1.5) { t in Int(t * 6) % 2 == 0 ? 40 : 3 }
        #expect(slow == 0, "40 <-> 3 pt/s is a slow writer, not a dysfluent one: \(slow)")
        let fast = Self.roughnessAfter(1.5) { t in Int(t * 6) % 2 == 0 ? 120 : 3 }
        #expect(fast > 0, "the same wobble above the 80 pt/s peak guard is dysfluent: \(fast)")
    }

    @Test("the roughness depth default is the literal 0.8: a stored 0.8 is the default and is not stamped")
    func depthDefaultIsTheLiteral() throws {
        #expect(StudyComparisonSettings.dysfluencyRoughnessDepthDefault == 0.8)
        #expect(Float(StudyComparisonSettings.dysfluencyRoughnessDepthDefault) == RoughnessTuning.maxDepth,
                "the engine's built-in depth and the setting's default must be the same Float")
        let suite = "r18s7d.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        d.set(0.8, forKey: StudyComparisonSettings.dysfluencyRoughnessDepthKey)
        let c = StudyComparisonSettings.configuration(in: d)
        #expect(c == StudyComparisonConfiguration.defaults)
        #expect(c.nonDefaultStamp == nil, "a stored 0.8 stamped as non-default: \(c.nonDefaultStamp ?? "")")
    }

    @Test("the setting round-trips through a throwaway suite and resetToDefaults clears it")
    func settingRoundTrip() throws {
        let suite = "r18s7.\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        #expect(StudyComparisonSettings.configuration(in: d).dysfluencyRoughness == false)
        d.set(true, forKey: StudyComparisonSettings.dysfluencyRoughnessKey)
        #expect(StudyComparisonSettings.configuration(in: d).dysfluencyRoughness == true)
        #expect(StudyComparisonSettings.resetToDefaults(in: d))
        #expect(StudyComparisonSettings.configuration(in: d).dysfluencyRoughness == false)
    }

    // MARK: Seam C

    static let sr = LiveSonificationKernel.sampleRate

    static func render(roughness: Float?, seconds: Double = 1.0, switchAt: Double? = nil, switchOffAt: Double? = nil) throws -> [Float] {
        let src = try StudySources.load("spatial_carrier")
        let k = LiveSonificationKernel()
        let (r, twin) = LiveSonificationAudio.makeRendererPair(src.sonificationSource)
        let slot = try #require(k.register(r, twin: twin, gain: 1))
        if let roughness, switchAt == nil { k.setRoughness(roughness) }
        k.open(slot: slot, fadeInFrames: 0)
        let total = Int(seconds * sr)
        var y = [Float](repeating: 0, count: total)
        var pos = 0, switched = false, switchedOff = false
        y.withUnsafeMutableBufferPointer { b in
            while pos < total {
                if let at = switchAt, let roughness, !switched, Double(pos) / sr >= at { k.setRoughness(roughness); switched = true }
                if let off = switchOffAt, !switchedOff, Double(pos) / sr >= off { k.setRoughness(0); switchedOff = true }
                let n = min(256, total - pos)
                k.render(into: b.baseAddress! + pos, frames: n)
                pos += n
            }
        }
        return y
    }

    /// Std-dev / mean of the 5 ms RMS envelope over 0.3...0.9 s.
    static func envelopeDepth(_ y: [Float]) -> Double {
        let w = Int(0.005 * sr)
        var env: [Double] = []
        var i = Int(0.3 * sr)
        while i + w <= Int(0.9 * sr) { env.append(SonificationMetrics.rms(y[i..<(i + w)])); i += w }
        let mean = env.reduce(0, +) / Double(env.count)
        let v = env.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(env.count)
        return v.squareRoot() / max(mean, 1e-12)
    }

    @Test("kernel: roughness 1 modulates the level measurably; 0 and unset are byte-identical to r17")
    func kernelRender() throws {
        let plain = try Self.render(roughness: nil)
        let zero = try Self.render(roughness: 0)
        let rough = try Self.render(roughness: 1)
        #expect(plain == zero, "roughness 0 must be the r17 output, sample for sample")
        let dPlain = Self.envelopeDepth(plain), dRough = Self.envelopeDepth(rough)
        #expect(dRough > 0.25, "rough envelope depth \(dRough)")
        #expect(dRough > 10 * dPlain, "rough \(dRough) vs plain \(dPlain)")
    }

    /// The voices alone: the same source through a bare renderer, driven the way the kernel drives voice 0
    /// (reset, rate 1, pitch 0, gate open, then rate/pitch/render per chunk). No kernel stage is in this chain,
    /// so it is the absolute reference the kernel's own self-comparisons (`plain == zero`) cannot give.
    static func bareRender(seconds: Double = 1.0, chunk: Int = 256) throws -> [Float] {
        let src = try StudySources.load("spatial_carrier")
        let (r, _) = LiveSonificationAudio.makeRendererPair(src.sonificationSource)
        r.reset(); r.setRate(1); r.setPitchCents(0); r.setGate(true)
        let total = Int(seconds * sr)
        var y = [Float](repeating: 0, count: total)
        var pos = 0
        y.withUnsafeMutableBufferPointer { b in
            while pos < total {
                let n = min(chunk, total - pos)
                r.setRate(1); r.setPitchCents(0)
                r.render(into: b.baseAddress! + pos, frames: n)
                pos += n
            }
        }
        return y
    }

    /// First sample compared: past the 8 ms onset ramp (384 samples), where the voice shape is exactly 1.
    static let afterOnset = 2048

    @Test("kernel: at roughness 0 (and never set) the output IS the voices' output, sample for sample: the stage adds no gain")
    func kernelOffIsTheBareVoices() throws {
        let bare = try Self.bareRender()
        let plain = try Self.render(roughness: nil)
        let zero = try Self.render(roughness: 0)
        #expect(Array(plain[Self.afterOnset...]) == Array(bare[Self.afterOnset...]),
                "the default kernel render differs from the bare renderer: some stage scales the sound at depth 0")
        #expect(Array(zero[Self.afterOnset...]) == Array(bare[Self.afterOnset...]))
        #expect(bare[Self.afterOnset...].contains { abs($0) > 0.01 }, "precondition: the reference is not silence")
    }

    @Test("kernel: roughness 1 is the voices times the documented modulator, 1 - d (0.5 - 0.5 cos 2 pi ph), d one-pole toward the depth")
    func kernelOnIsTheDocumentedModulator() throws {
        let bare = try Self.bareRender()
        let rough = try Self.render(roughness: 1)
        let a = RoughnessTuning.smoothingCoefficient
        let target = RoughnessTuning.maxDepth
        let step = Float(RoughnessTuning.frequencyHz) / Float(Self.sr)
        var d: Float = 0, ph: Float = 0
        var worst: Float = 0, peak: Float = 0
        for i in 0..<rough.count {
            d += a * (target - d)
            let m = 1 - d * (0.5 - 0.5 * cos(2 * Float.pi * ph))
            ph += step; if ph >= 1 { ph -= 1 }
            if i >= Self.afterOnset {
                worst = max(worst, abs(rough[i] - bare[i] * m))
                peak = max(peak, abs(bare[i]))
            }
        }
        #expect(peak > 0.01, "precondition: the reference is not silence")
        #expect(worst <= 1e-5 * peak, "largest deviation from voices x modulator \(worst), peak \(peak)")
    }

    @Test("kernel: switching roughness on mid-sound steps nothing (no click)")
    func kernelNoClick() throws {
        let plain = try Self.render(roughness: nil)
        let sw = try Self.render(roughness: 1, switchAt: 0.5)
        let around = Int(0.49 * Self.sr)..<Int(0.6 * Self.sr)
        let base = SonificationMetrics.maxDelta(plain, around)
        let d = SonificationMetrics.maxDelta(sw, around)
        #expect(d <= base * 1.5 + 1e-4, "max sample step \(d) vs unmodulated \(base)")
        // and the sound before the switch is untouched
        #expect(Array(sw[0..<Int(0.49 * Self.sr)]) == Array(plain[0..<Int(0.49 * Self.sr)]))
    }

    /// The smoothing's job is the OFF edge: the modulator starts at phase 0
    /// (where its factor is 1), so switching ON cannot step even unsmoothed
    /// (mutation s7-2 survived `kernelNoClick`), but switching OFF mid-cycle
    /// drops the factor from `1 - depth * mod` to 1 in one sample unless the
    /// depth decays.
    @Test("kernel: switching roughness OFF mid-sound steps nothing (no click)")
    func kernelNoClickOff() throws {
        let plain = try Self.render(roughness: nil)
        let on = try Self.render(roughness: 1)
        let sw = try Self.render(roughness: 1, switchOffAt: 0.5125)
        let around = Int(0.50 * Self.sr)..<Int(0.60 * Self.sr)
        let bound = max(SonificationMetrics.maxDelta(plain, around), SonificationMetrics.maxDelta(on, around))
        let d = SonificationMetrics.maxDelta(sw, around)
        #expect(d <= bound * 1.5 + 1e-4, "max sample step \(d) vs unswitched \(bound)")
        #expect(Array(sw[0..<Int(0.50 * Self.sr)]) == Array(on[0..<Int(0.50 * Self.sr)]),
                "precondition: the sound before the switch is the rough render")
        // and the tail really is unmodulated again once the depth has decayed
        let late = Int(0.9 * Self.sr)..<Int(1.0 * Self.sr)
        #expect(Array(sw[late]) == Array(plain[late]), "roughness off must return to the r17 output")
    }
}
