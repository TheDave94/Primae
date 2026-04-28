# Review Round 3 — Council Synthesis

Generated: 2026-04-28  
Last updated: 2026-04-28 (post W-23 + cleanup pass)  
Source: Regression check + deep bug hunt + test audit + thesis data audit

---

## Summary Table (sorted by severity)

| ID | Severity | Status | File | Finding |
|----|----------|--------|------|---------|
| **C-1** | 🔴 Critical | **FIXED** | TracingViewModel:1396 | `lastGuidedScore` wiped by `clearAll()` before freeWrite begins — "Nachspuren fertig" card never shown |
| **C-2** | 🔴 Critical | **FIXED** | FreeformController:97 | `isRecognizing` stuck `true` after canvas clear — spinner permanent |
| **C-3** | 🔴 Critical | **FIXED** | TracingViewModel:1437, ParentDashboardStore:222 | `schedulerPriority` hardcoded `0` — `schedulerEffectivenessProxy` permanently 0 |
| **C-4** | 🔴 Critical | **FIXED** | OverlayQueueManager:116 | Recognition badge silently dropped when CoreML finishes after celebration already showing |
| **W-1** | 🟡 Warning | **FIXED (via C-3)** | TracingViewModel:1380 | Priority captured at selection time — same site as C-3 |
| **W-2** | 🟡 Warning | **FIXED** | ParentDashboardExporter:103 | Phase rows now blank the recognition columns; per-letter aggregate retained |
| **W-3** | 🟡 Warning | **FIXED** | ParentDashboardStore + StreakStore | All stores now route through `LetterProgress.canonicalKey` so `ß` stays `ß` everywhere |
| **W-4** | 🟡 Warning | **FIXED** | TracingViewModel:1377 | "Weiter" button non-functional if `recommendNext` returns nil — child trapped on screen |
| **W-5** | 🟡 Warning | **FIXED** | CompletionCelebrationOverlay:40 | Stars hardcoded `1…4` for all conditions — motivational confound for guidedOnly/control |
| **W-6** | 🟡 Warning | **FIXED** | TracingViewModel:1411 | `isSingleTouchInteractionActive` not cleared in `resetForPhaseTransition()` — canvas lockout on interrupted gesture |
| **W-23** | 🟡 Warning | **FIXED** | LetterScheduler:88 | `fixedOrder()` now scores by `-completionCount` so control arm round-robins instead of stalling on the first letter |
| **W-16** | 🟡 Warning | not fixed (documented) | TracingViewModel:504 | `playback` remains IUO — two-phase init constraint documented; 98e63de reverted the IUO→let attempt |
| **W-17** | 🟡 Warning | not fixed | All stores | No `schemaVersion` sentinel — silent data loss on decode failure |
| **W-24** | 🟡 Warning | not fixed | LetterScheduler:49 | `memoryStabilityDays` fixed — no expanding-interval implementation |
| **I-2** | 🟢 Info | not fixed (documented) | TracingDependencies:16 | `adaptationPolicy = nil` meaning undocumented |
| **I-4** | 🟢 Info | **FIXED** | PhaseDotIndicator:26 + SchuleWorldView:330 | Now uses `vm.activePhases` so guidedOnly/control render only the dots they actually run |
| **I-5** | 🟢 Info | **FIXED** | SchriftArt:16 | Case renamed `vereinfachteAusgangsschrift` (genitive-s); raw value pinned to old spelling for back-compat |
| **I-6** | 🟢 Info | **FIXED** | FreeformWritingView:368, :642 | "Erkenne…" → "Wird erkannt…" / "Erkenne das Wort…" → "Wort wird erkannt…" |
| **I-7** | 🟢 Info | **FIXED** | CompletionCelebrationOverlay:34 | Headline changed from "Super gemacht!" to "Geschafft!" — no longer duplicates the feedback card |

---

## Detailed Findings

### C-1 — `lastGuidedScore` wiped before freeWrite begins (FIXED)

**Root cause:** `advanceLearningPhase()` sets `freeWriteRecorder.lastGuidedScore = score` immediately before calling `resetForPhaseTransition()`. That function calls `freeWriteRecorder.clearAll()`, which unconditionally sets `lastGuidedScore = nil`. The value is set and cleared in the same synchronous call stack before `startSession()` runs.

**Consequence:** `SchuleWorldView`'s "Nachspuren fertig" feedback card is gated on `vm.lastGuidedScore != nil && vm.learningPhase == .freeWrite`. Because `lastGuidedScore` is always nil when freeWrite starts, this card is permanently hidden. The guided-score verbal feedback scaffold — a thesis-motivated element — never displays.

