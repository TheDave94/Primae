# Hidden Features, Orphaned Views, and Data Dark Spots Audit

## A. Hidden Features (Implemented but Not Accessible from GUI)

### A.1 TracingDependencies Configuration (Not Exposed)

| Feature | Type | Location | Default | Purpose | Should Expose | Reason |
|---------|------|----------|---------|---------|---------------|--------|
| `adaptationPolicy` | Optional<AdaptationPolicy> | TracingDependencies.swift:22 | Condition-dependent (MovingAverage or Fixed) | Controls difficulty live-adaptation; Fixed for control condition to prevent confounding | debug-only | Allows test/researcher to lock difficulty progression for validation |
| `thesisCondition` | ThesisCondition | TracingDependencies.swift:29 | `.defaultForInstall` (reads ParticipantStore) | A/B study condition assignment; gates full 4-phase vs 1-phase pedagogy | research-only | Researcher needs visibility; parent can toggle via "Studienteilnahme" in SettingsView (✓ exposed) |
| `letterOrdering` | LetterOrderingStrategy | TracingDependencies.swift:31 | Persisted UserDefaults | Alphabet order (motor similarity / alphabetic / frequency) | parent-only (✓) | SettingsView line 19–22 exposes this; currently accessible |

### A.2 TracingViewModel Observable State (Hidden from GUI)

| Feature | Type | Location | Default | Purpose | Should Expose | Reason |
|---------|------|----------|---------|---------|---------------|--------|
| `showGhost` | Bool | TracingViewModel.swift:12 | false | Render blue stroke-direction guide lines | yes (parent) | Currently toggleable only via debug; should move to SettingsView for parent accessibility |
| `showAllLetters` | Bool | TracingViewModel.swift:13 | false | Demo mode: show full alphabet vs 7-letter demo set | debug-only | Only meaningful for onboarding/demo; no parent UI path visible |
| `showDebug` | Bool | TracingViewModel.swift:16 | false | Gate for debug panels (calibration, audio, metrics) | debug-only | Long-press on phase indicator toggles this (code line 44); undocumented feature |
| `showCalibration` | Bool | TracingViewModel.swift:21 | false | Stroke calibration overlay focus (hides other debug panels) | debug-only | Child on iPad can enter via undocumented gesture; should be gated to parent area |
| `pencilPressure` | CGFloat? | TracingViewModel.swift:14 | nil | Live digitizer force reading (Apple Pencil) | debug-only | Exposed in debug audio panel; no parent toggle |
| `pencilAzimuth` | CGFloat | TracingViewModel.swift:15 | 0 | Live Apple Pencil tilt angle | debug-only | Debug audio panel only |
| `letterOrdering` (mutable) | LetterOrderingStrategy | TracingViewModel.swift:28 | `.motorSimilarity` | Sortable copy of active ordering (can be changed live) | parent-only (✓) | Exposed in SettingsView; parent can change |
| `schriftArt` (mutable) | SchriftArt | TracingViewModel.swift:29 | `.druckschrift` | Font: Druckschrift (print) or Schreibschrift (cursive) | parent-only (✓) | Exposed in SettingsView lines 14–18; full picker available |
| `showingVariant` | Bool | TracingViewModel.swift:314 | false | Trace alternate stroke order (Schulschrift 1995 variant) | parent-only (✓) | Visible as "Variante" button in canvas; parent can toggle per letter |
| `enablePaperTransfer` | Bool | TracingViewModel.swift:316 | false (persisted) | After freeWrite, request paper-transfer phase | parent-only (✓) | SettingsView lines 32–36; fully exposed |
| `enableFreeformMode` | Bool | TracingViewModel.swift:324 | true (persisted) | Show "Freies Schreiben" (blank-canvas letter recognition) mode | parent-only (✓) | SettingsView lines 25–29; fully exposed |
| `feedbackIntensity` | CGFloat (computed) | TracingViewModel.swift:226 | Phase-dependent (1.0→0.6→0.0) | Guidance fading: observe/direct=full, guided=moderate, freeWrite=none | debug-only | Derived from phase; no parent control (by design, research constraint) |
| `velocitySmoothingAlpha` | CGFloat | TracingViewModel.swift:566 | 0.22 | Touch-velocity smoothing factor (debug audio panel only) | debug-only | Tunable in debug UI; child can hear speed-based audio feedback in real-time |
| `playbackActivationVelocityThreshold` | CGFloat | TracingViewModel.swift:567 | 22 pt/s | Minimum velocity to trigger playback audio | debug-only | Debug audio panel slider; no parent control |
| `minimumTouchMoveDistance` | CGFloat | TracingViewModel.swift:568 | 1.5 | Hysteresis on touch movement (ignores sub-pixel noise) | debug-only | Debug UI; no parent control |

