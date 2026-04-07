# BuchstabenNative — Architecture Reference

_Auto-generated from source. Update when adding files or changing wiring._

## What the app does

A child traces German letters with finger or Apple Pencil on an iPad.
Audio plays in real-time during tracing, speed adapts to tracing velocity.
Difficulty adapts automatically based on accuracy. 7 letters currently have
full stroke definitions (A, F, I, K, L, M, O); others use a fallback.

## Architecture
BuchstabenNativeApp
└── ContentView
├── TracingCanvasView   ← renders bitmap + ghost + stroke path
└── TracingViewModel    ← CENTRAL COORDINATOR (@MainActor @Observable)
├── AudioEngine          (via AudioControlling protocol)
├── StrokeTracker        (direct — not injected)
├── CoreHapticsEngine    (via HapticEngineProviding protocol)
├── JSONProgressStore    (via ProgressStoring protocol)
├── MovingAverageAdaptationPolicy (via AdaptationPolicy protocol)
└── LetterRepository
└── JSONLetterCache

## File map

### App/
| File | Role | Status |
|------|------|--------|
| `BuchstabenNativeApp.swift` | App entry. Creates TracingViewModel, wires scenePhase → appDidBecomeActive/Background | ✅ Wired |
| `ContentView.swift` | Root view. TopBar (Ghost/Order/Debug/Reset + letter indicator) + toast + CompletionHUD | ✅ Wired |

### Features/Tracing/
| File | Role | Status |
|------|------|--------|
| `TracingViewModel.swift` | @MainActor @Observable. Touch input → stroke tracking → audio → haptics → progress. 476 lines. | ✅ Core |
| `TracingCanvasView.swift` | SwiftUI Canvas: PBM bitmap + ghost overlay + active stroke path + progress bar. UIKit gesture handling (finger + Pencil). | ✅ Core |
| `TracingDependencies.swift` | DI struct for TracingViewModel. `.live` uses production defaults. Tests inject mocks. | ✅ Core |
| `LetterGuideGeometry.swift` | CGPath geometry for ghost overlay. Has definitions for: A, F, I, K, L, M, O. Others use fallback. | ✅ Wired |
| `LetterGuideRenderer.swift` | SwiftUI wrapper: LetterGuideGeometry → SwiftUI Path | ✅ Wired |

### Features/Library/
| File | Role | Status |
|------|------|--------|
| `LetterRepository.swift` | Loads LetterAsset[] from bundle (JSON stroke files + PBM images + audio files) | ✅ Wired |
| `LetterCache.swift` | JSONLetterCache: disk cache for letter assets. Used by LetterRepository. | ✅ Wired |

### Core/ — Wired
| File | Role | Status |
|------|------|--------|
| `Models.swift` | Data models: LetterAsset, LetterStrokes, StrokeDefinition, Checkpoint, TracingPoint | ✅ Core |
| `AudioControlling.swift` | Protocol: loadAudioFile, setAdaptivePlayback, play, stop, restart, suspend/resume | ✅ Core |
| `PlaybackStateMachine.swift` | Pure value-type FSM: idle↔active, guards for appIsForeground + resumeIntent | ✅ Core |
| `AudioEngine.swift` | Implements AudioControlling. AVAudioEngine + AVAudioUnitTimePitch for time-stretching. @MainActor. 382 lines. | ✅ Wired |
| `StrokeTracker.swift` | Checkpoint proximity detection. Owns progress[]. radiusMultiplier for difficulty. @MainActor. | ✅ Wired |
| `HapticEngine.swift` | HapticEngineProviding protocol + CoreHapticsEngine + UIKitHapticEngine + NullHapticEngine (tests) | ✅ Wired |
| `DifficultyAdaptation.swift` | DifficultyTier (easy/standard/strict) + MovingAverageAdaptationPolicy + FixedAdaptationPolicy | ✅ Wired |
| `ProgressStore.swift` | JSONProgressStore: per-letter completions + best accuracy + streak days. Persists to Application Support. | ✅ Wired |
| `PBMLoader.swift` | Loads PBM bitmap files → UIImage (P1 ASCII + P4 binary). Used by load(letter:) fallback. | ✅ Wired |
| `PrimaeLetterRenderer.swift` | Renders letters with Primae-Regular OTF font → UIImage. Used by load(letter:) in TracingViewModel. @MainActor. | ✅ Wired |

### Core/ — Scaffolded (built + tested, NOT wired into the app yet)
| File | Role | Wiring needed |
|------|------|--------------|
| `StreakStore.swift` | JSONStreakStore: streak tracking + reward events (firstLetter, streakDay3, streakWeek, etc.) | Wire into TracingViewModel.init via TracingDependencies |
| `LocalNotificationScheduler.swift` | Daily practice reminder scheduling with quiet hours + streak-aware messages | Wire into AppDelegate/BuchstabenNativeApp |
| `OnboardingCoordinator.swift` | State machine for 5 onboarding steps: welcome → traceDemo → firstTrace → rewardIntro → complete | Wire into ContentView, show on first launch |
| `ParentDashboardStore.swift` | Per-letter accuracy history, session durations, rolling 7-day practice time | Wire into TracingViewModel.init via TracingDependencies |
| `ParentDashboardExporter.swift` | CSV/JSON export of DashboardSnapshot (no UIKit — testable on Linux CI) | Wire into a share sheet when ParentDashboard is shown |
| `CloudSyncService.swift` | CloudKit sync protocol + NullSyncService + SyncCoordinator. Protocol ready. | Wire into app init after onboarding |
| `LetterSoundLibrary.swift` | AVAudioPlayer-based sound library (separate from AudioEngine). Used for letter name pronunciation. | Not currently needed — TracingViewModel uses AudioEngine |
| `LetterAnimationGuide.swift` | Animation step model for guided tracing (idle/playing/paused/complete states) | Wire into TracingCanvasView for animated stroke demonstration |
| `StrokeRecognizer.swift` | Protocol-based stroke matcher (EuclideanStrokeRecognizer + StrokeRecognizerSession). More testable than StrokeTracker. | Could replace StrokeTracker if needed |

## Key invariants (from LESSONS.md)

- `load(letter:)` in TracingViewModel MUST call audio.loadAudioFile synchronously — never inside Task {}
- `showGhost` must reset to false when letter changes
- `@MainActor` required on any class with @Observable or @Published
- Never use `Logger.shared` — instantiate Logger directly
- Never modify `.github/workflows/`
- Never replace `hypot()` with distSq in StrokeTracker.update()

## Debug toggle

`showDebug` in TracingViewModel is tracked but **nothing renders** when it's true.
The debug overlay in TracingCanvasView is a stub — implement if needed for development.

## Letters with full support

A, F, I, K, L, M, O — have both `strokes.json` (checkpoint data) and `LetterGuideGeometry` entries.
All other letters use `defaultStrokes()` fallback: a single vertical checkpoint line. Ghost overlay shows fallback geometry.