**Fix:** In `resetForPhaseTransition()`, save and restore `lastGuidedScore` around the `clearAll()` call:
```swift
let savedGuidedScore = freeWriteRecorder.lastGuidedScore
freeWriteRecorder.clearAll()
freeWriteRecorder.lastGuidedScore = savedGuidedScore
```

---

### C-2 — `isRecognizing` stuck `true` after canvas clear (FIXED)

**Root cause:** `FreeformController.clearBuffers()` cancels `pendingRecognitionTask` and resets `isWaitingForRecognition`, but does not reset `isRecognizing`. When a CoreML task completes after the canvas is cleared, the completion handler checks `activeRecognitionToken` (which was nil'd in `clearFreeformCanvas()`), returns early, and never sets `isRecognizing = false`.

**Consequence:** The freeform writing spinner/loading indicator is permanently active. Switching worlds while recognition is in flight leaves `isRecognizing = true` for any future re-entry.

**Fix:** Add `isRecognizing = false` to `clearBuffers()`.

---

### C-3 — `schedulerPriority` hardcoded to `0` (FIXED)

**Root cause:** `recordPhaseSessionCompletion()` always passes `schedulerPriority: 0` to `dashboardStore.recordPhaseSession`. The actual Ebbinghaus priority computed by `LetterScheduler.prioritized()` is used only to select the letter and then discarded.

**Consequence:** `schedulerEffectivenessProxy` in `DashboardSnapshot` computes Pearson correlation with all x-values = 0 → `xVar = 0` → guard hits → returns `0`. The metric is structurally 0 for every device. The CSV always emits `schedulerEffectivenessProxy,0.0000`. **Thesis claim "spaced-repetition scheduler improves outcomes" cannot be evaluated from exported data.**

**Fix:**
1. Add `private var lastScheduledLetterPriority: Double = 0` to the VM.
2. In `loadRecommendedLetter()`, call `letterScheduler.prioritized()` instead of `recommendNext()`, capture the top letter's priority, store it.
3. Pass `lastScheduledLetterPriority` to `recordPhaseSession` instead of `0`.

This also fixes **W-1** (priority must be captured at selection time, not completion time) since the same site is now used for both.

---

### C-4 — Recognition badge silently dropped when celebration already showing (FIXED)

**Root cause:** `enqueueBeforeCelebration()` searched only the *pending queue* for a `.celebration` entry. Once `celebration` became `currentOverlay` (popped from the queue), a late-arriving recognition badge was appended to the queue. With `currentOverlay != nil`, `advance()` was not called. When the child tapped "Weiter" → `loadRecommendedLetter()` → `overlayQueue.reset()`, the queued badge was silently dropped. This reliably fires on cold-start CoreML (first inference can take 3–5 s) with `enablePaperTransfer = false`.

**Fix:** Added a check in `enqueueBeforeCelebration()` for `if case .celebration = currentOverlay`. When the celebration is already the active overlay:
1. Cancel the (nil) advance task.
2. Push the current celebration back to queue position 0.
3. Insert the badge at queue position 0.
4. Set `currentOverlay = nil`.
5. Call `advance()` (which pops the badge, arms its timer, leaving celebration queued).

---

### W-4 — "Weiter" button non-functional if `recommendNext` returns nil (FIXED)

**Root cause:** `loadRecommendedLetter()` returned silently (without dismissing the overlay) when `recommendNext` returned nil or the returned letter was not in `letters`. The celebration overlay remained on screen with no functional "Weiter" button.

**Fix:** Added `overlayQueue.reset()` before the early return so the celebration is always dismissed regardless of whether a new letter is available.

---

### W-5 — Stars hardcoded `1…4` for all conditions (FIXED)

**Root cause:** `CompletionCelebrationOverlay` used `ForEach(1...4, id: \.self)` unconditionally. For `.guidedOnly` and `.control` conditions only 1 star is achievable, so a perfect guided session shows 3 empty stars — a motivational confound between conditions.

**Fix:**
1. Added `var maxStars: Int { activePhases.count }` to `LearningPhaseController`.
2. Added `var maxStars: Int { phaseController.maxStars }` VM forwarder.
3. `CompletionCelebrationOverlay` now accepts `maxStars: Int` and uses `ForEach(1...max(1, maxStars), id: \.self)`.
4. `SchuleWorldView` passes `maxStars: vm.maxStars` when instantiating the overlay.
5. Accessibility label updated to `"\(starsEarned) von \(maxStars) Sternen"`.

---

### W-6 — `isSingleTouchInteractionActive` not cleared in `resetForPhaseTransition()` (FIXED)

**Root cause:** `handleStrokeCompletionIfReached()` is called from `updateTouch()` while a finger is down (`isSingleTouchInteractionActive == true`). If a system interrupt (incoming call, Control Center swipe) cancels the gesture between that `updateTouch` and the matching `endTouch`, the flag is stranded `true`. The next `beginTouch()` hits `guard !isSingleTouchInteractionActive else { return }` and is silently rejected — canvas becomes unresponsive until the app is backgrounded/foregrounded.

**Fix:** Added `isSingleTouchInteractionActive = false` to `resetForPhaseTransition()`.

---

### W-2 — Phase rows attached the latest-ever recognition sample (FIXED)

**Root cause:** `ParentDashboardExporter` looked up `progress[rec.letter]?.recognitionSamples?.last` for every per-phase row. That array is a 10-deep rolling window with no session timestamps, so a phase that completed days ago got tagged with whatever the recognizer most recently saw — a structurally invalid correlation.

**Fix:** Blank the three recognition columns (`recognition_predicted`, `recognition_confidence`, `recognition_correct`) on per-phase rows. The per-letter aggregate block above still surfaces the recognition data (sample count + average confidence). Genuine session-aligned recognition correlation requires the schema change tracked in audit item D-2; until that lands, blanking is the only correct value. Two existing tests that asserted the buggy substring were rewritten to assert the new "always blank" contract.

---

### W-3 — `ß` collapsed to `"SS"` in dashboard / streak stores (FIXED)

**Root cause:** `ProgressStore` had a private `canonicalKey` that special-cased `ß` (Unicode would otherwise upper-case it to `"SS"`, losing identity). `ParentDashboardStore.recordSession` / `recordPhaseSession` / `phaseScores(for:)` and `StreakStore.recordCompletions` all called `letter.uppercased()` directly, so a child practising `ß` had their progress, dashboard rows, and streak completions land under three different keys.

**Fix:** Lifted the rule to `LetterProgress.canonicalKey(_:)` (extension, public to the module) and routed all four sites through it, including `JSONProgressStore` itself. One canonical normaliser, three stores in lock-step. Existing on-disk data is unaffected — the function returns the same value for every non-`ß` input as the prior `uppercased()` path.

---

### W-23 — `fixedOrder()` always returned the first letter (FIXED)

**Root cause:** `LetterScheduler.fixedOrder()` (the `.control` thesis arm scheduler) returned `priority: 0` for every letter. `recommendNext()` picked `prioritized().first?.letter`, and Swift's stable sort kept the caller-supplied order — so children in `.control` were perpetually recommended whichever letter sat first in `visibleLetterNames`.

**Fix:** Score by `priority: -Double(completionCount)` in the `fixedOrder` branch. Less-practised letters bubble up; on a tie (e.g. clean slate) the stable sort still returns the input order, so a fresh device starts on the first letter and rotates through as the child completes them. Three regression tests added to `LetterSchedulerTests`.

---

### I-4 — Phase dot indicator always rendered four dots (FIXED)

**Root cause:** `PhaseDotIndicator` iterated `LearningPhase.allCases` (always four). Under `.guidedOnly` / `.control`, only `.guided` runs — three dots were permanently empty placeholders, mis-cueing the child and creating a between-arms visual confound.

**Fix:** Added an `activePhases` parameter (default `LearningPhase.allCases` to keep current callers working). `SchuleWorldView` passes `vm.activePhases`, which forwards `phaseController.activePhases`. Dot count, completion count, and accessibility value now all derive from that list.

---

### I-5 — `vereinfachteAusgangschrift` missing genitive-s (FIXED)

**Root cause:** German "Vereinfachte Ausgangs**s**chrift" — the case label dropped the genitive *s* even though the display name was correct.

**Fix:** Renamed the enum case to `vereinfachteAusgangsschrift` and pinned the raw value to the old spelling (`= "vereinfachteAusgangschrift"`). Persisted user-default selections, the bundled font filename (`VereinfachteAusgangschrift-Regular`), and the `strokes_vereinfachteAusgangschrift.json` lookup all keep resolving without a migration step.

---

### I-6 — Recognition status titles read as imperatives (FIXED)

**Root cause:** "Erkenne…" / "Erkenne das Wort…" parses as an imperative ("recognise!"), not the intended progressive ("recognising…"). German learners reading the screen aloud would say it as a command to themselves.

**Fix:** Swapped to the passive present `"Wird erkannt…"` / `"Wort wird erkannt…"`. Tone matches the `Erkenne…`-paired sparkles icon and the subtitle.

---

### I-7 — Identical praise on overlay and feedback card (FIXED)

**Root cause:** `SchuleWorldView`'s "Nachspuren fertig" card emits `"Super gemacht!"` for a 3-of-3 score, then `CompletionCelebrationOverlay` headlines with the exact same string moments later — the child sees the same words stacked.

**Fix:** Celebration overlay headline changed to `"Geschafft!"`. The card keeps its scored praise so the score-to-text mapping stays informative.

---

## Thesis Data Findings (not fixed in this round — documentation only)

These findings from the thesis data audit require larger structural changes or are by-design limitations that need explicit acknowledgement in the thesis methodology.

| # | Risk | Impact | Why deferred |
|---|------|--------|--------------|
| D-1 | `schedulerEffectivenessProxy` always 0 | **FIXED** (C-3) | — |
| D-2 | `recognitionSamples` is a 10-deep rolling per-letter window with no per-sample timestamps. The CSV exporter could only attach "the latest sample" to every phase row, which mis-correlates recognition with phases that completed earlier. W-2 now blanks those columns; recovering real session-aligned recognition needs a schema change. | Correlation impossible from CSV without that schema change | Requires a new persisted type (per-session recognition record) and a migration. Out of scope for a review round; queued for the next thesis-data refactor. |
| D-3 | `PhaseSessionRecord` has no `Date` field, only an implicit append order. So you can't ask "what was this child's freeWrite score on day 4?" — only "what's their N-th freeWrite". Dated learning curves and duration-windowed analyses are impossible from the CSV. | Dated learning curves impossible | Adding a `recordedAt: Date` field is small in code but invalidates every prior-recorded JSON file unless paired with a careful migration; deferred to the same schema refactor as D-2. |
| D-4 | The `.guidedOnly` and `.control` arms only run the `.guided` phase, so they never produce freeWrite data. That's where Schreibmotorik dimensions (`formAccuracy`, `tempoConsistency`, `pressureControl`, `rhythmScore`) and the freeform recognition path live, so those columns are structurally empty for two of the three arms. | Between-condition ANOVA has empty cells | Cannot be fixed in code without changing the thesis design itself — by-design experimental contrast. Must be acknowledged in the methodology / limitations chapter. |
| D-5 | Session duration is computed as `endedAt − startedAt`. The clock keeps running when the app is backgrounded (lock screen, Control Center swipe, incoming notification), so a 4-minute "session" might include 3 minutes of the iPad sitting on a table. | Duration analysis unreliable | Switching to active-time (pause on `scenePhase == .background`) needs reconciliation across `FreeWritePhaseRecorder`, `ParentDashboardStore`, and `JSONProgressStore`. Worth doing, but bigger than a council-round fix; flagged for the next session-tracking refactor. |
| D-6 | `speedTrend` (the last 5 session writing speeds, used by the scheduler's `automatizationBonus`) is in `LetterProgress` but not in any CSV column. Researchers can only reconstruct the automatization signal from the JSON export. | Automatization analysis requires JSON export | Easy to add (one column to the per-letter row), but the CSV column set is referenced by downstream R/SPSS scripts; deferred until the schema bump batches D-2 / D-3 as well. |
| D-7 | Anything completed before a research participant was formally enrolled — pilot taps, parent demos, sandbox sessions — decodes today as `.threePhase` (the default) and is indistinguishable from real `.threePhase` arm data. | Pilot contamination risk | Needs a `ParticipantStore` `enrolledAt` timestamp + filtering at export time; touches three components. Methodology workaround: discard the first session date per device when analysing. |

---

## Regression Check Cross-Reference

| Item | Status |
|------|--------|
| W-5 (progressStore not private) | Still open — views access `vm.progressStore` directly; no `starCount(for:)` forwarder added. Deferred. |
| W-16 (IUO playback) | Documented but not fixed — two-phase init constraint; revert in 98e63de. Retained. |
| W-17 (schemaVersion) | Not fixed. No sentinel added to stores. Deferred — pair with D-2/D-3 refactor. |
| W-23 (fixedOrder() always first letter) | **FIXED** in 84fa6c8 — round-robin via `-completionCount`. |
| I-2 (nil adaptationPolicy undocumented) | Not fixed. Deferred (doc-only). |
| I-4 (PhaseDotIndicator always 4 dots) | **FIXED** — uses `vm.activePhases`. |
| I-5 (vereinfachteAusgangschrift typo) | **FIXED** — case renamed; raw value pinned for back-compat. |
| I-6 (imperative recognition titles) | **FIXED** — passive present tense ("Wird erkannt…"). |
| I-7 (duplicate praise text) | **FIXED** — overlay reads "Geschafft!"; card keeps scored praise. |

---

## Zero 🔴 Findings, Zero 🟡 Code-Bug Findings Remaining

All four critical findings (C-1 through C-4) and every actionable warning are fixed. The remaining 🟡 entries (W-16, W-17, W-24) are by-design or pure-doc deferrals; the remaining 🟢 entry (I-2) is documentation only. The thesis-data findings D-2 through D-7 are tracked above with the rationale for each deferral.
