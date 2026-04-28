# Council Code Review — Buchstaben-Lernen-App

**Date:** 2026-04-28  
**Reviewers:** Architecture · Safety · Scientific Methods · UX  
**Scope:** All production Swift source files in `BuchstabenNative/`  
**Severity key:** 🔴 CRITICAL · 🟡 WARNING · 🟢 INFO

Findings were cross-referenced against the actual codebase; duplicates merged, contradictions resolved by reading source. All 🔴 findings have been applied as code fixes in the same commit.

---

## Summary Table

| # | Sev | Category | Finding | File(s) | Fix |
|---|-----|----------|---------|---------|-----|
| C-1 | 🔴 | Architecture | Phase transitions guided→freeWrite and freeWrite→complete never triggered from production UI | `TracingViewModel.swift:931` | Replace `commitCompletion()` in `updateTouch` with `advanceLearningPhase()` |
| C-2 | 🔴 | Architecture | `DebugAudioPanel.swift` never instantiated (ContentView removed); 9 dead `tune*` VM properties | `DebugAudioPanel.swift`, `TracingViewModel.swift:1478–1535` | Delete file; remove `#if DEBUG` tune block |
| C-3 | 🔴 | UX | Blank canvas with no error message when letters fail to load | `SchuleWorldView.swift` | Add `ContentUnavailableView` guard |
| W-1 | 🟡 | Architecture | `TracingViewModel` God object: 2055 lines, ~16 distinct responsibilities | `TracingViewModel.swift` | Incremental extraction (see §Proposals P-1) |
| W-2 | 🟡 | Architecture | `updateTouch` is 158 lines combining proximity detection, snapping, audio, phase-completion | `TracingViewModel.swift:788` | Extract to dedicated methods (P-1) |
| W-3 | 🟡 | Architecture | `strokeEnforced` written but never read in any view or production logic | `TracingViewModel.swift:16, 530` | Remove property and toggle method |
| W-4 | 🟡 | Architecture | `completionMessage`/`dismissCompletionHUD()` are write-only from view layer | `TracingViewModel.swift:170, 1007` | Remove or wire to a view |
| W-5 | 🟡 | Architecture | `progressStore` is `internal let`; views bypass VM coordination | `TracingViewModel.swift:405` | Change to `private let`; add `starCount(for:)` forwarder |
| W-6 | 🟡 | Architecture | `TracingDependencies.live` reads `UserDefaults` at `static let` init; stale after parent settings change | `TracingDependencies.swift:89` | Document contract; or observe `UserDefaults` in VM |
| W-7 | 🟡 | Architecture | `wordCycleIndex`/`currentWordCycleLabel`/`cycleWord()` triad superseded by `SequencePickerBar` | `TracingViewModel.swift:677–694` | Remove triad |
| W-8 | 🟡 | Architecture | `CanvasOverlay.frechetScore` declared with "currently unused" comment; never enqueued | `OverlayQueueManager.swift:32` | Remove case (or implement) |
| W-9 | 🟡 | Architecture | `ProgressStoring.currentStreakDays` implemented in `JSONProgressStore` but never called in production | `ProgressStore.swift:82, 264` | Remove or move to streak store |
| W-10 | 🟡 | Architecture | `showingVariant + schriftArt` can silently produce an impossible state | `TracingViewModel.swift` | Add invariant assertion |
| W-11 | 🟡 | Architecture | `LearningPhaseController.advance()` re-entrancy window: `isLetterSessionComplete` flag set at end of method | `LearningPhaseController.swift:110` | Set flag before the side-effect block |
| W-12 | 🟡 | Architecture | `LetterPickerBar` uses `allLetterNames`; nav arrows use `visibleLetterNames` — inconsistent lists | `LetterPickerBar.swift:11`, `SchuleWorldView.swift` | Make picker use `visibleLetterNames` |
| W-13 | 🟡 | Architecture | `ProgressStoring` no-op protocol defaults silently swallow data in test stubs | `ProgressStore.swift:107–112` | Replace with `fatalError` stubs (P-3) |
| W-14 | 🟡 | Architecture | `AudioControlling.initializationError` default always returns `nil`; hides init failures in mocks | `AudioControlling.swift:20` | Remove default; require explicit stub |
| W-15 | 🟡 | Architecture | `.frechetScore` grouped with `.none` as `EmptyView`; semantic mismatch | `SchuleWorldView.swift:151` | Give explicit branch or remove the enum case |
| W-16 | 🟡 | Safety | `playback: PlaybackController!` IUO; compiler cannot verify init ordering | `TracingViewModel.swift:443` | Use `lazy var` with `preconditionFailure` |
| W-17 | 🟡 | Safety | Silent total data loss on any JSON decode failure; no schema version sentinel in any store | `ProgressStore.swift:312`, `ParentDashboardStore.swift:389`, `StreakStore.swift:185` | Add schema version; wrap field decodes in `try?` with defaults (P-5) |
| W-18 | 🟡 | Safety | Disk write failures (`try? data.write`) silently ignored in all stores | All stores | Wrap in `do/catch` with logger call |
| W-19 | 🟡 | Safety | `DispatchQueue.main.async` inside `nonisolated` callback — GCD/MainActor mixing | `AudioEngine.swift:374` | Known issue; document (file is STABLE — do not modify) |
| W-20 | 🟡 | Scientific | `haptics.fire(.strokeBegan)` fires ungated in freeWrite, violating Schmidt & Lee Guidance Hypothesis | `TracingViewModel.swift:777` | Guard with `feedbackIntensity > 0` (P-10) |
| W-21 | 🟡 | Scientific | `ConfidenceCalibrator` history boost implemented but never invoked — `historicalFormScores` always `[]` at call site | `CoreMLLetterRecognizer.swift` | Pass `progressStore.progress(for:).recognitionAccuracy` (P-4) |
| W-22 | 🟡 | Scientific | App reinstall generates new UUID, silently reassigning A/B condition mid-study | `ParticipantStore.swift` | Persist UUID in `NSUbiquitousKeyValueStore` (P-6) |
| W-23 | 🟡 | Scientific | `.control` condition does not neutralise spaced-repetition letter scheduling | `TracingDependencies.swift` | Inject `FixedLetterScheduler` for `.control` (P-7) |
| W-24 | 🟡 | Scientific | `memoryStabilityDays = 7.0` fixed for all letters; Cepeda 2006 expanding intervals not implemented | `LetterScheduler.swift` | Increase stability with `completionCount`; note limitation in thesis |
| W-25 | 🟡 | Scientific | `strokesPerSecond` measures checkpoints/second, not strokes/second — naming error | `TracingViewModel.swift`, `FreeWritePhaseRecorder.swift` | Rename to `checkpointsPerSecond` |
| W-26 | 🟡 | UX | Missing comma in VoiceOver hint (`"Tippen um"` → `"Tippen, um"`) | `RecognitionFeedbackView.swift:46` | Add comma (P-9) |
| W-27 | 🟡 | UX | Typo: `"Form (Frécheté)"` should be `"Form (Fréchet)"` | `ResearchDashboardView.swift:64` | Fix typo |
| W-28 | 🟡 | UX | English column headers in German-language parent tables (`"Letter"`, `"Score"`, `"Sessions"`, `"Ø Acc."`) | `ResearchDashboardView.swift:175, 205` | Translate to German (P-8) |
| W-29 | 🟡 | UX | Duplicate freeform prompt text with inconsistent terminal punctuation | `FreeformWritingView.swift:~187, ~380` | Unify; add period |
| W-30 | 🟡 | UX | Streak VoiceOver label always uses plural `"Tage"` even for streak of 1 | `FortschritteWorldView.swift:94` | Singular/plural branch (P-9) |
| W-31 | 🟡 | UX | Word-picker pills ~33 pt — below iOS HIG 44 pt minimum touch target | `FreeformWritingView.swift` (wordPickerStrip) | Increase vertical padding to 14 pt |
| W-32 | 🟡 | UX | `LetterPickerButton` has no `accessibilityHint` | `LetterPickerBar.swift` | Add hint (P-9) |
| W-33 | 🟡 | UX | `PaperTransferView` write-phase icon + text not grouped for VoiceOver | `PaperTransferView.swift` | `.accessibilityHidden(true)` on icon; `.accessibilityElement(children: .combine)` on VStack |
| W-34 | 🟡 | UX | `LetterWheelPicker` scrim is an interactive button behind the grid; VoiceOver focus order undefined | `LetterWheelPicker.swift` | Hide scrim from VoiceOver; add explicit Cancel button |
| W-35 | 🟡 | UX | `RecognitionFeedbackView` doc comment says "4 s" but queue fires at 3 s — view-level `.task` is dead code | `RecognitionFeedbackView.swift:13, 40`, `OverlayQueueManager.swift:54` | Remove `.task` from view; update comment |
| W-36 | 🟡 | UX | Study arm toggle restart-warning only in `accessibilityHint` — invisible to sighted parents | `SettingsView.swift:45` | Add visible `Text` caption below toggle |
| W-37 | 🟡 | UX | `FortschritteWorldView` letter gallery shows no placeholder when empty | `FortschritteWorldView.swift:99` | Add `ContentUnavailableView` or equivalent |
| W-38 | 🟡 | UX | `FreeformSurface` duplicates three tokens identical to `AppSurface` | `FreeformWritingView.swift:24–41`, `WorldPalette.swift` | Replace with `AppSurface.*` |
| W-39 | 🟡 | UX | "Mastered" green tint differs between `FortschritteWorldView` gallery and `LetterPickerBar` | `FortschritteWorldView.swift:121`, `LetterPickerBar.swift:66` | Unify to shared token in `AppSurface` |
| W-40 | 🟡 | UX | `WorldSwitcherRail` background gradient hardcoded; not in `WorldPalette` | `WorldSwitcherRail.swift:33` | Move to `WorldPalette` |
| W-41 | 🟡 | UX | PAPA missing from word list — natural pair to MAMA at difficulty 1 | `FreeformWordList.swift` | Add `FreeformWord(word: "PAPA", difficulty: 1)` |
| W-42 | 🟡 | UX | SCHULE misclassified as difficulty 2 (6 letters, SCH trigraph → difficulty 3) | `FreeformWordList.swift:35` | Move to difficulty 3 |
| W-43 | 🟡 | UX | FREUND too advanced for Austrian 1st-graders (FR onset, EU diphthong, ND coda) | `FreeformWordList.swift:39` | Replace with `BUCH` (4 letters, thematically apt) |
| I-1 | 🟢 | Architecture | Dead `tune*` debug props removed by C-2 fix | `TracingViewModel.swift:1478` | Covered by C-2 |
| I-2 | 🟢 | Architecture | `adaptationPolicy: nil` means "auto" — implicit two-level default undocumented | `TracingDependencies.swift` | Document contract in comment |
| I-3 | 🟢 | Architecture | Stale `"ContentView"` references in `TracingCanvasView` comments | `TracingCanvasView.swift:304, 507` | Update comments |
| I-4 | 🟢 | Architecture | `PhaseDotIndicator` always renders 4 dots regardless of `ThesisCondition` | `PhaseDotIndicator.swift` | Scope to `phaseController.activePhases` |
| I-5 | 🟢 | UX | `SchriftArt.vereinfachteAusgangschrift` enum case missing genitive-s | `SchriftArt.swift:13` | Rename case (display string already correct) |
| I-6 | 🟢 | UX | `"Erkenne…"` title is imperative — sounds like command to child | `FreeformWritingView.swift` | Change to `"Ich schaue…"` |
| I-7 | 🟢 | UX | `"Super gemacht!"` appears in both inline feedback card and celebration within seconds | `SchuleWorldView.swift:193`, `CompletionCelebrationOverlay.swift` | Differentiate wording |
| I-8 | 🟢 | Scientific | `direct` phase extends Pearson & Gallagher 1983 GRR — valid but not from original three-stage paper | `LearningPhase.swift` | Cite Fisher & Frey 2013 in thesis; already present in comment |
| I-9 | 🟢 | Scientific | KP overlay is terminal, not concurrent — deliberate design choice worth noting in thesis | `OverlayQueueManager.swift` | Acknowledge in thesis discussion |

