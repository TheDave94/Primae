# BuchstabenNative — Development Roadmap

## Current Focus (Q2 2026)

### P1 — User-Facing Features
- [ ] **Letter completion celebration** — visual + haptic reward when a letter is fully traced correctly (TracingViewModel, HapticEngine)
- [ ] **Progress screen** — show per-letter accuracy history, streak, and mastery level (ProgressStore, ParentDashboardStore)  
- [ ] **Difficulty indicator** — show current difficulty level visually so child/parent can see adaptation working (DifficultyAdaptation, ContentView)
- [ ] **Sound variant picker** — let user browse and preview available sounds for a letter (LetterSoundLibrary, ContentView)
- [ ] **Onboarding completion** — OnboardingCoordinator currently has stub screens; implement the full first-run flow

### P2 — Reliability
- [ ] **CloudSync offline queue** — CloudSyncService should queue writes when offline and flush on reconnect
- [ ] **ProgressStore persistence error handling** — silent failures when disk is full or corrupted; add user-visible error state
- [ ] **LetterRepository cache invalidation** — LetterCache doesn't invalidate on app update; stale letter data possible

### P3 — Test Coverage
- [ ] **DifficultyAdaptation edge cases** — no tests for boundary conditions (0 attempts, 100% accuracy cliff)
- [ ] **OnboardingCoordinator flow tests** — no tests covering the full onboarding sequence
- [ ] **CloudSyncService conflict resolution tests** — no tests for write conflict scenarios

## Out of Scope (do NOT propose)
- AudioEngine internal refactors (concurrency, NSNumber casting, self. prefixes, guard patterns) — stable, tested, not user-visible
- Pure Swift style changes (adding/removing self., formatting, renaming)
- Speculative concurrency fixes without a confirmed crash or test failure
- Adding debug print statements or logging
