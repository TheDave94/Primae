// PitchMetricSelfTests.swift
// PrimaeNativeTests — pitch bake-off harness (BENCH-P 2026-11-23; r31 gate-method & control tests, lane BENCH-R31)
//
// BAKEOFF-PITCH.md section 4.4 + lane BENCH-R31: every metric and gate is checked against known synthetic signals AND
// against the real study phonemes at 48 kHz (the iPad output rate), and every changed gate is checked against the
// controls (`ours` r28, `TDPSOLA2-g0.3`, `NaiveResample`) to prove they still FAIL where they should.
//
// XCTest, not Swift Testing: serial, and `-only-testing:PrimaeNativeTests/PitchMetricSelfTests` round-trips.

import XCTest
@testable import PrimaeNative

final class PitchMetricSelfTests: XCTestCase {
    typealias P = PitchMetrics
    let sr = BakeoffSources.pitchSampleRate
    static let pf600 = pow(2.0, 600.0 / 1200)

    func vowel(f0: Double, seconds: Double = 2.5, jitter: Double = 0, shimmer: Double = 0) -> [Float] {
        BakeoffSynthetic.vowel(seconds: seconds, sampleRate: sr, f0At: { _ in f0 }, jitter: jitter, shimmer: shimmer).x
    }

    func region(_ x: [Float]) -> ArraySlice<Float> { x[Int(0.6 * sr)..<Int(2.4 * sr)] }

    /// A synthetic "source" handed to the runner (letter A, so the matched-rate Praat LSD reference applies too).
    func syntheticSource(_ x: [Float]) -> BakeoffSource {
        BakeoffSource(name: "synthetic", letter: "A", kind: .voicedPhoneme, sampleRate: sr, samples: x, voicedFraction: 1)
    }

    func render(_ x: [Float]) -> BakeoffRender { BakeoffRender(samples: x, cpuNanos: [], claimedLatencyFrames: 0) }

    func gates(_ out: PitchRunner.Output, _ name: String) -> [PitchGates.Result] {
        out.gates.map(\.result).filter { $0.gate == name }
    }

    // MARK: - Envelope: own-F0 warp alpha, continuous refinement, no-zero-pad LTAS, matched-rate LSD

    func testWarpReadsOneForAnEnvelopePreservingShiftAndPfForAResampledCopy() {
        let src = vowel(f0: 200)
        let e0 = P.envelopeDB(region(src), sampleRate: sr, f0max: 200)
        let held = vowel(f0: 200 * Self.pf600)
        let eh = P.envelopeDB(region(held), sampleRate: sr, f0max: 200 * Self.pf600)
        let held1 = P.envelopeCompare(f: e0.f, source: e0.e, output: eh.e)
        XCTAssertEqual(held1.warp, 1, accuracy: 0.03, "an envelope-preserving +600 shift must read alpha ~ 1")
        XCTAssertTrue(PitchGates.warp(alpha: held1.warp, pitchFactor: Self.pf600).pass)
        for c in [-600.0, 600] {
            let pf = pow(2, c / 1200)
            let rs = BakeoffSynthetic.resample(vowel(f0: 200, seconds: 4), factor: pf)
            let er = P.envelopeDB(region(rs), sampleRate: sr, f0max: 200 * pf)
            let cmp = P.envelopeCompare(f: e0.f, source: e0.e, output: er.e)
            XCTAssertEqual(cmp.warp, pf, accuracy: 0.03, "a resampled copy at \(c) c must read alpha ~ pf")
            XCTAssertFalse(PitchGates.warp(alpha: cmp.warp, pitchFactor: pf).pass, "the envelope gate must flag it")
            XCTAssertTrue(PitchGates.warp(alpha: cmp.warp, pitchFactor: pf, gamma: 1).pass,
                          "with gamma = 1 (full co-shift) the resample is the target")
            XCTAssertGreaterThan(cmp.lsd, 3 * held1.lsd, "LSD at alpha 1 must see the moved formants")
        }
    }

    @MainActor
    func testOwnF0WarpIsScaleCovariantOnRealStudyPhonemesAndContinuous() throws {
        // Real varispeed y(t) = x(pf * t) has true warp == pf identically. Fixed 360 Hz order failed +-0.03 on L +600
        // (+0.047) and A +600 (+0.030); own-F0 order recovers pf within 0.01 for every voiced study phoneme.
        let pf = Self.pf600
        for src in try BakeoffSources.pitchSources(letters: ["A", "I", "L"]) {
            let ref = PitchSourceRef(src)
            let f0 = try XCTUnwrap(ref.f0)
            let tiled = Array(ref.steady) + Array(ref.steady)
            let rs = BakeoffSynthetic.resample(tiled, factor: pf)
            let er = P.envelopeDB(rs[0..<min(rs.count, ref.steady.count)], sampleRate: src.sampleRate, f0max: f0 * pf)
            let cmp = P.envelopeCompare(f: ref.ownF0Envelope.f, source: ref.ownF0Envelope.e, output: er.e)
            XCTAssertEqual(cmp.warp, pf, accuracy: 0.015, "\(src.name) varispeed +600: alpha \(cmp.warp) vs \(pf)")
            XCTAssertFalse(PitchGates.warp(alpha: cmp.warp, pitchFactor: pf).pass)
        }
        // Continuous refinement must recover a non-grid warp (not quantised to multiples of 0.005).
        let base = vowel(f0: 200, seconds: 3.5)
        let e0 = P.envelopeDB(region(base), sampleRate: sr, f0max: 200)
        let targetWarp = 1.033
        let warped = BakeoffSynthetic.resample(base, factor: targetWarp)
        let ew = P.envelopeDB(region(warped), sampleRate: sr, f0max: 200 * targetWarp)
        let cmp = P.envelopeCompare(f: e0.f, source: e0.e, output: ew.e)
        XCTAssertEqual(cmp.warp, targetWarp, accuracy: 0.002, "continuous warp \(cmp.warp) vs \(targetWarp)")
        let distToGrid = abs(cmp.warp - (cmp.warp * 200).rounded() / 200)
        XCTAssertGreaterThan(distToGrid, 0.0005, "warp \(cmp.warp) must not be quantised to the 0.005 grid")
    }

    func testLTASWithoutZeroPaddingIsStartPhaseInvariant() {
        // Sliding a 1.8 s window across a periodic vowel must not move the envelope (boundary='zeros' leaked +-0.2 dB).
        let x = vowel(f0: 215, seconds: 3.0)
        let ref = P.envelopeDB(x[Int(0.3 * sr)..<Int(2.1 * sr)], sampleRate: sr)
        var maxLSD = 0.0
        for shift in [0, 37, 79, 121, 163] {
            let lo = Int(0.3 * sr) + shift
            let e = P.envelopeDB(x[lo..<(lo + Int(1.8 * sr))], sampleRate: sr)
            maxLSD = max(maxLSD, P.envelopeCompare(f: ref.f, source: ref.e, output: e.e, refine: false).lsd)
        }
        XCTAssertLessThan(maxLSD, 0.02, "interior-Hann LTAS must be start-phase invariant (maxLSD \(maxLSD) dB)")
    }