### A.3 Speech & Haptics (Configured but Not Tunable)

| Feature | Type | Location | Default | Purpose | Should Expose | Reason |
|---------|------|----------|---------|---------|---------------|--------|
| `speech` (SpeechSynthesizing) | Protocol impl | TracingDependencies.swift:43 / TracingViewModel.swift:507 | AVSpeechSpeechSynthesizer (live TTS) | German child-facing verbal feedback (phase entries, recognition, celebrations) | no | Child-facing audio; parent shouldn't control speech rate/pitch directly (pedagogical constraint) |
| `haptics` (HapticEngineProviding) | Protocol impl | TracingDependencies.swift:15 / TracingViewModel.swift:476 | CoreHapticsEngine (live haptic) | Haptic feedback on stroke completion | no | Consistency constraint; not parent-tunable |
| Haptic intensity override | N/A | Not exposed | N/A | No slider for haptic intensity | no | Apple's haptic engine doesn't expose dynamic intensity to third-party apps |

### A.4 LetterRecognizer Configuration (Fixed)

| Feature | Type | Location | Default | Purpose | Should Expose | Reason |
|---------|------|----------|---------|---------|---------------|--------|
| `letterRecognizer` | LetterRecognizerProtocol | TracingDependencies.swift:38 | CoreMLLetterRecognizer (live model) | CoreML-backed letter recognition for freeform/freeWrite | no | Model is fixed post-training; parent shouldn't retrain or swap |

---

## B. Orphaned Views (Created but Never Displayed)

### B.1 Views That ARE Reachable (Fully Integrated)

| View | File:Line | Status | Reachability |
|------|-----------|--------|--------------|
| `RecognitionFeedbackView` | RecognitionFeedbackView.swift:18 | **INTEGRATED** | SchuleWorldView.swift:141 displays via `overlayQueue.currentOverlay == .recognitionBadge` |
| `PaperTransferView` | PaperTransferView.swift:7 | **INTEGRATED** | SchuleWorldView.swift:153 displays via `overlayQueue.currentOverlay == .paperTransfer` |
| `CompletionCelebrationOverlay` | CompletionCelebrationOverlay.swift:1 | **INTEGRATED** | SchuleWorldView.swift:159 displays via `overlayQueue.currentOverlay == .celebration` |
| `StrokeCalibrationOverlay` | StrokeCalibrationOverlay.swift:11 | **INTEGRATED** | TracingCanvasView renders when `vm.isCalibrating` (showDebug && showCalibration) |
| `PhaseRatesView` | PhaseRatesView.swift:1 | **INTEGRATED** | ParentDashboardView.swift:102 displays phase completion rates |
| `PracticeTrendChart` | PracticeTrendChart.swift:1 | **INTEGRATED** | ParentDashboardView.swift:108 displays 30-day practice trend |
| `ParentDashboardView` | ParentDashboardView.swift:6 | **INTEGRATED** | ParentAreaView.swift:70 routes via .overview case |
| `ResearchDashboardView` | ResearchDashboardView.swift:17 | **INTEGRATED** | ParentAreaView.swift:72 routes via .research case |
| `SettingsView` | SettingsView.swift:3 | **INTEGRATED** | ParentAreaView.swift:74 routes via .settings case (also ParentDashboardView.swift:43) |
| `ExportCenterView` (private) | ParentAreaView.swift:83 | **INTEGRATED** | ParentAreaView.swift:76 routes via .export case |
| `LetterWheelPicker` | LetterWheelPicker.swift:1 | **INTEGRATED** | SchuleWorldView.swift:100 displayed on long-press letter pill |

### B.2 Conclusion: No Orphaned Views Found

All SwiftUI View structs in `/BuchstabenNative/Features/` are either:
- Part of the active navigation tree (MainAppView → Worlds → child views)
- Part of the modal/overlay queue (OverlayQueueManager)
- Debug-gated (shown only when `showDebug == true`)
- Routed via ParentAreaView's NavigationSplitView

