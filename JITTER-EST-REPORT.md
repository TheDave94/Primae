# JITTER-EST — cycle-anchored jitter/shimmer estimator (lane JITTER-EST, 2026-11-28)

Branch `t3/jitter-est`, base `25a01f71` (BENCH-R31 fix, unsigned). Offline only: no iPad, no device xcodebuild, no
signing, no push, no gate or threshold change. Every line is marked MEASURED, UNMEASURED or (for inferences) INFERENCE.

## Verdict

- MEASURED: **I -300@2 jitter_ratio now passes on 8/8 seeds at both rates** for r31 (48 kHz 1.595 PASS 5/8 -> 0.903 PASS 8/8;
  44.1 kHz 1.627 FAIL 3/8 -> 0.883 PASS 8/8), and for C3d+14-xf0.2 (1.531 6/8 -> 0.788 8/8; 1.604 FAIL 4/8 -> 0.764 8/8).
- MEASURED, **RED**: the new estimator moves r31's jitter RED set rather than emptying it. New jitter FAILs for r31:
  A -600@2 (0.555 at 48k, 0/8; 0.543 at 44.1k, 0/8), A -300@2 (0.590 at 48k, 3/8), L -600@2 (0.558 / 0.555, 0/8),
  L -600@0.5 (0.592 at 44.1k, 3/8); passing with failing seeds: I +600@2 1.553 6/8 (48k) / 1.527 6/8 (44.1k),
  L -300@2, M -600@2, A -600@0.5 / -600@1 (44.1k). The same -600 cells flip for C3d+14-xf0.2 and TDPSOLA2-g0.3.
- MEASURED, **RED (control)**: NaiveResample **stops failing jitter_ratio at 48 kHz** (18 FAIL cells -> 0) and nearly
  stops at 44.1 kHz (16 -> 1: I +600@2, 0.594). Per the brief, this is reported as a RED finding, not a pass.
  INFERENCE: a resampled copy scales every period by the same factor, so its relative local jitter equals the
  source's; the true ratio is 1.0, and the new readings are 0.97 ... 1.11. The old FAILs (1.66 ... 2.05) were the
  old estimator's f0-dependent bias. So the Naive jitter_ratio FAILs were never evidence about the control; whether
  jitter_ratio should be expected to fail Naive is a gate-design question for the supervisor.
- UNMEASURED: whether the new -600 c lows (0.54 ... 0.60) are real or an estimator effect on PSOLA output. Praat was
  not run on those renders (the harness does not dump renders, and disk was at the 3 GiB stop line). That
  cross-check is owed before these findings are trusted either way.

## (1) The estimator

`PitchMetrics.perturbation` (the gate path, unchanged name) is now a cycle-anchored point process
(`PrimaeNativeTests/SonificationBakeoff/PitchMetrics.swift`); the old method is kept as `perturbationUnanchored`
for the truth table only. Clean-room, from Boersma (1993, IFA Proceedings 17) and the public Praat manual pages
("Sound & Pitch: To PointProcess (cc)", "PointProcess: Get jitter (local)", "Voice 2. Jitter", "Voice 3. Shimmer",
"Sound & PointProcess: Get shimmer (local)"); no Praat source read. Method:
- polarity = sign of the larger absolute extremum; first mark = extremum within one period of the middle;
- each next mark: NCC of the cycle window `[m - T/4, m + 3T/4]` (anchored on the mark) at lags 0.8T ... 1.25T, then
  the waveform extremum within +-T/8 of that prediction, refined on a 48-tap Hann-windowed sinc interpolation
  (golden-section search); period = mark distance; amplitude = the refined extremum value;
- chains left and right; r < 0.5 breaks a chain; Praat's local-jitter limits (0.1 ... 20 ms, period factor 1.3,
  amplitude factor 1.6); nil below 20 pairs;
- period guide: YIN (5 ms hop), octave-folded to the segment's own autocorrelation period (1 ms moving average first).
  MEASURED reasons: YIN locked to 3T on a jittered pulse train at 300 Hz, and called a 1 %-jitter pulse train at
  >= 150 Hz entirely unvoiced; a parabola through three samples doubled pulse-train shimmer (2.0 ... 2.2x truth).
- `BakeoffSynthetic.vowel` gains `formants: Bool = true` (false = the band-limited pulse train itself). Default
  behaviour unchanged.
- `PitchRunner` is unchanged: it already calls `PitchMetrics.perturbation` for source and render, so the swap is the
  function body. Gate definition and thresholds unchanged (`PitchGates.microVariation`, 0.6 ... 1.6).
- Shimmer goes through the same estimator (it shares the point process); shimmer readings change too (below).

## (2) Truth table (MEASURED)

`BakeoffSynthetic.vowel`, region 0.6 ... 2.4 s, shimmer 5 %, 3 seeds (777, 4242, 99) per cell, mean of read/true.
Truth = generated local jitter/shimmer of the cycles inside the region. Praat 6 (`/Applications/Praat.app`, run
offline): `To PointProcess (periodic, cc): 75, 600`, `Get jitter (local): 0, 0, 0.0001, 0.02, 1.3`,
`Get shimmer (local): ..., 1.3, 1.6`. "nan" = no reading (fewer than 20 pairs). J = jitter, S = shimmer.

```
rate kind f0 jit | J old new praat | S old new praat
48000 pulses 100.0 0.0025 | 0.99 1.00 1.00 | 2.79 1.12 1.05
48000 pulses 100.0 0.005 | 0.99 1.00 1.00 | 2.84 1.16 1.07
48000 pulses 100.0 0.01 | 1.00 1.00 1.00 | 2.75 1.20 1.11
48000 pulses 150.0 0.0025 | 0.93 1.00 1.42 | 2.40 1.13 1.10
48000 pulses 150.0 0.005 | 0.99 1.00 1.07 | 2.75 1.17 1.12
48000 pulses 150.0 0.01 | nan  1.00 0.87 | nan  1.14 1.11
48000 pulses 200.0 0.0025 | 0.85 1.00 0.94 | 2.45 1.11 1.05
48000 pulses 200.0 0.005 | 0.88 1.00 0.82 | 2.67 1.12 1.06
48000 pulses 200.0 0.01 | nan  1.00 0.62 | nan  1.15 1.05
48000 pulses 250.0 0.0025 | 0.78 1.01 0.93 | 2.45 1.12 1.05
48000 pulses 250.0 0.005 | 0.82 1.00 0.88 | 2.47 1.09 1.06
48000 pulses 250.0 0.01 | nan  1.00 0.54 | nan  1.14 1.07
48000 pulses 300.0 0.0025 | 1.62 1.00 0.95 | 2.57 1.11 1.05
48000 pulses 300.0 0.005 | 2.18 1.00 1.01 | 2.41 1.09 1.04
48000 pulses 300.0 0.01 | nan  1.00 0.84 | nan  1.11 1.11
48000 pulses 400.0 0.0025 | 0.94 1.00 0.85 | 2.39 1.13 1.07
48000 pulses 400.0 0.005 | 3.56 1.00 0.99 | 2.41 1.13 1.07
48000 pulses 400.0 0.01 | nan  1.00 1.73 | nan  1.12 1.10
48000 vowel 100.0 0.0025 | 0.92 1.17 0.88 | 0.93 0.93 0.91
48000 vowel 100.0 0.005 | 0.91 1.06 0.88 | 0.94 0.94 0.92
48000 vowel 100.0 0.01 | 0.89 1.01 0.89 | 0.95 0.96 0.95
48000 vowel 150.0 0.0025 | 0.78 0.98 0.81 | 1.02 1.06 1.03
48000 vowel 150.0 0.005 | 0.78 0.98 0.81 | 1.01 1.06 1.00
48000 vowel 150.0 0.01 | 0.75 0.99 0.82 | 0.98 1.06 1.04
48000 vowel 200.0 0.0025 | 0.88 0.92 0.80 | 1.09 1.09 1.09
48000 vowel 200.0 0.005 | 0.89 0.91 0.80 | 1.12 1.13 1.11
48000 vowel 200.0 0.01 | 0.89 0.92 0.79 | 1.19 1.24 1.15
48000 vowel 250.0 0.0025 | 0.63 0.92 0.91 | 0.86 0.86 0.83
48000 vowel 250.0 0.005 | 0.54 0.82 0.74 | 0.96 0.96 0.95
48000 vowel 250.0 0.01 | 0.53 0.79 0.69 | 1.32 1.43 1.32
48000 vowel 300.0 0.0025 | 0.80 0.98 0.56 | 0.91 0.91 0.91
48000 vowel 300.0 0.005 | 0.72 0.83 0.54 | 1.00 1.00 1.00
48000 vowel 300.0 0.01 | 0.70 0.80 0.55 | 1.29 1.29 1.27
48000 vowel 400.0 0.0025 | 0.59 0.69 0.45 | 0.57 0.57 0.58
48000 vowel 400.0 0.005 | 0.49 0.54 0.42 | 0.61 0.62 0.62
48000 vowel 400.0 0.01 | 0.44 0.50 0.41 | 0.77 0.77 0.77
44100 pulses 100.0 0.0025 | 1.00 1.00 1.00 | 2.81 1.14 1.07
44100 pulses 100.0 0.005 | 1.00 1.00 1.00 | 2.72 1.13 1.06
44100 pulses 100.0 0.01 | 1.00 1.00 1.00 | 2.79 1.08 1.02
44100 pulses 150.0 0.0025 | 0.94 1.00 1.44 | 2.54 1.10 1.05
44100 pulses 150.0 0.005 | 0.95 1.00 1.14 | 2.87 1.17 1.12
44100 pulses 150.0 0.01 | nan  1.00 0.89 | nan  1.12 1.10
44100 pulses 200.0 0.0025 | 0.80 1.00 0.97 | 2.41 1.08 1.02
44100 pulses 200.0 0.005 | 0.89 1.00 0.84 | 2.69 1.13 1.08
44100 pulses 200.0 0.01 | nan  1.00 0.65 | nan  1.09 1.07
44100 pulses 250.0 0.0025 | 0.60 1.01 0.99 | 2.15 1.13 1.07
44100 pulses 250.0 0.005 | 0.84 1.00 0.87 | 2.67 1.16 1.06
44100 pulses 250.0 0.01 | nan  1.00 0.61 | nan  1.08 1.08
44100 pulses 300.0 0.0025 | 1.07 0.99 0.92 | 2.50 1.12 1.06
44100 pulses 300.0 0.005 | 1.91 1.00 0.91 | 2.56 1.10 1.05
44100 pulses 300.0 0.01 | nan  1.00 0.97 | nan  1.15 1.13
44100 pulses 400.0 0.0025 | 3.79 1.01 1.01 | 2.41 1.13 1.07
44100 pulses 400.0 0.005 | 3.30 1.00 0.99 | 2.39 1.13 1.07
44100 pulses 400.0 0.01 | nan  1.00 1.70 | nan  1.14 1.09
44100 vowel 100.0 0.0025 | 0.92 1.17 0.88 | 0.93 0.93 0.91
44100 vowel 100.0 0.005 | 0.90 1.06 0.88 | 0.94 0.94 0.92
44100 vowel 100.0 0.01 | 0.89 1.01 0.89 | 0.94 0.96 0.95
44100 vowel 150.0 0.0025 | 0.78 0.98 0.80 | 1.02 1.06 0.99
44100 vowel 150.0 0.005 | 0.77 0.98 0.81 | 1.00 1.06 1.00
44100 vowel 150.0 0.01 | 0.76 0.99 0.82 | 0.99 1.06 1.04
44100 vowel 200.0 0.0025 | 0.88 0.92 0.80 | 1.09 1.09 1.09
44100 vowel 200.0 0.005 | 0.88 0.91 0.80 | 1.12 1.13 1.11
44100 vowel 200.0 0.01 | 0.87 0.92 0.79 | 1.19 1.24 1.15
44100 vowel 250.0 0.0025 | 0.63 0.92 0.91 | 0.86 0.86 0.83
44100 vowel 250.0 0.005 | 0.55 0.82 0.74 | 0.96 0.96 0.95
44100 vowel 250.0 0.01 | 0.53 0.79 0.69 | 1.32 1.43 1.32
44100 vowel 300.0 0.0025 | 0.82 0.98 0.56 | 0.91 0.91 0.91
44100 vowel 300.0 0.005 | 0.71 0.83 0.54 | 1.00 1.00 1.00
44100 vowel 300.0 0.01 | 0.69 0.80 0.55 | 1.29 1.29 1.27
44100 vowel 400.0 0.0025 | 0.53 0.69 0.45 | 0.57 0.57 0.58
44100 vowel 400.0 0.005 | 0.46 0.54 0.42 | 0.62 0.62 0.62
44100 vowel 400.0 0.01 | 0.43 0.50 0.41 | 0.78 0.77 0.77
```

