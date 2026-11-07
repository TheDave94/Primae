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

    @Test("default is r17: spatial arm 220-880 Hz mapping, phoneme and silent never pitched")
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
        #expect(StudyComparisonSettings.pitchScopeDefault == .spatialOnly)
        #expect(StudyComparisonSettings.pitchRangeCentsDefault == 2400)
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
        c.pitchScope = .both
        #expect(c.nonDefaultStamp == "pitchScope=both")
        c.pitchScope = .off
        #expect(c.nonDefaultStamp == "pitchScope=off")
        c.pitchScope = .spatialOnly
        c.pitchRangeCents = 1200
        #expect(c.nonDefaultStamp == "pitchRangeCents=1200")
        c.pitchScope = .both
        #expect(c.nonDefaultStamp == "pitchScope=both;pitchRangeCents=1200")
    }

    @Test("store: round trip, unknown value reads as default, span clamps, reset restores")
    func store() {
        let name = "pitchscope-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        typealias S = StudyComparisonSettings
        #expect(S.configuration(in: d).pitchScope == .spatialOnly)
        d.set("both", forKey: S.pitchScopeKey)
        d.set(1200, forKey: S.pitchRangeCentsKey)
        #expect(S.configuration(in: d).pitchScope == .both)
        #expect(S.configuration(in: d).pitchRangeCents == 1200)
        d.set("banana", forKey: S.pitchScopeKey)
        d.set(50, forKey: S.pitchRangeCentsKey)
        #expect(S.configuration(in: d).pitchScope == .spatialOnly)
        #expect(S.configuration(in: d).pitchRangeCents == 600)
        d.set("off", forKey: S.pitchScopeKey)
        #expect(S.resetToDefaults(in: d) == true)
        #expect(S.configuration(in: d).pitchScope == .spatialOnly)
        #expect(S.configuration(in: d).pitchRangeCents == 2400)
    }

    @Test("the view model captures the coupling from its dependencies and stamps it")
    func viewModelCaptures() {
        var deps = TracingDependencies.stub
        deps.pitchCoupling = PitchCoupling(scope: .both, spanCents: 1200)
        let vm = TracingViewModel(deps)
        #expect(vm.pitchCoupling == PitchCoupling(scope: .both, spanCents: 1200))
        #expect(vm.comparisonConfigurationStamp?.contains("pitchScope=both") == true)
        #expect(TracingViewModel(.stub).pitchCoupling == .default)
    }

    // MARK: Seam C

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
    func phonemeShiftsThroughTDPSOLA() throws {
        let c = PitchCoupling(scope: .both, spanCents: 1200)
        let up = try #require(c.cents(forNormalizedY: 0, arm: .phoneme))
        let down = try #require(c.cents(forNormalizedY: 1, arm: .phoneme))
        #expect(up == 600 && down == -600)
        let f0 = try renderF0("A_phoneme1", cents: 0)
        let fUp = try renderF0("A_phoneme1", cents: up)
        let fDown = try renderF0("A_phoneme1", cents: down)
        let mUp = SonificationMetrics.cents(fUp, f0), mDown = SonificationMetrics.cents(fDown, f0)
        #expect(abs(mUp - 600) < 40, "top: measured \(mUp) cents (f0 \(f0), shifted \(fUp))")
        #expect(abs(mDown + 600) < 40, "bottom: measured \(mDown) cents (shifted \(fDown))")
    }

    @Test("kernel: the default (spatialOnly) leaves the phoneme unshifted: no pitch command at any height, and what it would send plays at the unshifted f0")
    func defaultLeavesPhonemeAlone() throws {
        let dflt = PitchCoupling()
        let f0 = try renderF0("A_phoneme1", cents: 0)
        for y in stride(from: CGFloat(-0.2), through: 1.2, by: 0.1) {
            #expect(dflt.cents(forNormalizedY: y, arm: .phoneme) == nil, "the default pitched the phoneme at y=\(y)")
        }
        // Whatever the coupling sends at the canvas edges is what the kernel plays: render exactly that.
        for y in [CGFloat(0), 1] {
            let f = try renderF0("A_phoneme1", cents: dflt.cents(forNormalizedY: y, arm: .phoneme) ?? 0)
            #expect(abs(SonificationMetrics.cents(f, f0)) < 5, "y=\(y): f0 \(f) vs unshifted \(f0)")
        }
        // Control: the same measurement does see a shift when the scope asks for one.
        let up = try #require(PitchCoupling(scope: .both, spanCents: 1200).cents(forNormalizedY: 0, arm: .phoneme))
        let fUp = try renderF0("A_phoneme1", cents: up)
        #expect(abs(SonificationMetrics.cents(fUp, f0)) > 300, "control: a 'both' shift of \(up) cents measured \(SonificationMetrics.cents(fUp, f0))")
    }
}
