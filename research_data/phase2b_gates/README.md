# Phase 2b drift-from-reference gates — design + calibration

Design documents and calibration run results for the Phase 2b
drift-from-reference gates G1-G5 per `docs/BAKE_INVARIANTS.md` §0
(SPEC-VISUAL-APPROVAL). Each gate has a design doc (decisions +
alternatives + verification plan) and, once calibrated, a
calibration result doc (corpus measurement output, derived
threshold, sanity-check Pearson scores).

Cited by `docs/BAKE_INVARIANTS.md` Thresholds 1-4 and the thesis
methodology chapter (Track D). New gate designs land here BEFORE
implementation; calibration results land here in the same commit
that updates `BAKE_INVARIANTS.md` with the derived threshold.

## Contents

- `g1_design.md` — G1 (Threshold 1, asymmetry-profile drift)
  design proposal: metric shape, reference lookup, threshold
  calibration procedure, edge-case list, implementation outline,
  verification plan.
- `g1_calibration_run.md`
  — fresh-bake-vs-shipped self-Pearson floor across the 37
  bake-controlled letters, mandatory sanity-check on round-1 vs
  round-2 calibrator session pairs (A, W, m), derived production
  threshold, corpus state SHA.

G2-G6 docs now here: `g2_design.md`, `g2_calibration_run.md`,
`g3_design.md`, `g3_calibration_run.md`, `g3_curved_not_viable.md`,
`g4_design.md`, `g4_calibration_run.md`, `g5_design.md`,
`g5_verification.md`, `g6_design.md`, `g6_calibration_run.md`.

`phase2c_design.md` scopes the gate-coverage gaps that Track B
identified but did not close (G6 mid-stroke attachment, G3-curved,
composite-umlaut investigation). It defines what "Phase 2c"
means after the term had been used as an undefined forward-pointer
in `g4_calibration_run.md` and `BAKE_INVARIANTS.md`. Per-gate
design + calibration docs (`g6_design.md`,
`g3_curved_design.md`, etc.) land here as Phase 2c items ship.
