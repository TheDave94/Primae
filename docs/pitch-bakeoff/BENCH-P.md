# BENCH-P: pitch bake-off phase 2 harness + `ours` baseline (2026-11-24)

Branch `t3/pitch-bakeoff-bench-harness` off origin/main `584aec27`. Commits (unsigned, not pushed):
`f9981dee` harness + scenario/metric API (= BENCH-P-api.patch) and `73833bc3` fixes from the first iPad run.
**Siblings on the API patch: apply BENCH-P.patch's second commit too** (attack exclusion in lag metrics,
`traj_attack_rms_cents`, level-matched self-test). Two signature tweaks: `protocolInit` now requires
`T: SonificationRenderer & SendableMetatype`; `pitchSources(letters: [String]? = nil)`.

## What was built (BAKEOFF-PITCH section 4)
- `PrimaeNative/Core/Sonification/BakeoffCandidates.swift`: one registration list. `BakeoffCandidate(name:make:)`
  gets the full production `SonificationSource` (samples, kind, gain, onset); `.protocolInit(T.self)` for bare
  conformers. `ours` = `LiveSonificationAudio.makeRenderer` exactly as shipped (r27). Lanes append below the marker.
- `PrimaeNativeTests/SonificationBakeoff/`: PitchScenarios (held 0/-600/-300/+300/+600 c x rates 0.5/1/2; steps
  0->+600, 0->-600, +600->-600 at 1.0 s; triangle sweep +-600 c, 0.75 s legs; gate cycle; height trajectory via
  `PitchCoupling(.both, 1200)`), PitchMetrics (Swift ports of `metrics_r27`: true-envelope cepstral lifter, warp
  alpha, LSD and frame-wise LSD, YIN F0, mark-chained jitter/shimmer, F wobble/ACF/level, local click ratio),
  PitchGates (section 3 thresholds; `praatLSD` table), PitchRunner (rows + gates.csv), PitchMetricSelfTests (12).
- Bench modes `PRIMAE_BAKEOFF=pitch|pitch-quick|full|quick`; output Documents/bakeoff/{bench,gates}.csv,
  run_info.json, renders/<cand>/<L>__<c>c.wav (+ `__traj`, `__height`), float32, times the loudness gain.
- scripts/pitch_bakeoff/: calibrate_main.swift (Swift metrics vs phase-1 Python on the same WAVs), report.py
  (summary.md), collect.py (renders + phase-1 fixed columns into the MUSHRA root; refuses phase-1 `ours`).

## Calibration (Swift vs phase-1 Python, same WAVs)
env_warp identical; env_lsd max |d| 0.002 dB; frame LSD max 0.013 dB; level matches. F0 (YIN vs Praat AC):
median |d| 0.24 c, p90 0.86 c, max 5.1 c (A, world +600). Jitter ratio median |d| 0.115; shimmer ratio median
|d| 0.067, p90 0.25 (absolute shimmer reads higher than Praat on A).

## iPad runs (iPad13,8, iOS 27.3, Release-Study + ENABLE_TESTABILITY, bench 63 s)
GREEN, build of 73833bc3 (verbatim):
```
Executed 16 tests, with 0 failures (0 unexpected) in 0.329 (0.332) seconds
Executed 12 tests, with 0 failures (0 unexpected) in 4.115 (4.117) seconds
Executed 1 test, with 0 failures (0 unexpected) in 63.049 (63.049) seconds
Executed 29 tests, with 0 failures (0 unexpected) in 67.492 (67.499) seconds
** TEST EXECUTE SUCCEEDED **
```
Mutation round 1 (M1-M10, dropped WIP): `Executed 12 tests, with 19 failures (0 unexpected) in 4.516 (4.519) seconds`
Mutation round 2 (M11-M12, dropped WIP): `Executed 12 tests, with 2 failures (0 unexpected) in 4.258 (4.261) seconds` (exactly the two targeted tests)

| mutation | test that went RED |
|---|---|
| M1 warp pinned to 1 | Warp..., EnvelopeMetricsOnTheStudyPhonemes... |
| M2 F0 measured against the source | F0GateFails... |
| M3 level z - z | LevelGateFails... |
| M4 periods = YIN guess | PerturbationRecovers... (jitter 0.19 vs 1.03) |
| M5 wobble fold period - 1 | FMetricsSee... (0.395 dB) |
| M6 ACF lag + 1 | FMetricsSee... (0.003) |
| M7 click p99.9 -> p100 | SweepClickRatio... (ratio 1.0) |
| M8 step time + 30 ms | StepGateSees... |
| M9 command + 25 ms | SweepLagGate... (22.5 ms) |
| M10 frame-wise LSD es = xs | FramewiseLSD... |
| M11 jitter ratio source/source | MicroVariationGateFails... ("WORLD-like regularity must fail (jitter)") |
| M12 export name loses the sign | ScenarioSetAndExportNames ("A__600c.wav" vs "A__+600c.wav") |

All 12 self-tests are load-bearing: each went RED under at least one mutation, and every metric/gate family was mutated.

## Baseline gates (PASS / total)
| gate | ours | NaiveResample |
|---|---|---|
| env_lsd_vs_praat | 28/60 | 1/60 |
| env_warp | 60/60 | 5/60 |
| f0_within_5c | 60/60 | 20/60 |
| jitter_ratio | 54/60 | 49/60 |
| shimmer_ratio | 48/60 | 58/60 |
| level_flat | 36/48 | 48/48 |
| f_wobble / f_level / f_comb | 0/12, 0/12, 0/6 | 12/12, 2/12, 6/6 |
| pitch_step_90 | 36/36 | 25/36 |
| traj_pitch_lag | 16/16 | 8/16 |
| step / sweep / traj click | 45/45, 15/15, 5/5 | same |