    @MainActor
    func testEnvelopeMetricsOnTheStudyPhonemesThroughOursAndTheAnchor() throws {
        // At 48 kHz: ours A +600 passes per-cell ceiling (~1.05x) while NaiveResample fails (~7x) and ours A -600 fails (~1.88x).
        let src = try XCTUnwrap(BakeoffSources.pitchSources(letters: ["A"]).first)
        let ref = PitchSourceRef(src)
        let sc600 = PitchScenarios.held(cents: 600, rate: 1, loopSeconds: src.loopSeconds)
        for (candidate, expectWarp) in [(BakeoffCandidate.ours, 1.0), (BakeoffCandidate.naive, Self.pf600)] {
            let r = BakeoffRunner.render(candidate, source: src, scenario: sc600)
            let out = PitchRunner.rows(candidate: candidate.name, render: r, ref: ref, scenario: sc600)
            let warp = try XCTUnwrap(out.rows.first { $0.metric == "env_warp" }).value
            XCTAssertEqual(warp, expectWarp, accuracy: 0.05, "\(candidate.name) A +600: alpha")
            let lsdGate = try XCTUnwrap(gates(out, "env_lsd_vs_praat").first)
            XCTAssertEqual(lsdGate.pass, candidate.name == "ours", "\(candidate.name): LSD gate vs Praat (\(lsdGate.value))")
        }
        // Unshifted 0 c must NOT emit an env_lsd_vs_praat gate (offline Praat 0 c is unlooped identity), while still logging env_lsd_db.
        let sc0 = PitchScenarios.held(cents: 0, rate: 1, loopSeconds: src.loopSeconds)
        let r0 = BakeoffRunner.render(.r31, source: src, scenario: sc0)
        let out0 = PitchRunner.rows(candidate: "r31", render: r0, ref: ref, scenario: sc0)
        XCTAssertNotNil(out0.rows.first { $0.metric == "env_lsd_db" })
        XCTAssertTrue(gates(out0, "env_lsd_vs_praat").isEmpty, "0 c must not be gated against offline Praat identity")
    }

    func testFramewiseLSDSeesFrameLevelFormantDrift() throws {
        let src = vowel(f0: 200)
        let same = try XCTUnwrap(P.framewiseEnvelopeLSD(source: region(src), output: region(vowel(f0: 200 * Self.pf600)),
                                                        sampleRate: sr))
        let moved = try XCTUnwrap(P.framewiseEnvelopeLSD(
            source: region(src), output: region(BakeoffSynthetic.resample(vowel(f0: 200, seconds: 4), factor: Self.pf600)),
            sampleRate: sr))
        XCTAssertLessThan(same, 2.5, "envelope held: frame-wise LSD small")
        XCTAssertGreaterThan(moved, 2 * same, "envelope moved: frame-wise LSD must grow")
    }

    // MARK: - F0 (including shifted re 0 c render * pf)

    func testF0GateFailsOnATwentyCentDetunedRender() throws {
        let srcRef = PitchSourceRef(syntheticSource(vowel(f0: 200)))
        let sc0 = PitchScenarios.held(cents: 0, rate: 1)
        let scenario = PitchScenarios.held(cents: 300, rate: 1)
        // A renderer with a small -3 c loop offset at 0 c (like A) still passes 0 c and shifted +300 c when it shifts accurately.
        let zeroOffset = vowel(f0: 200 * pow(2, -3.0 / 1200))
        let zOut = PitchRunner.rows(candidate: "t", render: render(zeroOffset), ref: srcRef, scenario: sc0)
        XCTAssertTrue(try XCTUnwrap(gates(zOut, "f0_within_5c").first).pass, "-3 c at 0 c passes")
        let ok = vowel(f0: 200 * pow(2, 297.0 / 1200))
        let detuned = vowel(f0: 200 * pow(2, 317.0 / 1200))
        let good = PitchRunner.rows(candidate: "t", render: render(ok), ref: srcRef, scenario: scenario)
        let bad = PitchRunner.rows(candidate: "t", render: render(detuned), ref: srcRef, scenario: scenario)
        let eGood = try XCTUnwrap(good.rows.first { $0.metric == "f0_err_c" }).value
        let eBad = try XCTUnwrap(bad.rows.first { $0.metric == "f0_err_c" }).value
        XCTAssertEqual(eGood, 0, accuracy: 1, "exact +300 shift from 0 c render reads ~0 c")
        XCTAssertEqual(eBad, 20, accuracy: 1.5, "a 20-cent detune reads ~20 c")
        XCTAssertTrue(try XCTUnwrap(gates(good, "f0_within_5c").first).pass)
        XCTAssertFalse(try XCTUnwrap(gates(bad, "f0_within_5c").first).pass, "the F0 gate must fail a 20-cent detune")
        // A 20-cent detune at 0 c itself must also fail against the source F0.
        let badZero = PitchRunner.rows(candidate: "t2", render: render(vowel(f0: 200 * pow(2, 20.0 / 1200))),
                                       ref: srcRef, scenario: sc0)
        XCTAssertFalse(try XCTUnwrap(gates(badZero, "f0_within_5c").first).pass, "20 c off at 0 c must fail")
    }

    // MARK: - Level vs cents

    func testLevelGateFailsOnALevelSteppedRender() throws {
        let src = vowel(f0: 200)
        let ref = PitchSourceRef(syntheticSource(src))
        _ = PitchRunner.rows(candidate: "t", render: render(src), ref: ref, scenario: PitchScenarios.held(cents: 0, rate: 1))
        let raw = vowel(f0: 200 * Self.pf600)
        let match = Float(pow(10, (P.rmsDB(region(src)) - P.rmsDB(region(raw))) / 20))
        let up = raw.map { $0 * match }
        let flat = PitchRunner.rows(candidate: "t", render: render(up), ref: ref, scenario: PitchScenarios.held(cents: 600, rate: 1))
        let stepped = PitchRunner.rows(candidate: "t", render: render(up.map { $0 * Float(pow(10, 2.0 / 20)) }), ref: ref,
                                       scenario: PitchScenarios.held(cents: 600, rate: 1))
        let dFlat = try XCTUnwrap(flat.rows.first { $0.metric == "level_re_0c_db" }).value
        let dStep = try XCTUnwrap(stepped.rows.first { $0.metric == "level_re_0c_db" }).value
        XCTAssertEqual(dFlat, 0, accuracy: 0.05, "a level-matched render reads ~0 dB")
        XCTAssertEqual(dStep - dFlat, 2, accuracy: 0.01, "a +2 dB step reads +2 dB")
        XCTAssertTrue(try XCTUnwrap(gates(flat, "level_flat").first).pass)
        XCTAssertFalse(try XCTUnwrap(gates(stepped, "level_flat").first).pass, "the flatness gate must fail a level step")
    }

