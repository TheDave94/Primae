# ENVGAP: why TDPSOLA2 (r31) misses `env_lsd_vs_praat <= 1.20x` Praat

Lane ENVGAP, 2026-11-28. Branch `t3/envgap-tdpsola2-candidates`, worktree
`/Users/musicbox/.t3/worktrees/Primae/t3-f61bf2ab-b717a60b43821cb5`. Offline `swiftc -O` macOS harness only (no Xcode
project, no iPad, no lock). Every number below is MEASURED in this lane unless it is marked otherwise.

## Verdict

| candidate | listed cells, every seed, both rates | other gates, every seed | controls still fail | qualifies |
|---|---|---|---|---|
| C1 `wideUpshiftWindow` (item 9) | I +600 all fixed; A cells not | **21 new median FAILs per rate** (A/L/M upshift env_lsd, L env_warp, letter means, I +600@2 shimmer at 48k) | yes | **no** |
| C2 `downshiftWindowScale` (item 10) | A -600@1 1.204 at best (seed 0, 48k) | (not carried to a full run: the axis is exhausted, see below) | yes | **no** (abandoned) |
| C3 `extremumPhaseAlign` + `extremumPhaseMinOffset 0.025` (item 11, "C3-xphase-d") | **I +600 @0.5/@1/@2: 8/8 seeds at both rates**; A cells unchanged (A is bit-identical to r31) | none new except BENCH-owned I -300@2 jitter: 48k median 1.5952 PASS 5/8 -> **1.6005 FAIL 4/8** (44.1k: 1.6267 FAIL 3/8 -> 1.5936 PASS 4/8) | yes | **no** |

**No candidate qualifies.** C3-xphase-d is the I fix. It turns I +600 from 0/8 seeds to 8/8 seeds at every rate,
and at both sample rates, with margin (4.36–4.45 against a limit of 5.19/5.22). It moves no other letter. It
does not close the A cells, and they cannot be closed in the shifter (§3). At 48k it pushes the BENCH-owned I -300@2
jitter median 0.005 over its limit; the seed ranges overlap (r31 1.506–1.673, C3-d 1.514–1.615).

## 1. Method and harness validation