---

## Detailed Findings

### C-1 — Phase transitions guided→freeWrite and freeWrite→complete unreachable

`advanceLearningPhase()` — the sole function that drives phase progression — has exactly two production call sites: `completeObservePhase()` (observe→direct) and `tapDirectDot()` (direct→guided). When the child completes all guided strokes, `updateTouch` calls `commitCompletion()` directly, bypassing `advanceLearningPhase()`. The phase controller stays at `.guided`. The `.freeWrite` phase is completely unreachable in `ThesisCondition.threePhase`. Tests call `vm.advanceLearningPhase()` directly, masking the gap.

```swift
// TracingViewModel.swift:931–940 — BEFORE fix
} else if !didCompleteCurrentLetter {
    didCompleteCurrentLetter = true
    if feedbackIntensity > 0 { haptics.fire(.letterCompleted) }
    let duration = letterLoadTime.map { CACurrentMediaTime() - $0 } ?? 0
    commitCompletion(letter: currentLetterName,
                     accuracy: accuracy,
                     duration: duration)   // records data but never advances phase
    toast("Super gemacht!")
    playback.request(.idle, immediate: true)
}
```

**Fix:** Replace `commitCompletion()` + `toast("Super gemacht!")` with `advanceLearningPhase()`. The function handles all four terminal cases:
- `threePhase` guided → freeWrite: `phaseController.advance()` returns `true` → `resetForPhaseTransition()`
- `threePhase` freeWrite → complete: returns `false` → `recordPhaseSessionCompletion()` → celebration + `commitCompletion(phaseScores:)`
- `guidedOnly` / `control` guided → complete: same as above

