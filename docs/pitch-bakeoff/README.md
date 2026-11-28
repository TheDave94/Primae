# Pitch bake-off, phase 2 (2026-11-25)

Reports of the phoneme pitch-shift bake-off that chose TDPSOLA2 for protocol r31. The decision and its evidence are in `docs/DECISIONS.md`, "Phoneme pitch shift: TDPSOLA2".

These files were written on branch `lane/pitch-bakeoff-close` (head `0d12c736`, main `8bb28162` + 12 commits) and copied to `main` unchanged on 2026-11-28, so the branch is not the only record:

- `BENCH-2026-11-25.md`: the one iPad bench with every candidate column.
- `BENCH-P.md`: the bench harness (scenarios and metrics).
- `C1.md`, `C2.md`, `C3.md`: the candidate reports (TDPSOLA2, WorldRT, PitchBank).
- `PITCH-close.patch`: `git format-patch` of the 12 branch commits (sha256 `d1dcc11c8fab3cb963e9c303c6e3b2ee0a412353742969a256fbc077fe56f69d`). Its patch-ids equal the branch's (checked 2026-11-28). It applies to `8bb28162`, not to current `main`.

Only TDPSOLA2 landed (#158). The harness, WorldRT, PitchBank and the naive anchor are on `main` only as this patch. Paths in the reports that start with `wt-primae-audit-notes/` (bench CSVs, blind renders, the MUSHRA key) point to an untracked directory outside the repository and are not on `main`.
