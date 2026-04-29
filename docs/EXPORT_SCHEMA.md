# Buchstaben-Lernen-App — Research Export Schema

_Reference for analysts working with the CSV / TSV / JSON exports produced by `ParentDashboardExporter`. Every column is documented here with its source field, range, and analytical purpose. Update this file whenever the exporter shape changes._

---

## File-level header lines

Every CSV / TSV begins with comment lines starting `#`:

| Header | Source | Meaning |
|---|---|---|
| `# participantId=<UUID>` | `ParticipantStore.participantId` | Stable per-install UUID. Persists across reinstall via iCloud KV. |
| `# enrolledAt=<ISO-8601>` | `ParticipantStore.enrolledAt` | First-time the install opted into the thesis study. Only present when set. |
| `# timezone=<IANA>` | `TimeZone.current.identifier` | Device timezone at export time. Useful for interpreting `recordedAt` columns across travel / DST. |

Then a blank line, followed by four data sections.

---

## Section 1 — Per-letter aggregates

One row per letter the child has practised.

| Column | Type | Source | Range / Format | Purpose |
|---|---|---|---|---|
| `letter` | string | `LetterAccuracyStat.letter` | A–Z, Ä, Ö, Ü, ß (uppercase) | Slicing key. |
| `sessionCount` | int | `accuracySamples.count` | ≥ 0 | How often the child practised this letter. |
| `averageAccuracy` | float | `LetterAccuracyStat.averageAccuracy` | 0.0000–1.0000 | Mean of all completed-session scores. |
| `trend` | float | `LetterAccuracyStat.trend` | signed slope | Linear-regression slope over trailing 10 samples. Positive = improving. |
| `recognitionSamples` | int | `LetterProgress.recognitionAccuracy.count` | 0–10 | Count of CoreML recognition readings retained. |
| `recognitionAvg` | float | mean of `recognitionAccuracy` | 0.0000–1.0000 | Mean **calibrated** recognition confidence. |
| `speedTrend` | float-list (`;` joined) | `LetterProgress.speedTrend` | up to 50 values, checkpoints/sec | D-4 raised the cap from 5 → 50 so the trajectory is recoverable for an automatisation analysis. |
| `freeformCompletionCount` | int / blank | `LetterProgress.freeformCompletionCount` | ≥ 0 or empty | How often the child wrote this letter on a blank canvas (Werkstatt mode). |

---

## Section 2 — Per-day session durations

One row per recorded session. Sorted by `dateString`.

| Column | Type | Source | Range / Format | Purpose |
|---|---|---|---|---|
| `date` | string | `SessionDurationRecord.dateString` | `yyyy-MM-dd` (device local) | Day-level aggregation key. |
| `recordedAt` | ISO-8601 / blank | `SessionDurationRecord.recordedAt` | full timestamp | D-9: time-of-day analysis (morning vs evening practice). Blank for legacy pre-D-9 rows. |
| `durationSeconds` | float | `SessionDurationRecord.durationSeconds` | seconds | **Active** practice time. Pauses while the app is backgrounded (D-1). |
| `wallClockSeconds` | float / blank | `SessionDurationRecord.wallClockSeconds` | seconds | T4: total wall-clock time including backgrounded intervals. `wallClock − duration` measures distraction. Blank for legacy rows. |
| `condition` | string | `SessionDurationRecord.condition` | `threePhase` / `guidedOnly` / `control` | Thesis A/B arm. |
| `inputDevice` | string / blank | `SessionDurationRecord.inputDevice` | `finger` / `pencil` / blank | T7: lets duration be split by input device without joining record types. |

**Note:** `condition == threePhase` does not necessarily mean four phases ran — the case label predates the `direct` phase. See `ThesisCondition.swift:18–21`.

---

## Section 3 — Per-phase records

One row per phase × letter session, in chronological order. Filtered by `enrolledAt` cutoff (D-7) and pre-D-3 nil-recordedAt rows are dropped when `enrolledAt` is set (D-8).

| Column | Type | Source | Range | Purpose |
|---|---|---|---|---|
| `letter` | string | `PhaseSessionRecord.letter` | uppercase | Per-letter slicing. |
| `phase` | string | `PhaseSessionRecord.phase` | `observe` / `direct` / `guided` / `freeWrite` | Which gradual-release stage was running. |
| `completed` | bool | `PhaseSessionRecord.completed` | true / false | Selection criterion for "successful" sessions. |
| `score` | float | `PhaseSessionRecord.score` | 0.0000–1.0000 | Phase-level accuracy / form score. |
| `schedulerPriority` | float | `PhaseSessionRecord.schedulerPriority` | unbounded | Spaced-repetition priority at letter selection. IV in the per-arm proxy below. |
| `condition` | string | `PhaseSessionRecord.condition` | `threePhase` / `guidedOnly` / `control` | Thesis A/B arm. |
| `recordedAt` | ISO-8601 / blank | `PhaseSessionRecord.recordedAt` | full timestamp | D-3: enables dated learning curves. |
| `recognition_predicted` | string / blank | `PhaseSessionRecord.recognitionPredicted` | A–Z (or empty) | Letter the CoreML model picked. Populated for freeWrite rows since D-2. |
| `recognition_confidence` | float / blank | `PhaseSessionRecord.recognitionConfidence` | 0.0000–1.0000 | **Post-calibration** softmax confidence. |
| `recognition_confidence_raw` | float / blank | `PhaseSessionRecord.recognitionConfidenceRaw` | 0.0000–1.0000 | T5: **pre-calibration** softmax. `confidence − raw` is the calibrator's contribution; useful for reporting calibration effect on classification decisions. |
| `recognition_correct` | bool / blank | `PhaseSessionRecord.recognitionCorrect` | true / false | Whether the prediction matched the expected letter. |
| `formAccuracy` | float / blank | `PhaseSessionRecord.formAccuracy` | 0.0000–1.0000 | Schreibmotorik dimension 1 (Fréchet, weight 0.40). FreeWrite rows only. |
| `tempoConsistency` | float / blank | `PhaseSessionRecord.tempoConsistency` | 0.0000–1.0000 | Schreibmotorik dimension 2 (CV², weight 0.25). |
| `pressureControl` | float / blank | `PhaseSessionRecord.pressureControl` | 0.0000–1.0000 | Schreibmotorik dimension 3 (force variance, weight 0.15). |
| `rhythmScore` | float / blank | `PhaseSessionRecord.rhythmScore` | 0.0000–1.0000 | Schreibmotorik dimension 4 (active-time ratio, weight 0.20). |
| `inputDevice` | string / blank | `PhaseSessionRecord.inputDevice` | `finger` / `pencil` / blank | D-6: disambiguates `pressureControl == 1.0` between real finger sessions (no force data) and low-variance pencil sessions. |