**No dead code found.** Every View is referenced and displayed via an active control flow path.

---

## C. Data Dark Spots (Collected but Not Surfaced)

### C.1 WritingAssessment Four Dimensions (Collected in freeWrite Phase)

| Field | Type | Collected By | Exported | Parent Dashboard | Research Dashboard | Notes |
|-------|------|--------------|----------|------------------|-------------------|-------|
| `formAccuracy` | CGFloat | FreeWriteScorer.swift:21 (Fréchet distance) | ✓ ParentDashboardExporter.swift:147 | ✗ Not in ParentDashboardView | ✓ ResearchDashboardView.swift:64 (Ø Form tile) | Stored in PhaseSessionRecord.formAccuracy |
| `tempoConsistency` | CGFloat | FreeWriteScorer.swift:23 (speed variance) | ✓ ParentDashboardExporter.swift:148 | ✗ Not in ParentDashboardView | ✓ ResearchDashboardView.swift:67 (Ø Tempo tile) | Stored in PhaseSessionRecord.tempoConsistency |
| `pressureControl` | CGFloat | FreeWriteScorer.swift:25 (force variance) | ✓ ParentDashboardExporter.swift:149 | ✗ Not in ParentDashboardView | ✓ ResearchDashboardView.swift:70 (Ø Druck tile) | Stored in PhaseSessionRecord.pressureControl |
| `rhythmScore` | CGFloat | FreeWriteScorer.swift:27 (active time ratio) | ✓ ParentDashboardExporter.swift:150 | ✗ Not in ParentDashboardView | ✓ ResearchDashboardView.swift:71 (Ø Rhythmus tile) | Stored in PhaseSessionRecord.rhythmScore |

**Dark Spot Finding:** Parent-facing ParentDashboardView shows only `averageFreeWriteScore` (overall weighted composite) but does NOT break down the four Schreibmotorik dimensions. They are:
- ✓ Exported to CSV/TSV/JSON (lines 234–238 ParentDashboardExporter)
- ✓ Shown in ResearchDashboardView (researcher-only)
- ✗ NOT shown to parent in ParentDashboardView (only composite % in line 82)

**Recommendation:** Add a "Schreibqualität (Details)" collapsible section to ParentDashboardView that breaks down Form, Tempo, Druck, Rhythmus percentages.

---

### C.2 LetterProgress Fields (Per-Letter Statistics)

| Field | Type | Location | Written | Parent Dashboard | Child UI | Notes |
|-------|------|----------|---------|------------------|----------|-------|
| `recognitionAccuracy` | [Double]? | ProgressStore.swift:53 | progressStore.recordCompletion() / recordRecognitionSample() | ✓ ParentDashboardView.swift:169 (list of letters with avg %) | ✗ Not shown to child | Last 10 confidence scores; capped per ProgressStore.swift:292 |
| `recognitionSamples` | [RecognitionSample]? | ProgressStore.swift:61 | progressStore.recordCompletion() / recordRecognitionSample() | ✗ Aggregated only as confidence avg | ✗ Not shown to child | Richer format (predicted letter, isCorrect); capped at 10 |
| `speedTrend` | [Double]? | ProgressStore.swift:41 | progressStore.recordCompletion() (line 238) | ✗ Not shown in ParentDashboardView | ✓ FortschritteWorldView.swift:174–192 (fluency footer: improving/stable/declining) | Capped at 50 samples (ProgressStore.swift:246); automatization tracking |
| `paperTransferScore` | Double? | ProgressStore.swift:44 | progressStore.recordPaperTransfer() (called from vm.submitPaperTransfer) | ✓ ParentDashboardView.swift:141–157 (emoji summary table) | ✗ Not shown to child | One score per letter; only shown if enablePaperTransfer was on |
| `lastVariantUsed` | String? | ProgressStore.swift:47 | progressStore.recordVariant() (vm.submitVariantUsage) | ✗ Not shown to parent | ✗ Not shown to child | Which variant was last used (e.g. "variant"); useful for audit |
| `freeformCompletionCount` | Int? | ProgressStore.swift:65 | progressStore.recordFreeformCompletion() (vm freeform letter completion) | ✗ Not shown in ParentDashboardView | ✗ Not shown to child | Separate counter for blank-canvas mode vs guided mastery |
| `phaseScores` | [String: Double]? | ProgressStore.swift:38 | progressStore.recordCompletion() with phaseScores dict | ✓ ParentDashboardView.swift:120 (phaseScores used for detail row) + ✓ ResearchDashboardView.swift:177–185 (per-phase raw scores) | ✗ Not shown to child | Per-phase accuracy; used to compute LetterStars for gallery |

