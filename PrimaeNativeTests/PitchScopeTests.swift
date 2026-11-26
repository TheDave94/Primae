// PitchScopeTests.swift
// PrimaeNativeTests — R18DIM slice 2 (2026-11-06)
//
// "Height -> pitch" Off / spatial only / both arms, with a shared span.
// Seam A: ArmCoupling.parameters. Seam B: nonDefaultStamp + the store.
// Seam C: the live kernel renders a PHONEME pitch-shifted through TD-PSOLA.

import Testing
import CoreGraphics
import Foundation
@testable import PrimaeNative

@MainActor
@Suite("R18 pitch scope")
struct PitchScopeTests {

    private func params(_ y: CGFloat, arm: PilotAudioCondition, _ pitch: PitchCoupling? = nil) -> ArmCoupling.Parameters {
        if let pitch {
            return ArmCoupling.parameters(canvasNormalized: CGPoint(x: 0.5, y: y), velocity: 0,
                                          panningEnabled: true, rateCouplingEnabled: true, arm: arm, pitch: pitch)
        }
        return ArmCoupling.parameters(canvasNormalized: CGPoint(x: 0.5, y: y), velocity: 0,
                                      panningEnabled: true, rateCouplingEnabled: true, arm: arm)
    }

    // MARK: Seam A

