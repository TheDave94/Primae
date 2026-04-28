# BuchstabenNative — Architecture Reference

_Auto-generated from source. Update when adding files or changing wiring._

## What the app does

A child traces German letters with finger or Apple Pencil on an iPad.
Audio plays in real-time during tracing, speed adapts to tracing
velocity. Difficulty adapts automatically based on accuracy. Three
child-facing worlds (Schule / Werkstatt / Fortschritte) sit on a
persistent rail; a parent-gated area exposes settings, the standard
parent dashboard, a researcher-only metrics dashboard, and a CSV / TSV
/ JSON data export. Children only ever see verbal evaluations and
visual stars — every numeric metric (Schreibmotorik dimensions, CoreML
confidence, Fréchet distance) lives behind the parental gate.

7 letters have full stroke definitions and audio (A, F, I, K, L, M, O);
the remaining 26 lowercase + 4 umlauts/ß are loaded as placeholders
(empty stroke arrays) for completion testing.

## Architecture

```
BuchstabenNativeApp
└── MainAppView                     ← root, hosts WorldSwitcherRail + worlds
    ├── WorldSwitcherRail           ← persistent left rail; gear long-press → Parent Area
    ├── SchuleWorldView             ← guided 4-phase letter learning (observe → direct → guided → freeWrite)
    │   └── TracingCanvasView       ← Canvas: letter glyph + ghost + active path + KP overlay
    ├── WerkstattWorldView          ← freeform letter / word writing
    │   └── FreeformWritingView     ← blank canvas + result popup (verbal only)
    ├── FortschritteWorldView       ← child-facing star/streak/letter gallery
    └── ParentAreaView (parental gate)
        ├── ParentDashboardView     ← practice-time, per-letter accuracy, phase rates
        ├── ResearchDashboardView   ← Schreibmotorik dimensions, KI predictions, condition arms (research-only)
        ├── SettingsView            ← schriftArt / ordering / paper-transfer / freeform toggles
        └── ExportCenterView        ← CSV / TSV / JSON share-sheet export
```

`TracingViewModel` is a single shared `@Observable` instance created in
`BuchstabenNativeApp` and injected via `.environment(vm)`. All worlds
read from it; only the calibrator and parent-area mutate it directly.

## Key data flow on freeWrite end

```
endTouch → advanceLearningPhase
  ├─ runRecognizerForFreeWrite (background Task)
  ├─ overlayQueue.enqueue(.kpOverlay)
  ├─ overlayQueue.enqueue(.paperTransfer) [if enabled]
  ├─ phaseController.advance → recordPhaseSessionCompletion
  │   ├─ overlayQueue.enqueue(.celebration)
  │   ├─ speech.speak(praise)
  │   └─ progressStore + dashboardStore + streakStore writes
  └─ recognizer Task → overlayQueue.enqueueBeforeCelebration(.recognitionBadge)
                     + speech.speak(recognition message)
```

The OverlayQueueManager serialises everything: child sees one overlay
at a time in canonical order kpOverlay → recognitionBadge → paperTransfer
→ celebration, with auto-dismiss for the timed cases (kp, badge) and
explicit dismiss for the modal ones (paper-transfer, celebration).

## File map

### App/

| File | Role |
|------|------|
| `BuchstabenNativeApp.swift` | App entry. Creates the shared TracingViewModel, wires scenePhase → appDidBecomeActive / appDidEnterBackground. |
| `ContentView.swift` | `@available(*, deprecated)`. Pre-redesign root retained for chrome reference; not instantiated. |

### Core/ — wired

