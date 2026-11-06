// SonificationRegressionTests.swift
// PrimaeNativeTests — protocol r17 regression suite (2026-11-03)
//
// The permanent pins for the live sonification engine (BAKEOFF.md product
// gate 6; BRIEF-r17 item 8). Pure buffers through the `SonificationRenderer`
// protocol, every shipped arm sound (A F I L M phonemes + the spatial
// carrier), the one engine (TDPSOLA; `SonificationRendererUnderTest`).
// Device-only properties (touch -> onset, CPU, energy) are NOT here: they are
// the device instrument documented in R17.md.
//
// Each test was mutation-checked RED with the executed count read from the
// log (CLAUDE.md, Test Infrastructure 1 and 5); the mutations are listed in
// R17.md.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("r17 sonification regression")
nonisolated struct SonificationRegressionTests {

    static let sr = LiveSonificationKernel.sampleRate

    // MARK: Onset

    @Test("onset: silent while closed; first sample within 64 frames, -20 dB within the first 5 ms window",
          arguments: StudySources.names)
    func onsetIsImmediate(name: String) throws {
        let src = try StudySources.load(name)
        let r = SonificationRendererUnderTest.make(src)
        r.reset()
        let y = SonificationDriver.render(r, seconds: 1.0, events: [
            ControlEvent(time: 0, rate: 1, cents: 0),
            ControlEvent(time: 0.1, gate: true),
        ])
        let open = SonificationDriver.appliedFrame(0.1)
        #expect(y[0..<open].allSatisfy { $0 == 0 }, "\(name): sound while the gate was closed")
        let steady = SonificationMetrics.rms(y[Int(0.4 * Self.sr)..<Int(0.95 * Self.sr)])
        let nz = try #require(SonificationMetrics.firstNonZero(y, from: open))
        #expect(nz <= 64, "\(name): first non-zero \(nz) frames after the gate")
        let onset = try #require(SonificationMetrics.onsetFrames(y, from: open, steadyRMS: steady, sampleRate: Self.sr))
        // R17D: a file with a recorded onset rises as recorded (I, L, M, F: up to ~16 ms to -20 dB, ONSET.md section 5);
        // the renderer may add at most the 5 ms window to the recording's own rise, measured the same way on the file.
        let own = src.onset == nil ? 0
            : (SonificationMetrics.onsetFrames(src.samples, from: r.analysis.onset, steadyRMS: steady, sampleRate: Self.sr) ?? 0)
        #expect(onset <= own + Int(0.005 * Self.sr) + 64,
                "\(name): -20 dB reached \(onset) frames (\(Double(onset) / Self.sr * 1000) ms) after the gate; the recording's own rise \(own)")
    }

    // MARK: Pitch

    @Test("phoneme f0 is held within 1 % at rates 0.5 ... 2",
          arguments: StudySources.voicedNames)
    func phonemePitchHeld(name: String) throws {
        let src = try StudySources.load(name)
        let ref = try #require(SonificationMetrics.medianF0(src.samples, from: Int(0.2 * Self.sr),
                                                            to: src.samples.count - 1000, sampleRate: Self.sr))
        for rate: Float in [0.5, 0.75, 1, 1.5, 2] {
            let y = SonificationDriver.steady(SonificationRendererUnderTest.make(src), seconds: 2.0, rate: rate)
            let f = try #require(SonificationMetrics.medianF0(y, from: Int(0.3 * Self.sr), to: y.count, sampleRate: Self.sr),
                                 "\(name) rate \(rate): no f0")
            let err = abs(f / ref - 1) * 100
            #expect(err <= 1.0, "\(name) rate \(rate): f0 \(f) Hz vs source \(ref) Hz = \(err) %")
        }
    }

    @Test("carrier pitch follows the commanded cents within 5 c at rates 0.5, 1, 2")
    func carrierCents() throws {
        let src = try StudySources.load("spatial_carrier")
        let ref = try #require(SonificationMetrics.zeroCrossingFrequency(src.samples, from: 2000,
                                                                         to: src.samples.count - 2000, sampleRate: Self.sr))
        for rate: Float in [0.5, 1, 2] {
            for cents: Float in [-1200, -700, 0, 700, 1200] {
                let y = SonificationDriver.steady(SonificationRendererUnderTest.make(src), seconds: 1.6,
                                                  rate: rate, cents: cents)
                let f = try #require(SonificationMetrics.zeroCrossingFrequency(y, from: Int(0.3 * Self.sr), to: y.count,
                                                                               sampleRate: Self.sr))
                let err = SonificationMetrics.cents(f, ref) - Double(cents)
                #expect(abs(err) <= 5, "rate \(rate) cents \(cents): \(f) Hz, error \(err) c")
            }
        }
    }

    // MARK: Rate step (RVF instrument)

    @Test("instrument self-test: the ideal step reads ~0 ms and the ideal stepped 100 ms late reads ~100 ms")
    func rateStepInstrumentCalibrated() throws {
        let src = try StudySources.load("A_phoneme1")
        let x = src.samples
        for (a, b): (Float, Float) in [(1, 2), (1, 0.5)] {
            let now = try #require(RateStepProbe.measure(RateStepProbe.ideal(x, from: Double(a), to: Double(b), lag: 0,
                                                                             sampleRate: Self.sr), sampleRate: Self.sr))
            let late = try #require(RateStepProbe.measure(RateStepProbe.ideal(x, from: Double(a), to: Double(b), lag: 0.1,
                                                                              sampleRate: Self.sr), sampleRate: Self.sr))
            #expect(abs(now.hinge) < 0.004, "ideal \(a)->\(b): hinge \(now.hinge * 1000) ms")
            #expect(abs(late.hinge - 0.1) < 0.006, "ideal \(a)->\(b) +100 ms: hinge \(late.hinge * 1000) ms")
        }
    }

    @Test("rate step 1->2 and 1->0.5: equivalent dead time <= 20 ms, both rates honoured within 3 %",
          arguments: ["A_phoneme1", "M_phoneme1"])
    func rateStepIsFast(name: String) throws {
        let src = try StudySources.load(name)
        let am = StudySource(name: name + "+AM", samples: RateStepProbe.modulate(src.samples, sampleRate: Self.sr),
                             kind: src.kind)
        for (a, b): (Float, Float) in [(1, 2), (1, 0.5)] {
            let y = RateStepProbe.render(SonificationRendererUnderTest.make(am), from: a, to: b)
            let m = try #require(RateStepProbe.measure(y, sampleRate: Self.sr), "\(name) \(a)->\(b): unreadable")
            #expect(abs(m.preSlope / Double(a) - 1) <= 0.03, "\(name): pre-step rate \(m.preSlope)")
            #expect(abs(m.postSlope / Double(b) - 1) <= 0.03, "\(name): post-step rate \(m.postSlope)")
            #expect(m.hinge <= 0.020 && m.hinge >= -0.010,
                    "\(name) \(a)->\(b): hinge \(m.hinge * 1000) ms")
        }
    }

    @Test("TDPSOLA runs the r17 tuning: smoothing tau 2 ms, so a rate step 1->2 lands within 2.5 ms of ideal",
          arguments: ["A_phoneme1", "M_phoneme1"])
    func tdpsolaTuningPinned(name: String) throws {
        // Supervisor/David 2026-11-03 (lane OPT-T's curve): tau 2 ms, not the bake-off 5 ms and not 1 ms.
        // OPT-T measured the 1->2 hinge excess at 3.2-5.5 ms with tau 5 ms and -1.2-1.1 ms with tau 2 ms.
        #expect(TDPSOLATuning.default.smoothingSeconds == 0.002)
        #expect(TDPSOLATuning.default.gateRampSeconds == 0.002)
        let src = try StudySources.load(name)
        let am = StudySource(name: name + "+AM", samples: RateStepProbe.modulate(src.samples, sampleRate: Self.sr),
                             kind: src.kind)
        let y = RateStepProbe.render(SonificationRendererUnderTest.make(am), from: 1, to: 2)
        let m = try #require(RateStepProbe.measure(y, sampleRate: Self.sr), "\(name): unreadable")
        #expect(m.hinge <= 0.0025, "\(name) 1->2: hinge \(m.hinge * 1000) ms (tau 5 ms reads >= 3.2 ms)")
    }

    // MARK: Clicks

    @Test("gate open/close/reopen and parameter steps are click-free; exact zeros after close",
          arguments: StudySources.names)
    func noClicks(name: String) throws {
        let src = try StudySources.load(name)
        let r = SonificationRendererUnderTest.make(src)
        r.reset()
        var events = [
            ControlEvent(time: 0, rate: 1, cents: 0),
            ControlEvent(time: 0.05, gate: true),
            ControlEvent(time: 0.30, rate: 2),
            ControlEvent(time: 0.80, gate: false),
            ControlEvent(time: 0.802, gate: true),
            ControlEvent(time: 1.20, gate: false),
        ]
        if src.isCarrier {
            events.append(ControlEvent(time: 0.0, cents: -1200))
            events.append(ControlEvent(time: 0.55, cents: 1200))
        }
        let y = SonificationDriver.render(r, seconds: 1.4, events: events)
        func frames(_ a: Double, _ b: Double) -> Range<Int> { Int(a * Self.sr)..<Int(b * Self.sr) }
        // Reference: the largest sample step the render makes in its steady stretches,
        // and the source's own (scaled by the pitch factor for an upward-shifted carrier).
        let steady = [frames(0.12, 0.28), frames(0.38, 0.53), frames(0.63, 0.78), frames(0.9, 1.15)]
        var ref = steady.map { SonificationMetrics.maxDelta(y, $0) }.max() ?? 0
        ref = max(ref, SonificationMetrics.maxDelta(src.samples, 1..<src.samples.count) * (src.isCarrier ? 2 : 1))
        let times = src.isCarrier ? [0.05, 0.30, 0.55, 0.80, 0.802, 1.20] : [0.05, 0.30, 0.80, 0.802, 1.20]
        for t in times {
            let f = SonificationDriver.appliedFrame(t)
            let d = SonificationMetrics.maxDelta(y, (f - 64)..<(f + Int(0.02 * Self.sr)))
            #expect(d <= 1.5 * ref, "\(name): step \(d) at t=\(t) s vs steady \(ref)")
        }
        let end = SonificationDriver.appliedFrame(1.20) + Int(0.03 * Self.sr)
        #expect(y[end...].allSatisfy { $0 == 0 }, "\(name): output leaks after the gate closed")
    }

    // MARK: Determinism and goldens

    /// The fixed real-trajectory-like drive used for determinism and the goldens:
    /// 2.5 s, rate swept 0.6 -> 1.8 -> 0.8 at 120 Hz, two pen lifts, the carrier
    /// also swept -1000 -> +900 cents.
    static func trajectoryEvents(carrier: Bool) -> [ControlEvent] {
        var e: [ControlEvent] = [ControlEvent(time: 0, rate: 1, cents: 0, gate: true)]
        let dt = 1.0 / 120
        var t = 0.0
        while t < 2.5 {
            let u = t / 2.5
            let rate = Float(u < 0.5 ? 0.6 + 2.4 * u : 1.8 - 2.0 * (u - 0.5))
            var ev = ControlEvent(time: t, rate: rate)
            if carrier { ev.cents = Float(-1000 + 1900 * u) }
            e.append(ev)
            t += dt
        }
        e.append(ControlEvent(time: 0.9, gate: false)); e.append(ControlEvent(time: 1.1, gate: true))
        e.append(ControlEvent(time: 1.8, gate: false)); e.append(ControlEvent(time: 1.85, gate: true))
        return e
    }

    static func trajectoryRender(_ src: StudySource) -> [Float] {
        let r = SonificationRendererUnderTest.make(src)
        r.reset()
        return SonificationDriver.render(r, seconds: 2.5, events: trajectoryEvents(carrier: src.isCarrier))
    }

    @Test("determinism: two fresh instances, same drive -> bit-identical output",
          arguments: StudySources.names)
    func deterministic(name: String) throws {
        let src = try StudySources.load(name)
        let a = Self.trajectoryRender(src)
        let b = Self.trajectoryRender(src)
        #expect(a == b, "\(name): two renders of the same drive differ")
    }

    @Test("golden renders: the trajectory drive's 40-block RMS fingerprint matches the recorded one",
          arguments: StudySources.names)
    func golden(name: String) throws {
        let src = try StudySources.load(name)
        let fp = SonificationMetrics.fingerprint(Self.trajectoryRender(src))
        let literal = fp.map { String(format: "%.6g", $0) }.joined(separator: ", ")
        let key = name
        guard let want = SonificationGoldens.fingerprints[key] else {
            Issue.record("no golden for \(key); recorded: \"\(key)\": [\(literal)],")
            return
        }
        #expect(want.count == fp.count)
        var worst = 0.0
        for (w, g) in zip(want, fp) { worst = max(worst, abs(w - g) / max(1e-3, abs(w))) }
        #expect(worst <= 1e-3, "\(key): fingerprint moved (worst relative \(worst)); now: [\(literal)]")
    }

    // MARK: F loudness (R17 hardening)

    @Test("F (unvoiced) off rate 1: level within 0.5 dB of the source, grain-rate wobble <= 1 dB")
    func unvoicedLevelHolds() throws {
        let src = try StudySources.load("F_phoneme1")
        let srcRMS = SonificationMetrics.rms(src.samples[Int(0.2 * Self.sr)..<Int(1.8 * Self.sr)])
        for rate: Float in [0.5, 2] {
            let y = SonificationDriver.steady(SonificationRendererUnderTest.make(src), seconds: 2.5, rate: rate)
            let region = y[Int(0.3 * Self.sr)..<Int(2.4 * Self.sr)]
            let level = SonificationMetrics.dB(SonificationMetrics.rms(region), srcRMS)
            let bound = 0.5
            #expect(abs(level) <= bound, "F rate \(rate): level \(level) dB re source (bound \(bound))")
            // Power folded on the 5 ms WSOLA hop (220 frames), 20 bins.
            let period = 220, bins = 20
            var acc = [Double](repeating: 0, count: bins), cnt = [Double](repeating: 0, count: bins)
            var i = region.startIndex
            while i < region.endIndex {
                let b = ((i - region.startIndex) % period) * bins / period
                acc[b] += Double(y[i]) * Double(y[i]); cnt[b] += 1
                i += 1
            }
            let p = zip(acc, cnt).map { $0 / $1 }
            let wobble = 10 * log10(p.max()! / p.min()!)
            #expect(wobble <= 1.0, "F rate \(rate): grain-rate wobble \(wobble) dB")
        }
    }

    // MARK: TDPSOLA specifics

    @Test("TDPSOLA: every study phoneme's pitch marks stay inside the period clamp band (documented limit)",
          arguments: StudySources.voicedNames)
    func periodClampBoundsHold(name: String) throws {
        let src = try StudySources.load(name)
        // R17D: the analysis the renderer runs (declared onset). The onset's own pitch glide (L, M: ~290 -> 240 Hz in the
        // first 40-80 ms) plays once, verbatim, before the attack index; the clamp concerns the marks the loop uses.
        let a = TDPSOLAAnalysis.analyse(src.samples, sampleRate: Self.sr, kind: src.kind, onset: src.onset)
        #expect(a.isVoiced)
        let med = a.medianPeriod
        let inner = a.periods[a.attackIndex...a.loopEndIndex]
        #expect(inner.allSatisfy { $0 >= 0.8 * med && $0 <= 1.25 * med },
                "\(name): mark spacing \(inner.min() ?? 0)...\(inner.max() ?? 0) vs median \(med)")
        // Independently of the analysis: the source's own f0 never leaves the band either.
        var k = max(Int(0.05 * Self.sr), src.onset?.attackEndFrame ?? 0)
        while k + 4096 + 700 < src.samples.count {
            if let f = SonificationMetrics.f0(src.samples, from: k, sampleRate: Self.sr) {
                let p = Self.sr / f
                #expect(p >= 0.8 * med && p <= 1.25 * med, "\(name) at \(Double(k) / Self.sr) s: period \(p) vs \(med)")
            }
            k += Int(0.1 * Self.sr)
        }
    }

    @Test("the carrier is recognised by its file name, which is SpatialSonification's")
    @MainActor func carrierFileNameMatches() {
        #expect(SonificationSource.carrierFileName
                == (SpatialSonification.carrierToneFile as NSString).lastPathComponent)
    }
}
