# Buchstaben-Lernen-App — Developer Reference

_Generated 2026-03-12. Based on the `ux/smoother-ui-experiments` branch._

---

## What the App Does

**Buchstaben-Lernen-App** is an iPad/iPhone letter-tracing learning app for children. The child sees a blank canvas, traces a letter with their finger or Apple Pencil, and hears the letter sound played back as they draw. Key behaviours:

- One letter fills the whole screen as a tracing canvas.
- Audio plays while the child traces at a sufficient speed; it pauses when they stop.
- Stroke order can be enforced (child must trace strokes in the correct sequence).
- Difficulty auto-adjusts based on accuracy over the last 10 sessions (easy → standard → strict checkpoint radius).
- Progress (completions, accuracy, streaks) is persisted locally in JSON.
- A "ghost" guide overlay can be toggled to show the letter outline.
- Completion is celebrated with a HUD toast ("🎉 A geschafft!").
- Full VoiceOver / accessibility support.
- Apple Pencil support with pressure-sensitive ink width.
- Two-finger swipe gestures navigate letters and audio variants.

---

## Architecture Overview

```
BuchstabenNative/
├── App/
│   ├── BuchstabenNativeApp.swift   — App entry point (@main)
│   └── ContentView.swift           — Root SwiftUI view (top bar + canvas)
├── Core/
│   ├── Models.swift                — Data types (LetterAsset, Stroke, Checkpoint)
│   ├── AudioEngine.swift           — AVAudioEngine wrapper (plays audio files)
│   ├── AudioControlling.swift      — Protocol for AudioEngine (testable seam)
│   ├── LetterSoundLibrary.swift    — Alternative audio loader (bundle naming convention)
│   ├── ProgressStore.swift         — JSON-backed progress persistence
│   ├── StreakStore.swift            — Daily streak tracking
│   ├── StrokeTracker.swift         — Checkpoint hit-detection per stroke
│   ├── StrokeRecognizer.swift      — Stroke pattern recognition helpers
│   ├── HapticEngine.swift          — Core Haptics feedback (checkpoint / completion)
│   ├── DifficultyAdaptation.swift  — Moving-average difficulty tier engine
│   ├── PlaybackStateMachine.swift  — Audio play/pause state machine
│   ├── LetterAnimationGuide.swift  — Animated stroke guide logic
│   ├── LocalNotificationScheduler.swift — Daily reminder notifications
│   ├── OnboardingCoordinator.swift — First-launch onboarding state machine
│   ├── ParentDashboardStore.swift  — Parent-facing progress aggregation
│   ├── ParentDashboardExporter.swift — Export parent report (CSV/JSON)
│   └── CloudSyncService.swift      — iCloud sync (CloudKit)
└── Features/
    ├── Library/
    │   ├── LetterRepository.swift  — Loads letters from bundle (JSON strokes + audio)
    │   └── LetterCache.swift       — JSON cache for bundle load failures
    └── Tracing/
        ├── TracingCanvasView.swift — SwiftUI canvas + gesture handling
        ├── TracingViewModel.swift  — All tracing business logic (@MainActor)
        ├── LetterGuideRenderer.swift — Renders ghost guide path
        └── LetterGuideGeometry.swift — Path geometry calculations
```

---

## Core Features and Where They Live

### 1. Letter Tracing Canvas
**File:** `Features/Tracing/TracingCanvasView.swift`