    // MARK: - Jitter / shimmer

    func testPerturbationRecoversAKnownJitterAndShimmer() throws {
        let g = BakeoffSynthetic.vowel(seconds: 2.5, sampleRate: sr, f0At: { _ in 210 }, jitter: 0.01, shimmer: 0.05)
        let p = try XCTUnwrap(P.perturbation(region(g.x), sampleRate: sr))
        let trueJ = BakeoffSynthetic.localPerturbation(g.periods)
        let trueS = BakeoffSynthetic.localPerturbation(g.amps)
        XCTAssertEqual(p.jitterPct, trueJ, accuracy: 0.25 * trueJ, "jitter: measured \(p.jitterPct) % vs generated \(trueJ) %")
        XCTAssertEqual(p.shimmerPct, trueS, accuracy: 0.45 * trueS, "shimmer: measured \(p.shimmerPct) % vs generated \(trueS) %")
        let clean = try XCTUnwrap(P.perturbation(region(vowel(f0: 210)), sampleRate: sr))
        XCTAssertLessThan(clean.jitterPct, 0.1 * trueJ, "a strictly periodic vowel reads ~0 jitter")
        XCTAssertLessThan(clean.shimmerPct, 0.1 * trueS, "and ~0 shimmer")
    }

    /// Generated local jitter / shimmer (percent) over the cycles that lie inside `region` (0.6 ... 2.4 s).
    func regionTruth(_ g: (x: [Float], periods: [Double], amps: [Double]), sampleRate: Double) -> (j: Double, s: Double) {
        var t = 0.01, ps: [Double] = [], ams: [Double] = []
        for (i, p) in g.periods.enumerated() {
            if t >= 0.6 && t + p < 2.4 { ps.append(p); ams.append(g.amps[i]) }
            t += p
        }
        return (BakeoffSynthetic.localPerturbation(ps), BakeoffSynthetic.localPerturbation(ams))
    }

    /// JITTER-EST: on a band-limited pulse train (periods unambiguous) the cycle-anchored estimator reads the
    /// generated local jitter within 5 % at every f0 of the bench's range, every jitter level and both output rates
    /// (measured 0.99 ... 1.01x). The unanchored estimator it replaced read 0.60 ... 3.79x or nothing at all on the same
    /// signals. Shimmer (BENCHWIN3, one-period RMS amplitude): measured 0.98 ... 1.12x (the per-cycle peak read
    /// 1.08 ... 1.20x); the generator's pulses are not energy-normalised, so part of the spread is the sampled energy of
    /// a windowed sinc moving with its fractional position.
    func testCycleAnchoredPerturbationMatchesTruthOnAPulseTrainAcrossTheF0Range() throws {
        for rate in [48_000.0, 44_100.0] {
            for f0 in [100.0, 150, 200, 250, 300, 400] {
                for jitter in [0.0025, 0.005, 0.01] {
                    let g = BakeoffSynthetic.vowel(seconds: 2.5, sampleRate: rate, f0At: { _ in f0 }, jitter: jitter,
                                                   shimmer: 0.05, formants: false)
                    let truth = regionTruth(g, sampleRate: rate)
                    let p = try XCTUnwrap(P.perturbation(g.x[Int(0.6 * rate)..<Int(2.4 * rate)], sampleRate: rate),
                                          "\(rate) Hz, f0 \(f0), jitter \(jitter): no reading")
                    let label = "\(Int(rate)) Hz, f0 \(f0) Hz, jitter \(jitter)"
                    XCTAssertEqual(p.jitterPct / truth.j, 1, accuracy: 0.05,
                                   "\(label): jitter \(p.jitterPct) % vs generated \(truth.j) %")
                    XCTAssertEqual(p.shimmerPct / truth.s, 1.05, accuracy: 0.08,
                                   "\(label): shimmer \(p.shimmerPct) % vs generated \(truth.s) %")
                }
            }
        }
    }

    /// JITTER-EST: on the formant vowel, at the f0s and jitter levels the gate tests use (150 ... 210 Hz, 0.25 ... 1 %),
    /// the cycle-anchored estimator reads 0.88 ... 1.05x truth (measured 0.91 ... 0.99x at both rates); the unanchored
    /// one read 0.75 ... 0.89x. Above 250 Hz the formant ringing of one cycle overlaps the next pulse and every
    /// waveform-based reading falls below truth (ours 0.50 ... 0.98x, Praat's cc 0.41 ... 0.91x, JITTER-EST-REPORT.md),
    /// so the bound is pinned only where the signal carries the answer; there it must stay closer to truth than the
    /// old method.
    func testCycleAnchoredPerturbationOnTheFormantVowel() throws {
        for rate in [48_000.0, 44_100.0] {
            for f0 in [150.0, 200, 210] {
                for jitter in [0.0025, 0.005, 0.01] {
                    let g = BakeoffSynthetic.vowel(seconds: 2.5, sampleRate: rate, f0At: { _ in f0 }, jitter: jitter,
                                                   shimmer: 0.05)
                    let truth = regionTruth(g, sampleRate: rate)
                    let seg = g.x[Int(0.6 * rate)..<Int(2.4 * rate)]
                    let label = "\(Int(rate)) Hz, f0 \(f0) Hz, jitter \(jitter)"
                    let p = try XCTUnwrap(P.perturbation(seg, sampleRate: rate), "\(label): no reading")
                    XCTAssertEqual(p.jitterPct / truth.j, 0.965, accuracy: 0.085,
                                   "\(label): jitter \(p.jitterPct) % vs generated \(truth.j) %")
                    XCTAssertEqual(p.shimmerPct / truth.s, 1.05, accuracy: 0.25,
                                   "\(label): shimmer \(p.shimmerPct) % vs generated \(truth.s) %")
                    if let old = P.perturbationUnanchored(seg, sampleRate: rate) {
                        XCTAssertLessThanOrEqual(abs(p.jitterPct / truth.j - 1), abs(old.jitterPct / truth.j - 1) + 0.02,
                                                 "\(label): the anchored reading must not be further from truth")
                    }
                }
            }
        }
    }