- `scripts/envgap_harness/build.sh` compiles the production DSP as module `PrimaeNative` (Swift 6,
  `-default-isolation MainActor`, `-D STUDY_BUILD`, as `Package.swift`). The sources are SonificationRenderer/Source,
  StrokeEnvelopeTuning, PhonemeOnsets, Atomics, TDPSOLA/*, TDPSOLA2/*, PitchCoupling and AudioEngine+Loudness, plus
  `shim/Shims.swift`. The shim holds only bundle lookup and verbatim copies of the `LiveSonificationAudio` /
  `LiveSonificationKernel` / `SpatialSonification` constants. The build adds BENCH's metric files as module `Bench`.
- BENCH's metric files were copied fresh from the BENCH tree (read-only, never written). Their sha256 values are in
  `scripts/envgap_harness/bench/BENCH_SOURCE_SHA256.txt` and include `PitchRunner.swift` with the zeroF0 guard.
  BENCH's `noiseSeedXor` patch is applied to `TDPSOLA2.swift` together with its test (`noiseSeedXorKnob`).
- `main.swift` is a port of `SonificationBakeoffBench.runPitch`: 8 seeds, the per-cell `cellSeedXor`, and the median
  over seeds.
- **The harness reproduces BENCH exactly.**
  - r31 at 48k: PASS 486 / FAIL 5. At 44.1k: PASS 488 / FAIL 3.
  - The failing and partial-seed cells are exactly the supervisor's list, plus the BENCH-owned I -300@2 jitter and
    I traj_attack at 44.1k (table §2).
- **Praat reference reproduced.** `praat_psola.praat` runs To Manipulation 0.01 75 600 -> Multiply frequencies ->
  overlap-add resynthesis, in Praat 7 run headless. For I +600 at 48k it gives 4.3268, against 4.327 in
  `PitchGates.praatLSD48k`.

## 2. Baseline (r31 = `TDPSOLA2Options.production`) and controls, 8 seeds

| | 48 kHz | 44.1 kHz |
|---|---|---|
| r31 | 486 / 5 | 488 / 3 |
| ours (r28) | 409 / 82 | 412 / 79 |
| TDPSOLA2-g0.3 | 390 / 101 | 389 / 102 |
| NaiveResample | 298 / 193 | 295 / 196 |

The controls are untouched by every ENVGAP flag, so they fail identically in every candidate run.

r31 rows that FAIL, or that pass with failing seeds:

| rate | cell | gate | median | limit | seeds |
|---|---|---|---|---|---|
| 48k | A -600@0.5 | env_lsd_vs_praat | 1.1857 | 1.211 | 7/8 |
| 48k | A +300@0.5 | env_lsd_vs_praat | 1.3201 F | 1.315 | 3/8 |
| 48k | A -600@1 | env_lsd_vs_praat | 1.2215 F | 1.211 | 4/8 |
| 48k | I +600@0.5 / @1 / @2 | env_lsd_vs_praat | 5.281 / 5.263 / 5.407 F | 5.192 | 0/8 each |
| 48k | I -300@2 (BENCH) | jitter_ratio | 1.5952 | 0.6–1.6 | 5/8 |
| 44.1k | A -600@1 | env_lsd_vs_praat | 1.1302 | 1.150 | 5/8 |
| 44.1k | I +600@0.5 | env_lsd_vs_praat | 5.2223 | 5.222 | 4/8 |
| 44.1k | I +600@2 | env_lsd_vs_praat | 5.3421 F | 5.222 | 0/8 |
| 44.1k | I -300@2 (BENCH) | jitter_ratio | 1.6267 F | 0.6–1.6 | 3/8 |
| 44.1k | I traj_I_height (BENCH) | traj_attack | 5.172 F | 5.0 c | 0/8 |

## 3. Diagnosis

### 3.1 Ablations: one item off at a time (A and I, 8 seeds, env_lsd_vs_praat median and seeds passing)

48 kHz:

| candidate | A +300@0.5 | A -600@0.5 | A -600@1 | I +600@0.5 | I +600@1 | I +600@2 |
|---|---|---|---|---|---|---|
| r31 | 1.320 (3/8) F | 1.186 (7/8) | 1.222 (4/8) F | 5.281 (0/8) F | 5.263 (0/8) F | 5.407 (0/8) F |
| −item 2 cap | 1.320 (3/8) F | 2.420 (0/8) F | 2.509 (0/8) F | 5.281 (0/8) F | 5.263 (0/8) F | 5.407 (0/8) F |
| −item 4 H/N swap | 1.209 (1/1) | 1.205 (1/1) | 1.220 (0/1) F | 5.272 (0/1) F | 5.240 (0/1) F | 5.413 (0/1) F |
| −item 5 GCI snap | 1.320 (3/8) F | 1.186 (7/8) | 1.222 (4/8) F | 5.617 (0/8) F | 5.601 (0/8) F | 5.732 (0/8) F |
| −item 3 pulse density | = r31 | = r31 | = r31 | = r31 | = r31 | = r31 |
| −item 8 level | = r31 | = r31 | = r31 | = r31 | = r31 | = r31 |
| −item 7 shifted attack | 1.329 (2/8) F | 1.234 (1/8) F | 1.239 (2/8) F | 5.278 (0/8) F | 5.268 (0/8) F | 5.422 (0/8) F |

44.1 kHz:

| candidate | A +300@0.5 | A -600@0.5 | A -600@1 | I +600@0.5 | I +600@1 | I +600@2 |
|---|---|---|---|---|---|---|
| r31 | 1.303 (8/8) | 1.113 (8/8) | 1.130 (5/8) | 5.222 (4/8) | 5.210 (8/8) | 5.342 (0/8) F |
| −item 2 cap | 1.303 (8/8) | 2.279 (0/8) F | 2.477 (0/8) F | 5.222 (4/8) | 5.210 (8/8) | 5.342 (0/8) F |
| −item 4 H/N swap | 1.219 (1/1) | 1.109 (1/1) | 1.165 (0/1) F | 5.222 (1/1) | 5.190 (1/1) | 5.350 (0/1) F |
| −item 5 GCI snap | 1.303 (8/8) | 1.113 (8/8) | 1.130 (5/8) | 5.654 (0/8) F | 5.649 (0/8) F | 5.810 (0/8) F |
| −item 3 / −item 8 | = r31 | = r31 | = r31 | = r31 | = r31 | = r31 |
| −item 7 shifted attack | 1.333 (8/8) | 1.176 (1/8) F | 1.151 (4/8) F | 5.228 (2/8) F | 5.217 (5/8) | 5.345 (0/8) F |

Without item 4 the render is deterministic, so a single seed is shown. New failures each ablation causes elsewhere
(both rates):

- −item 2 breaks downshift: A -600 (2.28–2.51) and I -600 (3.77–4.77).
- −item 4 breaks A's jitter and shimmer at 0.5 (0.47–0.59 < 0.6), and A -600@1 env at 44.1k.
- −item 5 breaks I -600@0.5/@1 env (3.16–3.34) and I +300@0.5 (5.77–5.79).
- −item 8 breaks I +600 level_flat (−1.51 dB).
- −item 7 adds A -600@0.5 (and at 44.1k A -600@1 and I +600@0.5).
- −item 3: no change.

**Reading.** No item causes either gap. Items 2, 4, 5, 7 and 8 each carry weight elsewhere. Item 3 is neutral here.
The A +300@0.5 failure at 48k is item 4's seed spread: without the noise it is 1.209 and passes, but jitter and
shimmer then fail. Both A -600 cells fail with or without item 4. The I +600 gap survives every ablation, and only
removing item 5 moves it, making it worse.

### 3.2 I +600: a phase error in the marks, not a window or a level error

- **Harmonics** (seed 0, 48k, `harm.py`): r31 notches harmonic 3 (1062 Hz) at −5.7 dB relative to the source
  envelope, where Praat's is +0.5 dB. The per-band LSD share (`bands.py`) puts the excess in the F1–F2 region around
  it.
- **Black-box window probe of Praat** (`praat_window_probe.py`, DC and an impulse train through
  `praat_psola.praat`):
  - On downshift, Praat uses Hann halves of half-width = one period. The window sum is 1.0, falling to 0.40
    mid-gap, which is the same as r31's item 2 cap.
  - On upshift, Praat's window sum is flat at 1.0, so its windows overlap more than r31's capped T/pf halves.
    That suggested C1.
- **Marks vs Praat's pulses** (`praat_pulses.praat`, `extremum_offset.py`): Praat's pulses lead our item-5 marks by
  I +0.049T, L +0.021T, M +0.015T and A +0.001T. The offsets of our marks to the waveform extremum they track are
  I +0.040, L +0.016, M +0.006 and A −0.017. GCI polarity is 1.0 for all letters. So I's marks sit 4–5 % of a period
  before the excitation peak. Praat anchors its pulses to a waveform extremum (documented).
- **Phase sweep** (probe `markPhaseShift`, seed-0 envdump, 48k, I +600@1; r31's 8-seed median is 5.263):
  - +0.05T gives 4.27 and +0.075T gives 4.19.
  - A fluctuates ±0.08, non-monotonically, around 0. A is already at its optimum.
  - So I's gap is the analysis-mark phase. A window narrower than the period (upshift) must be centred on the
    excitation peak, or it cuts the pulse and notches the low harmonics.

### 3.3 A: a floor in the loop and its preparation, not in the shifter

A -600@1 at 48k, seed 0, from the envdump FLOOR decomposition:

| comparison | LSD |
|---|---|
| shifted render vs its OWN 0 c render | **1.0085** (Praat: 1.009) |
| 0 c render vs the source steady segment (the gate's reference) | 0.545 (@0.5: 0.84) |
| raw loop range vs the steady segment | 0.120 |
| prepared loop (SEAM2 + TDQ declick) vs the raw loop | 0.279 |
| 0 c render vs the prepared loop | 0.516 (sample identity residual −39 dB) |

The shifter's own error on A equals Praat's. A +300@0.5 is the same: 0.97 vs Praat's 1.10. The 0.5 margin the gate
wants is spent before any shift, on the production loop design (loop choice, SEAM2/TDQ preparation and the 0 c path)
measured against the source's steady range. **No pitch-shifter option can close it**, and every window, density,
level and phase variant here confirms that (§3.1, C2, C3). Closing A's cells needs a change to the loop or its
preparation, which is outside this lane's scope (the shifter), or a ruling on whether the gate's reference should be
the prepared loop rather than the raw steady segment. **That is a spec question for the supervisor. ENVGAP has not
relaxed or reinterpreted the gate.**

## 4. Candidates

All candidates are `TDPSOLA2Options` flags, OFF in `.default`, `.production` and `.r27` (pinned by test). Each item's
doc comment cites Moulines & Charpentier 1990 (TD-PSOLA analysis windows and normalised OLA) and Praat's documented
extremum anchor. This is clean-room work: papers and public documentation only.

### C1: item 9 `wideUpshiftWindow` (does not qualify)

On upshift, each half-window is one source period, spawned early enough to start on time, and the OLA is normalised
by the window sum where it exceeds 1. I +600 passes 8/8 seeds at both rates (48k 4.05 / 4.06 / 4.11). Gates:
48k 470 / 21, 44.1k 470 / 21. The new failures, identical at both rates:

- A +300 and +600 at every rate.
- L +300 env_lsd and L +600 env_warp (1.044–1.047).
- M ±300/600 env_lsd (3.2–4.3 against 2.6).
- The letter-mean rows for A and M.
- I +600@2 shimmer at 48k (1.6405, 3/8).

On the BENCH rows: it leaves I -300@2 jitter unchanged and improves I traj_attack at 44.1k from 5.172 to 5.082
(still failing). Wide upshift windows reproduce Praat's flat window sum, but they smear every other letter's formant
structure. The I fix it shows is a side effect of covering the misplaced pulse, not the cause.

### C2: item 10 `downshiftWindowScale` (does not qualify, abandoned)

κ is applied to the downshift half-width. Seed 0, 48k, A -600@1 (r31 1.204):

- Symmetric κ < 1 is monotonically worse (κ 0.3 / 0.5 / 0.7 / 0.85 swept).
- κ > 1 is worse too.
- Applying κ to the left half only, at 0.85, gives 1.198: marginal and inside the seed spread.

κ = 1 is r31's item 2, so the window axis is exhausted. This agrees with §3.3: A's downshift error already equals
Praat's. The code stays behind its OFF flag for reproducibility.

### C3: item 11 `extremumPhaseAlign` (+ guard `extremumPhaseMinOffset`) (does not qualify; it is the I fix)

After item 5, every mark moves by the median offset to the waveform extremum it already tracks. The offset is
measured per loop mark to the max and to the min within ±T/2, and of the two medians the one nearer 0 is used. The
marks keep their spacing, so jitter is unchanged by construction. The loop bounds are re-derived as item 5 does.

- With no guard ("C3-xphase") it moves A too: A -600@1 becomes 1.247 at 48k (0/8) and 1.154 at 44.1k.
- With the guard at 0.025T ("C3-xphase-d"), only marks more than 2.5 % of a period off the extremum move. Only I
  qualifies (offset 0.040T). A, L and M stay bit-identical to r31.

| | 48k gates | 44.1k gates |
|---|---|---|
| C3-xphase | 489 / 2 | 489 / 2 |
| **C3-xphase-d** | **488 / 3** | **490 / 1** |

C3-xphase-d, rows that FAIL or pass with failing seeds:

| rate | cell | gate | median | seeds | vs r31 |
|---|---|---|---|---|---|
| 48k | A -600@0.5 | env_lsd_vs_praat | 1.1857 | 7/8 | identical |
| 48k | A +300@0.5 | env_lsd_vs_praat | 1.3201 F | 3/8 | identical |
| 48k | A -600@1 | env_lsd_vs_praat | 1.2215 F | 4/8 | identical |
| 48k | I -300@2 (BENCH) | jitter_ratio | 1.6005 F | 4/8 | was 1.5952 PASS 5/8 |
| 44.1k | A -600@1 | env_lsd_vs_praat | 1.1302 | 5/8 | identical |
| 44.1k | I -300@2 (BENCH) | jitter_ratio | 1.5936 | 4/8 | was 1.6267 FAIL 3/8 |
| 44.1k | I traj_I_height (BENCH) | traj_attack | 5.2183 F | 0/8 | was 5.172 F |

I +600 env_lsd_vs_praat under C3-xphase-d, 8/8 seeds everywhere:

| | @0.5 | @1 | @2 |
|---|---|---|---|
| 48k | 4.400 | 4.359 | 4.440 |
| 44.1k | 4.419 | 4.381 | 4.452 |

Limits are 5.192 and 5.222. Every other I row passes on every seed at both rates. At 48k, I traj_attack is
3.66 -> 4.09 c (PASS 8/8, limit 5.0).

Effect on the BENCH-owned rows:

- I -300@2 jitter moves +0.005 at 48k, across the limit, and −0.033 at 44.1k, back under it. The seed ranges
  straddle 1.6 in both runs, so this gate is seed-noise-bound at its limit.
- I traj_attack at 44.1k worsens by 0.046 c and still fails.

## 5. Bit-identity (flags OFF): proved offline

- **Offline hash proof.** `scripts/envgap_harness/build_hash.sh` was built twice: from the pre-ENVGAP TDPSOLA2
  sources (`git show HEAD:` at 612128f2, `T2DIR=...`, `HashFlagsNone.swift`) and from this branch. FNV-1a of 2 s
  renders was taken for A, F, I, L and M under 6 drives (0.8/+450, 1/−600, 2/+600, 0.5/0, 1/+600, 0.5/−300) with
  `.default` and `.production` at 44.1 kHz, and with production through the file-rate path at 48 kHz.
  - **35/35 rows are identical.** That covers default, production, production with every ENVGAP flag spelled out
    OFF, and the guard set alone.
  - The pinned `TDPSOLA2RenderHashTests` values (A 95b25a3e6fab38d8, F ef0be5da24eb9951, I 627436734ddf5942) come
    out of both builds.
  - With a flag ON, the render differs exactly where that flag acts: item 9 on the 3 upshift drives, item 10 on the
    2 downshift drives, and item 11 and the probe on all 6. F never changes.
- **In-repo test** `PrimaeNativeTests/Sonification/TDPSOLA2/TDPSOLA2EnvgapFlagTests.swift` (Swift Testing, 4 tests):
  - the shipped sets are OFF;
  - production's render hashes are pinned to 612128f2's for 5 letters × 6 drives;
  - production equals production with the flags spelled OFF;
  - each flag ON changes its target render.

  It was compiled and run offline against this branch's module, linked with Testing.framework through
  `__swiftPMEntryPoint`: `Test run with 4 tests in 1 suite passed`.
- **Mutation checks**, test count read from the log both times:
  - Item 9 forced on: `Test run with 4 tests in 1 suite failed`. The pinned hashes went RED for A, I and L, and the
    ON test went RED.
  - Item 11 forced on: `4 tests ... failed with 41 issues`.

  The first mutation also showed that the same-binary OFF==production comparison alone cannot catch a flag that is
  ignored everywhere. That is why the pinned hashes were added.
- `xcodebuild` was not run (out of lane scope). CI or the integration seat should run `PrimaeNativeTests` as usual.

## 6. Recommendation

1. **Do not ship any candidate as-is.** None qualifies under the rule (every listed cell on every seed at both rates,
   with every other gate holding).
2. **Take C3-xphase-d forward as the I fix.** Fold it into the I-side work together with BENCH's I -300@2 jitter work.
   It closes all four I +600 entries on the list (48k @0.5/@1/@2, 44.1k @2, plus the 44.1k @0.5 seed failures) at
   8/8 with margin, leaves A/L/M/F bit-identical, and is phase-only, so jitter is unchanged by construction. The one
   interaction is the noise-bound I -300@2 jitter gate, +0.005 at 48k and −0.033 at 44.1k. BENCH owns that gate. It
   needs to clear with margin on its own; otherwise C3-d's 48k nudge decides its colour.
3. **Surface A to the supervisor as a spec question, not a shifter task** (§3.3). The shifter's A error already equals
   Praat's. The gap is the 0 c loop/prep path against the source steady segment. The options are a loop and
   preparation change (SEAM2/TDQ, loop choice), which is a different lane with its own protocol weight, or a ruling on
   the gate's reference. ENVGAP does neither.

## Files

- `PrimaeNative/Core/Sonification/TDPSOLA2/TDPSOLA2.swift`: BENCH's `noiseSeedXor`; items 9, 10 and 11 plus the
  `markPhaseShift` probe, all OFF.
- `PrimaeNativeTests/Sonification/TDPSOLA2/TDPSOLA2EnvgapFlagTests.swift` (new) and
  `TDPSOLA2HarmonicNoiseTests.swift` (BENCH's `noiseSeedXorKnob`).
- `scripts/envgap_harness/`:
  - build: `build.sh`, `build_hash.sh`, `shim/`, `strip_all.py`, `bench/` (BENCH copies plus `EnvgapCandidates.swift`)
  - drivers: `main.swift`, `EnvDump.swift`, `HashMode.swift`, `HashFlags*.swift`
  - Praat: `praat_*.praat`, `praat_window_probe.py`
  - analysis: `gates_table.py`, `cells.py`, `bands.py`, `harm.py`, `selflsd.py`, `extremum_offset.py`
- Run outputs were not committed (scratch). Run a gate set with:

  ```
  scripts/envgap_harness/build.sh <dir> && env PRIMAE_RES=$PWD/PrimaeNative/Resources RATE=48000 SEEDS=8 CANDS=C3-xphase-d OUT=<out> <dir>/envgap_bench
  ```