**Dark Spot Findings:**

1. **speedTrend (per-letter writing speed):**
   - ✓ Written to ProgressStore (capped 50 samples)
   - ✓ Exported to CSV (ParentDashboardExporter.swift:92)
   - ✗ NOT displayed to parent in ParentDashboardView
   - ✓ SHOWN to child as aggregated trend (Fortschritte world fluency footer)
   - **Recommendation:** Add per-letter speed trend sparkline to ParentDashboardView

2. **freeformCompletionCount:**
   - ✓ Written and persisted
   - ✗ NOT displayed anywhere (parent or child)
   - ✗ NOT exported to CSV/JSON
   - **Recommendation:** Export to CSV; show in parent dashboard as "Freies Schreiben: N Versuche" per letter

3. **lastVariantUsed:**
   - ✓ Written (for audit trail)
   - ✗ NOT displayed to parent
   - ✗ NOT exported to CSV
   - **Recommendation:** Not critical; low priority for display

---

### C.3 PhaseSessionRecord Fields (Session-Level Telemetry)

| Field | Type | Location | Written | Parent Dashboard | Research Dashboard | Notes |
|-------|------|----------|---------|------------------|-------------------|-------|
| `schedulerPriority` | Double | ParentDashboardStore.swift:13 | dashboardStore.recordPhaseSession() (from vm.phaseController scoring) | ✓ ParentDashboardExporter.csv (column: schedulerPriority) | ✗ Not explicitly shown; used for effectiveness proxy calc | Ebbinghaus spaced-rep weight |
| `condition` | ThesisCondition | ParentDashboardStore.swift:17 | dashboardStore.recordPhaseSession() | ✓ ParentDashboardExporter (lines 152, 178) | ✓ ResearchDashboardView.swift:121–138 (condition distribution pie) | A/B arm assignment |
| `recordedAt` | Date? | ParentDashboardStore.swift:22 | dashboardStore.recordPhaseSession() (default: Date()) | ✓ ParentDashboardExporter (line 143, ISO8601) | ✗ Not displayed | Added D-3; enables time-of-day analysis (morning vs evening) |
| `inputDevice` | String? | ParentDashboardStore.swift:38 | dashboardStore.recordPhaseSession() (inputDevice param) | ✓ ParentDashboardExporter.csv (line 156) | ✗ Not displayed as table column | D-6: "finger" / "pencil"; disambiguates pressure=1.0 (finger has no force data) |
| `formAccuracy`, `tempoConsistency`, `pressureControl`, `rhythmScore` | Double? | ParentDashboardStore.swift:24–27 | PhaseSessionRecord.init() from assessment (lines 53–56) | ✗ Only aggregated means shown | ✓ ResearchDashboardView.swift:177–185 (per-session table) | Schreibmotorik dimensions; only for freeWrite rows |
| `recognitionPredicted`, `recognitionConfidence`, `recognitionCorrect` | String?, Double?, Bool? | ParentDashboardStore.swift:31–33 | PhaseSessionRecord.init() from recognition sample (lines 57–59) | ✗ Not shown to parent | ✓ ResearchDashboardView.swift:101–107 (recognition table, last sample only) | D-2: per-session recognition outcome |

**Dark Spot Findings:**

1. **inputDevice ("finger" vs "pencil"):**
   - ✓ Written and exported to CSV
   - ✗ NOT displayed to parent
   - ✓ SHOWN in research dashboard table (ResearchDashboardView line 177)
   - **Recommendation:** Low parent visibility need (mostly research); current placement in research-only dashboard is appropriate

2. **recordedAt timestamp:**
   - ✓ Written (D-3)
   - ✓ Exported to CSV (ISO8601)
   - ✗ NOT displayed to parent
   - ✓ Exported to JSON (SnapshotWithMetrics includes raw records)
   - **Recommendation:** Low parent visibility need; timestamp exists for analytics layer