    /// JITTER-EST: the jitter gate compares a shifted render with its source, so the estimator's read/true factor
    /// must not move with f0. A pulse train with the SAME generated jitter at f0 and at f0 * 2^(-300/1200) and
    /// 2^(+600/1200) must read the same ratio to truth within 6 % (the old estimator: 0.78 ... 3.56x across f0).
    func testCycleAnchoredJitterFactorDoesNotMoveWithF0() throws {
        for base in [150.0, 210, 280] {
            var factors: [Double] = []
            for c in [0.0, -300, 600] {
                let f0 = base * pow(2, c / 1200)
                let g = BakeoffSynthetic.vowel(seconds: 2.5, sampleRate: sr, f0At: { _ in f0 }, jitter: 0.004,
                                               shimmer: 0.05, seed: 4242, formants: false)
                let p = try XCTUnwrap(P.perturbation(region(g.x), sampleRate: sr))
                factors.append(p.jitterPct / regionTruth(g, sampleRate: sr).j)
            }
            XCTAssertLessThan(factors.max()! / factors.min()!, 1.06, "base \(base) Hz: read/true factors \(factors)")
        }
    }

    /// BENCHWIN2: a cycle with TWO peaks of similar height. The recorded study phonemes have them (measured: the
    /// JITTER-EST marks on A hopped between two peaks ~0.3 ms apart, periods 3.97 / 4.63 / 3.98 ms where Praat's cc
    /// points read 4.26 ... 4.35 ms, so A read 3.8x Praat's jitter and M 11.5x). Each cycle here is a band-limited
    /// pulse at the generated time plus a second one 0.35 ms later whose height varies independently (+-10 %), so the
    /// larger of the two alternates at random from cycle to cycle. The periods are still the generated ones: the
    /// estimator must read the generated local jitter within 10 % at every f0 and both rates; a mark on the larger
    /// extremum reads several times more.
    func testJitterIsReadOnTheCycleNotOnTheLargerOfTwoSimilarPeaks() throws {
        for rate in [48_000.0, 44_100.0] {
            for f0 in [120.0, 200, 300] {
                for jitter in [0.0025, 0.005] {
                    let g = BakeoffSynthetic.vowel(seconds: 2.5, sampleRate: rate, f0At: { _ in f0 }, jitter: jitter,
                                                   shimmer: 0.02, seed: 99, formants: false)
                    var y = [Double](repeating: 0, count: g.x.count)
                    var state: UInt32 = 4242
                    func uniform() -> Double {
                        state = state &* 1_664_525 &+ 1_013_904_223
                        return Double(state) / 4_294_967_296
                    }
                    func pulse(at pos: Double, _ a: Double) {
                        let c = Int(pos.rounded(.down))
                        for k in -7...8 where c + k >= 0 && c + k < y.count {
                            let d = Double(c + k) - pos
                            let w = 0.5 + 0.5 * cos(.pi * d / 8.5)
                            y[c + k] += a * (abs(d) < 1e-12 ? 1 : sin(.pi * d) / (.pi * d)) * w
                        }
                    }
                    var t = 0.01
                    for (i, p) in g.periods.enumerated() {
                        pulse(at: t * rate, g.amps[i])
                        pulse(at: (t + 0.00035) * rate, g.amps[i] * (0.9 + 0.2 * uniform()))
                        t += p
                    }
                    let x = y.map { Float(0.4 * $0) }
                    let truth = regionTruth(g, sampleRate: rate)
                    let label = "\(Int(rate)) Hz, f0 \(f0) Hz, jitter \(jitter)"
                    let p = try XCTUnwrap(P.perturbation(x[Int(0.6 * rate)..<Int(2.4 * rate)], sampleRate: rate),
                                          "\(label): no reading")
                    XCTAssertEqual(p.jitterPct / truth.j, 1, accuracy: 0.10,
                                   "\(label): jitter \(p.jitterPct) % vs generated \(truth.j) %")
                }
            }
        }
    }

    /// BENCHWIN3: shimmer is a change of the cycle's AMPLITUDE, not of its waveform shape. Each cycle here is two
    /// unit-energy band-limited pulses, 0.35 ms apart or 0.4 T apart (energy spread over the cycle), with heights g cos(theta) and g sin(theta): the cycle's energy is g^2 for every
    /// theta, but theta varies at random (pi/4 +- 0.15 rad), so the larger of the two peaks changes from cycle to cycle at
    /// constant energy. The recorded study phonemes carry such shape variation (measured, per-period peak / RMS on
    /// Praat's cc points: I 2.25 %, L 2.48 %, A 6.92 % local variation; Praat's local shimmer of I is 0.84 %). The
    /// estimator must read the generated gain shimmer within 15 % at every f0, spacing and both rates; a per-cycle PEAK
    /// amplitude (the estimator before BENCHWIN3) reads the shape variation as shimmer, several times the truth, and a
    /// window shorter than the period (Praat's Hann +-0.2 T, or +-T/4) misses or down-weights the second pulse.
    func testShimmerIsReadOnTheCycleEnergyNotOnItsWaveformShape() throws {
        for (rate, spread) in [(48_000.0, false), (48_000.0, true), (44_100.0, false), (44_100.0, true)] {
            for f0 in [120.0, 200, 300] {
                let g = BakeoffSynthetic.vowel(seconds: 2.5, sampleRate: rate, f0At: { _ in f0 }, jitter: 0.003,
                                               shimmer: 0.02, seed: 77, formants: false)
                var y = [Double](repeating: 0, count: g.x.count)
                var state: UInt32 = 2024
                func uniform() -> Double {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    return Double(state) / 4_294_967_296
                }
                // Unit-ENERGY band-limited pulse: the sampled energy of a windowed sinc varies by ~10 % with its
                // fractional position, which would itself be a cycle-energy change the generator did not ask for.
                func pulse(at pos: Double, _ a: Double) {
                    let c = Int(pos.rounded(.down))
                    var v: [(Int, Double)] = [], e = 0.0
                    for k in -7...8 where c + k >= 0 && c + k < y.count {
                        let d = Double(c + k) - pos
                        let w = 0.5 + 0.5 * cos(.pi * d / 8.5)
                        let s = (abs(d) < 1e-12 ? 1 : sin(.pi * d) / (.pi * d)) * w
                        v.append((c + k, s)); e += s * s
                    }
                    for (i, s) in v { y[i] += a * s / e.squareRoot() }
                }
                var t = 0.01
                for (i, p) in g.periods.enumerated() {
                    let theta = Double.pi / 4 + 0.3 * (uniform() - 0.5)
                    pulse(at: t * rate, g.amps[i] * cos(theta))
                    pulse(at: (t + (spread ? 0.4 * p : 0.00035)) * rate, g.amps[i] * sin(theta))
                    t += p
                }
                let x = y.map { Float(0.4 * $0) }
                let truth = regionTruth(g, sampleRate: rate)
                let label = "\(Int(rate)) Hz, f0 \(f0) Hz, second pulse \(spread ? "0.4 T" : "0.35 ms") later"
                let p = try XCTUnwrap(P.perturbation(x[Int(0.6 * rate)..<Int(2.4 * rate)], sampleRate: rate),
                                      "\(label): no reading")
                XCTAssertEqual(p.shimmerPct / truth.s, 1, accuracy: 0.15,
                               "\(label): shimmer \(p.shimmerPct) % vs generated \(truth.s) %")
            }
        }
    }

