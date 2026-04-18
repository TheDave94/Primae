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
- `TracingCanvasView.swift` — Canvas rendering (ghost lines, start dots, ink)
- `ContentView.swift` — top-level layout, button bar, overlays
- `StrokeTracker.swift` — checkpoint proximity detection
- `AudioEngine.swift` — ⚠️ STABLE AND FRAGILE — do NOT modify
- `LetterRepository.swift` — loads letters from bundle
- `PrimaeLetterRenderer.swift` — renders letter glyphs using Primae font
- `ProgressStore.swift` — persists learning progress
- `StrokeCalibrationOverlay.swift` — debug stroke editing UI

## Build & Test
```bash
cd BuchstabenApp
xcodebuild test -project BuchstabenApp.xcodeproj -scheme BuchstabenApp \
  -destination "platform=iOS Simulator,name=iPad (A16)" \
  -configuration Debug CODE_SIGNING_ALLOWED=NO
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