| File | Role |
|------|------|
| `Models.swift` | LetterAsset, LetterStrokes, StrokeDefinition, Checkpoint, TracingPoint. |
| `AppWorld.swift` | Three-world enum + display labels + accessibility labels. |
| `LearningPhase.swift` | observe / direct / guided / freeWrite. German display names. Codable rawName for persistence. |
| `LearningPhaseController.swift` | Pure-value-type FSM. ThesisCondition-aware activePhases. Star thresholds per phase (max 4 stars). |
| `LetterOrderingStrategy.swift` | motorSimilarity / wordBuilding / alphabetical with German labels. |
| `SchriftArt.swift` | druckschrift / schreibschrift / grundschrift / vereinfachteAusgangsschrift / schulausgangsschrift. The `vereinfachteAusgangsschrift` case keeps the older mis-spelled `vereinfachteAusgangschrift` raw value so persisted user-defaults and the bundled font/strokes filenames keep resolving. Schreibschrift = Playwrite AT (SIL OFL); Schulschrift 1995 was renamed in code due to font licensing. |
| `WritingMode.swift` | guided / freeform. |
| `ThesisCondition.swift` | threePhase / guidedOnly / control. ParticipantStore enrolment gate. |
| `OverlayQueueManager.swift` | FIFO of CanvasOverlay (frechetScore / kpOverlay / recognitionBadge / paperTransfer / celebration). Modal overlays carry nil duration (wait for explicit dismiss); timed overlays auto-advance. `enqueueBeforeCelebration` slots late-arriving recognition badges ahead of celebration. |
| `AudioControlling.swift` | Protocol: load, play, stop, restart, suspend / resume. |
| `PlaybackStateMachine.swift` | Pure FSM idle ↔ active. |
| `AudioEngine.swift` | ⚠️ **STABLE & FRAGILE** — do NOT modify. AVAudioEngine + AVAudioUnitTimePitch. Lifecycle observers via `nonisolated(unsafe)` static dict. |
| `SpeechSynthesizer.swift` | German AVSpeechSynthesizer wrapper for child-facing verbal feedback. ChildSpeechLibrary centralises every German phrase the synthesiser ever utters. NullSpeechSynthesizer for tests. |
| `StrokeTracker.swift` | Checkpoint proximity. ⚠️ Do NOT replace `hypot` with `distSq`. |
| `HapticEngine.swift` | CoreHapticsEngine + UIKit fallback + Null. |
| `DifficultyAdaptation.swift` | DifficultyTier + MovingAverageAdaptationPolicy + FixedAdaptationPolicy (control arm). |
| `ProgressStore.swift` | JSONProgressStore. LetterProgress carries phaseScores, speedTrend (cap 5), recognitionAccuracy (cap 10), recognitionSamples (predictedLetter + isCorrect, cap 10), paperTransferScore, lastVariantUsed, freeformCompletionCount. Exposes `LetterProgress.canonicalKey(_:)` — the shared ß-preserving normaliser every per-letter store routes through. |
| `ParentDashboardStore.swift` | JSONParentDashboardStore. PhaseSessionRecord stores all 4 Schreibmotorik dimensions for freeWrite rows. accuracySamples cap 200. |
| `ParentDashboardExporter.swift` | CSV / TSV / JSON export. Per-phase rows include 13 columns: letter, phase, completed, score, schedulerPriority, condition, recognition_predicted, recognition_confidence, recognition_correct, formAccuracy, tempoConsistency, pressureControl, rhythmScore. The three recognition columns are intentionally blank on per-phase rows — the rolling per-letter `recognitionSamples` window has no session timestamps, so the per-letter aggregate block above is the only place the recognition signal can be read without mis-correlation (review item W-2 / audit D-2). |
| `StreakStore.swift` | JSONStreakStore. RewardEvent enum. |
| `LocalNotificationScheduler.swift` | Daily reminder with quiet hours + streak-aware copy. |
| `OnboardingCoordinator.swift` | 7-step state machine (welcome → 4 phase demos → reward intro → complete). |
| `CloudSyncService.swift` | Protocol + NullSyncService + SyncCoordinator. CloudKit-ready, no live impl. |
| `LetterScheduler.swift` | Ebbinghaus-style spaced repetition. `.fixedOrder()` returns a "control" scheduler that scores by `-completionCount` (round-robin through the alphabet) so the `.control` thesis arm doesn't confound scheduling with phase progression. |
| `LetterStars.swift` | phaseScores → 0…4 star count, mirrors LearningPhaseController.starThreshold. |
| `LetterRecognizer.swift` | CoreMLLetterRecognizer wraps GermanLetterRecognizer.mlpackage. nonisolated, runs on Task.detached. Falls back to nil on missing model. ConfidenceCalibrator applied to top-k. StubLetterRecognizer for tests. |
| `ConfidenceCalibrator.swift` | Confusable-pair penalties + history boost. |
| `FreeWriteScorer.swift` | Discrete Fréchet + Schreibmotorik 4-dimension WritingAssessment (formAccuracy 0.40 + tempoConsistency 0.25 + pressureControl 0.15 + rhythmScore 0.20 = 1.00). |
| `FreeformWordList.swift` | Demo word library for freeform-word mode. |
| `GlyphStrokeExtractor.swift` | CoreText path → checkpoint extraction (debug calibrator). |
| `PrimaeLetterRenderer.swift` | OTF-based glyph render → UIImage. SchriftArt-aware. |
| `PBMLoader.swift` | PBM bitmap fallback for letter images. |
| `LetterAnimationGuide.swift` | Per-stroke animation timing. |
| `CalibrationStore.swift` | Per-letter user-calibrated stroke persistence. |

### Features/Tracing/