The `accuracy` and `duration` local variables are removed (they were only passed to the now-replaced call). `playback.request(.idle)` moves before the call to stop audio before phase teardown.

---

### C-2 — DebugAudioPanel.swift never instantiated

`DebugAudioPanel.swift:9` reads: *"Wrapped in #if DEBUG at the use site (ContentView)"*. `ContentView` was removed. No call site exists anywhere in the codebase:

```
$ grep -r "DebugAudioPanel()" BuchstabenNative/ → (no output)
```

Nine `#if DEBUG` `tune*` computed properties on `TracingViewModel` (lines 1478–1535) exist solely to feed this panel's sliders. These remain accessible via their underlying owners (`playback.*`, `audio as? AudioEngine`) if future tooling needs them.

**Fix:** `DebugAudioPanel.swift` deleted. The `#if DEBUG` `// MARK: - Debug audio tuning` block removed from `TracingViewModel.swift`.

---

### C-3 — Blank canvas when letters fail to load

If `LetterRepository` returns zero letters (missing bundle resource, SPM layout mismatch), `vm.visibleLetterNames` is empty and `vm.currentLetterImage` is nil. `SchuleWorldView.body` opens directly with `ZStack { ... TracingCanvasView() ... }` — no guard. The child sees a blank white rectangle with no glyph, no guidance, and no error message. `FortschritteWorldView` letter gallery shares the same silent-empty gap.