    func testMicroVariationGateFailsWhenJitterAndShimmerAreHalved() throws {
        let src = BakeoffSynthetic.vowel(seconds: 2.5, sampleRate: sr, f0At: { _ in 200 }, jitter: 0.01, shimmer: 0.06).x
        let ref = PitchSourceRef(syntheticSource(src))
        let same = BakeoffSynthetic.vowel(seconds: 2.5, sampleRate: sr, f0At: { _ in 200 },
                                          jitter: 0.01, shimmer: 0.06, seed: 4242).x
        let halved = BakeoffSynthetic.vowel(seconds: 2.5, sampleRate: sr, f0At: { _ in 200 },
                                            jitter: 0.004, shimmer: 0.02, seed: 4242).x
        let sc = PitchScenarios.held(cents: 0, rate: 1)
        let a = PitchRunner.rows(candidate: "t", render: render(same), ref: ref, scenario: sc)
        let b = PitchRunner.rows(candidate: "t", render: render(halved), ref: ref, scenario: sc)
        XCTAssertTrue(try XCTUnwrap(gates(a, "jitter_ratio").first).pass, "same micro-variation passes (jitter)")
        XCTAssertTrue(try XCTUnwrap(gates(a, "shimmer_ratio").first).pass, "same micro-variation passes (shimmer)")
        XCTAssertFalse(try XCTUnwrap(gates(b, "jitter_ratio").first).pass, "WORLD-like regularity must fail (jitter)")
        XCTAssertFalse(try XCTUnwrap(gates(b, "shimmer_ratio").first).pass, "WORLD-like regularity must fail (shimmer)")
    }

    // MARK: - F (unvoiced)

    func testFMetricsSeeGrainRateBuzzAndAComb() {
        let hop = P.unvoicedHop(sampleRate: sr)
        XCTAssertEqual(hop, 240, "5 ms hop at 48 kHz")
        XCTAssertEqual(P.unvoicedHop(sampleRate: 44_100), 221, "5 ms hop at 44.1 kHz")
        let noise = BakeoffSynthetic.noise(Int(2.1 * sr))
        let wClean = P.grainRateWobble(noise[...], period: hop)
        var am = noise
        for i in am.indices { am[i] *= Float(1 + 0.3 * sin(2 * .pi * Double(i) / Double(hop))) }
        let wAM = P.grainRateWobble(am[...], period: hop)
        XCTAssertTrue(PitchGates.fWobble(wClean).pass, "white noise: wobble \(wClean) dB")
        XCTAssertFalse(PitchGates.fWobble(wAM).pass, "200 Hz AM noise must fail (wobble \(wAM) dB)")
        let lag = P.combLag(hop: hop, pitchFactor: Self.pf600)
        let rClean = P.acf(noise[...], lag: lag)
        var comb = noise
        let l = Int(lag.rounded())
        for i in l..<comb.count { comb[i] = noise[i] + 0.6 * noise[i - l] }
        let rComb = P.acf(comb[...], lag: Double(l))
        XCTAssertTrue(PitchGates.fComb(rClean).pass, "white noise: ACF \(rClean)")
        XCTAssertFalse(PitchGates.fComb(rComb).pass, "a comb at the lag must fail (ACF \(rComb))")
    }

    // MARK: - Clicks

    func testSweepClickRatioSeesAnInsertedDiscontinuity() throws {
        let glide = BakeoffSynthetic.vowel(seconds: 3, sampleRate: sr, f0At: { t in 200 * pow(2, Double(PitchScenarios.sweepCents(t)) / 1200) }).x
        let clean = try XCTUnwrap(P.localClickRatio(glide, from: Int(0.05 * sr), to: Int(2.95 * sr), sampleRate: sr))
        var clicked = glide
        for i in Int(1.3 * sr)..<clicked.count { clicked[i] += 0.25 }
        let bad = try XCTUnwrap(P.localClickRatio(clicked, from: Int(0.05 * sr), to: Int(2.95 * sr), sampleRate: sr))
        XCTAssertTrue(PitchGates.clicks("sweep_click", ratio: clean).pass, "a clean glide: ratio \(clean)")
        XCTAssertFalse(PitchGates.clicks("sweep_click", ratio: bad).pass, "a step of 0.25 must fail (ratio \(bad))")
    }

    // MARK: - Pitch control lag & attack

    func testStepGateSeesALateStep() throws {
        let ref = PitchSourceRef(syntheticSource(vowel(f0: 200)))
        let scenario = PitchScenarios.step(from: 0, to: 600, rate: 1)
        let st = Double(BakeoffRunner.appliedFrame(PitchScenarios.stepTime, sampleRate: sr)) / sr
        func stepped(late: Double) -> [Float] {
            BakeoffSynthetic.vowel(seconds: scenario.duration, sampleRate: sr,
                                   f0At: { t in t < st + late ? 200 : 200 * Self.pf600 }).x
        }
        let prompt = PitchRunner.rows(candidate: "t", render: render(stepped(late: 0)), ref: ref, scenario: scenario)
        let late = PitchRunner.rows(candidate: "t", render: render(stepped(late: 0.03)), ref: ref, scenario: scenario)
        let d0 = try XCTUnwrap(prompt.rows.first { $0.metric == "pitch_step_delay90_ms" }).value
        let d1 = try XCTUnwrap(late.rows.first { $0.metric == "pitch_step_delay90_ms" }).value
        XCTAssertEqual(d1 - d0, 30, accuracy: 3, "a 30 ms late step reads 30 ms later")
        XCTAssertTrue(try XCTUnwrap(gates(prompt, "pitch_step_90").first).pass, "an instant step passes (\(d0) ms)")
        XCTAssertFalse(try XCTUnwrap(gates(late, "pitch_step_90").first).pass, "30 ms lag must fail (\(d1) ms)")
    }

