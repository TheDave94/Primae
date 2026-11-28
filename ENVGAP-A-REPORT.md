# ENVGAP-A: where A loses its `env_lsd_vs_praat` margin in the loop path

Lane ENVGAP-A, 2026-11-28. Branch `t3/envgap-a-loopprep`, based on `cc08082e` (ENVGAP). The work was offline only:
`swiftc -O` macOS harness runs, no iPad, no `xcodebuild`, no signing, no push. No gate, threshold or reference was
changed. Each finding is tagged MEASURED (produced in this lane by the command named in §7) or UNMEASURED. Every table
says how many values it holds, and every N is greater than 0.

## Verdict

| candidate (flags; OFF in every shipped set) | A env_lsd cells, every seed, 48k / 44.1k | new median FAILs vs r31, 48k / 44.1k | controls still fail | qualifies | seam meter (ungated flags; r31 = 10) |
|---|---|---|---|---|---|
| C14-xf0.2 (`seamCrossfadeSeconds = 0.2`) | 12/12 cells 8/8 / 12/12 cells 8/8 | 0 / **2**: I +600@0.5 5.230 (1/8), I +600@1 5.251 (0/8), limit 5.222 | yes | **no** | 17 |
| C13+14-xf0.2 (+ `seamAlignLag = 0.5`) | 12/12 cells 8/8 / **A −600@1 6/8** (1.098, max 1.157, limit 1.150) | 0 / 0 | yes | **no** | 13 |
| **C3d+14-xf0.2** (ENVGAP item 11 `extremumPhaseAlign` + guard 0.025, + `seamCrossfadeSeconds = 0.2`) | **12/12 cells 8/8 / 12/12 cells 8/8** | **0 / 0** (gates 491/0 at 48k, 489/2 at 44.1k) | yes | **yes, under the lane rule** | **17** |

MEASURED: full 8-seed gate runs at both rates, compared row by row with r31 by `qualify.py`. The rows counted are the
491 gate rows per rate.

**C3d+14-xf0.2 passes the lane rule, and it is not a recommendation to ship.**

- Its two failing rows at 44.1k already fail in r31, so neither is new (MEASURED):
  - BENCH-owned I −300@2 jitter: r31 1.6267 FAIL 3/8, C3d+14 1.6037 FAIL 4/8.
  - BENCH-owned I traj_attack: r31 5.172, C3d+14 5.355, still failing and 0.18 c worse.
- It lowers A +300@0.5 jitter to 7/8 seeds at 48k (median 0.619 against a 0.6 floor). MEASURED.
- It raises SEAM2's own **ungated** wrap-meter flags from 10 to 17 (§4.4). Two of the new flags are the kind of wrap
  step SEAM2 was built to remove: an f0 step at A's wrap (34.6 c against a 21.1 c threshold at rate 0.5) and a timbre
  step at L's wrap at every rate (up to 2.12 dB against 1.16). MEASURED offline. Whether either is audible is
  UNMEASURED: no listening, no iPad.

The finding a ruling needs is §5. Production A, unchanged, passes every cell on every seed at both rates (MEASURED) if
the bench's held window spans whole **played** loops. This is what the bench header says it does ("integer number of
whole loops"). It does not do it today: the loop length the bench uses predates SEAM2's 0.4 s shortening. Whether to
change the bench is David's call, not this lane's.

## 1. Method (MEASURED unless marked)

- The harness is ENVGAP's (`scripts/envgap_harness/`): the production DSP compiled as module `PrimaeNative`, BENCH's
  metric files, `main.swift`. ENVGAP-A adds four parts:
  - `LoopStages.swift` (MODE=stages): per stage, per seed, the gate's own `env_lsd` measure (LTAS nfft 4096 → true
    envelope at order 0.5 fs/360 → level-free LSD 150–5000 Hz against the steady segment's envelope).
  - `SeamCheck.swift` (MODE=seam): SEAM2's `LoopSeamRegressionTests` gates and the ENV3 wrap-pulse gate, with the
    repo's `SeamMeter`/`SeamEvaluator`/`SeamRender` sources, for any option preset.
  - `build_tests.sh`: offline Swift Testing runs.
  - `stages_table.py` and `qualify.py`.
- **Harness reproduces ENVGAP.** Its r31 results here: 48k 486/5, 44.1k 488/3. The controls: `ours` 409/82 and
  412/79, NaiveResample 298/193 and 295/196, TDPSOLA2-g0.3 390/101 and 389/102. These are identical to ENVGAP-REPORT
  §2. The final binary's r31 rows are **value-identical** to the pre-change build's, all 491 rows at each rate.