3. **schedulerPriority:**
   - ✓ Written (from LetterScheduler)
   - ✓ Exported to CSV (line 142)
   - ✗ NOT displayed to parent
   - ✓ USED in research dashboard for effectiveness proxy (Pearson correlation, line 147–157)
   - **Recommendation:** Appropriate placement (research metric); parent doesn't need to see raw priorities

---

### C.4 SessionDurationRecord Fields (Daily Practice Time)

| Field | Type | Location | Written | Parent Dashboard | Export | Notes |
|-------|------|----------|---------|------------------|--------|-------|
| `dateString` | String | ParentDashboardStore.swift:107 | recordSession() | ✓ ParentDashboardView (implicit in PracticeTrendChart) | ✓ CSV | "yyyy-MM-dd" format |
| `durationSeconds` | TimeInterval | ParentDashboardStore.swift:109 | recordSession() | ✓ ParentDashboardView (line 78: 7-day total, line 108: chart) | ✓ CSV | Total seconds per day |
| `condition` | ThesisCondition | ParentDashboardStore.swift:111 | recordSession() | ✗ Not shown per session | ✓ CSV (line 103) | A/B arm for that session |
| `recordedAt` | Date? | ParentDashboardStore.swift:117 | recordSession() default Date() | ✗ Not shown to parent | ✓ CSV (line 105, ISO8601) | D-9: full timestamp for time-of-day analysis |

**Assessment:** All sessionDuration data is appropriately displayed to parent (trend chart, totals); no dark spots.

---

### C.5 DashboardSnapshot Derived Metrics (Already Exported, Not Shown to Parent)

| Metric | Type | Computed | Export | Parent Dashboard | Notes |
|--------|------|----------|--------|------------------|-------|
| `phaseCompletionRates` | [String: Double] | DashboardSnapshot.swift:187 (rate per phase) | ✓ CSV (lines 162–168) | ✓ ParentDashboardView.swift:102 (PhaseRatesView) | Shows observe/direct/guided/freeWrite completion % |
| `averageFreeWriteScore` | Double | DashboardSnapshot.swift:240 (mean score) | ✓ CSV (line 170) | ✓ ParentDashboardView.swift:82 (Schreibqualität %) | Parent sees composite only |
| `averageWritingDimensions` | Tuple (form, tempo, pressure, rhythm) | DashboardSnapshot.swift:250 | ✓ CSV (lines 235–238) + ✓ JSON | ✗ ParentDashboardView (only composite) | Schreibmotorik breakdown available in research dashboard |
| `schedulerEffectivenessProxy` | Double (Pearson r) | DashboardSnapshot.swift:265 (correlation) | ✓ CSV (line 171) + per-condition (209) | ✗ ParentDashboardView; ✓ DEBUG (line 193) | Research metric; shown only if `vm.showDebug` (undocumented) |
| `topLetters` | [LetterAccuracyStat] | DashboardSnapshot.swift:162 | ✗ Not exported | ✓ ParentDashboardView.swift:114 | Top 5 by accuracy |
| `lettersBelow(threshold)` | [LetterAccuracyStat] | DashboardSnapshot.swift:169 | ✗ Not exported | ✓ ParentDashboardView.swift:128 | Letters below 70% |
| `totalPracticeTime(days)` | TimeInterval | DashboardSnapshot.swift:175 | ✗ Not exported | ✓ ParentDashboardView.swift:78 (7-day) | Implicit in duration data |
| `dailyPracticeMinutes(days)` | [(date, minutes)] | DashboardSnapshot.swift:218 | ✗ Not exported | ✓ ParentDashboardView.swift:108 (PracticeTrendChart) | 30-day trend chart |

**Assessment:** Parent-visible metrics are well-selected; research-only metrics appropriately gated.

---

### C.6 StreakStore State (Appropriately Exposed)

| Field | Type | Location | Visible | Notes |
|--------|------|----------|---------|-------|
| `currentStreak` | Int | StreakStore.swift:39 | ✓ ParentDashboardView.swift:70 + ✓ FortschritteWorldView.swift:78 | Child sees "X Tage", parent sees same count |
| `longestStreak` | Int | StreakStore.swift:40 | ✓ ParentDashboardView.swift:73 | Parent sees "beste Serie" |
| `totalCompletions` | Int | StreakStore.swift:41 | ✓ ParentDashboardView.swift:66 (implicit in letter count) | Parent sees letter count |
| `completedLetters` | Set<String> | StreakStore.swift:42 | ✓ ParentDashboardView (letter gallery) | Child sees completed letters |
| `earnedRewards` | Set<String> | StreakStore.swift:43 | ✗ Not displayed; ✓ Available for future celebration UI | Achievement system exists but UI not yet built |
| `lastPracticeDayString` | String | StreakStore.swift:45 | ✗ Not displayed | Used only internally for streak logic |
| `streakStartDayString` | String | StreakStore.swift:47 | ✗ Not displayed | Used only internally |