**Filtering rules:**
- Rows with `recordedAt < enrolledAt` are dropped at export (D-7).
- Rows with `recordedAt == nil` are dropped when `enrolledAt` is set (D-8) — they cannot be proven post-enrolment, and their `condition` was decoded with the legacy `.threePhase` fallback.

---

## Section 4 — Aggregate metrics

One row per metric. Format `metric,value`.

### Phase completion rates
- `phaseCompletionRate_observe`, `phaseCompletionRate_direct`, `phaseCompletionRate_guided`, `phaseCompletionRate_freeWrite`: completed-session count / total-session count for that phase. Range 0–1.

### Overall metrics
- `averageFreeWriteScore`: mean of `score` across completed `freeWrite` rows.
- `schedulerEffectivenessProxy`: Pearson r between `schedulerPriority` and the next-session score delta. Cross-arm. **Interpret with caution** — the `.control` arm uses `−completionCount` priorities which share no scale with the Ebbinghaus priorities of the other arms.

### Per-arm metrics (D-7 / D-10)
For each `arm ∈ {threePhase, guidedOnly, control}` that has data:
- `averageFreeWriteScore_<arm>`: arm-restricted mean.
- `schedulerEffectivenessProxy_<arm>`: arm-restricted Pearson r. Computed only when ≥ 2 priority/delta pairs exist within the arm.

### Schreibmotorik dimension means
Emitted when ≥ 1 freeWrite session has dimension data:
- `averageFormAccuracy`, `averageTempoConsistency`, `averagePressureControl`, `averageRhythmScore`.

---

## Section 5 — Per-arm letter aggregates (D-5)

One row per `(arm, letter)` pair that has completed phase records, derived from `phaseSessionRecords`. Format:

```
letterByArm,<letter>,<arm>,<sampleCount>,<averageScore>
```

Lets between-arm letter-level analyses use a clean source rather than the cross-arm `letterStats` block (Section 1). For pre-T2 records, the per-row condition is the `PhaseSessionRecord.condition` (which is reliably populated since the condition column was added pre-launch).

---

## JSON export (alternative format)

The JSON export contains the full `DashboardSnapshot` plus a `thesisMetrics` block. It does not currently mirror the per-arm `letterByArm` block (TODO post-thesis). Use it when the analyst needs the raw `recognitionSamples` array per letter; use CSV / TSV for tabular analyses.

---

## Schema-version history

| Round | Items | Effect |
|---|---|---|
| W-17 | schema versioning on persisted root structs | Forward-incompatible files are refused at load and logged, instead of silently mis-decoded. |
| D-2 | session-aligned `recognition_*` populated on freeWrite rows | Reverses the W-2 blank-column workaround. |
| D-3 | `recordedAt` on phase records | Dated learning curves recoverable. |
| D-4 | `speedTrend` cap raised 5 → 50 | Full automatisation trajectory exportable. |
| D-5 | per-arm letter aggregates (`letterByArm` block) | Between-arm letter-level analysis. |
| D-6 | `inputDevice` on phase records | Disambiguates `pressureControl == 1.0`. |
| D-7 | per-arm `averageFreeWriteScore_<arm>`, `schedulerEffectivenessProxy_<arm>`; `enrolledAt` filter | Per-arm aggregates; pilot-data exclusion. |
| D-8 | drop legacy nil-recordedAt rows when enrolled | No silent .threePhase inflation. |
| D-9 | `recordedAt` on session durations | Time-of-day analysis. |
| D-11 | multi-character keys excluded from `letterStats` | Word labels don't pollute the per-letter table. |
| T2 | `LetterAccuracyStat.accuracyConditions` parallel array | (Source field; not directly exported — the `letterByArm` block is the analyst-facing surface.) |
| T3 | `# timezone=` header | Device timezone at export time. |
| T4 | `wallClockSeconds` column | Engagement-vs-practice split. |
| T5 | `recognition_confidence_raw` column | Calibrator-effect quantification. |
| T6 | `ThesisCondition.conditionOverride` | Stratified balance for small cohorts. |
| T7 | `inputDevice` on session durations | Duration split by input device without join. |

---

_Last updated 2026-04-29 against `main`. Aligns with `ParentDashboardExporter.swift` and `ParentDashboardStore.swift`._