- **Stages driver reproduces the gate.** Its production cells equal the bench's to the last digit: A +300@0.5
  1.3201 3/8, A −600@1 1.2215 4/8, A −600@0.5 1.1857 7/8 at 48k, and A −600@1 1.1302 5/8 at 44.1k.

## 2. Q1: which stage costs A its margin

### 2.1 Per-stage ablation (production analysis; one loop-preparation stage removed at a time; 8 seeds)

Each cell shows the median, the seed range and the seeds passing. F marks a median FAIL. "Tile" is a rate-1 identity
playback of the prepared buffer through the renderer's own loop bounds, over the gate's window: one value, because it
has no seed.

48 kHz (MEASURED):

| loop preparation | tile @1 | 0 c @0.5 | 0 c @1 | 0 c @2 | +300@0.5 (≤1.315) | −600@0.5 (≤1.211) | −600@1 (≤1.211) |
|---|---|---|---|---|---|---|---|
| production (SEAM2 crossfade + flatten, TDQ) | 0.533 | 0.838 | 0.545 | 0.664 | 1.320 (1.287–1.355) 3/8 F | 1.186 (1.122–1.253) 7/8 | 1.222 (1.162–1.273) 4/8 F |
| − TDQ declick | 0.518 | 0.802 | 0.532 | 0.684 | 1.291 8/8 | 1.172 8/8 | 1.243 3/8 F |
| − SEAM2 flatten | 0.495 | 0.801 | 0.509 | 0.638 | 1.274 8/8 | 1.178 7/8 | 1.201 5/8 |
| **− SEAM2 crossfade** | **0.317** | 0.626 | **0.244** | 0.841 | **1.210 8/8** | **0.958 8/8** | **0.986 8/8** |
| − SEAM2 (both) | 0.304 | 0.613 | 0.212 | 0.795 | 1.194 8/8 | 0.993 8/8 | 0.973 8/8 |
| − SEAM2 − TDQ | 0.290 | 0.603 | 0.203 | 0.780 | 1.172 8/8 | 0.978 8/8 | 0.995 8/8 |

44.1 kHz (MEASURED):

| loop preparation | tile @1 | 0 c @0.5 | 0 c @1 | 0 c @2 | +300@0.5 (≤1.397) | −600@0.5 (≤1.150) | −600@1 (≤1.150) |
|---|---|---|---|---|---|---|---|
| production | 0.475 | 0.745 | 0.483 | 0.601 | 1.303 8/8 | 1.113 8/8 | 1.130 (1.060–1.187) 5/8 |
| − TDQ declick | 0.461 | 0.721 | 0.470 | 0.529 | 1.271 8/8 | 1.101 8/8 | 1.151 3/8 F |
| − SEAM2 flatten | 0.435 | 0.704 | 0.445 | 0.551 | 1.246 8/8 | 1.085 8/8 | 1.145 4/8 |
| **− SEAM2 crossfade** | **0.222** | 0.617 | **0.268** | 0.771 | 1.272 8/8 | 0.956 8/8 | **0.954 8/8** |
| − SEAM2 (both) | 0.188 | 0.579 | 0.239 | 0.769 | 1.262 8/8 | 0.941 8/8 | 0.996 8/8 |
| − SEAM2 − TDQ | 0.184 | 0.567 | 0.236 | 0.755 | 1.260 8/8 | 0.967 8/8 | 0.996 8/8 |

Source controls: slice of the raw loop 0.120 (48k) and 0.119 (44.1k); raw loop tiled over the gate window 0.290 and
0.184. MEASURED.

Findings (each MEASURED):

- **The SEAM2 crossfade is the stage.** Removing it alone passes all three A cells on 8/8 seeds at both rates and
  halves the 0 c @1 floor (0.545 → 0.244).
- **Loop-range choice is not the cost.** The raw loop reads 0.12 as one slice and 0.18–0.29 tiled.
- **TDQ and the flatten are small, and not monotone.** Removing TDQ makes −600@1 worse at both rates.
- **The 0 c render path adds about nothing.** At 48k: render 0.545 against the tile of the same prepared buffer
  0.533. At 44.1k: 0.483 against 0.475.
- **The floor is not the shifter.** ENVGAP showed the shifted render against its own 0 c render reads Praat's own
  error (1.0085 against 1.009, ENVGAP §3.3).

### 2.2 Mechanism 1: the blend cancels A's F1 region

The crossfade blends the 0.4 s that follows the shortened loop end (the tail) into the loop's first 0.4 s (the head).
The table gives each part's envelope relative to the steady segment's, level-free, in dB per band. 48k, MEASURED. The
thirds are 0.13 s each.