    @Test("PitchCoupling() is the r17 reference: spatial arm 220-880 Hz mapping, phoneme and silent never pitched")
    func defaultIsR17() {
        for y in stride(from: CGFloat(-0.2), through: 1.2, by: 0.05) {
            #expect(params(y, arm: .spatial).spatialPitchCents == SpatialSonification.pitchCents(forNormalizedY: y))
            #expect(params(y, arm: .spatial, PitchCoupling()).spatialPitchCents
                    == SpatialSonification.pitchCents(forNormalizedY: y))
            #expect(params(y, arm: .phoneme).spatialPitchCents == nil)
            #expect(params(y, arm: .silent).spatialPitchCents == nil)
        }
        #expect(params(0, arm: .spatial).spatialPitchCents == 1200)
        #expect(params(1, arm: .spatial).spatialPitchCents == -1200)
    }

    @Test("r26: the study default pitches BOTH sound arms over one octave (+-600 cents), the same cents at the same height; silent none")
    func studyDefaultIsR26() {
        #expect(StudyComparisonSettings.pitchScopeDefault == .both)
        #expect(StudyComparisonSettings.pitchRangeCentsDefault == 1200)
        let c = PitchCoupling(scope: StudyComparisonSettings.pitchScopeDefault,
                              spanCents: StudyComparisonSettings.pitchRangeCentsDefault)
        for y in stride(from: CGFloat(-0.2), through: 1.2, by: 0.05) {
            let s = params(y, arm: .spatial, c).spatialPitchCents
            #expect(s == SpatialSonification.pitchCents(forNormalizedY: y, spanCents: 1200))
            #expect(params(y, arm: .phoneme, c).spatialPitchCents == s)
            #expect(params(y, arm: .silent, c).spatialPitchCents == nil)
        }
        #expect(params(0, arm: .phoneme, c).spatialPitchCents == 600)
        #expect(params(1, arm: .phoneme, c).spatialPitchCents == -600)
    }

    @Test("off: no arm is pitched")
    func offPitchesNoArm() {
        let c = PitchCoupling(scope: .off)
        for arm in PilotAudioCondition.allCases { #expect(params(0.3, arm: arm, c).spatialPitchCents == nil) }
    }

    @Test("both: phoneme and spatial get the SAME cents at the same height; silent none")
    func bothSharesTheRange() {
        for span in [2400, 1800, 1200, 600] {
            let c = PitchCoupling(scope: .both, spanCents: span)
            for y in [CGFloat(0), 0.25, 0.5, 0.8, 1] {
                let s = params(y, arm: .spatial, c).spatialPitchCents
                let p = params(y, arm: .phoneme, c).spatialPitchCents
                #expect(s != nil && s == p, "span \(span) y \(y): spatial \(String(describing: s)) phoneme \(String(describing: p))")
                #expect(params(y, arm: .silent, c).spatialPitchCents == nil)
            }
            #expect(params(0, arm: .phoneme, c).spatialPitchCents == Float(span) / 2)
            #expect(params(1, arm: .phoneme, c).spatialPitchCents == -Float(span) / 2)
            #expect(params(0.5, arm: .phoneme, c).spatialPitchCents == 0)
        }
    }

    @Test("spatialOnly with a narrower span narrows the spatial arm too; phoneme still flat")
    func spanAppliesToSpatial() {
        let c = PitchCoupling(scope: .spatialOnly, spanCents: 1200)
        #expect(params(0, arm: .spatial, c).spatialPitchCents == 600)
        #expect(params(0, arm: .phoneme, c).spatialPitchCents == nil)
    }

    @Test("an out-of-range stored span is clamped")
    func spanClamp() {
        #expect(params(0, arm: .spatial, PitchCoupling(scope: .both, spanCents: 99999)).spatialPitchCents == 1200)
        #expect(params(0, arm: .spatial, PitchCoupling(scope: .both, spanCents: 10)).spatialPitchCents == 300)
    }

    // MARK: Seam B

    @Test("stamp: nothing at defaults; pitchScope / pitchRangeCents appear when moved")
    func stamp() {
        #expect(StudyComparisonConfiguration.defaults.nonDefaultStamp == nil)
        var c = StudyComparisonConfiguration.defaults
        c.pitchScope = .spatialOnly
        #expect(c.nonDefaultStamp == "pitchScope=spatialOnly")
        c.pitchScope = .off
        #expect(c.nonDefaultStamp == "pitchScope=off")
        c.pitchScope = .both
        c.pitchRangeCents = 2400
        #expect(c.nonDefaultStamp == "pitchRangeCents=2400")
        // r26: an r17-r25 default session, replayed under r26, stamps both fields.
        c.pitchScope = .spatialOnly
        #expect(c.nonDefaultStamp == "pitchScope=spatialOnly;pitchRangeCents=2400")
    }

    @Test("store: round trip, unknown value reads as default, span clamps, reset restores")
    func store() {
        let name = "pitchscope-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        typealias S = StudyComparisonSettings
        #expect(S.configuration(in: d).pitchScope == .both)
        #expect(S.configuration(in: d).pitchRangeCents == 1200)
        d.set("spatialOnly", forKey: S.pitchScopeKey)
        d.set(2400, forKey: S.pitchRangeCentsKey)
        #expect(S.configuration(in: d).pitchScope == .spatialOnly)
        #expect(S.configuration(in: d).pitchRangeCents == 2400)
        d.set("banana", forKey: S.pitchScopeKey)
        d.set(50, forKey: S.pitchRangeCentsKey)
        #expect(S.configuration(in: d).pitchScope == .both)
        #expect(S.configuration(in: d).pitchRangeCents == 600)
        d.set("off", forKey: S.pitchScopeKey)
        #expect(S.resetToDefaults(in: d) == true)
        #expect(S.configuration(in: d).pitchScope == .both)
        #expect(S.configuration(in: d).pitchRangeCents == 1200)
    }

    @Test("the view model captures the coupling from its dependencies and stamps it")
    func viewModelCaptures() {
        var deps = TracingDependencies.stub
        // r26: the away values are the r25 behaviour (the defaults stamp nothing).
        deps.pitchCoupling = PitchCoupling(scope: .spatialOnly, spanCents: 2400)
        let vm = TracingViewModel(deps)
        #expect(vm.pitchCoupling == PitchCoupling(scope: .spatialOnly, spanCents: 2400))
        #expect(vm.comparisonConfigurationStamp?.contains("pitchScope=spatialOnly") == true)
        #expect(vm.comparisonConfigurationStamp?.contains("pitchRangeCents=2400") == true)
        #expect(TracingViewModel(.stub).pitchCoupling == PitchCoupling(scope: StudyComparisonSettings.pitchScopeDefault,
                                                                      spanCents: StudyComparisonSettings.pitchRangeCentsDefault))
        #expect(TracingViewModel(.stub).comparisonConfigurationStamp == nil)
    }

    // MARK: Seam C
    //
    // The renders below are pure kernel work (seconds each at -Onone), so the
    // tests are `nonisolated`: they run on the cooperative pool and do not
    // hold the main actor, which every view-model suite in the run queues on.
    // The coupling values they need are read on the main actor first.

    nonisolated static let sr = LiveSonificationKernel.sampleRate

    private nonisolated func renderF0(_ name: String, cents: Float) throws -> Double {
        let src = try StudySources.load(name)
        let kernel = LiveSonificationKernel(ramps: .production)
        let (r, twin) = LiveSonificationAudio.makeRendererPair(src.sonificationSource)
        let slot = try #require(kernel.register(r, twin: twin, gain: 1))
        kernel.setPitchCents(cents)
        kernel.open(slot: slot, fadeInFrames: 0)
        var y = [Float](repeating: 0, count: Int(1.2 * Self.sr))
        var pos = 0
        y.withUnsafeMutableBufferPointer { b in
            while pos < b.count {
                let n = min(256, b.count - pos)
                kernel.render(into: b.baseAddress! + pos, frames: n)
                pos += n
            }
        }
        return try #require(SonificationMetrics.medianF0(y, from: Int(0.3 * Self.sr), to: y.count, sampleRate: Self.sr))
    }

    @Test("kernel: a phoneme driven by the 'both' mapping at the top of the canvas plays shifted up by the mapped cents")
    nonisolated func phonemeShiftsThroughTDPSOLA() async throws {
        let (upOrNil, downOrNil) = await MainActor.run {
            let c = PitchCoupling(scope: .both, spanCents: 1200)
            return (c.cents(forNormalizedY: 0, arm: .phoneme), c.cents(forNormalizedY: 1, arm: .phoneme))
        }
        let up = try #require(upOrNil)
        let down = try #require(downOrNil)
        #expect(up == 600 && down == -600)
        let f0 = try renderF0("A_phoneme1", cents: 0)
        let fUp = try renderF0("A_phoneme1", cents: up)
        let fDown = try renderF0("A_phoneme1", cents: down)
        let mUp = SonificationMetrics.cents(fUp, f0), mDown = SonificationMetrics.cents(fDown, f0)
        #expect(abs(mUp - 600) < 40, "top: measured \(mUp) cents (f0 \(f0), shifted \(fUp))")
        #expect(abs(mDown + 600) < 40, "bottom: measured \(mDown) cents (shifted \(fDown))")
    }

    @Test("kernel: the r17 reference (spatialOnly) leaves the phoneme unshifted: no pitch command at any height, and what it would send plays at the unshifted f0")
    nonisolated func defaultLeavesPhonemeAlone() async throws {
        let heights = Array(stride(from: CGFloat(-0.2), through: 1.2, by: 0.1))
        let (sent, edges, upOrNil) = await MainActor.run {
            let dflt = PitchCoupling()
            return (heights.map { dflt.cents(forNormalizedY: $0, arm: .phoneme) },
                    [CGFloat(0), 1].map { dflt.cents(forNormalizedY: $0, arm: .phoneme) },
                    PitchCoupling(scope: .both, spanCents: 1200).cents(forNormalizedY: 0, arm: .phoneme))
        }
        let f0 = try renderF0("A_phoneme1", cents: 0)
        for (y, cents) in zip(heights, sent) {
            #expect(cents == nil, "the default pitched the phoneme at y=\(y)")
        }
        // Whatever the coupling sends at the canvas edges is what the kernel plays: render exactly that.
        for (y, cents) in zip([CGFloat(0), 1], edges) {
            let f = try renderF0("A_phoneme1", cents: cents ?? 0)
            #expect(abs(SonificationMetrics.cents(f, f0)) < 5, "y=\(y): f0 \(f) vs unshifted \(f0)")
        }
        // Control: the same measurement does see a shift when the scope asks for one.
        let up = try #require(upOrNil)
        let fUp = try renderF0("A_phoneme1", cents: up)
        #expect(abs(SonificationMetrics.cents(fUp, f0)) > 300, "control: a 'both' shift of \(up) cents measured \(SonificationMetrics.cents(fUp, f0))")
    }

    /// r26: F's phoneme is unvoiced (no pitch marks), so a "pitch" shift is a resampling of its
    /// noise grains by the pitch ratio: the noise gets brighter up and darker down. Measured as
    /// the zero-crossing rate of the steady render (r26 measurement: -600 0.72x, +600 1.21x).
    private nonisolated func renderF(cents: Float) throws -> [Float] {
        let src = try StudySources.load("F_phoneme1")
        let r = SonificationRendererUnderTest.make(src)
        return SonificationDriver.steady(r, seconds: 1.2, rate: 1, cents: cents)
    }

    @Test("r26 kernel: F (unvoiced) follows the default's +-600 cents: the noise is brighter at the top and darker at the bottom, at a similar level")
    nonisolated func unvoicedPhonemeShiftsWithHeight() async throws {
        let src = try StudySources.load("F_phoneme1")
        #expect(!SonificationRendererUnderTest.make(src).analysis.isVoiced, "precondition: F takes the unvoiced path")
        let (upOrNil, downOrNil) = await MainActor.run {
            let c = PitchCoupling(scope: StudyComparisonSettings.pitchScopeDefault,
                                  spanCents: StudyComparisonSettings.pitchRangeCentsDefault)
            return (c.cents(forNormalizedY: 0, arm: .phoneme), c.cents(forNormalizedY: 1, arm: .phoneme))
        }
        let up = try #require(upOrNil)
        let down = try #require(downOrNil)
        let a = Int(0.3 * Self.sr)
        let y0 = try renderF(cents: 0), yUp = try renderF(cents: up), yDown = try renderF(cents: down)
        // A plain sign-change rate: `SonificationMetrics.zeroCrossingFrequency` is a hysteresis
        // detector for TONAL signals and does not track a noise band's brightness (measured on the
        // iPad 2026-11-16: ratio 1.007 at +600 where the plain rate gives ~1.2).
        let z0 = Self.signChangeRate(y0, from: a), zUp = Self.signChangeRate(yUp, from: a)
        let zDown = Self.signChangeRate(yDown, from: a)
        #expect(zUp / z0 > 1.12, "top: zero-crossing rate \(zUp) vs \(z0) (ratio \(zUp / z0))")
        #expect(zDown / z0 < 0.82, "bottom: zero-crossing rate \(zDown) vs \(z0) (ratio \(zDown / z0))")
        let r0 = SonificationMetrics.rms(y0[a...])
        for (name, y) in [("top", yUp), ("bottom", yDown)] {
            let d = SonificationMetrics.dB(SonificationMetrics.rms(y[a...]), r0)
            #expect(abs(d) < 3, "\(name): level \(d) dB against the unshifted F")
        }
    }

    /// Sign changes per second over [from, end), halved (a sine of f Hz scores f).
    private nonisolated static func signChangeRate(_ y: [Float], from: Int) -> Double {
        var n = 0
        for i in (from + 1)..<y.count where (y[i - 1] < 0) != (y[i] < 0) { n += 1 }
        return Double(n) / (Double(y.count - from) / sr) / 2
    }

    @Test("r26 kernel: F at 0 cents is unchanged by the fix (the unvoiced grains are resampled by exactly 1)")
    nonisolated func unvoicedPhonemeAtZeroCentsIsUnchanged() throws {
        // At 0 cents pf == exp2(0) == 1 exactly, so inc is the pre-r26 1 and the render is bit for bit
        // the same; TDPSOLAIdentityTests pins F against the frozen r17 copy at 0 cents. Here: two
        // renders at cents 0 agree and differ from a shifted render (the comparison is not vacuous).
        let a = try renderF(cents: 0), b = try renderF(cents: 0), s = try renderF(cents: 600)
        #expect(a.count == b.count && zip(a, b).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(zip(a, s).contains { $0.bitPattern != $1.bitPattern }, "a +600 render equals the 0-cent render: the shift does nothing")
    }
}