**Fix:** Added `if vm.visibleLetterNames.isEmpty { ContentUnavailableView(...) }` branch at the top of `SchuleWorldView.body`. German-language text; parent instructed to restart the app.

---

### W-17 — Silent total data loss on JSON decode failure

All three stores use the same pattern:

```swift
guard let data = try? Data(contentsOf: url),
      let decoded = try? JSONDecoder().decode(Store.self, from: data)
else { return Store() }   // silently discards ALL progress on any error
```

A future schema addition of a non-optional `Codable` field causes the entire store to wipe itself on all existing devices with no warning. There is no `schemaVersion` sentinel in any store.

**Recommended fix (P-5):** Add `schemaVersion: Int = 1`; implement `init(from:)` with `try?` per-field fallbacks so a corrupt entry for one letter does not wipe all others.

---

### W-20 — `.strokeBegan` haptic ungated in freeWrite

```swift
// TracingViewModel.swift:777
func beginTouch(at p: CGPoint, t: CFTimeInterval) {
    ...
    haptics.fire(.strokeBegan)   // feedbackIntensity = 0.0 in freeWrite → should be silent
```

Every other haptic and audio channel is correctly gated on `feedbackIntensity > 0`. This is the only exception. Schmidt & Lee (2005) Guidance Hypothesis requires withdrawing all real-time concurrent feedback in freeWrite. The thesis description says feedback is fully withdrawn in freeWrite; the code does not match.