    func testSweepLagGateSeesALaggingGlide() throws {
        let ref = PitchSourceRef(syntheticSource(vowel(f0: 200)))
        let scenario = PitchScenarios.sweep(rate: 1, sampleRate: sr)
        func glide(lag: Double) -> [Float] {
            BakeoffSynthetic.vowel(seconds: scenario.duration, sampleRate: sr, f0At: { t in
                200 * pow(2, Double(PitchScenarios.sweepCents(max(0, t - lag))) / 1200)
            }).x
        }
        let a = PitchRunner.rows(candidate: "t", render: render(glide(lag: 0)), ref: ref, scenario: scenario)
        let b = PitchRunner.rows(candidate: "t", render: render(glide(lag: 0.025)), ref: ref, scenario: scenario)
        let l0 = try XCTUnwrap(a.rows.first { $0.metric == "traj_pitch_lag_ms" }).value
        let l1 = try XCTUnwrap(b.rows.first { $0.metric == "traj_pitch_lag_ms" }).value
        XCTAssertEqual(l1 - l0, 25, accuracy: 5, "a 25 ms lagging glide reads ~25 ms more")
        XCTAssertTrue(try XCTUnwrap(gates(a, "traj_pitch_lag").first).pass, "no lag passes (\(l0) ms)")
        XCTAssertFalse(try XCTUnwrap(gates(b, "traj_pitch_lag").first).pass, "25 ms lag must fail (\(l1) ms)")
    }

    @MainActor
    func testAttackGateSeesAnUnshiftedAttackAndExceedingCausalBudget() throws {
        XCTAssertTrue(PitchGates.attack(rmsCents: 4.9).pass)
        XCTAssertFalse(PitchGates.attack(rmsCents: 5.1).pass)
        XCTAssertFalse(PitchGates.attack(rmsCents: nil).pass, "an unmeasured attack must not pass")
        let ref = PitchSourceRef(syntheticSource(vowel(f0: 200)))
        let scenario = PitchScenarios.heightTrajectory(letter: "A", strokes: try BakeoffSources.strokes(letter: "A"))
        guard case .trajectory(_, _, _, let commanded) = scenario.family else { return XCTFail("not a trajectory") }
        let opens = scenario.openIntervals.map { Double(BakeoffRunner.appliedFrame($0.open, sampleRate: sr)) / sr }
        func traced(unshiftedAttack: Bool) -> [Float] {
            BakeoffSynthetic.vowel(seconds: scenario.duration, sampleRate: sr, f0At: { t in
                if unshiftedAttack, let o = opens.last(where: { $0 <= t }), t - o < 0.05 { return 200 }
                return 200 * pow(2, BakeoffScenarios.commanded(commanded, at: t) / 1200)
            }).x
        }
        let good = PitchRunner.rows(candidate: "t", render: render(traced(unshiftedAttack: false)), ref: ref, scenario: scenario)
        let bad = PitchRunner.rows(candidate: "t", render: render(traced(unshiftedAttack: true)), ref: ref, scenario: scenario)
        let g = try XCTUnwrap(good.rows.first { $0.metric == "traj_attack_rms_cents" }).value
        let b = try XCTUnwrap(bad.rows.first { $0.metric == "traj_attack_rms_cents" }).value
        XCTAssertGreaterThan(b, 100, "an attack held at 0 c reads >= 100 c (\(b))")
        XCTAssertLessThan(g, b / 5, "the traced attack reads far less than unshifted (\(g) vs \(b))")
        XCTAssertFalse(try XCTUnwrap(gates(bad, "traj_attack").first).pass, "the attack gate must fail an unshifted attack")
        // A 5 ms causal lag passes the 10 ms budget; a 30 ms lag on a steep +400 c/s stroke fails.
        let steep = (0..<20).map { i -> (t: Double, v: Double) in
            let t = 0.05 + Double(i) * 0.0025
            return (t, 400.0 * (t - 0.005))
        }
        let okLag = try XCTUnwrap(P.causalAttackRMS(points: steep, commanded: { 400.0 * $0 }))
        XCTAssertLessThan(okLag.rms, 0.5, "5 ms lag inside 10 ms causal budget")
        let slow = steep.map { (t: $0.t, v: 400.0 * ($0.t - 0.030)) }
        let badLag = try XCTUnwrap(P.causalAttackRMS(points: slow, commanded: { 400.0 * $0 }))
        XCTAssertGreaterThan(badLag.rms, 5.0, "30 ms lag exceeds 10 ms causal budget (\(badLag.rms) c)")
        XCTAssertFalse(PitchGates.attack(rmsCents: badLag.rms).pass)
    }

    /// The cents track behind `pitch_step_90`, `traj_pitch_lag` and `traj_attack` analyses the same span in TIME at
    /// 48 kHz and 44.1 kHz: a 21.33 ms window (1024 frames at 48 kHz, 941 at 44.1 kHz), with each point stamped at the
    /// window's centre. A fixed 1024-frame window would be 23.22 ms at 44.1 kHz and stamp its centre 0.94 ms late.
    func testCentsTrackWindowIsDefinedInTimeAtBothRates() {
        XCTAssertEqual(P.yinWindow(sampleRate: 48_000), 1024, "48 kHz keeps the 1024-frame window (bit-identical)")
        XCTAssertEqual(P.yinWindow(sampleRate: 44_100), 941)
        for rate in [48_000.0, 44_100.0] {
            let x = BakeoffSynthetic.vowel(seconds: 1.0, sampleRate: rate, f0At: { _ in 200 }).x
            let from = Int(0.2 * rate)
            let track = P.centsTrack(x, from: from, to: x.count, ref: 200, sampleRate: rate, hopSeconds: 0.0025)
            let first = try? XCTUnwrap(track.first)
            XCTAssertNotNil(first)
            guard let first else { continue }
            let expected = Double(from) / rate + 0.5 * P.yinWindowSeconds
            XCTAssertEqual(first.t, expected, accuracy: 0.05e-3,
                           "@\(Int(rate)) Hz: first point stamped at the 21.33 ms window centre")
            XCTAssertEqual(first.v ?? .nan, 0, accuracy: 5, "@\(Int(rate)) Hz: a 200 Hz vowel reads 0 c re 200 Hz")
        }
    }

