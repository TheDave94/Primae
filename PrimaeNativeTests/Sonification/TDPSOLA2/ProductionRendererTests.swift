// ProductionRendererTests.swift
// PrimaeNativeTests — protocol r31, lane PITCHWIN (2026-11-26)
//
// The renderer the study plays from r31 (`LiveSonificationAudio.makeRenderer` / `makeRendererPair`):
//   - the spatial carrier is the r17-r28 renderer, bit for bit, primary AND twin, under the identity drive (rate +
//     pitch + gate cycles + odd buffers): the spatial arm does not change;
//   - a phoneme is built with `TDPSOLA2Options.production` (the bake-off's TDPSOLA2-sa plus item 8), and its twin
//     renders what the primary renders (the crossover voice plays the same sound);
//   - item 8: a held phoneme (voiced, and F) keeps its 0-cent level within 0.5 dB at +-150 .. +-600 c and rates
//     0.5 / 1 / 2 (the 2026-11-25 bench: TDPSOLA2-sa I +600 -1.51 dB; F +600 -0.94 dB without item 8, offline), and
//     the table is exactly 1 at 0 cents, so 0 cents is TDPSOLA2-sa bit for bit;
//   - item 8's table is the same whether measured or taken from the cache (determinism, product gate 4);
//   - item 7: inside the attack the production renderer plays at the steady F0 x pf (the 2026-11-25 bench: the r28
//     renderer plays the first 0.1-0.4 s of every stroke 300-600 c off the note);
//   - the export stamps the phoneme arm's rows "TDPSOLA2", the other arms' "TDPSOLA".

import Testing
import Foundation
@testable import PrimaeNative