**Fix (P-10):** `if feedbackIntensity > 0 { haptics.fire(.strokeBegan) }`

---

### W-21 — ConfidenceCalibrator history boost dead code

`ConfidenceCalibrator.calibrate(…historicalFormScores:)` includes a 10% confidence boost for letters the child has practised reliably. The call site in `CoreMLLetterRecognizer.makeResult` passes `historicalFormScores: []` (the default), so `scores.count >= minimumHistorySamples` is always false and the boost path is never reached. The thesis describes this feature as active.

**Fix (P-4):** Pass `(progressStore.progress(for: expectedLetter ?? "").recognitionAccuracy ?? []).map { CGFloat($0) }` at the call site.

---

### W-35 — RecognitionFeedbackView 4 s timer dead code

`RecognitionFeedbackView` has `.task { try? await Task.sleep(for: .seconds(4)); onDismiss() }`. `OverlayQueueManager` fires its timer after 3 s for `.recognitionBadge`. The queue fires first, SwiftUI removes the view, and the Task is cancelled. The file's own doc comment `"Auto-dismisses after 4 seconds"` is wrong. Any developer who "fixes" the queue to 4 s to match the comment introduces a second auto-dismiss.

**Fix (W-35):** Remove the `.task` from `RecognitionFeedbackView`; update the comment to `"Auto-dismissed after 3 s by OverlayQueueManager"`.

---

### W-41–43 — Word list issues

| # | Issue | Current | Fix |
|---|-------|---------|-----|
| W-41 | PAPA missing | Only MAMA | `FreeformWord(word: "PAPA", difficulty: 1)` |
| W-42 | SCHULE difficulty wrong | 2 | Move to 3 (6 letters, SCH trigraph) |
| W-43 | FREUND too hard | difficulty 3 | Replace with `BUCH` (4 letters, thematically apt for a letter-learning app) |

---

## Improvement Proposals

Ordered by thesis impact, then code health. All proposals improve **existing features** only — no new functionality.

---

### P-1 — Extract `updateTouch` sub-methods (Effort: M)

`updateTouch` is ~158 lines. Extract three private helpers:
- `processVelocitySmoothing(distance:dt:)`
- `updateAudioFeedback(canvasNormalized:)`
- `checkLetterCompletion()` — wraps the `grid.advanceIfCompleted()` + `advanceLearningPhase()` block

**Files:** `TracingViewModel.swift:788–946` | **Thesis impact:** None (behaviour unchanged).

---

### P-2 — Remove dead VM properties (Effort: S)

Remove `strokeEnforced`/`toggleStrokeEnforcement()` (lines 16, 530), the `completionMessage` computed forwarder and `dismissCompletionHUD()` (lines 170, 1007), and the `wordCycleIndex`/`currentWordCycleLabel`/`cycleWord()` triad (lines 677–694). All are write-only or superseded by newer UI.

**Files:** `TracingViewModel.swift` | **Thesis impact:** None.

---

### P-3 — Replace ProgressStoring no-op defaults with fatalError stubs (Effort: S)

```swift
// Current — silently swallows thesis data in any stub that omits these
extension ProgressStoring {
    func recordPaperTransferScore(...) {}
    func recordRecognitionSample(...) {}
    ...
}
// Fix
extension ProgressStoring {
    func recordPaperTransferScore(...) { fatalError("Test stub must override \(#function)") }
    ...
}
```

**Files:** `ProgressStore.swift:107–112` | **Thesis impact:** 📝 Prevents false-positive tests on paper-transfer and recognition recording.

