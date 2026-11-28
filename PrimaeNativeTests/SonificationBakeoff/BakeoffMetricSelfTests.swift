// BakeoffMetricSelfTests.swift
// PrimaeNativeTests — sonification bake-off harness (BENCH lane, 2026-11-02)
//
// The metrics are instruments; these tests check each one against a
// synthetic signal whose true answer is known by construction (a delayed
// copy, a pitch-shifted copy, a resampled noise with a known rate step, an
// inserted discontinuity). Cheap and AVAudioEngine-free, so they run in
// every suite run, CI included; the bench itself
// (`SonificationBakeoffBench`) is opt-in.
//
// XCTest, not Swift Testing: XCTest classes run serially, so nothing here
// competes with the parallel suites for the CPU.

import XCTest
@testable import PrimaeNative

final class BakeoffMetricSelfTests: XCTestCase {
    typealias M = BakeoffMetrics
    let sr = 48_000.0

    func noise(_ n: Int, seed: UInt32 = 12345) -> [Float] { BakeoffSynthetic.noise(n, seed: seed) }
    func tone(_ f: Double, count: Int, start: Int = 0) -> [Float] {
        BakeoffSynthetic.tone(f, count: count, sampleRate: sr, start: start)
    }

    // MARK: - Onset

    func testOnsetReportsTheDelayOfADelayedCopy() {
        let gate = 4800
        let clean = tone(220, count: 48_000, start: gate)
        let delay = 1234
        let delayed = [Float](repeating: 0, count: delay) + clean.dropLast(delay)
        let a = M.onset(clean, gateFrame: gate, openEnd: clean.count, sampleRate: sr)
        let b = M.onset(delayed, gateFrame: gate, openEnd: delayed.count, sampleRate: sr)
        let da = try! XCTUnwrap(a.toMinus20dB), db = try! XCTUnwrap(b.toMinus20dB)
        XCTAssertLessThanOrEqual(da, 240, "a 2 ms attack: the first qualifying 5 ms window ends within 5 ms")
        XCTAssertEqual(Double(db - da), Double(delay), accuracy: 16, "onset must move by exactly the inserted delay")
        XCTAssertEqual(Double(try! XCTUnwrap(b.toNonZero) - (try! XCTUnwrap(a.toNonZero))), Double(delay), accuracy: 1)
    }

    func testOnsetIsNilForSilence() {
        let x = [Float](repeating: 0, count: 48_000)
        XCTAssertNil(M.onset(x, gateFrame: 100, openEnd: x.count, sampleRate: sr).toMinus20dB)
    }

    // MARK: - f0

    func testF0IsAccurateOnAKnownTone() {
        for f in [110.0, 220.0, 440.0, 880.0] {
            let x = tone(f, count: 24_000)
            let m = try! XCTUnwrap(M.medianF0(M.yinTrack(x, start: 0, end: x.count, sampleRate: sr, hop: 480,
                                                        fmin: 75, fmax: 1900)))
            XCTAssertEqual(M.cents(m, re: f), 0, accuracy: 1, "f0 of a \(f) Hz tone")
        }
    }

    func testF0CatchesAPitchShiftedCopy() {
        let base = 220.0
        let ref = try! XCTUnwrap(M.medianF0(M.yinTrack(tone(base, count: 24_000), start: 0, end: 24_000,
                                                      sampleRate: sr, hop: 480)))
        for shift in [-50.0, 17.0, 30.0] {
            let f = base * pow(2, shift / 1200)
            let m = try! XCTUnwrap(M.medianF0(M.yinTrack(tone(f, count: 24_000), start: 0, end: 24_000,
                                                        sampleRate: sr, hop: 480)))
            XCTAssertEqual(M.cents(m, re: ref), shift, accuracy: 1, "the f0 metric must see a \(shift)-cent shift")
        }
        // The phoneme gate is +/-1 %: a 1 % shift must read as ~1 %, not 0.
        let m = try! XCTUnwrap(M.medianF0(M.yinTrack(tone(base * 1.01, count: 24_000), start: 0, end: 24_000,
                                                    sampleRate: sr, hop: 480)))
        XCTAssertEqual((m / ref - 1) * 100, 1, accuracy: 0.05)
    }

