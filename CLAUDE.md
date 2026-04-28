# CLAUDE.md — Buchstaben-Lernen-App (Letter Learning App)

## Project Overview
iPad app for teaching German children (ages 5-6) to trace letters. Built with SwiftUI, Swift 6.3, targeting iOS 18+. Academic thesis project.

## Architecture
- **Main target**: Uses `.defaultIsolation(MainActor.self)` — all types are implicitly @MainActor
- **Test target**: Uses `.swiftLanguageMode(.v5)` — do NOT change this
- **CI**: GitHub Actions on macos-26 runner with Xcode 26.4, self-hosted MacBook
- **Learning phases**: observe → guided → freeWrite (managed by PhaseController)
- **Stroke data**: JSON files in `Resources/Letters/{letter}/strokes.json` with normalized coordinates
- **Audio**: Proximity-triggered playback via AudioEngine + StrokeTracker

## Key Files
- `TracingViewModel.swift` — main VM, coordinates phases, strokes, audio, animation
- `TracingCanvasView.swift` — Canvas rendering (ghost lines, start dots, ink, KP overlay)
- `MainAppView.swift` — root host with WorldSwitcherRail + worlds
- `SchuleWorldView.swift` — World 1: guided four-phase tracing
- `WerkstattWorldView.swift` — World 2: freeform writing
- `FortschritteWorldView.swift` — World 3: child-facing star/streak/letter gallery
- `StrokeTracker.swift` — checkpoint proximity detection
- `AudioEngine.swift` — ⚠️ STABLE AND FRAGILE — do NOT modify
- `SpeechSynthesizer.swift` — German TTS for child-facing verbal feedback
- `LetterRepository.swift` — loads letters from bundle
- `PrimaeLetterRenderer.swift` — renders letter glyphs using Primae font
- `ProgressStore.swift` — persists learning progress
- `OverlayQueueManager.swift` — serialised post-freeWrite overlay scheduler
- `StrokeCalibrationOverlay.swift` — debug stroke editing UI

For the full developer-grade reference see `docs/APP_REFERENCE.md`.
For the thesis-foundation document see `docs/APP_DOCUMENTATION.md`.

## Build & Test
```bash
cd BuchstabenApp
xcodebuild test -project BuchstabenApp.xcodeproj -scheme BuchstabenApp \
  -destination "platform=iOS Simulator,name=iPad (A16)" \
  -configuration Debug CODE_SIGNING_ALLOWED=NO
```

## Test Infrastructure

> **Note:** `xcodebuild` is NOT available on claudebox (Linux). Only Swift syntax
> checking works locally. Full build/test runs on the self-hosted MacBook CI runner
> via GitHub Actions. Always verify CI passes after pushing.

1. **Swift compilation check** (claudebox Linux — basic syntax check only, SwiftUI/QuartzCore won't link):
   ```bash
   swift build 2>&1 | head -20
   ```

2. **Full build** (CI runner or local Mac):
   ```bash
   xcodebuild build -project BuchstabenApp/BuchstabenApp.xcodeproj -scheme BuchstabenApp \
     -destination "platform=iOS Simulator,name=iPad (A16)" \
     -configuration Debug CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
     -derivedDataPath /tmp/DerivedData-BuchstabenApp 2>&1 | tail -20
   ```

3. **Full test suite** (CI runner or local Mac):
   ```bash
   xcodebuild test -project BuchstabenApp/BuchstabenApp.xcodeproj -scheme BuchstabenApp \
     -destination "platform=iOS Simulator,name=iPad (A16)" \
     -configuration Debug CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
     -derivedDataPath /tmp/DerivedData-BuchstabenApp 2>&1 | tail -30
   ```

4. **strokes.json validation** (works anywhere with python3):
   ```bash
   python3 -c "import json, pathlib; [json.loads(f.read_text()) for f in pathlib.Path('BuchstabenNative/Resources/Letters').rglob('strokes.json')]; print('All strokes.json valid')"
   ```

5. **CI status**:
   ```bash
   gh run list --repo TheDave94/Buchstaben-Lernen-App --limit 3
   ```

## DO NOT
- Do NOT modify `AudioEngine.swift` — it is stable and fragile
- Do NOT introduce new dependencies or frameworks
- Do NOT change `.swiftLanguageMode(.v5)` in the test target
- Do NOT change `.defaultIsolation(MainActor.self)` in the main target
- Do NOT modify the strokes.json coordinate format
- Do NOT modify `StrokeTracker.swift` unless the task explicitly targets it

## Conventions
- All new views go in `Features/Tracing/` unless they're core infrastructure
- Use existing protocols (AudioControlling, ProgressStoring) — don't create parallel interfaces
- Animations use SwiftUI `.transition()` and `withAnimation {}`
- Debug features gated on `vm.showDebug`
- German UI text (the app is for German-speaking children)