The canvas renders three things:
- The **ghost guide** (blue semi-transparent stroke if `vm.showGhost = true`)
- The **active ink path** (green line following the user's finger/pencil)
- A **progress bar** at the bottom edge

**Gestures handled:**
| Gesture | Action |
|---|---|
| Single finger drag | Trace the letter |
| Two-finger swipe left/right | Next / previous letter |
| Two-finger swipe up/down | Next / previous audio variant |
| Two-finger tap | Random letter |
| Three-finger tap | Toggle ghost guide |
| Apple Pencil | Full pressure + azimuth tracking |

To **change the canvas background colour**, edit the `.background(Color.white)` in `ContentView.swift`:
```swift
TracingCanvasView()
    .background(Color.white)  // ← change here
```

To **change the ink colour**, edit the `context.stroke(path, with: .color(.green), ...)` line in `TracingCanvasView.swift`:
```swift
context.stroke(path, with: .color(.green), ...)  // ← change .green to any Color
```

---

### 2. Letter Data (Strokes + Images)
**File:** `Features/Library/LetterRepository.swift`  
**Model:** `Core/Models.swift`

Each letter is a `LetterAsset`:
```swift
struct LetterAsset {
    let id: String          // e.g. "A"
    let name: String        // e.g. "A" (displayed in UI)
    let imageName: String   // path to .pbm bitmap image in bundle
    let audioFiles: [String] // paths to audio files in bundle
    let strokes: LetterStrokes // stroke checkpoint data
}
```

**How letters are loaded** (priority order):
1. JSON stroke files (`*_strokes.json`) in the app bundle
2. Folder-based `.pbm` files in the app bundle  
3. JSON cache (fallback if bundle fails)
4. Hardcoded fallback "A" letter

---

### 3. Adding/Changing Letter Bitmap Images

**Image format:** `.pbm` (Portable Bitmap — monochrome black & white)

**Naming convention:** Each letter lives in its own subfolder named with the letter:
```
Bundle Resources/
├── A/
│   ├── A.pbm          ← the bitmap image shown on screen
│   └── A_strokes.json ← stroke checkpoint definition
├── B/
│   ├── B.pbm
│   └── B_strokes.json
...
```

**To replace a letter's bitmap:**
1. Create a `.pbm` image at the correct dimensions (the renderer scales it to fit the canvas)
2. Name it `<letter>.pbm` (e.g. `B.pbm`)
3. Place it in the letter's subfolder in Xcode under `BuchstabenNative` → bundle resources
4. Make sure "Target Membership" is checked for `BuchstabenNative`

**Alternative image location** (flat, no subfolder):
```
Bundle Resources/
├── A.pbm    ← also accepted (LetterRepository looks here as fallback)
```

The repository tries `<letter>/<letter>.pbm` first, then `<letter>.pbm` flat.

**Where image loading happens:**
```
LetterRepository.swift → loadBundledStrokeLettersWithValidation()
```
Specifically:
```swift
let imageCandidates = ["\(base)/\(base).pbm", "\(base).pbm"]
let imageName = imageCandidates.first(where: { bundleHasResource(at: $0) }) ?? "\(base).pbm"
```

The image is referenced by `LetterAsset.imageName` but **note:** the current `TracingCanvasView` renders the ghost guide from `LetterGuideRenderer` (vector paths), not from the `.pbm` directly. The `.pbm` may be used for a separate display layer or future bitmap-based rendering — check `LetterGuideRenderer.swift` for how the ghost path is generated.

---

### 4. Audio / Sound Files

**Files:** `Core/AudioEngine.swift`, `Core/LetterSoundLibrary.swift`  
**Config:** `Features/Library/LetterRepository.swift → findAudioAssets()`

#### Naming Convention (primary system — `LetterRepository`)

Audio files are discovered automatically from the bundle. The repository scans for files in the letter's subfolder **or** files whose name starts with the letter:

```
Bundle Resources/
├── A/
│   ├── A1.mp3       ← phonetic sound variant 1
│   ├── A2.mp3       ← phonetic sound variant 2
│   ├── A3.mp3       ← phonetic sound variant 3
│   ├── Affe.mp3     ← example word ("Affe" = monkey)
│   └── Sirene.mp3   ← example word ("Siren")
├── F/
│   ├── Frosch.mp3   ← example word
│   └── Föhn.mp3
...
```

Supported formats: `.mp3`, `.wav`, `.m4a`, `.aac`, `.flac`, `.ogg`

**Preferred file order** (hardcoded in `LetterRepository.preferredAudioFiles()`):
```swift
"A": ["A/A1.mp3", "A/A2.mp3", "A/A3.mp3", "A/Affe.mp3", "A/Sirene.mp3", ...]
"F": ["F/Frosch.mp3", "F/Föhn.mp3", ...]
"K": ["K/K.mp3", "K/Katze.mp3", "K/Kuckuck1.mp3", ...]
"L": ["L/Löwe.mp3", ...]
"M": ["M/Meer.mp3", "M/Möwe.mp3", ...]
```

**To add a new sound for a letter:**
1. Add the `.mp3` (or other supported format) to the letter's subfolder in Xcode
2. Ensure "Target Membership" → `BuchstabenNative` is checked
3. If you want it to appear in a specific order, add it to `preferredAudioFiles()` in `LetterRepository.swift`

**To change which sound plays first:** Edit `preferredAudioFiles()` in `LetterRepository.swift` — the first match in the array is used as `audioIndex = 0`.

#### Alternative Audio System — `LetterSoundLibrary`

There is a second audio loader (`Core/LetterSoundLibrary.swift`) that uses a locale-based naming convention:
```
letter_a_de.mp3   ← German phonetic sound for "A"
letter_a_en.mp3   ← English phonetic sound for "A"
word_a_de.mp3     ← German example word for "A"
```
This system is currently used as an alternative/protocol-based layer. To switch to locale-aware audio, use `LetterSoundLibrary` instead of `AudioEngine` in `TracingViewModel`.

#### Audio Playback Behaviour

Audio plays **while tracing** (velocity-gated) and stops when the finger lifts. This is controlled in `TracingViewModel.updateTouch()`:

```swift
let shouldBeActive = shouldPlayForStroke && smoothedVelocity >= playbackActivationVelocityThreshold
```

- `playbackActivationVelocityThreshold = 22` (pt/s) — raise this to require faster movement before audio plays
- Speed range: slow tracing → `rate = 2.0` (slow playback), fast tracing → `rate = 0.5` (fast playback)
- To **disable velocity-gated audio** and always play: change `setPlaybackState(.active, immediate: true)` unconditionally in `updateTouch()`

---

### 5. Stroke Definitions (Letter Shape / Checkpoints)

**File:** `<letter>/<letter>_strokes.json` in bundle  
**Model:** `Core/Models.swift → LetterStrokes`

Each stroke is defined as a series of checkpoints in **normalised coordinates** (0–1, where 0,0 = top-left, 1,1 = bottom-right of the canvas):

```json
{
  "letter": "A",
  "checkpointRadius": 0.06,
  "strokes": [
    {
      "id": 1,
      "checkpoints": [
        { "x": 0.5, "y": 0.1 },
        { "x": 0.3, "y": 0.85 }
      ]
    },
    {
      "id": 2,
      "checkpoints": [
        { "x": 0.35, "y": 0.55 },
        { "x": 0.65, "y": 0.55 }
      ]
    }
  ]
}
```

- `checkpointRadius`: how close the finger must get to "hit" a checkpoint (as a fraction of canvas size). Default `0.06` = 6% of canvas width.
- Strokes are completed in order (when `strokeEnforced = true`).
- To make a letter **easier**, increase `checkpointRadius` or reduce the number of checkpoints.

**Where stroke hit-detection happens:** `Core/StrokeTracker.swift`

---

### 6. Difficulty Adaptation
**File:** `Core/DifficultyAdaptation.swift`

Three tiers adjust the checkpoint radius:
| Tier | Radius multiplier | Description |
|---|---|---|
| Easy | 1.5× | Larger hit area |
| Standard | 1.0× | Default |
| Strict | 0.65× | Smaller hit area |

Promotion/demotion happens after 10 sessions using a moving average. Thresholds:
```swift
promotionAccuracyThreshold = 0.85   // > 85% average → promote
demotionAccuracyThreshold  = 0.55   // < 55% average → demote
hysteresisCount = 3                 // must exceed threshold 3× in a row
```

To **lock the difficulty**, use `FixedAdaptationPolicy(currentTier: .easy)` in `TracingViewModel.init()`.

---

### 7. Progress Persistence
**File:** `Core/ProgressStore.swift`

Stored at: `Application Support/BuchstabenNative/progress.json`

Tracks per letter:
- `completionCount` — how many times completed
- `bestAccuracy` — best score (0–1)
- `lastCompletedAt` — date of last completion

Also tracks `completionDates` for streak calculation.

**To reset all progress:** call `progressStore.resetAll()`

---

### 8. Onboarding
**File:** `Core/OnboardingCoordinator.swift`

Five-step first-launch flow:
1. `welcome`
2. `traceDemo` — animated demonstration
3. `firstTrace` — guided first trace
4. `rewardIntro` — streak explanation
5. `complete`

State saved at: `Application Support/BuchstabenNative/onboarding.json`

**To force onboarding to show again:** call `JSONOnboardingStore().reset()`

---

### 9. Notifications
**File:** `Core/LocalNotificationScheduler.swift`

Schedules daily practice reminders via `UNUserNotificationCenter`.

---

### 10. Parent Dashboard
**Files:** `Core/ParentDashboardStore.swift`, `Core/ParentDashboardExporter.swift`

Aggregates per-letter progress for a parent-facing view. Can export as CSV or JSON.

---

### 11. Cloud Sync
**File:** `Core/CloudSyncService.swift`

iCloud/CloudKit-based sync for progress data across devices.

---

## Quick Reference: Common Changes

| What you want to change | File | What to edit |
|---|---|---|
| Add audio file for a letter | `<Letter>/` folder in bundle | Drop `.mp3` in, add to `preferredAudioFiles()` if ordering matters |
| Change audio naming convention | `LetterRepository.swift` | `preferredAudioFiles()` and `findAudioAssets()` |
| Replace a letter bitmap | `<Letter>/<Letter>.pbm` in bundle | Replace the `.pbm` file |
| Change letter stroke checkpoints | `<Letter>/<Letter>_strokes.json` | Edit `checkpoints` array (0–1 normalised coords) |
| Change checkpoint hit radius | `<Letter>_strokes.json` | Edit `checkpointRadius` (default 0.06) |
| Change canvas ink colour | `TracingCanvasView.swift` | `.color(.green)` in `tracingCanvas()` |
| Change canvas background | `ContentView.swift` | `.background(Color.white)` |
| Change difficulty thresholds | `DifficultyAdaptation.swift` | `promotionAccuracyThreshold`, `demotionAccuracyThreshold` |
| Change velocity needed to trigger audio | `TracingViewModel.swift` | `playbackActivationVelocityThreshold` |
| Change audio speed range | `TracingViewModel.swift` | `mapVelocityToSpeed()` static func |
| Add a new letter entirely | Bundle + `LetterRepository.swift` | Add `<X>/` folder with `.pbm`, `_strokes.json`, audio files |
| Completion celebration text | `TracingViewModel.swift` | `showCompletionHUD()` — edit `"🎉 \(letter) geschafft!"` |
| Completion HUD display duration | `TracingViewModel.swift` | `.seconds(1.8)` in `showCompletionHUD()` |
| Toast display duration | `TracingViewModel.swift` | `.seconds(1.3)` in `toast()` |
| Locale for audio (de/en) | `LetterSoundLibrary.swift` | `assetName(for:locale:)` — change default `"de"` |

---

## Bundle Asset Structure (Expected)

```
BuchstabenNative bundle resources/
├── A/
│   ├── A.pbm              ← letter bitmap (monochrome)
│   ├── A_strokes.json     ← stroke checkpoint definition
│   ├── A1.mp3             ← phonetic sound variants
│   ├── A2.mp3
│   ├── A3.mp3
│   ├── Affe.mp3           ← example words
│   └── Sirene.mp3
├── B/
│   ├── B.pbm
│   ├── B_strokes.json
│   └── Baum.mp3
...
(one folder per letter, A–Z plus Ä Ö Ü)
```

**Validation:** At launch, `LetterRepository` logs warnings for any letter missing its `.pbm` or audio files. Check Xcode console for `⚠️ Asset validation [X]:` messages.

---

## App Entry Points

**Host app entry point:** `BuchstabenApp/BuchstabenApp/BuchstabenAppApp.swift`
The `@main` attribute lives in the host app target, not in the `BuchstabenNative` library (library targets cannot have `@main`).

**Library app struct** (no `@main`): `BuchstabenNative/App/BuchstabenNativeApp.swift`
Used when running the package standalone. Does not carry `@main`.

**Host app target:** `BuchstabenApp/BuchstabenAppApp.swift` + `BuchstabenApp/ContentView.swift`
A thin wrapper that imports `BuchstabenNative` as a Swift package and embeds the tracing view.

---

_Last updated: 2026-03-12_