| part | 150–500 | 500–1000 | 1000–1500 | 1500–2000 | 2000–3000 | 3000–4000 | 4000–5000 |
|---|---|---|---|---|---|---|---|
| raw head, middle third | 1.11 | 0.17 | 0.58 | 2.88 | −1.44 | 0.09 | −0.87 |
| raw tail, middle third | −0.59 | −0.24 | −0.84 | −0.37 | −1.40 | 2.17 | 0.13 |
| **prepared head (the blend), middle third** | 1.67 | **−5.88** | **−3.43** | 4.00 | −0.02 | 0.16 | 1.92 |
| same, with item 13 (WSOLA-aligned tail) | 0.30 | −0.24 | 1.12 | 1.52 | −1.25 | 0.03 | −0.08 |

The parts it blends read −0.2 to +0.6 dB at 500–1500 Hz; the blend's middle reads −5.9 and −3.4 dB there. The
blend's weights are pitch-synchronous and mark-matched, and its gain is normalised by one correlation per broad band.
Where the head's and the tail's F1 harmonics drift out of phase, they cancel mid-blend. A per-band correlation
restores a band's average power, not the power where and when it cancels. Aligning the tail by waveform similarity
(item 13) removes the notch, and A's 0 c @1 floor falls 0.545 → 0.350 (48k) and 0.483 → 0.258 (44.1k).

### 2.3 Mechanism 2: the gate's window is not a whole number of played loops

The bench sizes each voiced window as whole loops of `loopSeconds`. That value is `analysis.loopEnd −
analysis.loopStart` = **1.944 s**, but SEAM2 plays a loop shortened by the crossfade, **1.546 s**. The window is
therefore 1.257 played loops, and it starts inside the blend. A's spectrum drifts strongly within the recording:
either half of its steady segment reads 1.04–1.34 dB against the whole. Which 0.4 s is counted twice therefore moves
the reading.

The probe tiles the same prepared A loop; only the window changes. 48k, one value each, MEASURED:

