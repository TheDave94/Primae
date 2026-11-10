// OnsetCeilingTests.swift
// PrimaeNativeTests — protocol r22 (lane ONSET-CEILING, audit 2026-11-10)
//
// A's recorded onset carries one glottal pulse at file -4.01 dBFS; its AE-2 gain is +5.92 dB (measured on the loop
// part), so the kernel played the pulse at +1.91 dBFS, 10 samples over digital full scale. `TDPSOLAOnsetCeiling` gives
// the samples of a recorded onset that would pass -0.5 dBFS at the file's gain one smooth local dip at renderer init.
// Measured offline before the change (onset-ceiling/REPORT.md): A is the only study file over full scale at rates 0.8,
// 1, 1.25 and the carrier at +-530 / +-1200 cents.
//
// The suite's other renders build their sources at gain 1 (`StudySource.sonificationSource`), where nothing reaches
// the ceiling, so they do not see this change; the pins here use each file's REAL loudness gain, as production does.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("r22: a recorded onset stays under full scale at its loudness gain")
nonisolated struct OnsetCeilingTests {

    static let sr = LiveSonificationKernel.sampleRate
    static let ceiling = TDPSOLAOnsetCeiling.ceiling

    // MARK: the pure function

    /// `base` everywhere (0.5: under the ceiling at gain 1) with a pulse of `width` samples at `at` reaching `peak`.
    static func pulse(count: Int = 4000, at: Int = 2000, width: Int = 5, peak: Float = 1.2, base: Float = 0.5) -> [Float] {
        var x = [Float](repeating: base, count: count)
        for i in at..<(at + width) { x[i] = i % 2 == 0 ? peak : -peak }
        return x
    }

    @Test("a pulse over the ceiling comes out at or under it")
    func pulseIsBroughtUnderTheCeiling() {
        let x = Self.pulse()
        #expect(x.contains { abs($0) > Self.ceiling }, "precondition: the input passes the ceiling")
        let y = TDPSOLAOnsetCeiling.limit(x, gain: 1, ceiling: Self.ceiling, taper: 190, in: 0..<x.count)
        let worst = y.map { abs($0) }.max() ?? 0
        #expect(worst <= Self.ceiling, "peak \(worst) over the ceiling \(Self.ceiling)")
        // The loudest sample lands on the ceiling (the dip is no deeper than it must be).
        #expect(worst > Self.ceiling * 0.9999, "the dip is deeper than needed: peak \(worst)")
    }

    @Test("the gain is applied: a sample under the ceiling at gain 1 but over it at the file's gain is limited")
    func ceilingIsAtTheOutputGain() {
        let x = Self.pulse(peak: 0.8, base: 0.3)
        let gain: Float = 1.9767
        #expect(TDPSOLAOnsetCeiling.limit(x, gain: 1, ceiling: Self.ceiling, taper: 190, in: 0..<x.count) == x)
        let y = TDPSOLAOnsetCeiling.limit(x, gain: gain, ceiling: Self.ceiling, taper: 190, in: 0..<x.count)
        let worst = y.map { abs($0) * gain }.max() ?? 0
        #expect(worst <= Self.ceiling, "peak x gain \(worst) over the ceiling")
        #expect(Array(y.prefix(1500)) == Array(x.prefix(1500)), "the steady level (0.59 at this gain) must not be touched")
    }

    @Test("samples outside the dip are bit-identical, and the dip spans the pulse plus one taper on each side")
    func outsideTheDipIsUntouched() {
        let x = Self.pulse(at: 2000, width: 5)
        let t = 190
        let y = TDPSOLAOnsetCeiling.limit(x, gain: 1, ceiling: Self.ceiling, taper: t, in: 0..<x.count)
        let changed = (0..<x.count).filter { x[$0].bitPattern != y[$0].bitPattern }
        #expect(changed.first == 2000 - t && changed.last == 2004 + t, "dip spans \(changed.first ?? -1)...\(changed.last ?? -1)")
        for i in 0..<x.count where i < 2000 - t || i > 2004 + t {
            #expect(x[i].bitPattern == y[i].bitPattern, "sample \(i) outside the dip changed")
        }
    }

    @Test("the dip is smooth: on a steady level its gain moves by no more than a raised-cosine slope per sample")
    func dipHasNoStep() {
        let x = Self.pulse(at: 2000, width: 5, peak: 1.2)
        let t = 190
        let y = TDPSOLAOnsetCeiling.limit(x, gain: 1, ceiling: Self.ceiling, taper: t, in: 0..<x.count)
        let env = (0..<x.count).map { Double(y[$0]) / Double(x[$0]) }
        let depth = 1 - (env.min() ?? 1)
        #expect(depth > 0.1, "precondition: a real dip (depth \(depth))")
        // A raised-cosine taper of t samples rises by at most depth * pi / (2 (t + 1)) per sample.
        let bound = depth * Double.pi / Double(2 * (t + 1)) * 1.01
        var worst = 0.0
        for i in 1..<env.count { worst = max(worst, abs(env[i] - env[i - 1])) }
        #expect(worst <= bound, "gain step \(worst) per sample (bound \(bound))")
    }

    @Test("input under the ceiling, a bad gain, or a pulse outside the range is returned bit-identical")
    func nothingToDoIsIdentity() {
        let quiet = Self.pulse(peak: 0.9)
        #expect(TDPSOLAOnsetCeiling.limit(quiet, gain: 1, ceiling: Self.ceiling, taper: 190, in: 0..<quiet.count) == quiet)
        let loud = Self.pulse(at: 3000)
        #expect(TDPSOLAOnsetCeiling.limit(loud, gain: 1, ceiling: Self.ceiling, taper: 190, in: 0..<2500) == loud,
                "a pulse after the range (the loop) must not be touched")
        #expect(TDPSOLAOnsetCeiling.limit(loud, gain: 0, ceiling: Self.ceiling, taper: 190, in: 0..<loud.count) == loud)
        #expect(TDPSOLAOnsetCeiling.limit(loud, gain: .nan, ceiling: Self.ceiling, taper: 190, in: 0..<loud.count) == loud)
    }

    @Test("the shipped constants: -0.5 dBFS, a 4.3 ms taper (190 samples at 44.1 kHz)")
    func constantsPinned() {
        #expect(TDPSOLAOnsetCeiling.ceilingDBFS == -0.5)
        #expect(abs(Double(Self.ceiling) - 0.944061) < 1e-6)
        #expect(TDPSOLAOnsetCeiling.taperFrames(sampleRate: 44_100) == 190)
    }

    // MARK: the shipped files at their real gain

    static func url(_ name: String) throws -> URL {
        if name == "spatial_carrier" {
            return try #require(PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Sonification", name: name, ext: "wav"))
                                ?? PrimaeBundle.audioURL(for: "Resources/Sonification/spatial_carrier.wav"))
        }
        let letter = String(name.prefix(1))
        return try #require(PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(letter)", name: name, ext: "wav")))
    }

    /// The source as production builds it: decoded samples, the file's recorded onset, its AE-2 loudness gain.
    @MainActor static func productionSource(_ name: String) throws -> SonificationSource {
        let src = try StudySources.load(name)
        let gain = AudioEngine.loudnessGain(forFileAt: try url(name))
        return SonificationSource(key: "test:\(name)", samples: src.samples, kind: src.kind, gain: gain, onset: src.onset)
    }

    @Test("every study file, rendered at its loudness gain, stays at or under the ceiling (rates 0.8, 1, 1.25; carrier +-530 cents)",
          arguments: StudySources.names)
    @MainActor func noStudyFilePassesFullScale(name: String) throws {
        let s = try Self.productionSource(name)
        let cents: [Float] = s.kind == .carrier ? [0, -530, 530] : [0]
        for rate: Float in [0.8, 1, 1.25] {
            for c in cents {
                // 4 s: the whole file (A 2.37 s, F 4.14 s at rate 1 reads from the onset) and loop wraps.
                let y = SonificationDriver.steady(LiveSonificationAudio.makeRenderer(s), seconds: 4.2, rate: rate, cents: c)
                let peak = (y.map { abs($0) }.max() ?? 0) * s.gain
                let over = y.filter { abs($0) * s.gain > 1 }.count
                #expect(over == 0, "\(name) rate \(rate) cents \(c): \(over) samples over full scale (peak \(20 * log10(Double(peak))) dBFS)")
                #expect(peak <= Self.ceiling, "\(name) rate \(rate) cents \(c): peak \(20 * log10(Double(peak))) dBFS over the ceiling")
            }
        }
    }

    @Test("A at its gain differs from A at gain 1 only inside the one dip around its onset pulse (file samples 2481-2896), by at most 2.5 dB")
    @MainActor func aChangesOnlyInsideTheDip() throws {
        let s = try Self.productionSource("A_phoneme1")
        #expect(s.gain > 1.9 && s.gain < 2.05, "precondition: A's gain \(s.gain) (+5.92 dB measured)")
        let unity = SonificationSource(key: s.key, samples: s.samples, kind: s.kind, gain: 1, onset: s.onset)
        let r = LiveSonificationAudio.makeRenderer(s)
        let y = SonificationDriver.steady(r, seconds: 4, rate: 1)
        let ref = SonificationDriver.steady(LiveSonificationAudio.makeRenderer(unity), seconds: 4, rate: 1)
        // Output frame i plays source frame onset + i at rate 1 through the onset (PhonemeOnsetTests (a)).
        let o = r.analysis.onset
        let changed = (0..<y.count).filter { y[$0].bitPattern != ref[$0].bitPattern }.map { $0 + o }
        #expect(!changed.isEmpty, "A at its gain is not limited at all")
        #expect((changed.first ?? 0) >= 2481 && (changed.last ?? .max) <= 2896,
                "A changed at file samples \(changed.first ?? -1)...\(changed.last ?? -1), outside the measured dip")
        var deepest = 0.0
        for f in changed where abs(ref[f - o]) > 1e-4 { deepest = min(deepest, 20 * log10(Double(abs(y[f - o]) / abs(ref[f - o])))) }
        #expect(deepest >= -2.5, "A's dip is \(deepest) dB deep (measured -2.41)")
        // The twin (the restart's crossover voice) is built with the same gain and plays the same onset.
        let (_, twin) = LiveSonificationAudio.makeRendererPair(s)
        #expect(SonificationDriver.steady(twin, seconds: 0.2, rate: 1) == Array(y.prefix(Int(0.2 * Self.sr))),
                "the twin's onset is not limited like the first voice's")
    }
}