    /// Lane BENCHWIN (2026-11-28): the voiced held window spans a WHOLE NUMBER of the loops the renderer PLAYS. SEAM2
    /// shortens the analysis loop by its crossfade (A: 1.944 s -> 1.546 s), so a window sized from
    /// `analysis.loopEnd - analysis.loopStart` spans 1.257 played loops and counts part of the blend twice. The loop
    /// length comes from the production renderer's own bounds (`TDPSOLA2.playedLoop`), checked here against SEAM2's
    /// `TDPSOLA2.prepared` at the file rate, and the window is an integer number of played loops at every rate.
    @MainActor
    func testHeldWindowIsWholePlayedLoopsAtBothRates() throws {
        for rate in [48_000.0, 44_100.0] {
            let src = try XCTUnwrap(BakeoffSources.pitchSources(letters: ["A"], sampleRate: rate).first)
            let loop = try XCTUnwrap(src.loopSeconds, "@\(Int(rate)) Hz: A is voiced, so it has a loop")
            let prod = LiveSonificationAudio.makeRenderer(src.sonification)
            let played = (prod.playedLoop.end - prod.playedLoop.start) / rate
            let raw = (prod.analysis.loopEnd - prod.analysis.loopStart) / rate
            XCTAssertEqual(loop, played, accuracy: 1e-9, "@\(Int(rate)) Hz: loopSeconds is the PLAYED loop")
            XCTAssertEqual(raw - played, 0.4, accuracy: 0.02,
                           "@\(Int(rate)) Hz: SEAM2's 0.4 s crossfade shortens the played loop (\(raw) -> \(played) s)")
            if src.fileSource == nil {
                let prep = TDPSOLA2.prepared(src.samples, sampleRate: rate, analysis: prod.analysis, kind: src.kind,
                                             tuning: .default, outputGain: src.gain, seam: prod.options.seamBlend)
                XCTAssertEqual(prod.playedLoop.end, prep.loopEnd, "@\(Int(rate)) Hz: playedLoop is SEAM2's loop end")
                XCTAssertEqual(prod.playedLoop.start, prod.analysis.loopStart)
            }
            for r in PitchScenarios.rates {
                let w = PitchScenarios.heldAnalysisDuration(rate: r, loopSeconds: loop)
                let n = w / (played / Double(r))
                XCTAssertEqual(n, n.rounded(), accuracy: 1e-9, "@\(Int(rate)) Hz rate \(r): \(n) played loops")
                XCTAssertGreaterThanOrEqual(n.rounded(), 1)
                XCTAssertGreaterThanOrEqual(w, PitchScenarios.heldAnalysisMinSeconds - 1e-9)
                let sc = PitchScenarios.held(cents: 0, rate: r, loopSeconds: loop)
                XCTAssertGreaterThanOrEqual(sc.duration, PitchScenarios.heldRegion.from + w,
                                            "@\(Int(rate)) Hz rate \(r): the render holds the whole window")
            }
        }
    }

    // MARK: - Seed-spread derivation & median gating

    func testPerCellXorSeedsAreDistinctAndSpreadGatesOnMedian() throws {
        XCTAssertEqual(PitchRunner.cellSeedXor(source: "A_phoneme1", scenario: "pitch_+600@1", seedIndex: 0), 0)
        let aSeeds = (0..<8).map { PitchRunner.cellSeedXor(source: "A_phoneme1", scenario: "pitch_+600@1", seedIndex: $0) }
        let bSeeds = (0..<8).map { PitchRunner.cellSeedXor(source: "A_phoneme1", scenario: "pitch_-600@1", seedIndex: $0) }
        XCTAssertEqual(Set(aSeeds).count, 8, "all 8 seeds for one cell must be distinct")
        XCTAssertTrue(Set(aSeeds.dropFirst()).isDisjoint(with: Set(bSeeds.dropFirst())),
                      "different cells must derive distinct xor seeds")
        func makeOut(_ jitter: Double) -> PitchRunner.Output {
            PitchRunner.Output(
                rows: [BakeoffRow(candidate: "c", source: "A", kind: "voiced", sampleRate: 48_000, scenario: "s",
                                  metric: "jitter_ratio", value: jitter, unit: "x")],
                gates: [PitchGateRow(candidate: "c", source: "A", scenario: "s",
                                     result: PitchGates.microVariation("jitter_ratio", ratio: jitter))])
        }
        // 7 passing seeds + 1 tail outlier -> median passes, spread records 7/8.
        let passSpread = PitchRunner.aggregateSeedSpread([1.45, 1.50, 1.52, 1.54, 1.56, 1.58, 1.59, 1.63].map(makeOut))
        let gPass = try XCTUnwrap(passSpread.gates.first?.result)
        XCTAssertTrue(gPass.pass, "median 1.55 passes")
        XCTAssertEqual(gPass.value, 1.55, accuracy: 1e-9)
        XCTAssertEqual(gPass.spread?.passCount, 7)
        XCTAssertEqual(gPass.spread?.total, 8)
        // Majority failing -> median fails.
        let failSpread = PitchRunner.aggregateSeedSpread([1.55, 1.58, 1.61, 1.63, 1.65, 1.67, 1.70, 1.72].map(makeOut))
        let gFail = try XCTUnwrap(failSpread.gates.first?.result)
        XCTAssertFalse(gFail.pass, "median 1.64 must fail")
        XCTAssertEqual(gFail.spread?.passCount, 2)
    }

    // MARK: - Controls must keep failing every changed gate at 48 kHz