| start of window | 1 loop | **1.257 loops (the gate's)** | 2 loops | 3 loops | 6 loops |
|---|---|---|---|---|---|
| loop start | 0.313 | 0.535 | 0.309 | 0.304 | 0.306 |
| gate start (onset + 0.6 s) | 0.245 | **0.533** | 0.264 | 0.277 | 0.290 |
| loop middle | 0.452 | 0.294 | 0.387 | 0.361 | 0.329 |

This answers the brief's "why 0.516 at −39 dB identity". The 0 c render *is* the prepared loop: −39 dB residual in
the first pass (ENVGAP §3.3), and render 0.545 against tile 0.533 (§2.1). The 0.516 compared the render's 1.257-loop
window with a single one-loop slice of the prepared buffer. A one-loop slice and a 1.257-loop window weight A's
drifting content differently by about 0.2 dB (0.31 against 0.53 against the same steady reference). MEASURED.

**Does the LSD metric see the loop repetition or the seam period?** It sees the **window weighting**, and it does not
see the repetition. MEASURED, with one INFERENCE marked below:

- The loop rate is 0.65 Hz, and the LTAS bins are 11.7 Hz apart (nfft 4096 at 48k), so no repetition lines can be
  resolved (INFERENCE from those two numbers).
- Over whole loops, every start reads 0.25–0.39.
- At @0.5 the 1.257-loop window covers the blend twice: 0 c @0.5 reads 0.838 in the gate's window and 0.581 over whole
  played loops.

## 3. Q2: the same floor on I, L, M and F?

Production against "− SEAM2 crossfade", 8 seeds. The 0 c values are medians. "Tightest" is limit − worst seed over the
12 shifted cells. Seed-fails count over 96 values. MEASURED.

| letter | rate | raw loop tile | prepared tile (prod / −xf) | 0 c @1 (prod / −xf) | tightest cell, prod | seed-fails prod / −xf | steady halves vs whole |
|---|---|---|---|---|---|---|---|
| A | 48k | 0.290 | 0.533 / 0.317 | 0.545 / 0.244 | −600@1 −0.062 (−5.1 %) | 10 / 0 | 1.34 / 1.06 |
| I | 48k | 0.273 | 0.322 / 0.261 | 0.360 / 0.151 | +600@2 −0.240 (−4.6 %) | 24 / 19 | 0.37 / 0.62 |
| L | 48k | 0.249 | 0.259 / 0.255 | 0.257 / 0.204 | −600@2 +0.020 (+1.3 %) | 0 / 0 | 0.72 / 0.44 |
| M | 48k | 0.441 | 0.566 / 0.448 | 0.582 / 0.317 | −300@2 +0.179 (+8.7 %) | 0 / 0 | 1.43 / 1.09 |
| A | 44.1k | 0.184 | 0.475 / 0.222 | 0.483 / 0.268 | −600@1 −0.037 (−3.2 %) | 3 / 0 | 1.26 / 1.04 |
| I | 44.1k | 0.183 | 0.339 / 0.182 | 0.315 / 0.172 | +600@2 −0.135 (−2.6 %) | 12 / 8 | 0.37 / 0.67 |
| L | 44.1k | 0.124 | 0.278 / 0.138 | 0.268 / 0.153 | −600@2 +0.082 (+4.7 %) | 0 / 0 | 0.68 / 0.43 |
| M | 44.1k | 0.382 | 0.585 / 0.382 | 0.553 / 0.262 | −300@2 +0.096 (+5.0 %) | 0 / 0 | 1.52 / 1.16 |

F is unvoiced, has no Praat reference and no `env_lsd_vs_praat` gate. Its 0 c floor is 0.338 (48k) and 0.377 (44.1k),
with or without the crossfade.

Findings, by letter:

- **The crossfade adds a 0 c floor to every voiced letter.** I +0.21, L +0.05, M +0.27 at 48k. MEASURED.
- **A combines the largest floor increase with the smallest Praat reference.** A −600's 1.2 × Praat limit is 1.211
  (48k) and 1.150 (44.1k), the smallest of any letter. MEASURED.
- **M has as much drift and a similar floor, but its references are larger** (limits 2.04–2.60), so it keeps a 5–9 %
  margin. MEASURED.
- **I's failing cells are +600, ENVGAP's mark-phase problem** (§3.2 there), not this floor. Removing the crossfade
  improves them only from 24 to 19 failing seeds at 48k. MEASURED.
- **A is the letter with the least margin against this floor**, because its limits are the tightest. It is not the
  only letter that has the floor. INFERENCE from the rows above.

## 4. Q3: candidates

### 4.1 Items (all OFF in `.default`, `.production` and `.r27`, pinned by test)

- **Item 13 `seamAlignLag`** (with `seamAlignSlope` 0.004 and `seamAlignFade` 0.25): SEAM2's voiced head blend aligns
  the tail to the head before blending. Per block of 2 periods, it takes the lag within ±lag × median period that
  maximises the NCC. The lag curve is median-of-5 smoothed, faded in from 0 (the wrap stays continuous) and
  slope-limited (≤ 7 c local tail pitch change). This is the alignment step of SOLA (Roucos & Wilgus 1985, ICASSP) and
  WSOLA (Verhelst & Roelands 1993, ICASSP), cited in the doc comment.
- **Item 14 `seamCrossfadeSeconds`**: a voiced phoneme's SEAM2 crossfade length in place of the tuning's 0.4 s.
  Unvoiced sources keep the tuning's value.
- Code: `TDPSOLALoopSeam.Blend`, reached through `TDPSOLA2Options.seamBlend` → `TDPSOLA2.prepared(…, seam:)`. The
  shipped path runs the original code, unchanged.

Screened and **removed** (MEASURED, table §4.3): fine-band gain normalisation (8 cutoffs), signed-correlation gain
law, and a loop-end search by head/tail NCC (24 and 48 marks). None lowered the floor. The loop-end search made every
A cell worse.

### 4.2 Qualify table (full bench, 8 seeds, both rates; MEASURED)

| candidate | rate | gates PASS/FAIL | A +300@0.5 | A −600@0.5 | A −600@1 | worst A cell seeds | new median FAIL vs r31 | seed-count drops |
|---|---|---|---|---|---|---|---|---|
| r31 (reference) | 48k | 486/5 | 1.320 3/8 F | 1.186 7/8 | 1.222 4/8 F | 3/8 | – | – |
| r31 (reference) | 44.1k | 488/3 | 1.303 8/8 | 1.113 8/8 | 1.130 5/8 | 5/8 | – | – |
| C14-xf0.2 | 48k | 488/3 | 1.240 8/8 | 1.101 8/8 | 1.147 8/8 | 8/8 | 0 | A +300@0.5 jitter 8→7/8 |
| C14-xf0.2 | 44.1k | 487/4 | 1.279 8/8 | 1.019 8/8 | 1.072 8/8 | 8/8 | **2** (I +600@0.5, @1) | 0 |
| C13+14-xf0.2 | 48k | 488/3 | 1.280 8/8 | 1.104 8/8 | 1.132 8/8 | 8/8 | 0 | 0 |
| C13+14-xf0.2 | 44.1k | 489/2 | 1.319 8/8 | 1.018 8/8 | 1.098 6/8 | **6/8** | 0 | 0 |
| **C3d+14-xf0.2** | 48k | **491/0** | 1.240 8/8 | 1.101 8/8 | 1.147 8/8 | 8/8 | **0** | A +300@0.5 jitter 8→7/8 |
| **C3d+14-xf0.2** | 44.1k | **489/2** | 1.279 8/8 | 1.019 8/8 | 1.072 8/8 | 8/8 | **0** | 0 |

The controls are unaffected by items 13 and 14 (`ours` builds `.r27`, so `seamBlend` is `.shipped`; NaiveResample has
no TDPSOLA2). They fail exactly as in ENVGAP §2 on the final binary. MEASURED.

C14 alone fails the rule at 44.1k: the I +600 cells sat at 5.2223 and 5.2098 against 5.222, and item 14 also changes
I's loop. ENVGAP's I fix (item 11, C3-xphase-d) takes I +600 to about 4.4, and that combination is the candidate that
qualifies. C3d+14's A values are bit-for-bit C14's, because item 11's guard leaves A untouched.

### 4.3 Screened variants (A only, the stages driver, 8 seeds; MEASURED)

| variant | 0 c @1 48k | +300@0.5 48k | −600@0.5 48k | −600@1 48k | 0 c @1 44.1k | +300@0.5 44.1k | −600@0.5 44.1k | −600@1 44.1k | all A cells, all seeds |
|---|---|---|---|---|---|---|---|---|---|
| r31 production | 0.545 | 1.320 3/8 | 1.186 7/8 | 1.222 4/8 | 0.483 | 1.303 8/8 | 1.113 8/8 | 1.130 5/8 | no |
| fine bands (removed) | 0.540 | 1.311 5/8 | 1.174 7/8 | 1.199 5/8 | 0.467 | 1.287 8/8 | 1.089 8/8 | 1.166 2/8 | no |
| signed rho (removed) | 0.602 | 1.317 4/8 | 1.188 8/8 | 1.240 1/8 | 0.551 | 1.334 8/8 | 1.100 8/8 | 1.138 5/8 | no |
| loop-end search 24 (removed) | 0.594 | 1.348 1/8 | 1.243 2/8 | 1.335 0/8 | 0.549 | 1.362 7/8 | 1.167 3/8 | 1.275 0/8 | no |
| loop-end search 48 (removed) | 0.547 | 1.376 0/8 | 1.348 0/8 | 1.323 0/8 | 0.540 | 1.385 6/8 | 1.224 0/8 | 1.185 2/8 | no |
| item 13, lag 0.5 | 0.350 | 1.304 4/8 | 1.156 8/8 | 1.202 5/8 | 0.258 | 1.295 8/8 | 1.053 8/8 | 1.118 8/8 | no |
| item 13, lag 1.0 | 0.449 | 1.307 5/8 | 1.174 8/8 | 1.213 4/8 | 0.353 | 1.287 8/8 | 1.122 8/8 | 1.161 4/8 | no |
| item 13, slope .008 | 0.350 | 1.335 1/8 | 1.172 8/8 | 1.213 4/8 | 0.260 | 1.298 8/8 | 1.079 8/8 | 1.136 5/8 | no |
| item 13, fade .10 | 0.358 | 1.300 5/8 | 1.149 8/8 | 1.197 6/8 | 0.266 | 1.313 8/8 | 1.063 8/8 | 1.122 8/8 | no |
| item 13, slope .002 | 0.405 | 1.329 2/8 | 1.148 8/8 | 1.180 8/8 | 0.326 | 1.321 8/8 | 1.058 8/8 | 1.099 8/8 | no |
| crossfade 0.2 s (= item 14 for A) | 0.297 | 1.240 8/8 | 1.101 8/8 | 1.147 8/8 | 0.222 | 1.279 8/8 | 1.019 8/8 | 1.072 8/8 | yes |
| crossfade 0.1 s | 0.201 | 1.228 8/8 | 1.040 8/8 | 1.044 8/8 | 0.159 | 1.297 8/8 | 0.986 8/8 | 1.035 8/8 | yes |
| crossfade 0.05 s | 0.231 | 1.255 8/8 | 0.978 8/8 | 0.984 8/8 | 0.221 | 1.281 8/8 | 0.946 8/8 | 1.000 8/8 | yes |
| item 13 + crossfade 0.1 s | 0.220 | 1.256 8/8 | 1.011 8/8 | 1.061 8/8 | 0.173 | 1.275 8/8 | 0.973 8/8 | 1.026 8/8 | yes |

The full bench for C14-xf0.1 (MEASURED) fails the same two I +600 rows at 44.1k as C14-xf0.2 (5.245 and 5.256), and it
drops A +300@0.5 jitter to 4/8 seeds at 48k. It has 19 ungated seam flags. It is not proposed.

### 4.4 SEAM2's own seam gates (`SeamCheck.swift`, 44.1 kHz as the tests run; MEASURED)

| preset | gated checks (level ≤ 0.3 dB, drift-reset ≤ 0.3, in-cycle drift ≤ 0.8, wrap pulse ≤ 1.8×) | ungated meter flags (timbre/centroid/f0/flux) | new ungated flags vs r31 |
|---|---|---|---|
| r31 production | 31/31 PASS | 10 (F centroid × 5, I r1.4 × 2, I r2.0, L r1.0, L r1.4) | – |
| C14-xf0.2 | 31/31 PASS | 17 | **A f0 at wrap r0.5 34.6/21.1 c, r0.7 23.2/19.6 c**; A r1.4 flux; **L timbre at all 5 rates (1.46–2.12 dB, thresholds 1.13–1.48)**; M r1.4 timbre 1.287/1.286; I r2.0 timbre |
| C13+14-xf0.2 | 31/31 PASS | 13 | A f0 r0.5 35.7/20.5 c, r0.7 24.5/19.5 c; L timbre r0.7–1.4; L r0.5 flux; M r1.4 |
| C3d+14-xf0.2 | 31/31 PASS | 17 | as C14-xf0.2 (A f0 34.6/21.1 c; L timbre at 5 rates up to 2.12/1.16 dB) |
| C14-xf0.1 | 31/31 PASS | 19 | A f0 r0.5/0.7; L timbre at 5 rates; M timbre r0.5–1.4 |

A's wrap pulse rises from 0.90–1.02× to 1.21–1.27× under item 14, still under the 1.8× gate. **The shorter crossfade
buys A's LSD margin with a faster tail-to-head transition at the wrap, which is the thing SEAM2 exists to hide.** These
flags are ungated, and whether they are audible is UNMEASURED.

### 4.5 Bit identity and tests (MEASURED)

- **Hash mode.** `build_hash.sh` was run with `T1DIR`/`T2DIR` set to 612128f2's TDPSOLA and TDPSOLA2 sources and
  `HashFlagsNone`, and again on this branch. FNV-1a of 2 s renders, A F I L M × 6 drives, at 44.1k (C1Make
  construction) and 48k (file-rate production path).
  - **55/55 OFF rows are identical to 612128f2.** These are `default`, `production`, ENVGAP's spelled-off and
    guard-only sets, ENVGAP-A's spelled-off set, and the parameters-only set (slope/fade set, lag 0).
  - ON: item 13 and item 14 each change 6/6 drives of A, I, L and M at both rates, and 0/6 of F.
- **Bench.** The r31 gate rows of the final binary equal the pre-change build's, 491/491 per rate.
- **In-repo test.** `PrimaeNativeTests/Sonification/TDPSOLA2/TDPSOLA2EnvgapAFlagTests.swift` (4 tests):
  - shipped sets OFF (`seamBlend == .shipped`);
  - production with items 13/14 spelled OFF, inert parameters set, hashes as 612128f2 (ENVGAP's pinned table) for 5
    letters × 6 drives;
  - the explicit `.shipped` blend prepares the same loop as SEAM2's default arguments;
  - each item ON changes A's prepared loop, item 13 keeps the loop end, item 14 lengthens it and leaves F alone.

  Run offline with ENVGAP's suite: `Test run with 8 tests in 2 suites passed`.
- **Mutation checks.** Each was compiled, run, and the source restored afterwards (`cmp` against a saved copy):
  - M1, `seamAlignLag` default 0.5: `Test run with 8 tests in 2 suites failed … with 31 issues` (shipped-OFF, ON,
    ENVGAP pins RED).
  - M2, item 14 ignored in `prepare`: `… failed … with 2 issues` (the ON test RED).
  - M3, OFF path perturbed (×0.95 crossfade): `… failed … with 48 issues` (both hash-pin tests RED).
  - After the restore: `Test run with 8 tests in 2 suites passed`.
- `xcodebuild` and CI were not run (out of lane). UNMEASURED.

## 5. Q4: what the gate would read with another reference or another window (evidence for a ruling)

Production r31, unchanged, 8 seeds, the limit unchanged (1.2 × Praat) in every column. The columns are:

- **gate**: today's gate.
- **ref = prepared loop**: the reference envelope is the prepared loop as it plays (two whole played loops from the
  loop start) instead of the raw steady segment.
- **whole played loops**: the bench's own scenario and window built from SEAM2's effective loop (1.546 s) instead of
  `analysis.loopEnd − loopStart` (1.944 s), so the window is a whole number of the loops actually played. The renders
  were made long enough to hold that window.

MEASURED.

| A cell | 48k limit | gate | ref = prepared loop | whole played loops | 44.1k limit | gate | ref = prepared loop | whole played loops |
|---|---|---|---|---|---|---|---|---|
| −600@0.5 | 1.211 | 1.186 7/8 | 1.092 8/8 | 1.027 8/8 | 1.150 | 1.113 8/8 | 1.131 7/8 | 0.963 8/8 |
| −300@0.5 | 1.830 | 1.650 8/8 | 1.530 8/8 | 1.622 8/8 | 1.819 | 1.601 8/8 | 1.560 8/8 | 1.560 8/8 |
| +300@0.5 | 1.315 | 1.320 3/8 F | 1.279 8/8 | 1.147 8/8 | 1.397 | 1.303 8/8 | 1.357 8/8 | 1.165 8/8 |
| +600@0.5 | 1.603 | 1.519 8/8 | 1.426 8/8 | 1.420 8/8 | 1.651 | 1.517 8/8 | 1.501 8/8 | 1.421 8/8 |
| −600@1 | 1.211 | 1.222 4/8 F | 1.135 8/8 | 1.044 8/8 | 1.150 | 1.130 5/8 | 1.120 5/8 | 0.944 8/8 |
| −300@1 | 1.830 | 1.678 8/8 | 1.568 8/8 | 1.660 8/8 | 1.819 | 1.631 8/8 | 1.604 8/8 | 1.619 8/8 |
| +300@1 | 1.315 | 1.139 8/8 | 1.105 8/8 | 1.015 8/8 | 1.397 | 1.121 8/8 | 1.187 8/8 | 1.034 8/8 |
| +600@1 | 1.603 | 1.391 8/8 | 1.313 8/8 | 1.313 8/8 | 1.651 | 1.376 8/8 | 1.373 8/8 | 1.314 8/8 |
| −600@2 | 1.211 | 1.056 8/8 | 1.032 8/8 | 1.052 8/8 | 1.150 | 0.991 8/8 | 1.092 7/8 | 0.978 8/8 |
| −300@2 | 1.830 | 1.472 8/8 | 1.419 8/8 | 1.464 8/8 | 1.819 | 1.382 8/8 | 1.420 8/8 | 1.391 8/8 |
| +300@2 | 1.315 | 0.994 8/8 | 1.013 8/8 | 1.055 8/8 | 1.397 | 0.982 8/8 | 1.107 8/8 | 1.044 8/8 |
| +600@2 | 1.603 | 1.270 8/8 | 1.228 8/8 | 1.296 8/8 | 1.651 | 1.273 8/8 | 1.323 8/8 | 1.299 8/8 |

All letters, as median FAIL cells /12 and failing seeds /96. MEASURED.

| letter | rate | gate | ref = prepared loop | whole played loops |
|---|---|---|---|---|
| A | 48k | 2/12, 10/96 | **0/12, 0/96** | **0/12, 0/96** |
| A | 44.1k | 0/12, 3/96 | 0/12, 5/96 | **0/12, 0/96** |
| I | 48k | 3/12, 24/96 (+600 ×3) | 5/12, 39/96 (adds −600@0.5, −600@2) | 3/12, 24/96 (+600 ×3) |
| I | 44.1k | 1/12, 12/96 | 3/12, 24/96 | 3/12, 21/96 (adds +600@0.5 5.233 and +600@1 5.308) |
| L | 48k | 0/12, 0/96 | 0/12, 2/96 | 0/12, 0/96 |
| L | 44.1k | 0/12, 0/96 | 0/12, 0/96 | 0/12, 0/96 |
| M | 48k / 44.1k | 0/12, 0/96 | 0/12, 0/96 | 0/12, 0/96 |

A's 0 c floor under each column (MEASURED):

| rate | gate @0.5 / @1 / @2 | against the prepared loop | over whole played loops |
|---|---|---|---|
| 48k | 0.838 / 0.545 / 0.664 | 0.657 / 0.338 / 0.608 | 0.581 / 0.274 / 0.690 |
| 44.1k | 0.745 / 0.483 / 0.601 | 0.635 / 0.315 / 0.645 | 0.491 / 0.261 / 0.681 |

Reading:

- **A prepared-loop reference is not a clean answer.** It clears A at 48k, but at 44.1k it leaves A with 5 failing
  seeds (medians pass) and makes I worse at both rates (MEASURED). It also stops measuring what the loop preparation
  does to the timbre, because the reference absorbs it.
- **A whole-played-loop window keeps the steady reference and applies the bench's own stated design ("integer number
  of whole loops") to the loop that actually plays.** Production then clears A on every seed at both rates (MEASURED).
  Its cost: at 44.1k I +600@0.5 and @1 read FAIL (I +600 is ENVGAP's open I problem, which C3-xphase-d fixes at about
  4.4).
- **This is David's call, not this lane's.** ENVGAP-A changed no gate, threshold, reference or bench window. The bench
  source copies in `scripts/envgap_harness/bench/` are untouched apart from `EnvgapACandidates.swift` (new). The
  alternative readings are computed in the harness driver only.

## 6. What it would take to close A

There are two routes:

1. **A ruling on the bench's held window.** Size it in whole *played* loops, because SEAM2 shortens the loop that
   `loopSeconds` measures. Production A then passes all 12 cells on every seed at both rates, with no renderer change
   (MEASURED). I +600 still needs ENVGAP's item 11.
2. **A renderer change.** Ship item 14 at 0.2 s together with ENVGAP's item 11 (C3d+14-xf0.2). It passes the pitch
   bench under the lane rule (MEASURED), but it adds SEAM2-meter wrap flags: an f0 step on A, timbre steps on L. These
   need David's ear and an iPad walk-through before any protocol revision (UNMEASURED).

Item 13 (WSOLA alignment) fixes the blend's F1 cancellation, the real defect in §2.2, but it does not close A alone
(MEASURED). It is the part to keep whichever route is taken, if the seam is ever reworked.

## 7. Files and commands

- Production (all OFF):
  - `PrimaeNative/Core/Sonification/TDPSOLA/TDPSOLALoopSeam.swift`: `Blend`, item 13 `align`, item 14 crossfade
    override.
  - `PrimaeNative/Core/Sonification/TDPSOLA2/TDPSOLA2.swift`: options `seamAlignLag`/`seamAlignSlope`/
    `seamAlignFade`/`seamCrossfadeSeconds`, `seamBlend`, `prepared(…, seam:)`.
- Test: `PrimaeNativeTests/Sonification/TDPSOLA2/TDPSOLA2EnvgapAFlagTests.swift`.
- Harness:
  - drivers: `scripts/envgap_harness/LoopStages.swift`, `SeamCheck.swift`, `bench/EnvgapACandidates.swift`
  - scripts: `stages_table.py`, `qualify.py`, `build_tests.sh`
  - edited: `build.sh`, `build_hash.sh` (`T1DIR`), `HashFlags.swift`, `main.swift` (modes `stages`/`seam`)
- Commands. Outputs were not committed (scratch). `<B>` is the build directory, `$R` the rate (48000 or 44100) and
  `<P>` an option preset name:
  - gates: `scripts/envgap_harness/build.sh <B> && env PRIMAE_RES=$PWD/PrimaeNative/Resources RATE=$R SEEDS=8 CANDS=<name> OUT=<out> <B>/envgap_bench`,
    then `python3 scripts/envgap_harness/qualify.py <r31 gates.csv> <cand gates.csv> <name>`
  - stages: `env MODE=stages [OPTS=<P>] [VARIANTS=prod,noTDQ,noXF,noFlat,noSeam,none] [ALTREF=1] [DUMP=1] [TILEPROBE=1] LETTERS=A SEEDS=8 RATE=$R PRIMAE_RES=… OUT=<out> <B>/envgap_bench`,
    then `python3 scripts/envgap_harness/stages_table.py <out>/stages.csv`
  - seam: `env MODE=seam OPTS=<P> PRIMAE_RES=… <B>/envgap_bench`
  - hash: `T1DIR=<612128f2 TDPSOLA> T2DIR=<612128f2 TDPSOLA2> HASHFLAGS=scripts/envgap_harness/HashFlagsNone.swift scripts/envgap_harness/build_hash.sh <H0>`,
    then `scripts/envgap_harness/build_hash.sh <H1>`, and run both `envgap_hash`
  - tests: `scripts/envgap_harness/build_tests.sh <T> PrimaeNativeTests/Sonification/TDPSOLA2/TDPSOLA2EnvgapFlagTests.swift PrimaeNativeTests/Sonification/TDPSOLA2/TDPSOLA2EnvgapAFlagTests.swift && env PRIMAE_RES=… <T>/envgap_tests`