**Assessment:** Streak data is well-surfaced. RewardEvent enum (StreakStore.swift:5) exists (firstLetter, dailyGoalMet, streakDay3, streakWeek, streakMonth, allLettersComplete, perfectAccuracy, centuryClub) but no celebration UI is implemented — `earnedRewards` is collected but never shown to child/parent.

---

### C.7 ParticipantStore (Enrollment / Condition Assignment)

| Field | Type | Location | Parent Dashboard | Research Dashboard | Export | Notes |
|-------|------|----------|------------------|-------------------|--------|-------|
| `participantId` | UUID | ParticipantStore (static) | ✗ Not shown to parent | ✓ ResearchDashboardView.swift:44 (copyable UUID) | ✓ CSV header (line 65) | Stable across reinstalls; needed for A/B analysis |
| `enrolledAt` | Date? | ParticipantStore (static) | ✗ Not shown | ✓ Could be shown in research dashboard | ✓ CSV header (line 71) if set | D-7: enrollment timestamp; filters pre-enrollment records from export |
| `isEnrolled` (thesisCondition flag) | Bool | SettingsView.swift:7 / ParticipantStore | ✓ SettingsView.swift:38 (toggle "Studienteilnahme") | ✗ Not explicitly shown; visible via condition arm | ✗ Condition is in CSV | Parent can enroll/unenroll; SettingsView explains effect |

**Assessment:** ParticipantStore state is appropriately controlled via SettingsView toggle. `participantId` is shown in research dashboard. `enrolledAt` is exported but not displayed (low visibility need).

---

## Summary Table: All Dark Spots and Recommendations

| Dark Spot | Severity | Recommendation | Priority |
|-----------|----------|-----------------|----------|
| Schreibmotorik dimensions (Form/Tempo/Druck/Rhythmus) not broken down in ParentDashboardView | Medium | Add collapsible section showing per-dimension averages (% or 0–1 scale) | Medium |
| `speedTrend` per-letter not shown to parent | Medium | Add sparkline or trend arrow next to each letter in "Noch zu üben" section | Low |
| `freeformCompletionCount` never shown or exported | Low | Add to ParentDashboardView per-letter as "Freies Schreiben: N Versuche"; export to CSV | Low |
| `earnedRewards` collected but never surfaced | Medium | Build celebration UI for achievements (7-day streak, all letters, etc.); integrate with overlay queue | Medium |
| Debug metrics (schedulerEffectivenessProxy) require undocumented `showDebug` toggle | Low | Document gesture; or move to research dashboard if research-only | Low |
| `showGhost` (stroke guide lines) not exposed to parent | Low | Add toggle "Hilfslinien anzeigen" to SettingsView | Low |

---

## Appendix: How to Access Hidden Features (Undocumented)

### Debug Mode Entry Point
- **Gesture:** Long-press on the phase-dot indicator at the bottom of SchuleWorldView
- **Effect:** Sets `vm.showDebug = true`, revealing:
  - Calibration overlay (if then long-press again to enable `vm.showCalibration = true`)
  - Audio panel with velocity tuning knobs
  - Letter picker visibility toggle
  - Metrics row in ParentDashboardView (if DEBUG build)

### Calibration Overlay (Stroke Editing)
- **Prerequisite:** `vm.showDebug && vm.showCalibration` both true
- **Functionality:** Interactive dot-dragging to adjust stroke checkpoints
- **Persistence:** Saves to per-script JSON (Application Support/BuchstabenNative/calibration/)
- **Scope:** Druckschrift only (Schreibschrift strokes are read-only from bundle)

### Full-Alphabet Demo Mode
- **Toggle:** `vm.showAllLetters` (toggled in debug panel)
- **Default:** 7-letter demo set (A, F, I, K, L, M, O)
- **Effect:** LetterPickerBar and LetterWheelPicker show full 26-letter alphabet

