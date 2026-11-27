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

    static let sr = LiveSonificationKernel.referenceSampleRate

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
        // The output probe, on the renderer it was calibrated on: TDPSOLA2 with every option off is the r17-r28
        // TDPSOLA bit for bit (TDPSOLA2IdentityTests), and its output envelope is a pure function of its read-head.
        let s = am.sonificationSource
        let r28 = TDPSOLA2(source: s.samples, sampleRate: Self.sr, kind: s.kind, maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                           tuning: .default, options: .r27, onset: s.onset, outputGain: s.gain)
        let y = RateStepProbe.render(r28, from: 1, to: 2)
        let m = try #require(RateStepProbe.measure(y, sampleRate: Self.sr), "\(name): unreadable")
        #expect(m.hinge <= 0.0025, "\(name) 1->2: hinge \(m.hinge * 1000) ms (tau 5 ms reads >= 3.2 ms)")
        // The production renderer (r31): its rate smoother IS the one above, so pin it where it lives, on the read-head.
        // The output probe cannot: item 4 (harmonic/noise swap) plays every grain at rate 2 as h_i + n_j, h_i a
        // five-period average and n_j drawn from +-8 marks, so the output AM no longer follows the read-head alone
        // (M read 3.63 ms at this step phase with item 7, 0.88 without; over 24 step phases the probe spreads
        // -1.0 ... 6.9 ms on r28 itself, MEASURED, lane PITCHWIN macOS driver). The read-head hinge reads tau to
        // 0.01 ms: tau 1 / 2 / 5 ms read 0.989 / 1.989 / 4.988 ms on r28 and production alike.
        let hinge = Self.readHeadHinge(SonificationRendererUnderTest.make(am), to: 2)
        #expect(hinge >= 0.0015 && hinge <= 0.0025, "\(name) 1->2: read-head hinge \(hinge * 1000) ms (tau 2 ms reads 1.99, tau 5 ms 4.99)")
    }

    /// Where the line fits of the read-head over [-0.3, -0.05] s and [+0.2, +0.4] s around a 1 -> b step at the
    /// probe's step time intersect (64-frame blocks; the probe's windows and gate timing).
    static func readHeadHinge(_ r: TDPSOLA2, to b: Float) -> Double {
        r.reset(); r.setRate(1); r.setPitchCents(0); r.setGate(false)
        let open = SonificationDriver.appliedFrame(RateStepProbe.gateOpen, sampleRate: sr)
        let step = SonificationDriver.appliedFrame(RateStepProbe.stepTime, sampleRate: sr)
        var buf = [Float](repeating: 0, count: 64)
        var t = 0
        var pts: [(t: Double, p: Double)] = []
        while t < Int(RateStepProbe.duration * sr) {
            if t == open { r.setGate(true) }
            if t == step { r.setRate(b) }
            buf.withUnsafeMutableBufferPointer { r.render(into: $0.baseAddress!, frames: 64) }
            t += 64
            pts.append((t: Double(t - step) / sr, p: r.debugReadHead / sr))
        }
        guard let l0 = RateStepProbe.lineFit(pts.filter { $0.t >= -0.3 && $0.t <= -0.05 }),
              let l1 = RateStepProbe.lineFit(pts.filter { $0.t >= 0.2 && $0.t <= 0.4 }) else { return .infinity }
        return (l0.intercept - l1.intercept) / (l1.slope - l0.slope)
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

    /// Peak-to-trough power ripple (dB) of `region`, folded on `period` output samples into `bins` phase bins.
    static func foldedWobble(_ y: [Float], _ region: Range<Int>, period: Int, bins: Int = 20) -> Double {
        var acc = [Double](repeating: 0, count: bins), cnt = [Double](repeating: 0, count: bins)
        for i in region {
            let b = ((i - region.lowerBound) % period) * bins / period
            acc[b] += Double(y[i]) * Double(y[i]); cnt[b] += 1
        }
        let p = zip(acc, cnt).map { $0 / $1 }
        return 10 * log10(p.max()! / p.min()!)
    }

    /// F wobble: the PHYSICAL bound. An unvoiced source carries no grain-rate periodicity, so a renderer that
    /// continues it without a seam adds none: <= 1 dB folded on the grain hop (BENCH-P `PitchGates.fWobbleDB`).
    static let unvoicedWobblePhysicalDB = 1.0
    /// F wobble of the SHIPPED engine at +-600 c, measured on the physical iPad (Debug-Study, 2026-11-24): 3.19 dB at
    /// -600 c, 3.16 dB at +600 c (rates 0.5 and 2 identical: the unvoiced read-head ignores the rate, U1).
    static let unvoicedWobbleShippedDB = 3.19
    /// Non-regression margin: above the meter's own floor at this fold (white noise reads 0.18-0.20 dB on the iPad)
    /// so device/simulator float drift cannot trip it, and well under the 1 dB a listener would notice as a new
    /// regression. The render is deterministic; the margin is for the platform, not for run-to-run noise.
    static let unvoicedWobbleMarginDB = 0.3

    /// The grain period (output samples, within +-30 of `around`) at which `region` ripples most, and that ripple.
    static func wobblePeak(_ y: [Float], _ region: Range<Int>, around: Int) -> (period: Int, dB: Double) {
        (around - 30...around + 30).map { ($0, foldedWobble(y, region, period: $0)) }.max { $0.1 < $1.1 }!
    }

    /// F (unvoiced) level and grain-rate wobble, at the engine's real grain hop.
    ///
    /// The physical bound on the wobble is 1 dB (`unvoicedWobblePhysicalDB`). At 0 c the shipped engine meets it
    /// (0.48 dB on the iPad) and is held to it. Across the r26 phoneme pitch span (+-600 c) the shipped engine measures
    /// 3.19 dB on the iPad (`unvoicedWobbleShippedDB`), so there this test is a NON-REGRESSION ceiling (3.19 + 0.3 dB),
    /// not a quality gate: the physical bound for those cells lives in the pitch bake-off gate (BENCH-P, F wobble),
    /// where the shipped engine is recorded as failing and the candidates compete. The fix is tracked by that bake-off;
    /// when a renderer that meets 1 dB ships, this ceiling drops to the physical bound.
    ///
    /// The level bound (0.5 dB re source) is held at 0 c only, as before: at +-600 c the shipped engine plays F about
    /// 1.9 dB under the source (iPad), which is the bake-off's F level gate, not this test's.
    @Test("F (unvoiced): level within 0.5 dB and wobble <= 1 dB at 0 c; wobble does not regress past the shipped engine at +-600 c")
    func unvoicedLevelDoesNotRegress() throws {
        let src = try StudySources.load("F_phoneme1")
        let srcRMS = SonificationMetrics.rms(src.samples[Int(0.2 * Self.sr)..<Int(1.8 * Self.sr)])
        let ceiling = Self.unvoicedWobbleShippedDB + Self.unvoicedWobbleMarginDB
        // r26: the phoneme arm pitches F over +-600 cents (PitchCoupling / PilotAudioCondition), and the unvoiced grain is
        // read at the pitch ratio, so the span's ends are where the WSOLA continuation is poorest.
        for cents: Float in [-600, 0, 600] {
            for rate: Float in [0.5, 2] {
                let r = SonificationRendererUnderTest.make(src)
                // The grain rate is the ENGINE's unvoiced hop, read off the analysis the production factory
                // (`LiveSonificationAudio.makeRenderer`) built: round(5 ms * 44.1 kHz) = 221 output samples, not 220.
                // Folding one sample off smears the ripple across every phase bin over the ~420 grains in the window
                // and reads it near zero (iPad, +600 c: 0.40 dB at 220 vs 3.16 dB at 221).
                let period = r.analysis.unvoicedHop
                let y = SonificationDriver.steady(r, seconds: 2.5, rate: rate, cents: cents)
                let region = Int(0.3 * Self.sr)..<Int(2.4 * Self.sr)
                let wobble = Self.foldedWobble(y, region, period: period)
                if cents == 0 {
                    let level = SonificationMetrics.dB(SonificationMetrics.rms(y[region]), srcRMS)
                    let bound = 0.5
                    #expect(abs(level) <= bound, "F rate \(rate): level \(level) dB re source (bound \(bound))")
                    #expect(wobble <= Self.unvoicedWobblePhysicalDB,
                            "F rate \(rate): grain-rate wobble \(wobble) dB (hop \(period), physical bound \(Self.unvoicedWobblePhysicalDB))")
                } else {
                    #expect(wobble <= ceiling,
                            "F rate \(rate) cents \(cents): grain-rate wobble \(wobble) dB (hop \(period)) regressed past the shipped engine's \(Self.unvoicedWobbleShippedDB) dB + \(Self.unvoicedWobbleMarginDB) dB")
                }
                // Instrument check: where the output carries a grain-rate ripple above the physical bound, it must
                // peak at the period this test folds on. A fold on the wrong period reads the ripple as ~0.4 dB and
                // would pass any ceiling; this is what makes the hop's derivation load-bearing.
                let peak = Self.wobblePeak(y, region, around: period)
                if peak.dB > Self.unvoicedWobblePhysicalDB {
                    #expect(peak.period == period,
                            "F rate \(rate) cents \(cents): output ripples at \(peak.period) samples (\(peak.dB) dB), test folds on \(period)")
                }
            }
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