@Suite("r31 production renderer: TDPSOLA2 for the phonemes, the carrier unchanged")
nonisolated struct ProductionRendererTests {

    static let sr = LiveSonificationKernel.referenceSampleRate
    typealias Id = TDPSOLA2IdentityTests

    @Test("the spatial carrier is the r28 renderer bit for bit (primary and twin) under the identity drive")
    func carrierIsTheR28Renderer() throws {
        let s = try StudySources.load("spatial_carrier")
        let sc = Id.script(sampleRate: Self.sr)
        let r28 = Id.drive(SonificationRendererUnderTest.makeR28(s), sc)
        let (a, b) = LiveSonificationAudio.makeRendererPair(s.sonificationSource)
        #expect(a.options == .r27 && b.options == .r27, "the carrier runs every option off")
        #expect(r28.count > 400_000, "precondition: the drive is long (\(r28.count))")
        for (label, r) in [("primary", a), ("twin", b)] {
            let d = Id.firstDifference(r28, Id.drive(r, sc))
            #expect(d == nil, "carrier \(label): first difference at frame \(d ?? -1)")
        }
    }

    @Test("a phoneme is built with the production options, and its twin renders what the primary renders",
          arguments: ["A_phoneme1", "F_phoneme1", "I_phoneme1", "L_phoneme1", "M_phoneme1"])
    func phonemePairIsProduction(name: String) throws {
        let s = try StudySources.load(name)
        let (a, b) = LiveSonificationAudio.makeRendererPair(s.sonificationSource)
        #expect(a.options == .production && b.options == .production)
        #expect(a.levelTableValues == b.levelTableValues)
        let sc = Id.script(sampleRate: Self.sr)
        let x = Id.drive(a, sc)
        let d = Id.firstDifference(x, Id.drive(b, sc))
        #expect(d == nil, "\(name): twin differs from the primary at frame \(d ?? -1)")
        // And it is not the r28 renderer: the phoneme arm changed.
        #expect(Id.firstDifference(x, Id.drive(SonificationRendererUnderTest.makeR28(s), sc)) != nil)
    }

    @Test("item 8: a held phoneme keeps its 0-cent level within 0.5 dB (+-150 .. +-600 c; rates 0.5, 1, 2)",
          arguments: StudySources.voicedNames + ["F_phoneme1"])
    func levelIsFlat(name: String) throws {
        let s = try StudySources.load(name)
        let r = SonificationRendererUnderTest.make(s)
        for rate: Float in [0.5, 1, 2] {
            let l0 = C1Metrics.rms(TDPSOLA2PitchGateTests.steadySeg(r, rate: rate, cents: 0))
            for c: Float in [-600, -450, -300, -150, 150, 300, 450, 600] {
                let d = C1Metrics.dB(C1Metrics.rms(TDPSOLA2PitchGateTests.steadySeg(r, rate: rate, cents: c)), l0)
                #expect(abs(d) <= 0.5, "\(name) rate \(rate) \(c) c: level \(d) dB re 0 cents")
            }
        }
    }

    @Test("item 8 is exactly 1 at 0 cents: 0 cents is TDPSOLA2-sa bit for bit",
          arguments: StudySources.voicedNames + ["F_phoneme1"])
    func zeroCentsUnchanged(name: String) throws {
        let s = try StudySources.load(name)
        let prod = SonificationRendererUnderTest.make(s)
        #expect(prod.levelTableValues[LevelTable.zeroIndex] == 1)
        #expect(prod.levelTableValues.contains { $0 != 1 }, "\(name): the table measured something")
        let sa = C1Make.make(s, C1Make.with { $0.shiftedAttack = true })
        let x = SonificationDriver.steady(prod, seconds: 2, rate: 1, cents: 0)
        let y = SonificationDriver.steady(sa, seconds: 2, rate: 1, cents: 0)
        #expect(Id.firstDifference(x, y) == nil)
    }

    @Test("item 8: the table measured now equals the cached one, and both renderers play alike")
    func tableIsDeterministic() throws {
        let s = try StudySources.load("I_phoneme1")
        let cached = SonificationRendererUnderTest.make(s)
        LevelTable.removeAllForTesting()
        let measured = SonificationRendererUnderTest.make(s)
        #expect(cached.levelTableValues == measured.levelTableValues)
        let ev = [ControlEvent(time: 0, rate: 0.8, cents: -250, gate: true), ControlEvent(time: 0.4, cents: 380),
                  ControlEvent(time: 0.7, rate: 1.6), ControlEvent(time: 0.9, gate: false),
                  ControlEvent(time: 1.0, cents: 520, gate: true)]
        cached.reset(); measured.reset()
        let x = SonificationDriver.render(cached, seconds: 1.4, events: ev)
        let y = SonificationDriver.render(measured, seconds: 1.4, events: ev)
        #expect(x == y)
        #expect(x.contains { $0 != 0 })
    }

    @Test("item 7: inside the attack the production renderer plays at the steady F0 x pf (+-10 c at +400 c)",
          arguments: ["I_phoneme1", "L_phoneme1", "M_phoneme1"])
    func attackFollowsPitch(name: String) throws {
        let s = try StudySources.load(name)
        let r = SonificationRendererUnderTest.make(s)
        let f0 = try #require(C1Metrics.medianF0(
            SonificationDriver.steady(r, seconds: 2.0, rate: 1, cents: 0)[Int(0.6 * Self.sr)..<Int(1.9 * Self.sr)]))
        let pf = exp2(400.0 / 1200)
        let x = SonificationDriver.steady(r, seconds: 0.3, rate: 1, cents: 400)
        // Output time 0 = the source onset; the read-head advances at 1 through the attack. Skip the flat grain (the
        // recorded first pulse) and stop one period before the attack index's mark, so no window reaches the loop
        // (a window that reached the loop measured the loop and let an unshifted attack pass: lane C3, mutation D).
        let a = r.analysis
        let m0 = r.attackFirstMark
        let on = Double(a.onset)
        let lo = Int(a.marks[m0] - on + 2 * a.periods[m0]), hi = Int(a.marks[a.attackIndex] - on - a.periods[a.attackIndex])
        let maxLag = Int(Self.sr / (f0 * pf / 1.15)) + 1
        let window = min(2048, hi - lo - maxLag - 2 - 64)
        // At least five periods of the target pitch per analysis window. I's periodic attack is 57-96 ms once the
        // breath before it is the flat grain (r31): 1005 samples here, 7 periods at 316 Hz (a fixed 1024 refused it).
        let minWindow = Int((5 * Self.sr / (f0 * pf)).rounded(.up))
        try #require(window >= minWindow, "\(name): attack too short to measure (\(lo)..<\(hi), window \(window) < \(minWindow))")
        let f = try #require(C1Metrics.f0Near(x[lo..<hi], expected: f0 * pf, windows: 3, window: window),
                             "\(name): no f0 near \(f0 * pf) Hz inside the attack \(lo)..<\(hi)")
        let e = C1Metrics.cents(f, f0 * pf)
        #expect(abs(e) <= 10, "\(name): attack \(f) Hz against \(f0 * pf) Hz, \(e) c (\(lo)..<\(hi), window \(window))")
    }

    /// MEASURED (lane PITCHWIN, macOS driver): the correlation of the period ending at each attack mark with the one
    /// before it. A 0-9 below 0.47 (its rough glottal start), 10 0.54, then >= 0.84; I 0-13 below 0.3 (breath, -58 to
    /// -37 dB), 14 0.77, then >= 0.92; L 1 0.42, 2 0.52, 3 0.69, 4+ >= 0.87; M 0 0.70, then >= 0.87.
    static let firstPeriodicMark = ["A_phoneme1": 10, "I_phoneme1": 14, "L_phoneme1": 2, "M_phoneme1": 0]

    @Test("item 7 starts where the voice does: the pre-voicing (I's breath) is the flat grain, played as recorded",
          arguments: StudySources.voicedNames)
    func attackStartsAtTheVoice(name: String) throws {
        let s = try StudySources.load(name)
        let r = SonificationRendererUnderTest.make(s)
        #expect(r.attackFirstMark == Self.firstPeriodicMark[name], "\(name): attackFirstMark \(r.attackFirstMark)")
        // The flat grain is the recorded material: up to its mark the output is the played samples from the onset.
        let a = r.analysis
        let n = Int(a.marks[r.attackFirstMark].rounded(.down)) - a.onset - 2
        r.reset()
        let x = SonificationDriver.steady(r, seconds: 0.2, rate: 1, cents: 500)
        let src = r.playedSamples
        let ramp = Int((TDPSOLATuning.default.gateRampSeconds * Self.sr).rounded()) + 1
        if n > ramp {
            let d = (ramp..<n).map { abs(x[$0] - src[a.onset + $0]) }.max() ?? 0
            #expect(d < 1e-5, "\(name): the flat grain at +500 c is not the recording (max diff \(d))")
        }
    }

    @Test("the export stamps the phoneme arm TDPSOLA2 and the spatial and silent arms TDPSOLA")
    func stampFollowsTheArm() {
        #expect(LiveSonificationKernel.engineStamp(for: .phoneme) == "TDPSOLA2")
        #expect(LiveSonificationKernel.engineStamp(for: .spatial) == "TDPSOLA")
        #expect(LiveSonificationKernel.engineStamp(for: .silent) == "TDPSOLA")
        #expect(LiveSonificationAudio.rendererOptions(for: .carrier) == .r27)
        #expect(LiveSonificationAudio.rendererOptions(for: .voicedPhoneme) == .production)
        #expect(LiveSonificationAudio.rendererOptions(for: .unvoicedPhoneme) == .production)
    }
}