`ours`, rate 1, held (f0 err c / alpha / LSD dB / level dB):
| | -600 | -300 | +300 | +600 |
|---|---|---|---|---|
| A | -4.4 / 1.02 / 1.88 / -2.12 | -3.0 / 0.99 / 2.19 / -0.70 | -3.2 / 1.005 / 1.13 / -0.14 | -4.1 / 1.005 / 1.39 / -0.35 |
| I | 1.4 / 1.00 / 1.64 / -2.59 | 1.4 / 1.005 / 3.90 / -0.74 | 0.9 / 1.015 / 4.70 / -0.30 | 1.2 / 1.025 / 5.36 / -0.86 |
| L | 2.4 / 1.005 / 1.51 / -2.24 | 1.4 / 1.015 / 2.59 / -0.79 | 2.0 / 1.015 / 2.74 / -0.14 | 2.1 / 1.02 / 3.67 / -0.31 |
| M | 1.3 / 1.00 / 1.16 / -2.63 | 1.3 / 1.01 / 1.63 / -0.72 | 1.3 / 1.005 / 1.79 / -0.25 | 1.2 / 1.00 / 1.90 / -0.77 |
| F | alpha 0.68, wobble 3.19 dB, lvl -1.93 | 0.825, 3.11, -1.95 | 1.205, 2.87, -1.93, acf 0.275 | 1.41, 3.16, -1.90, acf 0.389 |

Where `ours` fails: env LSD vs 1.2x Praat (A 9, I 12, L 6, M 5; worst I +300/+600, 4.7/5.4 dB);
level_flat at -600 on every voiced phoneme (-2.1 to -2.6 dB) at every rate; F fails all three F gates
(no envelope-preserving path for the fricative; matches r27); shimmer/jitter below 0.6x only at rate 0.5
(12 shimmer, 5 jitter: halved-speed playback repeats grains, smoothing period-to-period variation) plus M jitter
1.61x at rate 2. Control: step90 7.3-13.3 ms (A 0->+600 @1: 9.3 ms), sweep/traj lag 0-7.5 ms, rms 6-14 c,
click ratio <= 1.69. Onset 1.5 ms (A gate cycle) to 20.7 ms (L).
CPU (iPad, per 256 frames): voiced median ~3.4 us, max 3.6-29 us; F median 8.4 us, max up to 18.7 us; p99
median 3.8 us. init 47-90 ms (median 49), footprint delta -1.2..+2.1 MB.

Renders: `primae-pitch-sota/renders/{ours,NaiveResample}/` (35 each) + the phase-1 fixed columns, via collect.py.
## How to run (supervisor-serialised; bare xcodebuild/xcrun, nothing before or after)
```
xcodebuild build-for-testing -project Primae/Primae.xcodeproj -scheme Primae -configuration Release-Study \
  -destination "platform=iOS,id=<UDID>" -allowProvisioningUpdates -derivedDataPath /tmp/dd-pitch-<LANE> \
  ENABLE_TESTABILITY=YES -quiet
# copy Build/Products/*.xctestrun to a writable path; replace __TESTROOT__ with the absolute Products dir;
# add EnvironmentVariables PRIMAE_BAKEOFF=pitch (optional PRIMAE_BAKEOFF_CANDIDATES=ours,<Name>) under the
# PrimaeNativeTests target (plutil -insert ... or python plistlib)
xcodebuild test-without-building -xctestrun <file> -destination "platform=iOS,id=<UDID>" \
  -only-testing:PrimaeNativeTests/SonificationBakeoffBench -resultBundlePath <path>.xcresult
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier com.flamingistan.primae.study --source Documents/bakeoff --destination <dir>
python3 scripts/pitch_bakeoff/report.py <dir>; python3 scripts/pitch_bakeoff/collect.py <dir> <renders root> --phase1 <wav>
```

## Open risks
1. The shipped engine plays each stroke's recorded attack UNSHIFTED (A: first ~0.42 s at 0 c);
   `traj_attack_rms_cents` 359-595 c. Lag metrics exclude attack+50 ms, so they do not see it; a candidate
   that shifts the attack is not rewarded by any gate. A ruling is needed on whether that is a defect.
2. F0 instrument: YIN vs Praat AC disagree up to ~5 c on A; `ours` A sits at -3 to -4.4 c, close to the 5 c gate.
3. Jitter/shimmer are waveform mark-based and cross-talk with formant placement; calibration is median-good,
   tail-poor (shimmer p90 0.25). Treat the micro-variation gates as coarse.
4. AppleTimePitch (r17 reference) was not re-applied; `full`/`quick` modes run without it.
5. The attack exclusion uses rate-1 attack timing at every rate.
6. `/tmp/dd-pitch-BENCH-P` (686 MB) is NOT deleted: the seat's sandbox denies /tmp writes for `rm`
   (`Operation not permitted`). Run `rm -rf /tmp/dd-pitch-BENCH-P` from a terminal.
7. Device: the test host now carries a Release-Study + testability build over the pilot artefact; the
   supervisor's clean-slate reinstall is required (not done by this lane, per brief).
8. `praatLSD` was measured in Swift on phase-1 praat_psola WAVs (Swift's own LSD), so the 1.2x gate compares
   like with like, but carries the phase-1 Praat settings.
