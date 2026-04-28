# Buchstaben-Lernen-App

An iPadOS app for children to learn letter writing with adaptive audio feedback.

## How it works

A child traces a letter outline with their finger or Apple Pencil. Writing speed controls sound playback in real-time — audio plays while tracing and pauses when the finger lifts. Difficulty adapts automatically based on accuracy over recent sessions.

## Gestures

| Gesture | Action |
|---|---|
| 1 finger — trace | Play audio, speed adapts to writing velocity |
| 2 fingers — swipe left/right | Next / previous letter |
| 2 fingers — swipe up/down | Next / previous sound variant |
| 2 fingers — tap | Random letter |
| 3 fingers — tap | Toggle ghost tracing overlay |
| Apple Pencil | Full pressure + azimuth tracking |

## Tech Stack

- **Swift 6** with strict concurrency
- **SwiftUI** + **UIKit** (canvas rendering)
- **AVAudioEngine** + **AVAudioUnitTimePitch** — real-time time-stretching
- **CoreHaptics** — haptic feedback on stroke checkpoints

## Building

### Requirements
- macOS with Xcode 26+
- iOS 26 SDK

### Open in Xcode
````bash
open BuchstabenApp/BuchstabenApp.xcodeproj
````

Set your development team in project settings and build to a simulator or device.

### CI

Every push to `main` triggers a GitHub Actions build + test on an iPad Simulator (macos-26/Xcode 26) and a self-hosted Mac runner.

See `.github/workflows/ios-build.yml`.

## Project Structure
````
BuchstabenNative/          Swift Package (library)
├── App/                   App entry point
├── Core/                  Audio, progress, strokes, haptics, difficulty,
│                          recognition, scoring, speech synthesis
└── Features/
    ├── Library/           Letter loading + caching
    ├── Navigation/        World switcher rail + main app shell
    ├── Onboarding/        First-run flow
    ├── Parent/            Parental-gate + research dashboard
    ├── Worlds/            Schule / Werkstatt / Fortschritte
    ├── Dashboard/         Settings + parent dashboard
    └── Tracing/           Canvas, ViewModel, freeform / freeWrite controllers

BuchstabenApp/             Xcode host app target (imports BuchstabenNative)
BuchstabenNativeTests/     Swift Testing test suite
docs/                      Documentation (architecture, thesis foundation,
                            code-level invariants)
scripts/                   PBM + stroke + audio generation utilities
````

## Documentation

All project documentation lives under `docs/`:

| File | Purpose |
|------|---------|
| `docs/APP_DOCUMENTATION.md` (+ `.pdf`) | Thesis-ready technical foundation — architecture, scientific methods with citations, learning pipeline, data schemas, claim verification, bibliography. |
| `docs/APP_REFERENCE.md` | Concise architecture reference — file map, dependency graph, key invariants. Use this for quick lookup while editing code. |
| `docs/LESSONS.md` | Code-level invariants that catch regressions a typecheck won't. Read before touching `AudioEngine.swift`, `StrokeTracker.swift`, or the `load(letter:)` path. |