---

### P-4 — Wire ConfidenceCalibrator history boost (Effort: S)

Pass actual historical recognition accuracy to the calibrator call site so the implemented boost activates:

```swift
// CoreMLLetterRecognizer.makeResult
let calibratedTopConfidence = calibrator.calibrate(
    rawConfidence: CGFloat(top.confidence),
    predictedLetter: rawTopLetter,
    expectedLetter: expectedLetter,
    historicalFormScores: (progressStore.progress(for: expectedLetter ?? "")
                                         .recognitionAccuracy ?? [])
                          .map { CGFloat($0) }
)
```

**Files:** `CoreMLLetterRecognizer.swift` | **Thesis impact:** 📝 Activates the feature the thesis describes; improves confidence for practised letters.

---

### P-5 — Add schema versioning to all three persistence stores (Effort: M)

Add `schemaVersion: Int = 1` to `Store`, `DashboardSnapshot`, and `StreakState`. Implement custom `init(from:)` with `try?` per-field fallbacks so partial JSON corruption never silently resets all progress.

**Files:** `ProgressStore.swift:131`, `ParentDashboardStore.swift`, `StreakStore.swift` | **Thesis impact:** 📝 High — prevents silent data loss that would corrupt study results.

---

### P-6 — Persist participant UUID in iCloud to survive reinstall (Effort: M)

Store the participant UUID in `NSUbiquitousKeyValueStore` (iCloud Key-Value) with `UserDefaults` as fallback. An app reinstall on the same iCloud account restores the same UUID and same A/B condition assignment.

**Files:** `ParticipantStore.swift` | **Thesis impact:** 📝 High — prevents silent A/B condition reassignment mid-study.

---

### P-7 — Neutralise letter scheduling for .control condition (Effort: S)

Inject a `FixedLetterScheduler` (round-robin) for `.control` in `TracingDependencies.live`. Currently all conditions receive the same Ebbinghaus-weighted scheduler, conflating the scheduling effect with the phase-progression manipulation.

**Files:** `TracingDependencies.swift`, new `FixedLetterScheduler.swift` | **Thesis impact:** 📝 Improves between-conditions validity.

---

### P-8 — Translate mixed English headers in ResearchDashboardView (Effort: S)

Lines 175 and 205 mix English (`"Letter"`, `"Score"`, `"Sessions"`, `"Ø Acc."`, `"Trend"`) into a German UI. Suggested replacements: Buchstabe · Wertung · Sitzungen · Ø Genauigkeit · Trend.

**Files:** `ResearchDashboardView.swift:175, 205` | **Thesis impact:** Presentation quality.

---

### P-9 — Targeted accessibility fixes (Effort: S each)

| Item | File | Fix |
|------|------|-----|
| Missing comma in VoiceOver hint | `RecognitionFeedbackView.swift:46` | `"Tippen, um die Rückmeldung zu schließen"` |
| Streak VoiceOver wrong grammatical number | `FortschritteWorldView.swift:94` | `vm.currentStreak == 1 ? "1 Tag hintereinander" : "\(vm.currentStreak) Tage hintereinander"` |
| `LetterPickerButton` no hint | `LetterPickerBar.swift` | `.accessibilityHint("Tippen, um diesen Buchstaben zu üben")` |
| `PaperTransferView` icon not hidden | `PaperTransferView.swift` | `.accessibilityHidden(true)` on `Image`; `.accessibilityElement(children: .combine)` on `VStack` |

**Thesis impact:** Accessibility compliance.

---

### P-10 — Haptic fading in freeWrite (Effort: S)

Guard `haptics.fire(.strokeBegan)` in `beginTouch` with `feedbackIntensity > 0`. Every other feedback channel already respects this gate; `.strokeBegan` is the sole exception.

**Files:** `TracingViewModel.swift:777` | **Thesis impact:** 📝 Ensures zero real-time concurrent haptic feedback in freeWrite, matching the Guidance Hypothesis protocol the thesis describes.

---

*End of council review — 2026-04-28*