    func testNoiseIsUnvoiced() {
        let x = noise(24_000)
        XCTAssertLessThan(M.voicedFraction(M.yinTrack(x, start: 0, end: x.count, sampleRate: sr, hop: 480)), 0.2)
    }

    // MARK: - Local duration scale and its step response

    func testDurationScaleOfAnIdealTSMOnTheSweepProbe() {
        for r in [0.5, 0.75, 1.0, 1.5, 2.0] {
            let out = BakeoffSynthetic.idealSweepTSM(count: 192_000, sampleRate: sr) { _ in r }
            let med = try! XCTUnwrap(M.median(M.localRate(M.sweepTrack(out, from: 0, to: out.count, sampleRate: sr)).map(\.rate)))
            XCTAssertEqual(med, r, accuracy: r * 0.01, "duration scale at rate \(r)")
        }
    }

    func testDurationScaleOfAVarispeedOnTheSweepProbe() {
        // A varispeed shifts f0 by a constant ratio: a constant position
        // offset, the slope (the rate) is still read correctly.
        let probe = BakeoffSynthetic.sweepProbe(sampleRate: sr)
        for r in [0.75, 1.5] {
            var out = [Float](repeating: 0, count: 144_000)
            var pos = 0.0
            for i in 0..<out.count {
                let k = Int(pos), f = Float(pos - Double(k))
                out[i] = probe[k % probe.count] + (probe[(k + 1) % probe.count] - probe[k % probe.count]) * f
                pos += r
            }
            let med = try! XCTUnwrap(M.median(M.localRate(M.sweepTrack(out, from: 0, to: out.count, sampleRate: sr)).map(\.rate)))
            XCTAssertEqual(med, r, accuracy: r * 0.02, "varispeed duration scale at rate \(r)")
        }
    }

    func testRateStepResponseSeesADelayedStep() throws {
        let step = Int(0.6 * sr)
        func response(_ stepAt: Int) throws -> M.StepResponse {
            let out = BakeoffSynthetic.idealSweepTSM(count: Int(1.5 * sr), sampleRate: sr) { $0 < stepAt ? 1 : 2 }
            let rates = M.localRate(M.sweepTrack(out, from: 0, to: out.count, sampleRate: sr))
            let series = rates.map { (t: Double($0.frame) / sr, v: $0.rate) }
            return try XCTUnwrap(M.stepResponse(series, stepTime: Double(step) / sr))
        }
        let immediate = try response(step)
        let late = try response(step + Int(0.1 * sr))
        XCTAssertLessThan(abs(immediate.delayTo90), 0.07, "an instantaneous step reads within the estimator's resolution")
        XCTAssertEqual(late.delayTo90 - immediate.delayTo90, 0.1, accuracy: 0.0051, "a step 100 ms late must read 100 ms later")
    }

    func testPitchStepResponseSeesADelayedStep() throws {
        let step = Int(0.6 * sr)
        func toneStep(at s: Int) -> [Float] {
            var x = [Float](repeating: 0, count: Int(1.5 * sr))
            var phase = 0.0
            for i in 0..<x.count {
                let f = i < s ? 440.0 : 440.0 * pow(2, 700.0 / 1200)
                phase += 2 * .pi * f / sr
                x[i] = Float(sin(phase)) * 0.3
            }
            return x
        }
        func delay90(_ s: Int) throws -> Double {
            let x = toneStep(at: s)
            let tr = M.yinTrack(x, start: 0, end: x.count, sampleRate: sr, hop: 48, fmin: 150, fmax: 1900)
            let series = tr.compactMap { p in p.f0.map { (t: Double(p.frame) / sr, v: M.cents($0, re: 440)) } }
            return try XCTUnwrap(M.stepResponse(series, stepTime: Double(step) / sr)).delayTo90
        }
        let a = try delay90(step), b = try delay90(step + Int(0.05 * sr))
        XCTAssertEqual(b - a, 0.05, accuracy: 0.006, "a pitch step 50 ms late must read 50 ms later")
    }

    func testTrackingLagRecoversAKnownLag() throws {
        let times = stride(from: 0.0, to: 3.0, by: 0.0025).map { $0 }
        let commanded: (Double) -> Double = { 600 * sin(2 * .pi * $0 / 0.9) }
        let measured: [Double?] = times.map { commanded($0 - 0.04) }
        let t = try XCTUnwrap(M.trackingLag(times: times, commanded: commanded, measured: measured))
        XCTAssertEqual(t.lag, 0.04, accuracy: 0.0026)
        XCTAssertLessThan(t.rmsAtLag, t.rmsAtZero)
    }

