# Review Round 3 — Council Synthesis

Generated: 2026-04-28  
Source: Regression check + deep bug hunt + test audit + thesis data audit

---

## Summary Table (sorted by severity)

| ID | Severity | Status | File | Finding |
|----|----------|--------|------|---------|
| **C-1** | 🔴 Critical | **FIXED** | TracingViewModel:1396 | `lastGuidedScore` wiped by `clearAll()` before freeWrite begins — "Nachspuren fertig" card never shown |
| **C-2** | 🔴 Critical | **FIXED** | FreeformController:97 | `isRecognizing` stuck `true` after canvas clear — spinner permanent |
| **C-3** | 🔴 Critical | **FIXED** | TracingViewModel:1437, ParentDashboardStore:222 | `schedulerPriority` hardcoded `0` — `schedulerEffectivenessProxy` permanently 0 |
| **C-4** | 🔴 Critical | **FIXED** | OverlayQueueManager:116 | Recognition badge silently dropped when CoreML finishes after celebration already showing |
| **W-4** | 🟡 Warning | **FIXED** | TracingViewModel:1361 | "Weiter" button non-functional if `recommendNext` returns nil — child trapped on screen |
| **W-5** | 🟡 Warning | **FIXED** | CompletionCelebrationOverlay:35 | Stars hardcoded `1…4` for all conditions — motivational confound for guidedOnly/control |
| **W-6** | 🟡 Warning | **FIXED** | TracingViewModel:1396 | `isSingleTouchInteractionActive` not cleared in `resetForPhaseTransition()` — canvas lockout on interrupted gesture |
| **W-1** | 🟡 Warning | not fixed | TracingViewModel:1361 | Priority should be captured at selection time — now fixed by C-3 fix (same site) |
| **W-2** | 🟡 Warning | not fixed | ParentDashboardExporter:103 | CSV attaches latest-ever recognition sample to every phase row |
| **W-3** | 🟡 Warning | not fixed | ParentDashboardStore:344 | `ß` → `"SS"` in `PhaseSessionRecord.letter` vs `ß` in `ProgressStore` |
| **W-16** | 🟡 Warning | not fixed (documented) | TracingViewModel:497 | `playback` remains IUO — two-phase init constraint documented |
| **W-17** | 🟡 Warning | not fixed | All stores | No `schemaVersion` sentinel — silent data loss on decode failure |
| **W-23** | 🟡 Warning | not fixed (new bug) | LetterScheduler:90 | `fixedOrder()` control scheduler always returns first letter — not round-robin |
| **W-24** | 🟡 Warning | not fixed | LetterScheduler:49 | `memoryStabilityDays` fixed — no expanding-interval implementation |
| **I-2** | 🟢 Info | not fixed (documented) | TracingDependencies:16 | `adaptationPolicy = nil` meaning undocumented |
| **I-4** | 🟢 Info | not fixed | PhaseDotIndicator:26 | Always 4 dots regardless of thesis condition |
| **I-5** | 🟢 Info | not fixed | SchriftArt:11 | `vereinfachteAusgangschrift` missing genitive-s |
| **I-6** | 🟢 Info | not fixed | FreeformWritingView:368, :642 | Recognition alert titles remain imperative |
| **I-7** | 🟢 Info | not fixed | CompletionCelebrationOverlay:29 | Identical praise text in overlay and feedback card |
| **W-5** | 🟡 Warning | not fixed | CompletionCelebrationOverlay:35 | Star display condtion-agnostic — fixed in this round |

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

## Thesis Data Findings (not fixed in this round — documentation only)

These findings from the thesis data audit require larger structural changes or are by-design limitations that need explicit acknowledgement in the thesis methodology.

| # | Risk | Impact |
|---|------|--------|
| D-1 | `schedulerEffectivenessProxy` always 0 (C-3) | **FIXED** |
| D-2 | Recognition data attached at export-time from rolling window, not at session-time | Correlation impossible from CSV |
| D-3 | No per-session timestamps on `PhaseSessionRecord` | Dated learning curves impossible |
| D-4 | `.guidedOnly`/`.control` have zero Schreibmotorik + recognition data | Between-condition ANOVA has empty cells |
| D-5 | Session duration includes background time | Duration analysis unreliable |
| D-6 | `speedTrend` (5-entry rolling) absent from CSV | Automatization analysis requires JSON export |
| D-7 | Pre-enrollment records decode as `.threePhase` — indistinguishable from real data | Pilot contamination risk |

---

## Regression Check Cross-Reference

The regression check identified 5 items not fixed by round 2:

| Item | Status |
|------|--------|
| W-5 (progressStore not private) | Still open — views access `vm.progressStore` directly; no `starCount(for:)` forwarder added. Deferred. |
| W-16 (IUO playback) | Documented but not fixed — two-phase init constraint. Retained. |
| W-17 (schemaVersion) | Not fixed. No sentinel added to stores. Deferred. |
| I-2 (nil adaptationPolicy undocumented) | Not fixed. Deferred. |
| I-4 (PhaseDotIndicator always 4 dots) | Not fixed. Deferred. |
| I-5 (vereinfachteAusgangschrift typo) | Not fixed. Deferred. |
| I-6 (imperative recognition titles) | Not fixed. Deferred. |
| I-7 (duplicate praise text) | Not fixed. Deferred. |

**New bug W-23 introduced by prior round** (still open): `LetterScheduler.fixedOrder()` returns all letters with `priority: 0`; `recommendNext()` always returns the first letter in `visibleLetterNames` (stable sort on equal priorities). Control children are perpetually recommended the same single letter rather than cycling through the alphabet. Requires `fixedOrder()` to return letters in rotating fashion or `loadRecommendedLetter()` to track position.

---

## Zero 🔴 Findings Remaining

All four critical findings (C-1 through C-4) have been fixed. The guided feedback scaffold now displays correctly, the freeform spinner clears on canvas reset, the scheduler effectiveness metric is now computable from exported data, and the recognition badge no longer races the celebration to disappear.