| File | Role |
|------|------|
| `TracingViewModel.swift` | @MainActor @Observable. Coordinates touch, audio, haptics, phase advance, scoring, recognition, freeform, calibration, dashboard writes, speech. Forwards observable state for views. |
| `TracingDependencies.swift` | DI bundle. `.live` defaults; `.stub` (in tests) replaces audio / stores / scheduler / recognizer / speech with no-ops. |
| `TracingCanvasView.swift` | SwiftUI Canvas: glyph + ghost + ink + KP overlay (gated on `overlayQueue.currentOverlay == .kpOverlay`). Pencil + finger overlays. |
| `FreeformWritingView.swift` | Blank-canvas writing mode. Result popup shows predicted letter + verbal evaluation + stars only — no Klarheit/Form percentages (those live in ResearchDashboardView). |
| `RecognitionFeedbackView.swift` | German verbal-only badge for freeWrite recognition. Auto-dismisses, mirrored by speech. |
| `CompletionCelebrationOverlay.swift` | Stars + "Weiter" button. |
| `PaperTransferView.swift` | 3 s reference → 10 s write-on-paper → 3-emoji self-assessment. Speaks each prompt via TTS. |
| `PhaseDotIndicator.swift` / `PhaseIndicatorView.swift` | Phase-progress UI. `PhaseDotIndicator` takes an explicit `activePhases` list (default `LearningPhase.allCases`) so guidedOnly/control conditions render only the dots they actually run — wired up via `vm.activePhases` from `LearningPhaseController`. |
| `LetterPickerBar.swift` / `LetterWheelPicker.swift` / `SequencePickerBar.swift` | Letter / word selection chrome. |
| `DebugAudioPanel.swift` | Live audio-tuning sliders (DEBUG only). |
| `StrokeCalibrationOverlay.swift` | Debug stroke editing (drag / add / delete) with per-script persistence. German UI strings throughout. |
| `PlaybackController.swift` / `AnimationGuideController.swift` / `TransientMessagePresenter.swift` | Per-VM controllers built via factories in TracingDependencies. |
| `InputModeDetector.swift` / `InputPreset.swift` | Finger / pencil hysteresis. |
| `LetterCell.swift` / `SequenceGridController.swift` / `GridLayoutCalculator.swift` / `TracingSequence.swift` | Word-mode grid. |

### Features/Library/

| File | Role |
|------|------|
| `LetterRepository.swift` | Loads LetterAsset[] from bundle. Filtering / variant-strokes loader. |
| `LetterCache.swift` | JSONLetterCache: disk-cached letter list. |

### Features/Navigation/

| File | Role |
|------|------|
| `MainAppView.swift` | Root host. `@AppStorage` persists active world across launches. |
| `WorldSwitcherRail.swift` | 64 pt rail. World buttons + 2 s long-press gear → ParentAreaView. |
| `WorldPalette.swift` | Per-world background + accent palette. |

### Features/Worlds/

| File | Role |
|------|------|
| `SchuleWorldView.swift` | World 1. Hosts TracingCanvasView + observes overlayQueue for celebration / paperTransfer / recognitionBadge. Verbal-only feedback cards (no percentages). |
| `WerkstattWorldView.swift` | World 2. 140 pt mode-card panel + FreeformWritingView. |
| `FortschritteWorldView.swift` | World 3. Star + streak + letter gallery + Schreibflüssigkeit trend (verbal-only). |

### Features/Onboarding/

| File | Role |
|------|------|
| `OnboardingView.swift` | First-run flow. One animated demo per phase. German `.accessibilityLabel` on every CTA. |

### Features/Parent/

| File | Role |
|------|------|
| `ParentAreaView.swift` | Parental-gate destination. NavigationSplitView with 4 sections: overview / research / settings / export. |
| `ResearchDashboardView.swift` | Researcher-only. Schreibmotorik dimensions, KI predictions vs expected, condition-arm distribution, scheduler effectiveness, raw phase-session table, per-letter aggregates. Children never see this view. |

### Features/Dashboard/

| File | Role |
|------|------|
| `ParentDashboardView.swift` | Adult-grade overview. |
| `PhaseRatesView.swift` / `PracticeTrendChart.swift` | Charts. |
| `SettingsView.swift` | schriftArt / ordering / paper-transfer / freeform / debug toggles. |

## Verbal feedback wiring

Children can't read fluently yet, so every numeric metric the data
model captures is **only** spoken or rendered as visual encouragement
(stars, colour swatches). The synthesiser wiring:

| Trigger | Phrase source |
|---------|---------------|
| `load(letter:)` initial phase | `ChildSpeechLibrary.phaseEntry(currentPhase)` |
| `advanceLearningPhase` transition | `ChildSpeechLibrary.phaseEntry(newPhase)` |
| `recordPhaseSessionCompletion` | `ChildSpeechLibrary.praise(starsEarned:)` |
| Recognition result lands (freeWrite) | `ChildSpeechLibrary.recognition(result, expected)` |
| Freeform recognition lands | `ChildSpeechLibrary.recognition(result, expected: predicted)` |
| `PaperTransferView` phase rotation | `paperTransferShow / Write / Assess` |
| `appDidEnterBackground` | `speech.stop()` |

## Key invariants (from LESSONS.md)

- `load(letter:)` MUST call `audio.loadAudioFile` synchronously — never inside `Task { }`.
- `showGhost` resets to false when letter changes.
- `@MainActor` required on classes with `@Observable` / `@Published`.
- Never use `Logger.shared` — instantiate `Logger(subsystem:category:)` directly.
- Never modify `.github/workflows/` from this repo.
- Never replace `hypot()` with `distSq` in `StrokeTracker.update()`.
- Test target uses `.swiftLanguageMode(.v5)` — do not change.
- Main target uses `.defaultIsolation(MainActor.self)` — do not change.

## Letters with full support

A, F, I, K, L, M, O — both `strokes.json` (checkpoints) and audio.
Lowercase a-z + Ä Ö Ü ß have placeholder folders so the bundle scan
discovers them; they render the glyph but skip phase scaffolding when
their stroke array is empty.