    // MARK: - Discontinuities and spectra

    func testClickRatioSeesAnInsertedDiscontinuity() {
        var x = tone(440, count: 48_000)
        let typical = M.typicalDelta(x, 1000, 40_000)
        XCTAssertLessThan(M.maxAbsDelta(x, 20_000, 21_000) / typical, 1.5)
        for i in 20_500..<48_000 { x[i] += 0.4 }
        XCTAssertGreaterThan(M.maxAbsDelta(x, 20_000, 21_000) / typical, 5)
    }

    func testLogSpectralDistance() {
        let x = noise(48_000)
        let a = M.spectrogram(x, from: 0, to: x.count)
        XCTAssertEqual(try XCTUnwrap(M.logSpectralDistance(a, a)), 0, accuracy: 1e-9)
        var y = x
        for i in 1..<y.count { y[i] = 0.5 * (x[i] + x[i - 1]) }   // low-pass
        XCTAssertGreaterThan(try XCTUnwrap(M.logSpectralDistance(a, M.spectrogram(y, from: 0, to: y.count))), 3)
    }

    func testFluxSpikesSeeABurst() {
        var x = tone(440, count: 48_000)
        let clean = try! XCTUnwrap(M.fluxSpikes(M.spectrogram(x, from: 0, to: x.count)))
        for i in 24_000..<24_064 { x[i] += Float(i % 2 == 0 ? 0.5 : -0.5) }
        let burst = try! XCTUnwrap(M.fluxSpikes(M.spectrogram(x, from: 0, to: x.count)))
        XCTAssertGreaterThan(burst.ratio, clean.ratio * 3)
    }

    func testModulationDeviationSeesTremolo() {
        let steady = tone(440, count: 96_000)
        var trem = steady
        for i in 0..<trem.count { trem[i] *= Float(1 + 0.5 * sin(2 * .pi * 8 * Double(i) / sr)) }
        let a = M.modulationSpectrum(steady, from: 0, to: steady.count, sampleRate: sr)
        let b = M.modulationSpectrum(trem, from: 0, to: trem.count, sampleRate: sr)
        XCTAssertEqual(try XCTUnwrap(M.modulationDeviation(a, a)), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(M.modulationDeviation(a, b)), 3)
    }

    // MARK: - Harness plumbing

    func testNaiveResampleRunsThroughTheHarness() throws {
        let source = BakeoffSource(name: "probe_sweep", letter: nil, kind: .voicedPhoneme, sampleRate: sr,
                                   samples: BakeoffSynthetic.sweepProbe(sampleRate: sr), voicedFraction: 1,
                                   isProbe: true)
        let scenario = BakeoffScenario(name: "rate_1.5", family: .fixedRate(1.5), duration: 3,
                                       events: [.init(time: 0, kind: .rate(1.5)),
                                                .init(time: 0.05, kind: .gate(true))])
        let r = BakeoffRunner.render(NaiveResampleRenderer.self, source: source, scenario: scenario)
        let gate = BakeoffRunner.appliedFrame(0.05, sampleRate: sr)
        XCTAssertEqual(M.rms(r.samples, 0, gate), 0, "nothing before the gate opens")
        let ref = BakeoffRunner.sourceReference(source: source, scenario: scenario)
        let rows = BakeoffRunner.metrics(candidate: "NaiveResample", render: r, source: source, scenario: scenario,
                                         sourceRef: ref, reference: nil)
        XCTAssertEqual(try XCTUnwrap(rows.first { $0.metric == "duration_scale" }).value, 1.5, accuracy: 0.03)
        let onset = try XCTUnwrap(rows.first { $0.metric == "onset_m20_ms" }).value
        XCTAssertLessThan(onset, 6, "naive varispeed: -20 dB within the 2 ms ramp + one 5 ms window")
    }

    func testRegisteredCandidateNamesAreUnique() {
        let names = BakeoffCandidates.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.contains("ours"), "the shipped engine (the baseline column) must stay registered")
        XCTAssertTrue(names.contains("NaiveResample"), "the listening anchor must stay registered")
    }
}