    @MainActor
    func testControlsStillFailEveryChangedGateAt48k() throws {
        let sources = try BakeoffSources.pitchSources(letters: ["A", "M"])
        let srcA = sources[0], srcM = sources[1]
        let refA = PitchSourceRef(srcA), refM = PitchSourceRef(srcM)

        // 1. `traj_attack`: r31 passes A & M; `ours` (r28 unshifted attack) FAILS both.
        for (src, ref, letter) in [(srcA, refA, "A"), (srcM, refM, "M")] {
            let traj = PitchScenarios.heightTrajectory(letter: letter, strokes: try BakeoffSources.strokes(letter: letter))
            let rProd = PitchRunner.rows(candidate: "r31", render: BakeoffRunner.render(.r31, source: src, scenario: traj),
                                         ref: ref, scenario: traj)
            let rOurs = PitchRunner.rows(candidate: "ours", render: BakeoffRunner.render(.ours, source: src, scenario: traj),
                                         ref: ref, scenario: traj)
            XCTAssertTrue(try XCTUnwrap(gates(rProd, "traj_attack").first).pass, "r31 \(letter) traj_attack passes")
            XCTAssertFalse(try XCTUnwrap(gates(rOurs, "traj_attack").first).pass, "ours \(letter) traj_attack must FAIL")
        }

        // 2. `env_warp` & `env_lsd_vs_praat` (per-cell <= 1.2x) & `env_lsd_letter_vs_praat` (per-letter mean <= 1.2x):
        //    - `ours` fails A -600 @1 per-cell (~1.88x > 1.2x) and A rate-1 mean (> 1.2x);
        //    - `TDPSOLA2-g0.3` fails `env_warp`, per-cell LSD, and per-letter mean LSD;
        //    - `NaiveResample` fails `env_warp`, per-cell LSD, per-letter mean LSD.
        let shiftedCents: [Float] = [-600, -300, 300, 600]
        func rateOneSummary(_ cand: BakeoffCandidate) throws -> (mean: Double, lsdByCents: [Int: Bool], warpAllPass: Bool) {
            var lsds: [Double] = []
            var lsdPass: [Int: Bool] = [:]
            var allWarpPass = true
            let sc0 = PitchScenarios.held(cents: 0, rate: 1, loopSeconds: srcA.loopSeconds)
            _ = PitchRunner.rows(candidate: cand.name, render: BakeoffRunner.render(cand, source: srcA, scenario: sc0),
                                 ref: refA, scenario: sc0)
            for c in shiftedCents {
                let sc = PitchScenarios.held(cents: c, rate: 1, loopSeconds: srcA.loopSeconds)
                let out = PitchRunner.rows(candidate: cand.name, render: BakeoffRunner.render(cand, source: srcA, scenario: sc),
                                           ref: refA, scenario: sc)
                lsds.append(try XCTUnwrap(out.rows.first { $0.metric == "env_lsd_db" }).value)
                lsdPass[Int(c)] = try XCTUnwrap(gates(out, "env_lsd_vs_praat").first).pass
                if !(try XCTUnwrap(gates(out, "env_warp").first).pass) { allWarpPass = false }
            }
            return (lsds.reduce(0, +) / Double(lsds.count), lsdPass, allWarpPass)
        }
        let mProd = try rateOneSummary(.r31)
        XCTAssertTrue(mProd.lsdByCents[600] == true && mProd.lsdByCents[300] == true && mProd.lsdByCents[-300] == true,
                      "r31 A +600/+300/-300 pass <= 1.2x")
        XCTAssertTrue(mProd.warpAllPass, "r31 A rate-1 warp passes")
        XCTAssertTrue(try XCTUnwrap(PitchGates.envelopeLetterMeanLSD(mProd.mean, letter: "A", sampleRate: sr)).pass,
                      "r31 A mean LSD passes <= 1.2x (\(mProd.mean))")

        let mOurs = try rateOneSummary(.ours)
        XCTAssertEqual(mOurs.lsdByCents[-600], false, "ours must FAIL per-cell LSD (1.2x) on A -600")
        XCTAssertFalse(try XCTUnwrap(PitchGates.envelopeLetterMeanLSD(mOurs.mean, letter: "A", sampleRate: sr)).pass,
                       "ours must FAIL per-letter mean LSD on A (\(mOurs.mean))")

        let mG03 = try rateOneSummary(.g03)
        XCTAssertFalse(mG03.warpAllPass, "g0.3 must FAIL env_warp")
        XCTAssertTrue(mG03.lsdByCents.values.allSatisfy { !$0 }, "g0.3 must FAIL every A per-cell LSD (1.2x)")
        XCTAssertFalse(try XCTUnwrap(PitchGates.envelopeLetterMeanLSD(mG03.mean, letter: "A", sampleRate: sr)).pass,
                       "g0.3 must FAIL per-letter mean LSD (\(mG03.mean))")

        let mNaive = try rateOneSummary(.naive)
        XCTAssertFalse(mNaive.warpAllPass, "NaiveResample must FAIL env_warp")
        XCTAssertTrue(mNaive.lsdByCents.values.allSatisfy { !$0 }, "NaiveResample must FAIL every A per-cell LSD (1.2x)")
        XCTAssertFalse(try XCTUnwrap(PitchGates.envelopeLetterMeanLSD(mNaive.mean, letter: "A", sampleRate: sr)).pass,
                       "NaiveResample must FAIL per-letter mean LSD (\(mNaive.mean))")
        // Rate-coupled varispeed must NOT hide behind its own 0-cent F0 at @0.5 or @2: shifted cells must fail f0_within_5c.
        let sc0r2 = PitchScenarios.held(cents: 0, rate: 2, loopSeconds: srcA.loopSeconds)
        let sc6r2 = PitchScenarios.held(cents: 600, rate: 2, loopSeconds: srcA.loopSeconds)
        let n0r2 = PitchRunner.rows(candidate: "NaiveResample", render: BakeoffRunner.render(.naive, source: srcA, scenario: sc0r2),
                                    ref: refA, scenario: sc0r2)
        let n6r2 = PitchRunner.rows(candidate: "NaiveResample", render: BakeoffRunner.render(.naive, source: srcA, scenario: sc6r2),
                                    ref: refA, scenario: sc6r2)
        XCTAssertFalse(try XCTUnwrap(gates(n0r2, "f0_within_5c").first).pass, "Naive @2 0 c must FAIL f0_within_5c")
        XCTAssertFalse(try XCTUnwrap(gates(n6r2, "f0_within_5c").first).pass, "Naive @2 +600 c must FAIL f0_within_5c")
    }

    // MARK: - Scenarios and export plumbing

    func testScenarioSetAndExportNames() throws {
        let s = try PitchScenarios.standard(letter: "A", sampleRate: sr, loopSeconds: 1.94)
        XCTAssertEqual(s.count, 3 * (5 + 3 + 1) + 2, "held x5, steps x3, sweep per rate; gate cycle; height trajectory")
        XCTAssertEqual(Set(s.map(\.name)).count, s.count, "scenario names unique")
        let names = s.compactMap { SonificationBakeoffBench.renderName(scenario: $0, letter: "A") }
        XCTAssertEqual(Set(names), ["A__0c.wav", "A__-600c.wav", "A__-300c.wav", "A__+300c.wav", "A__+600c.wav",
                                    "A__traj.wav", "A__height.wav"], "the names method/build_mushra.py reads")
        // At @0.5, a 1.94 s loop needs 1 full loop = 3.88 s -> open >= 0.6 + 3.88 + 0.15 = 4.63 s.
        let slow = try XCTUnwrap(s.first { $0.name == "pitch_+600@0.5" })
        XCTAssertGreaterThan(slow.duration, 4.9, "@0.5 held scenario must stay open for 1 full loop")
        XCTAssertEqual(PitchScenarios.sweepCents(0.75), 600, accuracy: 0.01)
        XCTAssertEqual(PitchScenarios.sweepCents(2.25), -600, accuracy: 0.01)
        XCTAssertEqual(PitchScenarios.sweepCents(1.5), 0, accuracy: 0.01)
        let traj = try XCTUnwrap(s.first { $0.name == "traj_A_height" })
        let cents = traj.events.compactMap { e -> Float? in if case .cents(let c) = e.kind { return c }; return nil }
        XCTAssertLessThanOrEqual(cents.max() ?? 0, 600)
        XCTAssertGreaterThanOrEqual(cents.min() ?? 0, -600)
        XCTAssertGreaterThan((cents.max() ?? 0) - (cents.min() ?? 0), 600, "A spans most of the letter height")
    }
}