Summary (MEASURED): pulse train — new 0.99 ... 1.01x at every f0 (100 ... 400 Hz), jitter level and rate; old
0.60 ... 3.79x or no reading (all 1 % cells >= 150 Hz); Praat 0.54 ... 1.73x. Formant vowel at 100 ... 210 Hz —
new 0.91 ... 1.17x, old 0.75 ... 0.92x, Praat 0.79 ... 0.89x. Formant vowel at 250 ... 400 Hz — every method reads
low (new 0.50 ... 0.98x, old 0.43 ... 0.82x, Praat 0.41 ... 0.91x). INFERENCE: one cycle's formant ringing
(bandwidth 80 Hz, time constant ~4 ms) overlaps the next pulse, so the waveform's peak times no longer equal the
pulse times; no waveform-anchored method recovers the generated value there.

## (3) Bench, before/after (MEASURED)

Offline harness `scripts/envgap_harness` from `0b953dac` (production DSP from `0b953dac`, which carries the
C3d/seam flags), bench metric files from this branch: "before" = `25a01f71`'s files, "after" = this commit's.
Candidates r31, ours, NaiveResample, TDPSOLA2-g0.3, C3d+14-xf0.2; 8 seeds; `PRIMAE_RES` = this worktree's Resources.
Only `jitter_ratio` and `shimmer_ratio` rows changed (600 changed rows per rate; zero rows added or lost; every
other gate value identical).

| candidate | 48k before | 48k after | 44.1k before | 44.1k after |
|---|---|---|---|---|
| r31 | 486 / 5 | 483 / 8 | 489 / 2 | 487 / 4 |
| ours | 409 / 82 | 397 / 94 | 412 / 79 | 396 / 95 |
| NaiveResample | 298 / 193 | 315 / 176 | 298 / 193 | 312 / 179 |
| TDPSOLA2-g0.3 | 390 / 101 | 389 / 102 | 389 / 102 | 388 / 103 |
| C3d+14-xf0.2 | 491 / 0 | 489 / 2 | 490 / 1 | 487 / 4 |

(PASS / FAIL gate rows.) The "before" r31/ours/Naive/g0.3 totals at 48k and 44.1k match BENCH-R31's device
"after" numbers exactly, so the offline harness reproduces the device bench (MEASURED: same 486/5, 409/82, 298/193,
390/101, 489/2, 412/79, 298/193, 389/102).

Gate classes failed, controls (MEASURED): `ours` and `TDPSOLA2-g0.3` lose no class at either rate.
NaiveResample loses `jitter_ratio` at 48 kHz (RED, above) and keeps it at 44.1 kHz by one cell; it gains
`shimmer_ratio` (M +600@2 1.549 -> 1.611 at 48k). r31, C3d+14-xf0.2 and g0.3 gain `jitter_ratio` at 48 kHz.

Shimmer flips (MEASURED): 13 cells across both rates change PASS/FAIL, all `ours` (to FAIL, 0.39 ... 0.59) or NaiveResample (above);
none for r31, C3d+14-xf0.2 or g0.3; r31 I 0@2 shimmer at 44.1k reads 0.797 PASS with 7/8 seeds.

## (4) Self-tests (MEASURED, offline)

Offline XCTest bundle (`swiftc` + `xcrun xctest`, -O) of the bench metric files + `PitchMetricSelfTests.swift`
against the harness `libPrimaeNative.a`. `testScenarioSetAndExportNames` is excluded offline (it needs the
`SonificationBakeoffBench` XCTest class); everything else ran: **"Executed 20 tests, with 0 failures"**.
New tests:
- `testCycleAnchoredPerturbationMatchesTruthOnAPulseTrainAcrossTheF0Range` (36 cells, both rates: jitter within 5 %,
  shimmer 1.12 +- 0.13x);
- `testCycleAnchoredPerturbationOnTheFormantVowel` (150/200/210 Hz x 3 jitter levels x 2 rates: jitter 0.88 ... 1.05x,
  shimmer 1.05 +- 0.25x, never further from truth than the old method);
- `testCycleAnchoredJitterFactorDoesNotMoveWithF0` (read/true factor at 0, -300, +600 c within 6 %).

Mutation checks, each with the three new tests ("Executed 3 tests" read every time), source restored to sha1
`4abfcac` after each: M1 sampled (not interpolated) amplitude — 36 failures; M2 integer mark position —
40 failures; M3 old unanchored method on the gate path — 19 failures (all 3 tests RED); M4 no octave fold —
31 failures; M5 no 1 ms smoothing — 2 failures. Green control: 0 failures.

UNMEASURED: the self-tests on the iPad (Primae-DeviceTests) — the brief is offline-only. The device run is owed
before landing.

## Owed

- UNMEASURED: Praat (cc) on the r31/C3d renders at A/L -600 c and I +600@2, to decide whether the new lows/highs
  are the renderer or the estimator.
