# iOS Native Rewrite (WIP)

This folder contains a native-first rewrite of the app architecture.

## Goals
- Replace SDL-driven UI with native iOS rendering/input
- Keep current learning behavior (trace letters, adaptive audio speed, gesture navigation)
- Move app logic into Swift modules that are testable and maintainable
- Keep Objective-C++ only where unavoidable (if native DSP replacement requires it)

## Current Status
- Native app skeleton with SwiftUI entry point
- Native tracing canvas + touch smoothing
- Stroke checkpoint engine (ordered strokes)
- Letter repository using existing per-letter JSON assets
- AVAudioEngine-based adaptive playback (rate/pan)
- Two-finger gesture handling for navigation/randomize
- Overlay toggles and completion feedback state

## Next Milestones
1. Wire this module into an Xcode iOS target
2. Implement robust asset import from existing folder structure
3. Add unit tests for stroke progression and adaptive speed mapping
4. Add full parity gestures and completion HUD polish
5. Optional: bridge RubberBand if AVAudioUnitTimePitch quality is insufficient
