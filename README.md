# Buchstaben Lernen App

An iPadOS app for children to learn letter writing with adaptive audio feedback.

## How it works

A child traces a letter outline with one finger. Writing speed controls sound playback in real-time via pitch-preserving time-stretching:
- **Slow strokes** → sound plays faster (encourages slowing down)
- **Fast strokes** → sound plays slower (stretches with the movement)

## Gestures

| Gesture | Action |
|---|---|
| 1 finger — trace | Play audio, speed adapts to writing velocity |
| 2 fingers — swipe left/right | Next / previous letter |
| 2 fingers — swipe up/down | Next / previous sound variant |
| 2 fingers — tap (no swipe) | Random letter + sound |
| 3 fingers — tap | Toggle ghost tracing overlay |

## Tech Stack

- **SDL3** 3.2.28 — window, touch input, rendering
- **RubberBand** 4.0.0 — real-time time-stretch & pitch shift
- **libsndfile** 1.2.2 — audio decoding (mp3/wav/flac/ogg)
- **fftw3**, **libFLAC**, **libvorbis**, **mpg123**, **opus** — audio codec support

## Building

### Requirements
- macOS with Xcode 16+
- iOS 18 SDK

### Open in Xcode
```bash
open Timestretch/Timestretch.xcodeproj
```

Set your development team in project settings and build to a simulator or device.

### CI

Every push to `main` or `develop` triggers a GitHub Actions build for the iOS Simulator.
See `.github/workflows/ios-build.yml`.

## Project Structure

```
ios-build/
  SDL3.xcframework/          SDL3 prebuilt framework
  vcpkg/installed/arm64-ios/ Prebuilt static libraries
  Timestretch/               Xcode project
    Timestretch/main.mm      Main source file (all logic here)
    A/ F/ I/ K/ L/ M/ O/     Letter assets (PBM masks + MP3 audio)
```