- UNMEASURED: device run of `PitchMetricSelfTests` and the bench through Primae-DeviceTests.
- Supervisor ruling: NaiveResample no longer fails jitter_ratio at 48 kHz (RED by the brief's rule).

## Appendix B — jitter_ratio before/after, every I/A/L/M cell (MEASURED, offline harness, 8 seeds, median gating; limit 0.6...1.6)

### 48000 Hz

| candidate | letter | scenario | before | after |
|---|---|---|---|---|
| C3d+14-xf0.2 | A | pitch_+300@0.5 | 0.619 PASS 7/8 | 0.806 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+300@1 | 0.817 PASS 8/8 | 0.983 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+300@2 | 0.855 PASS 8/8 | 0.888 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+600@0.5 | 0.626 PASS 8/8 | 0.908 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+600@1 | 0.720 PASS 8/8 | 0.958 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+600@2 | 0.872 PASS 8/8 | 1.014 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_-300@0.5 | 0.721 PASS 8/8 | 0.665 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_-300@1 | 1.030 PASS 8/8 | 0.857 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_-300@2 | 0.830 PASS 8/8 | 0.708 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_-600@0.5 | 0.794 PASS 8/8 | 0.636 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_-600@1 | 1.034 PASS 8/8 | 0.654 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_-600@2 | 1.042 PASS 8/8 | 0.609 PASS 5/8 |
| C3d+14-xf0.2 | A | pitch_0@0.5 | 0.625 PASS 8/8 | 0.793 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_0@1 | 1.099 PASS 8/8 | 1.043 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_0@2 | 0.932 PASS 8/8 | 0.824 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+300@0.5 | 0.976 PASS 8/8 | 1.031 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+300@1 | 1.089 PASS 8/8 | 1.161 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+300@2 | 1.144 PASS 8/8 | 1.075 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+600@0.5 | 0.983 PASS 8/8 | 1.137 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+600@1 | 1.171 PASS 8/8 | 1.346 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+600@2 | 1.346 PASS 8/8 | 1.327 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-300@0.5 | 0.938 PASS 8/8 | 0.776 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-300@1 | 1.273 PASS 8/8 | 0.814 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-300@2 | 1.531 PASS 6/8 | 0.788 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-600@0.5 | 0.768 PASS 8/8 | 0.693 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-600@1 | 1.201 PASS 8/8 | 0.661 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-600@2 | 1.368 PASS 8/8 | 0.692 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_0@0.5 | 0.852 PASS 8/8 | 0.850 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_0@1 | 0.989 PASS 8/8 | 1.097 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_0@2 | 1.009 PASS 8/8 | 0.921 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+300@0.5 | 0.837 PASS 8/8 | 0.851 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+300@1 | 1.203 PASS 8/8 | 1.103 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+300@2 | 0.975 PASS 8/8 | 0.804 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+600@0.5 | 0.776 PASS 8/8 | 1.053 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+600@1 | 1.040 PASS 8/8 | 1.212 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+600@2 | 1.217 PASS 8/8 | 1.160 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_-300@0.5 | 0.954 PASS 8/8 | 0.663 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_-300@1 | 1.341 PASS 8/8 | 0.831 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_-300@2 | 1.298 PASS 8/8 | 0.637 PASS 7/8 |
| C3d+14-xf0.2 | L | pitch_-600@0.5 | 1.048 PASS 8/8 | 0.593 FAIL 3/8 |
| C3d+14-xf0.2 | L | pitch_-600@1 | 1.321 PASS 8/8 | 0.675 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_-600@2 | 1.315 PASS 8/8 | 0.544 FAIL 2/8 |
| C3d+14-xf0.2 | L | pitch_0@0.5 | 0.836 PASS 8/8 | 0.751 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_0@1 | 1.047 PASS 8/8 | 1.057 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_0@2 | 0.831 PASS 8/8 | 0.795 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+300@0.5 | 0.975 PASS 8/8 | 0.976 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+300@1 | 1.051 PASS 8/8 | 1.086 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+300@2 | 1.168 PASS 8/8 | 0.991 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+600@0.5 | 1.039 PASS 8/8 | 1.048 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+600@1 | 1.101 PASS 8/8 | 1.142 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+600@2 | 1.196 PASS 8/8 | 1.129 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-300@0.5 | 0.880 PASS 8/8 | 0.716 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-300@1 | 1.313 PASS 8/8 | 0.857 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-300@2 | 1.367 PASS 8/8 | 0.757 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-600@0.5 | 0.912 PASS 8/8 | 0.624 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-600@1 | 1.196 PASS 8/8 | 0.653 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-600@2 | 1.432 PASS 8/8 | 0.639 PASS 7/8 |
| C3d+14-xf0.2 | M | pitch_0@0.5 | 0.732 PASS 8/8 | 0.865 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_0@1 | 1.205 PASS 8/8 | 1.065 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_0@2 | 1.085 PASS 8/8 | 0.905 PASS 8/8 |
| NaiveResample | A | pitch_+300@0.5 | 0.999 PASS 1/1 | 0.897 PASS 1/1 |
| NaiveResample | A | pitch_+300@1 | 1.053 PASS 1/1 | 0.870 PASS 1/1 |
| NaiveResample | A | pitch_+300@2 | 1.061 PASS 1/1 | 0.928 PASS 1/1 |
| NaiveResample | A | pitch_+600@0.5 | 1.129 PASS 1/1 | 0.986 PASS 1/1 |
| NaiveResample | A | pitch_+600@1 | 1.079 PASS 1/1 | 0.873 PASS 1/1 |
| NaiveResample | A | pitch_+600@2 | 1.062 PASS 1/1 | 0.944 PASS 1/1 |
| NaiveResample | A | pitch_-300@0.5 | 0.972 PASS 1/1 | 0.941 PASS 1/1 |
| NaiveResample | A | pitch_-300@1 | 0.889 PASS 1/1 | 1.065 PASS 1/1 |
| NaiveResample | A | pitch_-300@2 | 0.886 PASS 1/1 | 0.777 PASS 1/1 |
| NaiveResample | A | pitch_-600@0.5 | 0.985 PASS 1/1 | 0.962 PASS 1/1 |
| NaiveResample | A | pitch_-600@1 | 1.041 PASS 1/1 | 1.025 PASS 1/1 |
| NaiveResample | A | pitch_-600@2 | 1.079 PASS 1/1 | 0.873 PASS 1/1 |
| NaiveResample | A | pitch_0@0.5 | 1.080 PASS 1/1 | 0.969 PASS 1/1 |
| NaiveResample | A | pitch_0@1 | 0.867 PASS 1/1 | 0.893 PASS 1/1 |
| NaiveResample | A | pitch_0@2 | 1.051 PASS 1/1 | 0.781 PASS 1/1 |
| NaiveResample | I | pitch_+300@0.5 | 1.222 PASS 1/1 | 1.133 PASS 1/1 |
| NaiveResample | I | pitch_+300@1 | 1.400 PASS 1/1 | 1.070 PASS 1/1 |
| NaiveResample | I | pitch_+300@2 | 1.212 PASS 1/1 | 1.062 PASS 1/1 |
| NaiveResample | I | pitch_+600@0.5 | 1.165 PASS 1/1 | 1.146 PASS 1/1 |
| NaiveResample | I | pitch_+600@1 | 1.297 PASS 1/1 | 1.101 PASS 1/1 |
| NaiveResample | I | pitch_+600@2 | 1.267 PASS 1/1 | 1.160 PASS 1/1 |
| NaiveResample | I | pitch_-300@0.5 | 1.112 PASS 1/1 | 0.974 PASS 1/1 |
| NaiveResample | I | pitch_-300@1 | 1.212 PASS 1/1 | 0.987 PASS 1/1 |
| NaiveResample | I | pitch_-300@2 | 1.331 PASS 1/1 | 1.061 PASS 1/1 |
| NaiveResample | I | pitch_-600@0.5 | 1.099 PASS 1/1 | 0.993 PASS 1/1 |
| NaiveResample | I | pitch_-600@1 | 0.997 PASS 1/1 | 0.967 PASS 1/1 |
| NaiveResample | I | pitch_-600@2 | 1.297 PASS 1/1 | 1.101 PASS 1/1 |
| NaiveResample | I | pitch_0@0.5 | 1.716 FAIL 0/1 | 1.115 PASS 1/1 |
| NaiveResample | I | pitch_0@1 | 1.405 PASS 1/1 | 1.167 PASS 1/1 |
| NaiveResample | I | pitch_0@2 | 1.285 PASS 1/1 | 1.135 PASS 1/1 |
| NaiveResample | L | pitch_+300@0.5 | 1.871 FAIL 0/1 | 0.978 PASS 1/1 |
| NaiveResample | L | pitch_+300@1 | 1.215 PASS 1/1 | 1.042 PASS 1/1 |
| NaiveResample | L | pitch_+300@2 | 1.228 PASS 1/1 | 0.983 PASS 1/1 |
| NaiveResample | L | pitch_+600@0.5 | 1.821 FAIL 0/1 | 1.004 PASS 1/1 |
| NaiveResample | L | pitch_+600@1 | 1.153 PASS 1/1 | 0.975 PASS 1/1 |
| NaiveResample | L | pitch_+600@2 | 1.700 FAIL 0/1 | 0.972 PASS 1/1 |
| NaiveResample | L | pitch_-300@0.5 | 1.004 PASS 1/1 | 0.966 PASS 1/1 |
| NaiveResample | L | pitch_-300@1 | 1.365 PASS 1/1 | 0.989 PASS 1/1 |
| NaiveResample | L | pitch_-300@2 | 2.018 FAIL 0/1 | 1.006 PASS 1/1 |
| NaiveResample | L | pitch_-600@0.5 | 1.169 PASS 1/1 | 1.038 PASS 1/1 |
| NaiveResample | L | pitch_-600@1 | 1.470 PASS 1/1 | 1.023 PASS 1/1 |
| NaiveResample | L | pitch_-600@2 | 1.153 PASS 1/1 | 0.975 PASS 1/1 |
| NaiveResample | L | pitch_0@0.5 | 1.459 PASS 1/1 | 0.992 PASS 1/1 |
| NaiveResample | L | pitch_0@1 | 1.903 FAIL 0/1 | 1.011 PASS 1/1 |
| NaiveResample | L | pitch_0@2 | 1.660 FAIL 0/1 | 1.006 PASS 1/1 |
| NaiveResample | M | pitch_+300@0.5 | 1.747 FAIL 0/1 | 0.985 PASS 1/1 |
| NaiveResample | M | pitch_+300@1 | 1.734 FAIL 0/1 | 1.045 PASS 1/1 |
| NaiveResample | M | pitch_+300@2 | 1.899 FAIL 0/1 | 1.000 PASS 1/1 |
| NaiveResample | M | pitch_+600@0.5 | 1.694 FAIL 0/1 | 1.037 PASS 1/1 |
| NaiveResample | M | pitch_+600@1 | 1.774 FAIL 0/1 | 0.977 PASS 1/1 |
| NaiveResample | M | pitch_+600@2 | 2.050 FAIL 0/1 | 1.036 PASS 1/1 |
| NaiveResample | M | pitch_-300@0.5 | 1.221 PASS 1/1 | 1.017 PASS 1/1 |
| NaiveResample | M | pitch_-300@1 | 1.297 PASS 1/1 | 0.994 PASS 1/1 |
| NaiveResample | M | pitch_-300@2 | 1.994 FAIL 0/1 | 1.003 PASS 1/1 |
| NaiveResample | M | pitch_-600@0.5 | 1.177 PASS 1/1 | 1.016 PASS 1/1 |
| NaiveResample | M | pitch_-600@1 | 1.006 PASS 1/1 | 1.063 PASS 1/1 |
| NaiveResample | M | pitch_-600@2 | 1.774 FAIL 0/1 | 0.977 PASS 1/1 |
| NaiveResample | M | pitch_0@0.5 | 2.032 FAIL 0/1 | 1.035 PASS 1/1 |
| NaiveResample | M | pitch_0@1 | 2.007 FAIL 0/1 | 0.999 PASS 1/1 |
| NaiveResample | M | pitch_0@2 | 1.983 FAIL 0/1 | 0.967 PASS 1/1 |
| TDPSOLA2-g0.3 | A | pitch_+300@0.5 | 0.678 PASS 8/8 | 0.852 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+300@1 | 0.814 PASS 8/8 | 1.026 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+300@2 | 0.788 PASS 8/8 | 0.823 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+600@0.5 | 0.634 PASS 8/8 | 0.947 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+600@1 | 0.775 PASS 8/8 | 0.998 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+600@2 | 0.853 PASS 8/8 | 0.896 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-300@0.5 | 0.783 PASS 8/8 | 0.729 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-300@1 | 1.078 PASS 8/8 | 0.912 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-300@2 | 0.827 PASS 8/8 | 0.614 PASS 5/8 |
| TDPSOLA2-g0.3 | A | pitch_-600@0.5 | 0.841 PASS 8/8 | 0.699 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-600@1 | 0.993 PASS 8/8 | 0.759 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-600@2 | 1.035 PASS 8/8 | 0.600 FAIL 4/8 |
| TDPSOLA2-g0.3 | A | pitch_0@0.5 | 0.660 PASS 8/8 | 0.759 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_0@1 | 1.153 PASS 8/8 | 0.978 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_0@2 | 0.958 PASS 8/8 | 0.650 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+300@0.5 | 0.920 PASS 8/8 | 1.030 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+300@1 | 1.084 PASS 8/8 | 1.314 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+300@2 | 1.082 PASS 8/8 | 1.243 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+600@0.5 | 0.894 PASS 8/8 | 1.165 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+600@1 | 1.100 PASS 8/8 | 1.436 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+600@2 | 1.294 PASS 8/8 | 1.455 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-300@0.5 | 0.932 PASS 8/8 | 0.871 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-300@1 | 1.212 PASS 8/8 | 1.071 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-300@2 | 1.579 PASS 5/8 | 0.997 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-600@0.5 | 0.839 PASS 8/8 | 0.823 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-600@1 | 1.259 PASS 8/8 | 0.951 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-600@2 | 1.554 PASS 7/8 | 0.970 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_0@0.5 | 0.814 PASS 8/8 | 0.963 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_0@1 | 0.951 PASS 8/8 | 1.226 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_0@2 | 1.125 PASS 8/8 | 1.138 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+300@0.5 | 0.799 PASS 8/8 | 0.885 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+300@1 | 1.249 PASS 8/8 | 1.100 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+300@2 | 1.015 PASS 8/8 | 0.847 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+600@0.5 | 0.733 PASS 8/8 | 0.900 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+600@1 | 0.994 PASS 8/8 | 1.096 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+600@2 | 1.268 PASS 8/8 | 0.969 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-300@0.5 | 0.948 PASS 8/8 | 0.751 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-300@1 | 1.406 PASS 8/8 | 0.850 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-300@2 | 1.315 PASS 8/8 | 0.674 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-600@0.5 | 1.056 PASS 8/8 | 0.710 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-600@1 | 1.325 PASS 8/8 | 0.783 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-600@2 | 1.362 PASS 8/8 | 0.611 PASS 6/8 |
| TDPSOLA2-g0.3 | L | pitch_0@0.5 | 0.807 PASS 8/8 | 0.783 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_0@1 | 1.022 PASS 8/8 | 1.087 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_0@2 | 0.783 PASS 8/8 | 0.768 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+300@0.5 | 0.917 PASS 8/8 | 0.998 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+300@1 | 1.052 PASS 8/8 | 1.146 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+300@2 | 1.204 PASS 8/8 | 1.009 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+600@0.5 | 0.994 PASS 8/8 | 1.064 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+600@1 | 1.091 PASS 8/8 | 1.126 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+600@2 | 1.149 PASS 8/8 | 1.063 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-300@0.5 | 0.845 PASS 8/8 | 0.751 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-300@1 | 1.188 PASS 8/8 | 0.895 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-300@2 | 1.403 PASS 8/8 | 0.779 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-600@0.5 | 0.922 PASS 8/8 | 0.719 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-600@1 | 1.230 PASS 8/8 | 0.775 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-600@2 | 1.380 PASS 8/8 | 0.756 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_0@0.5 | 0.701 PASS 8/8 | 0.893 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_0@1 | 1.128 PASS 8/8 | 1.068 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_0@2 | 1.120 PASS 8/8 | 0.923 PASS 8/8 |
| ours | A | pitch_+300@0.5 | 0.551 FAIL 0/1 | 0.576 FAIL 0/1 |
| ours | A | pitch_+300@1 | 0.990 PASS 1/1 | 1.039 PASS 1/1 |
| ours | A | pitch_+300@2 | 0.977 PASS 1/1 | 0.962 PASS 1/1 |
| ours | A | pitch_+600@0.5 | 0.508 FAIL 0/1 | 0.566 FAIL 0/1 |
| ours | A | pitch_+600@1 | 0.868 PASS 1/1 | 0.950 PASS 1/1 |
| ours | A | pitch_+600@2 | 1.039 PASS 1/1 | 0.994 PASS 1/1 |
| ours | A | pitch_-300@0.5 | 0.599 FAIL 0/1 | 0.566 FAIL 0/1 |
| ours | A | pitch_-300@1 | 0.740 PASS 1/1 | 0.897 PASS 1/1 |
| ours | A | pitch_-300@2 | 0.750 PASS 1/1 | 0.680 PASS 1/1 |
| ours | A | pitch_-600@0.5 | 0.627 PASS 1/1 | 0.552 FAIL 0/1 |
| ours | A | pitch_-600@1 | 0.783 PASS 1/1 | 0.737 PASS 1/1 |
| ours | A | pitch_-600@2 | 0.935 PASS 1/1 | 0.556 FAIL 0/1 |
| ours | A | pitch_0@0.5 | 0.584 FAIL 0/1 | 0.557 FAIL 0/1 |
| ours | A | pitch_0@1 | 0.825 PASS 1/1 | 0.938 PASS 1/1 |
| ours | A | pitch_0@2 | 0.844 PASS 1/1 | 0.781 PASS 1/1 |
| ours | I | pitch_+300@0.5 | 0.731 PASS 1/1 | 0.744 PASS 1/1 |
| ours | I | pitch_+300@1 | 0.841 PASS 1/1 | 1.194 PASS 1/1 |
| ours | I | pitch_+300@2 | 1.042 PASS 1/1 | 1.353 PASS 1/1 |
| ours | I | pitch_+600@0.5 | 0.655 PASS 1/1 | 0.747 PASS 1/1 |
| ours | I | pitch_+600@1 | 0.891 PASS 1/1 | 1.215 PASS 1/1 |
| ours | I | pitch_+600@2 | 1.144 PASS 1/1 | 1.568 PASS 1/1 |
| ours | I | pitch_-300@0.5 | 0.794 PASS 1/1 | 0.710 PASS 1/1 |
| ours | I | pitch_-300@1 | 1.018 PASS 1/1 | 1.046 PASS 1/1 |
| ours | I | pitch_-300@2 | 1.297 PASS 1/1 | 0.945 PASS 1/1 |
| ours | I | pitch_-600@0.5 | 0.763 PASS 1/1 | 0.697 PASS 1/1 |
| ours | I | pitch_-600@1 | 1.088 PASS 1/1 | 0.854 PASS 1/1 |
| ours | I | pitch_-600@2 | 1.290 PASS 1/1 | 0.823 PASS 1/1 |
| ours | I | pitch_0@0.5 | 0.746 PASS 1/1 | 0.668 PASS 1/1 |
| ours | I | pitch_0@1 | 1.039 PASS 1/1 | 1.235 PASS 1/1 |
| ours | I | pitch_0@2 | 1.234 PASS 1/1 | 1.075 PASS 1/1 |
| ours | L | pitch_+300@0.5 | 0.650 PASS 1/1 | 0.576 FAIL 0/1 |
| ours | L | pitch_+300@1 | 0.768 PASS 1/1 | 1.050 PASS 1/1 |
| ours | L | pitch_+300@2 | 0.993 PASS 1/1 | 1.007 PASS 1/1 |
| ours | L | pitch_+600@0.5 | 0.619 PASS 1/1 | 0.495 FAIL 0/1 |
| ours | L | pitch_+600@1 | 0.830 PASS 1/1 | 0.962 PASS 1/1 |
| ours | L | pitch_+600@2 | 1.219 PASS 1/1 | 1.190 PASS 1/1 |
| ours | L | pitch_-300@0.5 | 0.857 PASS 1/1 | 0.621 PASS 1/1 |
| ours | L | pitch_-300@1 | 1.244 PASS 1/1 | 0.946 PASS 1/1 |
| ours | L | pitch_-300@2 | 1.241 PASS 1/1 | 0.783 PASS 1/1 |
| ours | L | pitch_-600@0.5 | 0.944 PASS 1/1 | 0.586 FAIL 0/1 |
| ours | L | pitch_-600@1 | 1.211 PASS 1/1 | 0.731 PASS 1/1 |
| ours | L | pitch_-600@2 | 1.170 PASS 1/1 | 0.706 PASS 1/1 |
| ours | L | pitch_0@0.5 | 0.663 PASS 1/1 | 0.629 PASS 1/1 |
| ours | L | pitch_0@1 | 0.909 PASS 1/1 | 1.073 PASS 1/1 |
| ours | L | pitch_0@2 | 0.961 PASS 1/1 | 0.876 PASS 1/1 |
| ours | M | pitch_+300@0.5 | 0.659 PASS 1/1 | 0.614 PASS 1/1 |
| ours | M | pitch_+300@1 | 0.949 PASS 1/1 | 1.080 PASS 1/1 |
| ours | M | pitch_+300@2 | 1.192 PASS 1/1 | 1.185 PASS 1/1 |
| ours | M | pitch_+600@0.5 | 0.578 FAIL 0/1 | 0.565 FAIL 0/1 |
| ours | M | pitch_+600@1 | 0.870 PASS 1/1 | 1.006 PASS 1/1 |
| ours | M | pitch_+600@2 | 1.095 PASS 1/1 | 1.122 PASS 1/1 |
| ours | M | pitch_-300@0.5 | 0.823 PASS 1/1 | 0.600 FAIL 0/1 |
| ours | M | pitch_-300@1 | 1.232 PASS 1/1 | 0.873 PASS 1/1 |
| ours | M | pitch_-300@2 | 1.570 PASS 1/1 | 0.832 PASS 1/1 |
| ours | M | pitch_-600@0.5 | 0.925 PASS 1/1 | 0.558 FAIL 0/1 |
| ours | M | pitch_-600@1 | 1.250 PASS 1/1 | 0.722 PASS 1/1 |
| ours | M | pitch_-600@2 | 1.380 PASS 1/1 | 0.741 PASS 1/1 |
| ours | M | pitch_0@0.5 | 0.711 PASS 1/1 | 0.625 PASS 1/1 |
| ours | M | pitch_0@1 | 1.138 PASS 1/1 | 1.026 PASS 1/1 |
| ours | M | pitch_0@2 | 1.463 PASS 1/1 | 1.015 PASS 1/1 |
| r31 | A | pitch_+300@0.5 | 0.670 PASS 8/8 | 0.896 PASS 8/8 |
| r31 | A | pitch_+300@1 | 0.838 PASS 8/8 | 1.075 PASS 8/8 |
| r31 | A | pitch_+300@2 | 0.795 PASS 8/8 | 0.862 PASS 8/8 |
| r31 | A | pitch_+600@0.5 | 0.680 PASS 8/8 | 1.032 PASS 8/8 |
| r31 | A | pitch_+600@1 | 0.800 PASS 8/8 | 1.073 PASS 8/8 |
| r31 | A | pitch_+600@2 | 0.896 PASS 8/8 | 0.949 PASS 8/8 |
| r31 | A | pitch_-300@0.5 | 0.772 PASS 8/8 | 0.677 PASS 8/8 |
| r31 | A | pitch_-300@1 | 1.046 PASS 8/8 | 0.855 PASS 8/8 |
| r31 | A | pitch_-300@2 | 0.802 PASS 8/8 | 0.590 FAIL 3/8 |
| r31 | A | pitch_-600@0.5 | 0.824 PASS 8/8 | 0.638 PASS 8/8 |
| r31 | A | pitch_-600@1 | 0.975 PASS 8/8 | 0.701 PASS 8/8 |
| r31 | A | pitch_-600@2 | 1.007 PASS 8/8 | 0.555 FAIL 0/8 |
| r31 | A | pitch_0@0.5 | 0.660 PASS 8/8 | 0.759 PASS 8/8 |
| r31 | A | pitch_0@1 | 1.153 PASS 8/8 | 0.978 PASS 8/8 |
| r31 | A | pitch_0@2 | 0.958 PASS 8/8 | 0.650 PASS 8/8 |
| r31 | I | pitch_+300@0.5 | 0.963 PASS 8/8 | 1.118 PASS 8/8 |
| r31 | I | pitch_+300@1 | 1.060 PASS 8/8 | 1.313 PASS 8/8 |
| r31 | I | pitch_+300@2 | 1.095 PASS 8/8 | 1.282 PASS 8/8 |
| r31 | I | pitch_+600@0.5 | 0.960 PASS 8/8 | 1.239 PASS 8/8 |
| r31 | I | pitch_+600@1 | 1.183 PASS 8/8 | 1.471 PASS 8/8 |
| r31 | I | pitch_+600@2 | 1.377 PASS 8/8 | 1.553 PASS 6/8 |
| r31 | I | pitch_-300@0.5 | 0.950 PASS 8/8 | 0.833 PASS 8/8 |
| r31 | I | pitch_-300@1 | 1.219 PASS 8/8 | 1.050 PASS 8/8 |
| r31 | I | pitch_-300@2 | 1.595 PASS 5/8 | 0.903 PASS 8/8 |
| r31 | I | pitch_-600@0.5 | 0.755 PASS 8/8 | 0.752 PASS 8/8 |
| r31 | I | pitch_-600@1 | 1.212 PASS 8/8 | 0.812 PASS 8/8 |
| r31 | I | pitch_-600@2 | 1.449 PASS 8/8 | 0.844 PASS 8/8 |
| r31 | I | pitch_0@0.5 | 0.814 PASS 8/8 | 0.963 PASS 8/8 |
| r31 | I | pitch_0@1 | 0.951 PASS 8/8 | 1.226 PASS 8/8 |
| r31 | I | pitch_0@2 | 1.125 PASS 8/8 | 1.138 PASS 8/8 |
| r31 | L | pitch_+300@0.5 | 0.824 PASS 8/8 | 0.899 PASS 8/8 |
| r31 | L | pitch_+300@1 | 1.221 PASS 8/8 | 1.089 PASS 8/8 |
| r31 | L | pitch_+300@2 | 1.030 PASS 8/8 | 0.857 PASS 8/8 |
| r31 | L | pitch_+600@0.5 | 0.772 PASS 8/8 | 0.967 PASS 8/8 |
| r31 | L | pitch_+600@1 | 1.040 PASS 8/8 | 1.138 PASS 8/8 |
| r31 | L | pitch_+600@2 | 1.232 PASS 8/8 | 1.076 PASS 8/8 |
| r31 | L | pitch_-300@0.5 | 0.955 PASS 8/8 | 0.693 PASS 8/8 |
| r31 | L | pitch_-300@1 | 1.386 PASS 8/8 | 0.856 PASS 8/8 |
| r31 | L | pitch_-300@2 | 1.303 PASS 8/8 | 0.641 PASS 7/8 |
| r31 | L | pitch_-600@0.5 | 1.043 PASS 8/8 | 0.639 PASS 8/8 |
| r31 | L | pitch_-600@1 | 1.298 PASS 8/8 | 0.718 PASS 8/8 |
| r31 | L | pitch_-600@2 | 1.341 PASS 8/8 | 0.558 FAIL 0/8 |
| r31 | L | pitch_0@0.5 | 0.807 PASS 8/8 | 0.783 PASS 8/8 |
| r31 | L | pitch_0@1 | 1.022 PASS 8/8 | 1.087 PASS 8/8 |
| r31 | L | pitch_0@2 | 0.783 PASS 8/8 | 0.768 PASS 8/8 |
| r31 | M | pitch_+300@0.5 | 0.933 PASS 8/8 | 1.011 PASS 8/8 |
| r31 | M | pitch_+300@1 | 1.043 PASS 8/8 | 1.161 PASS 8/8 |
| r31 | M | pitch_+300@2 | 1.212 PASS 8/8 | 1.024 PASS 8/8 |
| r31 | M | pitch_+600@0.5 | 1.026 PASS 8/8 | 1.099 PASS 8/8 |
| r31 | M | pitch_+600@1 | 1.131 PASS 8/8 | 1.162 PASS 8/8 |
| r31 | M | pitch_+600@2 | 1.180 PASS 8/8 | 1.109 PASS 8/8 |
| r31 | M | pitch_-300@0.5 | 0.849 PASS 8/8 | 0.722 PASS 8/8 |
| r31 | M | pitch_-300@1 | 1.223 PASS 8/8 | 0.842 PASS 8/8 |
| r31 | M | pitch_-300@2 | 1.435 PASS 8/8 | 0.730 PASS 8/8 |
| r31 | M | pitch_-600@0.5 | 0.881 PASS 8/8 | 0.647 PASS 8/8 |
| r31 | M | pitch_-600@1 | 1.176 PASS 8/8 | 0.666 PASS 8/8 |
| r31 | M | pitch_-600@2 | 1.346 PASS 8/8 | 0.674 PASS 7/8 |
| r31 | M | pitch_0@0.5 | 0.701 PASS 8/8 | 0.893 PASS 8/8 |
| r31 | M | pitch_0@1 | 1.128 PASS 8/8 | 1.068 PASS 8/8 |
| r31 | M | pitch_0@2 | 1.120 PASS 8/8 | 0.923 PASS 8/8 |

### 44100 Hz

| candidate | letter | scenario | before | after |
|---|---|---|---|---|
| C3d+14-xf0.2 | A | pitch_+300@0.5 | 0.663 PASS 8/8 | 0.804 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+300@1 | 0.845 PASS 8/8 | 0.952 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+300@2 | 0.870 PASS 8/8 | 0.858 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+600@0.5 | 0.663 PASS 8/8 | 0.867 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+600@1 | 0.746 PASS 8/8 | 0.950 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_+600@2 | 0.937 PASS 8/8 | 0.982 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_-300@0.5 | 0.759 PASS 8/8 | 0.644 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_-300@1 | 1.074 PASS 8/8 | 0.816 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_-300@2 | 0.868 PASS 8/8 | 0.651 PASS 6/8 |
| C3d+14-xf0.2 | A | pitch_-600@0.5 | 0.839 PASS 8/8 | 0.598 FAIL 3/8 |
| C3d+14-xf0.2 | A | pitch_-600@1 | 1.061 PASS 8/8 | 0.593 FAIL 2/8 |
| C3d+14-xf0.2 | A | pitch_-600@2 | 1.113 PASS 8/8 | 0.648 PASS 7/8 |
| C3d+14-xf0.2 | A | pitch_0@0.5 | 0.659 PASS 8/8 | 0.773 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_0@1 | 1.141 PASS 8/8 | 1.019 PASS 8/8 |
| C3d+14-xf0.2 | A | pitch_0@2 | 0.989 PASS 8/8 | 0.817 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+300@0.5 | 1.008 PASS 8/8 | 0.978 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+300@1 | 1.084 PASS 8/8 | 1.152 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+300@2 | 1.186 PASS 8/8 | 1.023 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+600@0.5 | 1.004 PASS 8/8 | 1.119 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+600@1 | 1.192 PASS 8/8 | 1.248 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_+600@2 | 1.343 PASS 8/8 | 1.253 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-300@0.5 | 0.941 PASS 8/8 | 0.735 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-300@1 | 1.297 PASS 8/8 | 0.813 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-300@2 | 1.604 FAIL 4/8 | 0.764 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-600@0.5 | 0.838 PASS 8/8 | 0.692 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-600@1 | 1.212 PASS 8/8 | 0.673 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_-600@2 | 1.356 PASS 8/8 | 0.667 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_0@0.5 | 0.873 PASS 8/8 | 0.846 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_0@1 | 0.975 PASS 8/8 | 1.053 PASS 8/8 |
| C3d+14-xf0.2 | I | pitch_0@2 | 1.071 PASS 8/8 | 0.851 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+300@0.5 | 0.879 PASS 8/8 | 0.813 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+300@1 | 1.249 PASS 8/8 | 1.051 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+300@2 | 1.037 PASS 8/8 | 0.868 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+600@0.5 | 0.823 PASS 8/8 | 0.986 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+600@1 | 1.063 PASS 8/8 | 1.100 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_+600@2 | 1.283 PASS 8/8 | 1.112 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_-300@0.5 | 1.007 PASS 8/8 | 0.626 PASS 7/8 |
| C3d+14-xf0.2 | L | pitch_-300@1 | 1.392 PASS 8/8 | 0.778 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_-300@2 | 1.376 PASS 8/8 | 0.604 PASS 4/8 |
| C3d+14-xf0.2 | L | pitch_-600@0.5 | 1.094 PASS 8/8 | 0.586 FAIL 3/8 |
| C3d+14-xf0.2 | L | pitch_-600@1 | 1.376 PASS 8/8 | 0.685 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_-600@2 | 1.397 PASS 8/8 | 0.556 FAIL 0/8 |
| C3d+14-xf0.2 | L | pitch_0@0.5 | 0.853 PASS 8/8 | 0.722 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_0@1 | 1.087 PASS 8/8 | 0.999 PASS 8/8 |
| C3d+14-xf0.2 | L | pitch_0@2 | 0.873 PASS 8/8 | 0.718 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+300@0.5 | 0.938 PASS 8/8 | 0.970 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+300@1 | 1.072 PASS 8/8 | 1.125 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+300@2 | 1.208 PASS 8/8 | 1.021 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+600@0.5 | 1.118 PASS 8/8 | 1.068 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+600@1 | 1.200 PASS 8/8 | 1.151 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_+600@2 | 1.224 PASS 8/8 | 1.124 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-300@0.5 | 0.908 PASS 8/8 | 0.727 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-300@1 | 1.378 PASS 8/8 | 0.854 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-300@2 | 1.412 PASS 8/8 | 0.758 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-600@0.5 | 0.942 PASS 8/8 | 0.646 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-600@1 | 1.239 PASS 8/8 | 0.675 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_-600@2 | 1.479 PASS 8/8 | 0.651 PASS 7/8 |
| C3d+14-xf0.2 | M | pitch_0@0.5 | 0.756 PASS 8/8 | 0.887 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_0@1 | 1.242 PASS 8/8 | 1.065 PASS 8/8 |
| C3d+14-xf0.2 | M | pitch_0@2 | 1.151 PASS 8/8 | 0.933 PASS 8/8 |
| NaiveResample | A | pitch_+300@0.5 | 1.085 PASS 1/1 | 0.905 PASS 1/1 |
| NaiveResample | A | pitch_+300@1 | 1.100 PASS 1/1 | 0.871 PASS 1/1 |
| NaiveResample | A | pitch_+300@2 | 1.078 PASS 1/1 | 0.874 PASS 1/1 |
| NaiveResample | A | pitch_+600@0.5 | 1.184 PASS 1/1 | 0.955 PASS 1/1 |
| NaiveResample | A | pitch_+600@1 | 1.125 PASS 1/1 | 0.901 PASS 1/1 |
| NaiveResample | A | pitch_+600@2 | 1.171 PASS 1/1 | 0.846 PASS 1/1 |
| NaiveResample | A | pitch_-300@0.5 | 1.049 PASS 1/1 | 0.920 PASS 1/1 |
| NaiveResample | A | pitch_-300@1 | 0.945 PASS 1/1 | 1.004 PASS 1/1 |
| NaiveResample | A | pitch_-300@2 | 0.983 PASS 1/1 | 0.710 PASS 1/1 |
| NaiveResample | A | pitch_-600@0.5 | 1.063 PASS 1/1 | 0.962 PASS 1/1 |
| NaiveResample | A | pitch_-600@1 | 1.102 PASS 1/1 | 0.995 PASS 1/1 |
| NaiveResample | A | pitch_-600@2 | 1.125 PASS 1/1 | 0.901 PASS 1/1 |
| NaiveResample | A | pitch_0@0.5 | 1.139 PASS 1/1 | 0.971 PASS 1/1 |
| NaiveResample | A | pitch_0@1 | 0.917 PASS 1/1 | 0.899 PASS 1/1 |
| NaiveResample | A | pitch_0@2 | 1.024 PASS 1/1 | 0.776 PASS 1/1 |
| NaiveResample | I | pitch_+300@0.5 | 1.340 PASS 1/1 | 1.073 PASS 1/1 |
| NaiveResample | I | pitch_+300@1 | 1.412 PASS 1/1 | 1.086 PASS 1/1 |
| NaiveResample | I | pitch_+300@2 | 1.266 PASS 1/1 | 1.099 PASS 1/1 |
| NaiveResample | I | pitch_+600@0.5 | 1.144 PASS 1/1 | 1.112 PASS 1/1 |
| NaiveResample | I | pitch_+600@1 | 1.320 PASS 1/1 | 1.065 PASS 1/1 |
| NaiveResample | I | pitch_+600@2 | 1.385 PASS 1/1 | 0.594 FAIL 0/1 |
| NaiveResample | I | pitch_-300@0.5 | 1.104 PASS 1/1 | 0.932 PASS 1/1 |
| NaiveResample | I | pitch_-300@1 | 1.224 PASS 1/1 | 0.958 PASS 1/1 |
| NaiveResample | I | pitch_-300@2 | 1.318 PASS 1/1 | 1.040 PASS 1/1 |
| NaiveResample | I | pitch_-600@0.5 | 1.116 PASS 1/1 | 0.975 PASS 1/1 |
| NaiveResample | I | pitch_-600@1 | 0.984 PASS 1/1 | 0.932 PASS 1/1 |
| NaiveResample | I | pitch_-600@2 | 1.320 PASS 1/1 | 1.065 PASS 1/1 |
| NaiveResample | I | pitch_0@0.5 | 1.533 PASS 1/1 | 1.063 PASS 1/1 |
| NaiveResample | I | pitch_0@1 | 1.273 PASS 1/1 | 1.144 PASS 1/1 |
| NaiveResample | I | pitch_0@2 | 1.324 PASS 1/1 | 1.157 PASS 1/1 |
| NaiveResample | L | pitch_+300@0.5 | 1.941 FAIL 0/1 | 0.982 PASS 1/1 |
| NaiveResample | L | pitch_+300@1 | 1.243 PASS 1/1 | 0.950 PASS 1/1 |
| NaiveResample | L | pitch_+300@2 | 1.359 PASS 1/1 | 0.922 PASS 1/1 |
| NaiveResample | L | pitch_+600@0.5 | 1.898 FAIL 0/1 | 0.939 PASS 1/1 |
| NaiveResample | L | pitch_+600@1 | 1.372 PASS 1/1 | 0.932 PASS 1/1 |
| NaiveResample | L | pitch_+600@2 | 1.913 FAIL 0/1 | 0.944 PASS 1/1 |
| NaiveResample | L | pitch_-300@0.5 | 1.050 PASS 1/1 | 0.989 PASS 1/1 |
| NaiveResample | L | pitch_-300@1 | 1.446 PASS 1/1 | 0.935 PASS 1/1 |
| NaiveResample | L | pitch_-300@2 | 2.031 FAIL 0/1 | 0.985 PASS 1/1 |
| NaiveResample | L | pitch_-600@0.5 | 1.225 PASS 1/1 | 1.000 PASS 1/1 |
| NaiveResample | L | pitch_-600@1 | 1.524 PASS 1/1 | 0.952 PASS 1/1 |
| NaiveResample | L | pitch_-600@2 | 1.372 PASS 1/1 | 0.932 PASS 1/1 |
| NaiveResample | L | pitch_0@0.5 | 1.555 PASS 1/1 | 0.993 PASS 1/1 |
| NaiveResample | L | pitch_0@1 | 2.057 FAIL 0/1 | 1.005 PASS 1/1 |
| NaiveResample | L | pitch_0@2 | 1.462 PASS 1/1 | 1.019 PASS 1/1 |
| NaiveResample | M | pitch_+300@0.5 | 1.800 FAIL 0/1 | 1.025 PASS 1/1 |
| NaiveResample | M | pitch_+300@1 | 1.779 FAIL 0/1 | 0.997 PASS 1/1 |
| NaiveResample | M | pitch_+300@2 | 1.874 FAIL 0/1 | 1.007 PASS 1/1 |
| NaiveResample | M | pitch_+600@0.5 | 1.730 FAIL 0/1 | 1.057 PASS 1/1 |
| NaiveResample | M | pitch_+600@1 | 1.856 FAIL 0/1 | 0.972 PASS 1/1 |
| NaiveResample | M | pitch_+600@2 | 2.016 FAIL 0/1 | 1.028 PASS 1/1 |
| NaiveResample | M | pitch_-300@0.5 | 1.260 PASS 1/1 | 1.048 PASS 1/1 |
| NaiveResample | M | pitch_-300@1 | 1.365 PASS 1/1 | 1.010 PASS 1/1 |
| NaiveResample | M | pitch_-300@2 | 2.118 FAIL 0/1 | 0.996 PASS 1/1 |
| NaiveResample | M | pitch_-600@0.5 | 1.212 PASS 1/1 | 1.023 PASS 1/1 |
| NaiveResample | M | pitch_-600@1 | 1.032 PASS 1/1 | 1.076 PASS 1/1 |
| NaiveResample | M | pitch_-600@2 | 1.856 FAIL 0/1 | 0.972 PASS 1/1 |
| NaiveResample | M | pitch_0@0.5 | 2.048 FAIL 0/1 | 1.054 PASS 1/1 |
| NaiveResample | M | pitch_0@1 | 2.067 FAIL 0/1 | 1.016 PASS 1/1 |
| NaiveResample | M | pitch_0@2 | 2.155 FAIL 0/1 | 1.090 PASS 1/1 |
| TDPSOLA2-g0.3 | A | pitch_+300@0.5 | 0.697 PASS 8/8 | 0.818 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+300@1 | 0.849 PASS 8/8 | 0.982 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+300@2 | 0.810 PASS 8/8 | 0.805 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+600@0.5 | 0.668 PASS 8/8 | 0.942 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+600@1 | 0.775 PASS 8/8 | 0.960 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_+600@2 | 0.883 PASS 8/8 | 0.877 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-300@0.5 | 0.811 PASS 8/8 | 0.723 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-300@1 | 1.121 PASS 8/8 | 0.897 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-300@2 | 0.838 PASS 8/8 | 0.644 PASS 6/8 |
| TDPSOLA2-g0.3 | A | pitch_-600@0.5 | 0.868 PASS 8/8 | 0.692 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-600@1 | 1.042 PASS 8/8 | 0.703 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_-600@2 | 1.066 PASS 8/8 | 0.584 FAIL 3/8 |
| TDPSOLA2-g0.3 | A | pitch_0@0.5 | 0.696 PASS 8/8 | 0.723 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_0@1 | 1.170 PASS 8/8 | 0.966 PASS 8/8 |
| TDPSOLA2-g0.3 | A | pitch_0@2 | 0.997 PASS 8/8 | 0.695 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+300@0.5 | 0.952 PASS 8/8 | 0.990 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+300@1 | 1.128 PASS 8/8 | 1.311 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+300@2 | 1.145 PASS 8/8 | 1.230 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+600@0.5 | 0.928 PASS 8/8 | 1.147 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+600@1 | 1.120 PASS 8/8 | 1.183 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_+600@2 | 1.315 PASS 8/8 | 1.356 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-300@0.5 | 0.926 PASS 8/8 | 0.847 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-300@1 | 1.223 PASS 8/8 | 0.984 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-300@2 | 1.610 FAIL 4/8 | 0.950 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-600@0.5 | 0.898 PASS 8/8 | 0.842 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-600@1 | 1.295 PASS 8/8 | 0.877 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_-600@2 | 1.563 PASS 8/8 | 0.911 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_0@0.5 | 0.832 PASS 8/8 | 0.908 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_0@1 | 0.955 PASS 8/8 | 1.209 PASS 8/8 |
| TDPSOLA2-g0.3 | I | pitch_0@2 | 1.152 PASS 8/8 | 1.032 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+300@0.5 | 0.840 PASS 8/8 | 0.826 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+300@1 | 1.288 PASS 8/8 | 1.050 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+300@2 | 1.098 PASS 8/8 | 0.828 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+600@0.5 | 0.759 PASS 8/8 | 0.882 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+600@1 | 1.038 PASS 8/8 | 1.024 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_+600@2 | 1.323 PASS 8/8 | 0.980 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-300@0.5 | 1.007 PASS 8/8 | 0.712 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-300@1 | 1.447 PASS 8/8 | 0.831 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-300@2 | 1.379 PASS 8/8 | 0.666 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-600@0.5 | 1.103 PASS 8/8 | 0.693 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-600@1 | 1.396 PASS 8/8 | 0.758 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_-600@2 | 1.393 PASS 8/8 | 0.596 FAIL 4/8 |
| TDPSOLA2-g0.3 | L | pitch_0@0.5 | 0.848 PASS 8/8 | 0.739 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_0@1 | 1.037 PASS 8/8 | 1.016 PASS 8/8 |
| TDPSOLA2-g0.3 | L | pitch_0@2 | 0.810 PASS 8/8 | 0.753 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+300@0.5 | 0.903 PASS 8/8 | 0.994 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+300@1 | 1.058 PASS 8/8 | 1.134 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+300@2 | 1.196 PASS 8/8 | 1.035 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+600@0.5 | 1.099 PASS 8/8 | 1.080 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+600@1 | 1.163 PASS 8/8 | 1.128 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_+600@2 | 1.192 PASS 8/8 | 1.148 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-300@0.5 | 0.871 PASS 8/8 | 0.761 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-300@1 | 1.246 PASS 8/8 | 0.891 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-300@2 | 1.434 PASS 8/8 | 0.807 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-600@0.5 | 0.951 PASS 8/8 | 0.741 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-600@1 | 1.263 PASS 8/8 | 0.730 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_-600@2 | 1.423 PASS 8/8 | 0.748 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_0@0.5 | 0.721 PASS 8/8 | 0.911 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_0@1 | 1.162 PASS 8/8 | 1.039 PASS 8/8 |
| TDPSOLA2-g0.3 | M | pitch_0@2 | 1.165 PASS 8/8 | 0.958 PASS 8/8 |
| ours | A | pitch_+300@0.5 | 0.603 PASS 1/1 | 0.549 FAIL 0/1 |
| ours | A | pitch_+300@1 | 1.040 PASS 1/1 | 0.957 PASS 1/1 |
| ours | A | pitch_+300@2 | 1.029 PASS 1/1 | 0.907 PASS 1/1 |
| ours | A | pitch_+600@0.5 | 0.520 FAIL 0/1 | 0.556 FAIL 0/1 |
| ours | A | pitch_+600@1 | 0.881 PASS 1/1 | 0.946 PASS 1/1 |
| ours | A | pitch_+600@2 | 1.107 PASS 1/1 | 0.957 PASS 1/1 |
| ours | A | pitch_-300@0.5 | 0.652 PASS 1/1 | 0.545 FAIL 0/1 |
| ours | A | pitch_-300@1 | 0.784 PASS 1/1 | 0.883 PASS 1/1 |
| ours | A | pitch_-300@2 | 0.760 PASS 1/1 | 0.673 PASS 1/1 |
| ours | A | pitch_-600@0.5 | 0.604 PASS 1/1 | 0.534 FAIL 0/1 |
| ours | A | pitch_-600@1 | 0.803 PASS 1/1 | 0.704 PASS 1/1 |
| ours | A | pitch_-600@2 | 0.912 PASS 1/1 | 0.536 FAIL 0/1 |
| ours | A | pitch_0@0.5 | 0.616 PASS 1/1 | 0.542 FAIL 0/1 |
| ours | A | pitch_0@1 | 0.875 PASS 1/1 | 0.965 PASS 1/1 |
| ours | A | pitch_0@2 | 0.862 PASS 1/1 | 0.724 PASS 1/1 |
| ours | I | pitch_+300@0.5 | 0.754 PASS 1/1 | 0.775 PASS 1/1 |
| ours | I | pitch_+300@1 | 0.848 PASS 1/1 | 1.188 PASS 1/1 |
| ours | I | pitch_+300@2 | 1.030 PASS 1/1 | 1.383 PASS 1/1 |
| ours | I | pitch_+600@0.5 | 0.698 PASS 1/1 | 0.787 PASS 1/1 |
| ours | I | pitch_+600@1 | 0.904 PASS 1/1 | 1.206 PASS 1/1 |
| ours | I | pitch_+600@2 | 1.090 PASS 1/1 | 1.570 PASS 1/1 |
| ours | I | pitch_-300@0.5 | 0.810 PASS 1/1 | 0.749 PASS 1/1 |
| ours | I | pitch_-300@1 | 1.033 PASS 1/1 | 1.082 PASS 1/1 |
| ours | I | pitch_-300@2 | 1.255 PASS 1/1 | 1.052 PASS 1/1 |
| ours | I | pitch_-600@0.5 | 0.757 PASS 1/1 | 0.724 PASS 1/1 |
| ours | I | pitch_-600@1 | 1.128 PASS 1/1 | 0.894 PASS 1/1 |
| ours | I | pitch_-600@2 | 1.336 PASS 1/1 | 0.907 PASS 1/1 |
| ours | I | pitch_0@0.5 | 0.749 PASS 1/1 | 0.654 PASS 1/1 |
| ours | I | pitch_0@1 | 1.045 PASS 1/1 | 1.220 PASS 1/1 |
| ours | I | pitch_0@2 | 1.255 PASS 1/1 | 1.072 PASS 1/1 |
| ours | L | pitch_+300@0.5 | 0.684 PASS 1/1 | 0.526 FAIL 0/1 |
| ours | L | pitch_+300@1 | 0.792 PASS 1/1 | 0.984 PASS 1/1 |
| ours | L | pitch_+300@2 | 1.190 PASS 1/1 | 0.936 PASS 1/1 |
| ours | L | pitch_+600@0.5 | 0.643 PASS 1/1 | 0.516 FAIL 0/1 |
| ours | L | pitch_+600@1 | 0.881 PASS 1/1 | 0.951 PASS 1/1 |
| ours | L | pitch_+600@2 | 1.306 PASS 1/1 | 1.145 PASS 1/1 |
| ours | L | pitch_-300@0.5 | 0.888 PASS 1/1 | 0.580 FAIL 0/1 |
| ours | L | pitch_-300@1 | 1.302 PASS 1/1 | 0.873 PASS 1/1 |
| ours | L | pitch_-300@2 | 1.314 PASS 1/1 | 0.746 PASS 1/1 |
| ours | L | pitch_-600@0.5 | 0.988 PASS 1/1 | 0.563 FAIL 0/1 |
| ours | L | pitch_-600@1 | 1.267 PASS 1/1 | 0.665 PASS 1/1 |
| ours | L | pitch_-600@2 | 1.207 PASS 1/1 | 0.680 PASS 1/1 |
| ours | L | pitch_0@0.5 | 0.692 PASS 1/1 | 0.601 PASS 1/1 |
| ours | L | pitch_0@1 | 0.959 PASS 1/1 | 1.034 PASS 1/1 |
| ours | L | pitch_0@2 | 0.914 PASS 1/1 | 0.819 PASS 1/1 |
| ours | M | pitch_+300@0.5 | 0.629 PASS 1/1 | 0.640 PASS 1/1 |
| ours | M | pitch_+300@1 | 0.980 PASS 1/1 | 1.060 PASS 1/1 |
| ours | M | pitch_+300@2 | 1.258 PASS 1/1 | 1.174 PASS 1/1 |
| ours | M | pitch_+600@0.5 | 0.560 FAIL 0/1 | 0.573 FAIL 0/1 |
| ours | M | pitch_+600@1 | 0.840 PASS 1/1 | 0.973 PASS 1/1 |
| ours | M | pitch_+600@2 | 1.127 PASS 1/1 | 1.159 PASS 1/1 |
| ours | M | pitch_-300@0.5 | 0.847 PASS 1/1 | 0.589 FAIL 0/1 |
| ours | M | pitch_-300@1 | 1.273 PASS 1/1 | 0.871 PASS 1/1 |
| ours | M | pitch_-300@2 | 1.629 FAIL 0/1 | 0.816 PASS 1/1 |
| ours | M | pitch_-600@0.5 | 0.953 PASS 1/1 | 0.555 FAIL 0/1 |
| ours | M | pitch_-600@1 | 1.292 PASS 1/1 | 0.714 PASS 1/1 |
| ours | M | pitch_-600@2 | 1.422 PASS 1/1 | 0.734 PASS 1/1 |
| ours | M | pitch_0@0.5 | 0.704 PASS 1/1 | 0.648 PASS 1/1 |
| ours | M | pitch_0@1 | 1.157 PASS 1/1 | 1.060 PASS 1/1 |
| ours | M | pitch_0@2 | 1.590 PASS 1/1 | 1.069 PASS 1/1 |
| r31 | A | pitch_+300@0.5 | 0.707 PASS 8/8 | 0.848 PASS 8/8 |
| r31 | A | pitch_+300@1 | 0.860 PASS 8/8 | 1.022 PASS 8/8 |
| r31 | A | pitch_+300@2 | 0.843 PASS 8/8 | 0.830 PASS 8/8 |
| r31 | A | pitch_+600@0.5 | 0.704 PASS 8/8 | 1.008 PASS 8/8 |
| r31 | A | pitch_+600@1 | 0.820 PASS 8/8 | 1.029 PASS 8/8 |
| r31 | A | pitch_+600@2 | 0.885 PASS 8/8 | 0.921 PASS 8/8 |
| r31 | A | pitch_-300@0.5 | 0.801 PASS 8/8 | 0.680 PASS 8/8 |
| r31 | A | pitch_-300@1 | 1.080 PASS 8/8 | 0.864 PASS 8/8 |
| r31 | A | pitch_-300@2 | 0.818 PASS 8/8 | 0.616 PASS 6/8 |
| r31 | A | pitch_-600@0.5 | 0.859 PASS 8/8 | 0.606 PASS 4/8 |
| r31 | A | pitch_-600@1 | 1.029 PASS 8/8 | 0.636 PASS 7/8 |
| r31 | A | pitch_-600@2 | 1.034 PASS 8/8 | 0.543 FAIL 0/8 |
| r31 | A | pitch_0@0.5 | 0.696 PASS 8/8 | 0.723 PASS 8/8 |
| r31 | A | pitch_0@1 | 1.170 PASS 8/8 | 0.966 PASS 8/8 |
| r31 | A | pitch_0@2 | 0.997 PASS 8/8 | 0.695 PASS 8/8 |
| r31 | I | pitch_+300@0.5 | 0.999 PASS 8/8 | 1.022 PASS 8/8 |
| r31 | I | pitch_+300@1 | 1.094 PASS 8/8 | 1.313 PASS 8/8 |
| r31 | I | pitch_+300@2 | 1.171 PASS 8/8 | 1.256 PASS 8/8 |
| r31 | I | pitch_+600@0.5 | 1.008 PASS 8/8 | 1.283 PASS 8/8 |
| r31 | I | pitch_+600@1 | 1.208 PASS 8/8 | 1.440 PASS 8/8 |
| r31 | I | pitch_+600@2 | 1.413 PASS 8/8 | 1.527 PASS 6/8 |
| r31 | I | pitch_-300@0.5 | 0.923 PASS 8/8 | 0.796 PASS 8/8 |
| r31 | I | pitch_-300@1 | 1.233 PASS 8/8 | 0.963 PASS 8/8 |
| r31 | I | pitch_-300@2 | 1.627 FAIL 3/8 | 0.883 PASS 8/8 |
| r31 | I | pitch_-600@0.5 | 0.829 PASS 8/8 | 0.722 PASS 8/8 |
| r31 | I | pitch_-600@1 | 1.235 PASS 8/8 | 0.725 PASS 8/8 |
| r31 | I | pitch_-600@2 | 1.449 PASS 8/8 | 0.789 PASS 8/8 |
| r31 | I | pitch_0@0.5 | 0.832 PASS 8/8 | 0.908 PASS 8/8 |
| r31 | I | pitch_0@1 | 0.955 PASS 8/8 | 1.209 PASS 8/8 |
| r31 | I | pitch_0@2 | 1.152 PASS 8/8 | 1.032 PASS 8/8 |
| r31 | L | pitch_+300@0.5 | 0.867 PASS 8/8 | 0.817 PASS 8/8 |
| r31 | L | pitch_+300@1 | 1.282 PASS 8/8 | 1.035 PASS 8/8 |
| r31 | L | pitch_+300@2 | 1.075 PASS 8/8 | 0.853 PASS 8/8 |
| r31 | L | pitch_+600@0.5 | 0.815 PASS 8/8 | 0.954 PASS 8/8 |
| r31 | L | pitch_+600@1 | 1.089 PASS 8/8 | 1.070 PASS 8/8 |
| r31 | L | pitch_+600@2 | 1.282 PASS 8/8 | 1.023 PASS 8/8 |
| r31 | L | pitch_-300@0.5 | 1.008 PASS 8/8 | 0.644 PASS 8/8 |
| r31 | L | pitch_-300@1 | 1.446 PASS 8/8 | 0.775 PASS 8/8 |
| r31 | L | pitch_-300@2 | 1.369 PASS 8/8 | 0.624 PASS 5/8 |
| r31 | L | pitch_-600@0.5 | 1.090 PASS 8/8 | 0.592 FAIL 3/8 |
| r31 | L | pitch_-600@1 | 1.363 PASS 8/8 | 0.708 PASS 8/8 |
| r31 | L | pitch_-600@2 | 1.362 PASS 8/8 | 0.555 FAIL 0/8 |
| r31 | L | pitch_0@0.5 | 0.848 PASS 8/8 | 0.739 PASS 8/8 |
| r31 | L | pitch_0@1 | 1.037 PASS 8/8 | 1.016 PASS 8/8 |
| r31 | L | pitch_0@2 | 0.810 PASS 8/8 | 0.753 PASS 8/8 |
| r31 | M | pitch_+300@0.5 | 0.911 PASS 8/8 | 1.015 PASS 8/8 |
| r31 | M | pitch_+300@1 | 1.064 PASS 8/8 | 1.157 PASS 8/8 |
| r31 | M | pitch_+300@2 | 1.199 PASS 8/8 | 1.052 PASS 8/8 |
| r31 | M | pitch_+600@0.5 | 1.126 PASS 8/8 | 1.112 PASS 8/8 |
| r31 | M | pitch_+600@1 | 1.186 PASS 8/8 | 1.167 PASS 8/8 |
| r31 | M | pitch_+600@2 | 1.219 PASS 8/8 | 1.114 PASS 8/8 |
| r31 | M | pitch_-300@0.5 | 0.876 PASS 8/8 | 0.712 PASS 8/8 |
| r31 | M | pitch_-300@1 | 1.270 PASS 8/8 | 0.853 PASS 8/8 |
| r31 | M | pitch_-300@2 | 1.469 PASS 8/8 | 0.749 PASS 8/8 |
| r31 | M | pitch_-600@0.5 | 0.905 PASS 8/8 | 0.654 PASS 8/8 |
| r31 | M | pitch_-600@1 | 1.213 PASS 8/8 | 0.705 PASS 8/8 |
| r31 | M | pitch_-600@2 | 1.386 PASS 8/8 | 0.674 PASS 7/8 |
| r31 | M | pitch_0@0.5 | 0.721 PASS 8/8 | 0.911 PASS 8/8 |
| r31 | M | pitch_0@1 | 1.162 PASS 8/8 | 1.039 PASS 8/8 |
| r31 | M | pitch_0@2 | 1.165 PASS 8/8 | 0.958 PASS 8/8 |

