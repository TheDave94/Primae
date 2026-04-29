# Roadmap V5 — Buchstaben-Lernen-App

_Forward-looking plan. Last updated 2026-04-29 against branch `roadmap-v5-tier12`. Only items still requiring work appear here — every shipped item from earlier versions of this document has been removed. Where a row says "infrastructure shipped, asset work pending", the code-side foundation is in place and the remaining work is content authoring (audio, glyph definitions) on your side._

Effort key: **S** = under 1 day · **M** = 1–3 days · **L** = 3+ days · **XL** = multi-week
Priority key: **P1** = thesis-blocking · **P2** = thesis-strengthening · **P3** = post-thesis polish

The deeper context for each item — failure modes, file lists, line-count budgets, what works on macOS vs needs an iPad — lives in `docs/ROADMAP_V5_DEFERRED_NOTES.md`.

---

## 1. THESIS-CRITICAL

### T1 — Lowercase letter coverage *(asset work + on-device authoring)*
**Effort:** XL · **Priority:** P1

**Problem.** `Resources/Letters/` has 56 directories (26 upper + 26 lower + Ä Ö Ü ß). 25 have non-empty `strokes.json`; 31 have **empty** stroke arrays as placeholders. The empty-stroke fallback path is correct (`LearningPhaseController` skips observe + direct phases when strokes are empty, drops the child into guided/freeWrite directly), but it means the four-phase pedagogy that the thesis demonstrates **does not actually run** for 31 of 56 letters. The thesis claim "Vier-Phasen-Pädagogik for Volksschule 1. Klasse" is exposed: a reviewer who picks `q` gets the empty-strokes fallback.

**What needs to be true per letter.**
1. **Stroke definition.** 1–3 strokes per letter, each with 5–15 checkpoints in 0–1 cell-local coordinates. Author by:
   - Open the app in Debug mode (long-press the phase indicator on SchuleWorldView)
   - Open the calibration overlay (long-press again)
   - Drag-place each checkpoint visually over the rendered glyph
   - The calibration store writes to `Application Support/BuchstabenNative/calibration/`
   - Export the calibrated checkpoints into the bundle's `Resources/Letters/<x>/strokes.json`
2. **PBM bitmap fallback.** Optional but the validator complains without it. Generate via the existing PBM tooling.
3. **Audio takes.** 3 mp3 recordings of the letter name (`<x>1.mp3`, `<x>2.mp3`, `<x>3.mp3`). Voice talent or ElevenLabs.
4. **Phoneme audio.** P6 infrastructure is in place; you need 3 phoneme takes per letter. See `docs/PHONEME_AUDIO_GUIDE.md` for the convention and ElevenLabs prompt template.

**Per-letter budget.** ~2–3 hours, mostly the calibration session + audio editing.

**Two viable scopes.**
- **Demo lowercase set** (`a f i k l m o`): 7 letters × 2–3 hours = 14–21 hours. **This is the thesis-floor minimum.** The uppercase demo set already ships full pedagogy; matching the lowercase counterparts means the four-phase flow runs on the letters most exposed to a thesis reviewer.
- **Full alphabet** (26 lowercase + 19 missing uppercase + 4 umlauts/ß = 49 letters): ~100–150 hours. Post-thesis or a multi-week dedicated authoring sprint.

**What you can do without a device.** Pre-generate stroke definitions from CoreText measurements run on macOS (write a small `swift run` script that loads Primae, renders each glyph, samples the path). The output won't be perfect (Primae's glyph metrics depend on font-loading order at runtime), but it gets you 80% of the way as a starting point for device calibration.

---

### P1 — Spaced retrieval testing prompts *(infrastructure shipped on branch; UI pending)*
**Effort:** M (UI only — infrastructure already lives in `Core/RetrievalScheduler.swift` and `LetterProgress.retrievalAttempts`) · **Priority:** P1

**Problem.** The app implements spaced *practice* (Cepeda 2006) via `LetterScheduler` but not spaced *retrieval*. Roediger & Karpicke (2006) showed retrieval tests produce better long-term retention than additional study — generating an answer beats re-encoding it. Adding retrieval extends the thesis pedagogical claim from "spacing exposure" to "spacing recall".

**What's already in code (branch `roadmap-v5-tier12`).**
- `Core/RetrievalScheduler.swift` — every-Nth-letter cadence with `interval` (default 3), `minimumPriorCompletions` (default 1, skips testing on never-seen letters), persisted counter so cadence survives relaunch.
- `LetterProgress.retrievalAttempts: [Bool]?` rolling outcome log (cap 10) on `ProgressStore`.
- `JSONProgressStore.recordRetrievalAttempt(letter:correct:)` write path.
- Stub default on `ProgressStoring` so older mocks compile.

**What's still needed.**
1. **`RetrievalPromptView`** (new file in `Features/Tracing/`). Three-button German recognition test: "Welcher Buchstabe ist das?" with the audio plays the letter (or phoneme — useful overlap with P6) and three candidate buttons (the correct letter + two distractors from the same motor-similarity cluster — `LetterOrderingStrategy.motorSimilarity` ordering gives you the cluster automatically). On tap, record the outcome and dismiss.
2. **Settings opt-in.** `enableRetrievalPrompts: Bool` UserDefaults key in `TracingDependencies`, mirrored toggle in SettingsView under a "Erinnerungstest" / "Forschung" section. Default off — opt-in research feature.
3. **VM wiring.** In `loadRecommendedLetter()`, before `load(letter:)`, call `retrievalScheduler.shouldPrompt(for: letter, progress: progress)` — when it returns `true`, push a `.retrievalPrompt(letter:)` overlay onto the queue ahead of the actual letter load. The retrieval prompt's onComplete then runs the load.
4. **`CanvasOverlay.retrievalPrompt(letter: String)`** case on `OverlayQueueManager`. Modal (no auto-dismiss).
5. **CSV export.** Add `retrievalAccuracy` column to the per-letter aggregate row in `ParentDashboardExporter.swift`. Update `docs/EXPORT_SCHEMA.md`.
6. **Tests.** RetrievalScheduler unit tests (interval cadence, minimum-prior-completions skip, counter reset). RetrievalPromptView is integration-tested through the queue.

**Citation.** Roediger, H. L., & Karpicke, J. D. (2006). Test-enhanced learning: Taking memory tests improves long-term retention. *Psychological Science*, 17(3), 249–255.

---

### P6 — Phoneme audio recordings *(infrastructure shipped; audio assets pending)*
**Effort:** XL (recording + voice direction work) · **Priority:** P1

**Problem.** Phonemic awareness (Adams 1990) predicts later reading acquisition; pairing handwriting practice with the *sound* the letter makes (`/a/` as in *Affe*) instead of just its name (`/aː/`) is curriculum-aligned for German Volksschule.

**What's already in code (branch `roadmap-v5-tier12`).**
- `LetterAsset.phonemeAudioFiles: [String]` — populated by `LetterRepository.partitionPhonemeAudio` from the bundle scan.
- `enablePhonemeMode: Bool` UserDefaults toggle, threaded through `TracingDependencies` and the VM.
- All 7 audio call sites (replay, variants, autoplay, begin-touch reload, direct-phase first-tap, load() prime) routed through `activeAudioFiles(for:)` helper. Toggle-on with no phoneme recordings → silent fallback to letter-name set.
- SettingsView "Lautwert" section with the toggle + Adams 1990 caption.

**What's still needed.**
1. **Audio recordings** following the convention `<base>_phoneme<n>.<ext>` per `docs/PHONEME_AUDIO_GUIDE.md`. Three takes per letter (different voices for child preference). 30 letters × 3 takes = 90 recordings.
2. ElevenLabs prompt template + per-letter IPA reference table is in the guide. Generation should be straightforward; clean-up (trim silence, normalise to -16 LUFS, export at 44.1 kHz mp3) is the per-file labour.
3. **Bundle wiring.** Drop the files into `BuchstabenNative/Resources/Letters/<base>/`. The repository scan picks them up automatically; no Swift code changes required.
4. **Verification checklist** (in the guide): toggle on → tap → phoneme plays; two-finger swipe cycles through takes; toggle off → name resumes.

**Citations.**
- Adams, M. J. (1990). *Beginning to Read: Thinking and Learning about Print*. MIT Press.
- Krech, E.-M. et al. (2009). *Deutsches Aussprachewörterbuch*. de Gruyter — the standard reference for German phoneme realisations.

---

## 2. PEDAGOGICAL — DEFERRED

### P5 — Forward + backward stroke chaining toggle
**Effort:** S–M · **Priority:** P3

**Why deferred.** The cited research (Spooner et al. 2014) is about *special-needs interventions* — autism, motor-planning disorders. Not the typical first-grade Volksschule population. Adding it as an opt-in parent toggle is plausible but reads as feature creep without IRB / curriculum justification. It also adds complexity to the direct-phase order tracking (the "next-expected" index has to flip direction) for a feature your thesis cohort won't use.

**If you decide to do it anyway.** Settings toggle "Schreibrichtung umkehren" (off by default), `LearningPhaseController.directDotOrder` reading the toggle and flipping the iteration. The change is local to the direct phase only; guided/freeWrite always run canonical order. ~1 day of work.

**Recommendation.** Skip for thesis. Defer to a post-thesis inclusive-design pass if the app ships to clinical SPED settings.

---

## 3. UX — DEFERRED

### U4 — Onboarding length tuning *(needs empirical signal first)*
**Effort:** M · **Priority:** P3

**Why deferred.** The current 7-step onboarding (welcome → 4 phase demos → reward intro → complete) was deferred because compressing without empirical signal is a UX risk: children might miss the per-phase concept demos, parents miss the reward-system intro and don't connect stars to practice motivation.

**What needs to happen first.** Instrument `OnboardingCoordinator.advance()` calls with timestamps; measure step-level completion rate. Two failure modes to watch for: (a) drop-off concentrated on a specific step (signal that step is broken), (b) uniform drop-off across all steps (signal it's just too long). The compression decision is data-driven, not a priori.

**The proposed compression** (if data warrants): 3 steps for the child path — welcome → "Zeig mal was du kannst" (10-second guided trace of letter `A`, child does it, success animation) → "Los geht's!". Move the per-phase concept demos and reward-system intro behind the existing parent's "Einführung wiederholen" button.

**Decision threshold.** Onboarding-completion < 70% → compress. > 90% → leave alone. In between → A/B split.

---

### U5 — Apple Pencil 2 squeeze *(wired on branch; needs device validation)*
**Effort:** S (already done in code) — but **0–1 days for device validation** · **Priority:** P3

**Status.** Wired into `PencilAwareCanvasOverlay` on branch `roadmap-v5-tier12`. `UIPencilInteraction` is installed lazily; squeeze and double-tap both trigger `vm.replayAudio()`. Devices without `UIPencilInteraction` support pass nil and the interaction is never installed.

**What's needed before merging to main.** Real iPad with Apple Pencil 2nd gen, in your hand. Check:
- Squeeze fires the audio replay (not a "switch tools" default action).
- Double-tap (the legacy gesture) also fires the audio replay.
- Finger-only sessions never invoke the handler (verified in code via the `delegate` only being added when the interaction exists).
- Audio doesn't double-fire when squeeze + finger-tap occur in rapid succession (potentially a debounce-needed scenario).

If any of those fails on device, the fix is a tweak in `Coordinator.pencilInteractionDidTap` — don't ship to main without verifying.

---

### U10 — Accessibility audit *(partial shipped; full audit needs device)*
**Effort:** S–M (depending on findings) · **Priority:** P3

**What's already done.**
- Schreibqualität dimension rows collapse to one VoiceOver element per row ("Form, 78 Prozent") instead of three separate focuses.
- Reward badges, daily-goal pill, settings additions, celebration overlay all carry combined-element labels + hints.
- Sparkline view is `accessibilityHidden(true)` (the percentage carries the load-bearing label).

**What's still needed (real iPad with VoiceOver enabled).**
- Walk every screen in VoiceOver order. Watch for skipped elements, misordered focus, ambiguous labels.
- Verify the order of focus in `SchuleWorldView` after a phase advance — does the "Weiter" button get focus before the celebration is announced, or vice versa? Current code may rely on accessibility focus shifts that don't land where intended.
- Switch Control routing — direct-phase dot taps need to be reachable via the switch.
- AssistiveTouch overlay — confirm the touch-handler hierarchy doesn't block AssistiveTouch's hit-testing.
- Dynamic Type stress test — the dashboard rows should not clip at the largest accessibility text size.

**Recommendation.** Schedule 2–3 hours with VoiceOver enabled on the iPad before submitting the thesis to anyone external.

---

### U11 — Dark-mode parity
**Effort:** M (~1 day code + ≥2 hr device validation) · **Priority:** P3

**Why deferred.** `FortschritteWorldView` and the freeform writing canvas pin `.preferredColorScheme(.light)` because their card surfaces use opaque `Color.white`. Removing the pin without device validation is a roll of the dice — the prior author chose the pin specifically because they couldn't validate.

**The change.** Three card surfaces switch from `Color.white` to `Color(uiColor: .secondarySystemGroupedBackground)` (white in light mode, dark grey in dark mode — auto-adapts). After the swap, remove the `.preferredColorScheme(.light)` pin.

**Affected files.**
- `Features/Worlds/FortschritteWorldView.swift` — 4 cards (starCount, streak, dailyGoal, fluencyFooter) + the rewards row
- `Features/Tracing/FreeformWritingView.swift` — canvas chrome + result popups
- Possibly `Features/Tracing/CompletionCelebrationOverlay.swift` — the gradient stays; the white scrim opacity might need tuning

**Failure modes to watch for on device.**
- `AppSurface.starGold` pops against white but might look harsh on dark grey.
- Letter glyph rendered as `Color.primary` over the card → white-on-grey in dark mode. Verify legibility for a 5-year-old (target 7:1 contrast for body, 3:1 for large text).
- Material backgrounds inside `List` already adapt; double-adapting can render weirdly.

**Recommendation.** Worth doing post-thesis. Children use the app in classroom / daylight conditions; the dark-mode population is parents reviewing the dashboard at night. Low pedagogical priority but a polish win.

---

## 4. TECHNICAL DEBT

### D1 — TracingViewModel God-object decomposition *(deliberate multi-day refactor; needs your in-the-loop review)*
**Effort:** L (3–5 days, one PR per extraction) · **Priority:** P1

**Why this matters.** `TracingViewModel.swift` is **2350+ lines** as of `roadmap-v5-tier12`. ~16 distinct responsibilities. Every subsequent thesis-supporting feature lands in this file — once you commit to T1 (lowercase) or P1 (retrieval UI), every change cuts through this God object. **Ship D1 first or pay the per-feature tax forever.**

**Three clean extractions** (each = one PR, CI green between them):

1. **`TouchDispatcher`** — owns `beginTouch` / `updateTouch` / `endTouch`, velocity smoothing knobs, the playback-activation threshold logic. Inputs: haptics, playback, audio, freeWriteRecorder, phaseController (for `feedbackIntensity`). Outputs: callbacks for stroke-completion + canvas-progress updates. **~300 lines** moved out.

2. **`RecognitionOrchestrator`** — owns `activeRecognitionToken`, `runRecognizerForFreeWrite`, the freeform-letter and freeform-word recognition paths, the `enqueueBeforeCelebration` + speech wiring. Inputs: recognizer, calibrator, progress store, overlay queue, speech, animation guide (for the P2 self-explanation re-animation). Token tracking is currently shared across three call sites; centralising it removes 3 nearly-identical guards. **~200 lines** moved out.

3. **`PhaseTransitionCoordinator`** — owns `advanceLearningPhase`, `recordPhaseSessionCompletion`, `commitCompletion`, the post-transition side-effect block (overlay enqueue, speech praise, store writes, adaptation sample, HUD). Inputs: phaseController, freeWriteRecorder, all four stores, overlay queue, speech, syncCoordinator. **~200 lines** moved out.

**After all three:** VM ~1500 lines, dominated by the @Observable forwarder properties (which can't move because views bind to them).

**Failure modes.**
- **Forwarders.** Each property/method that views currently call must keep its name on the VM after the move. An extraction that drops a forwarder breaks the view.
- **MainActor isolation.** All collaborators must be `@MainActor`. Background work (recognition's `Task.detached`) hops back to MainActor before mutating state.
- **Test fixtures.** `TestFixtures.StubProgressStore` etc. are used directly; new collaborators need stub-friendly initialisers.

**Recommendation.** This is the highest-EV technical-debt item. **Worth scheduling a dedicated week with you in the loop** — three PRs over three days, each reviewed before the next starts. I'm not comfortable doing this fully autonomously because each extraction has subtle MainActor + forwarder traps; the failure mode is a test that *passes* but a runtime regression that surfaces in a real session weeks later.

---

### D3 — CoreMLLetterRecognizer Vision-request coverage *(rendering tests shipped; model path still needs a mock)*
**Effort:** M · **Priority:** P3

**What's already done.** Five `renderToImage` golden-image tests in `BuchstabenNativeTests/CoreMLLetterRecognizerTests.swift` cover empty/single-point input → nil, 40×40 grayscale output for non-trivial paths, vertical-only degenerate path, centring-translation invariance.

**What's still missing.** The Vision-request path (`loadModelIfNeeded`, `makeResult`, `VNCoreMLRequest` lifecycle, `ConfidenceCalibrator` wiring). This needs either:
- A real `.mlpackage` bundled into the test target (synthetic tiny model trained on 4×4 inputs to keep size under 100 KB), or
- A mock `VNCoreMLModel` — but `VNCoreMLModel` is `final`, so this requires a protocol-typed seam in the recognizer that the tests can swap.

**Recommendation.** The mock-protocol approach is the cleaner long-term path: define `LetterClassifying` with `func classify(_ image: CGImage) async -> [VNClassificationObservation]?`, route the production call through it, swap a deterministic stub in tests. ~1 day of work.

---

### D8 — Canvas redraw frequency profile
**Effort:** S (profile only) — could expand to M if a real bottleneck surfaces · **Priority:** P3

**Why deferred.** No measured evidence of a problem. On an M-class iPad it's probably fine; on an older iPad (A12 / iPad 8th gen) high-velocity drawing might drop frames because the freeWriteRecorder appends per touch event, the VM publishes the change, the canvas re-renders, the canvas re-builds the path, the GPU rasterises.

**What to do.**
1. Open Instruments → Time Profiler → run a guided session for ~30 seconds at high velocity.
2. Check the SwiftUI Update Profiler for `tracingCanvas` body invocations / second.
3. If sustained >60 invocations / sec, two cuts available:
   - Wrap static layers in `Equatable` subviews (glyph image, ghost lines, start dots only change when `currentLetterName` / `schriftArt` / `showGhost` / `phaseController.showCheckpoints` change). `.equatable()` lets SwiftUI skip body re-eval when those don't change.
   - Throttle recorder writes to ~30 Hz (every other touch event). Coalescing halves redraw count without the child noticing.

**Recommendation.** Don't pre-optimise. Profile only after a real classroom user reports lag or the device-test job reports a frame drop.

---

## 5. POST-THESIS

These remain untouched from V1 of the roadmap. Each is a worthwhile addition once the thesis ships.

### F1 — App Store readiness pass
**Effort:** L · **Priority:** P1 (post-thesis)

Privacy Manifest (`PrivacyInfo.xcprivacy`) declaring `UserDefaults`, `NSUbiquitousKeyValueStore`, `Application Support` writes, on-device CoreML usage. App icon set at every required size. iPad screenshots (5–7 stills covering Schule / Werkstatt / Fortschritte / Eltern-Dashboard). Marketing copy in German + English. App Store Connect "Privacy Practices" section: "Daten werden auf dem Gerät gespeichert; keine Übertragung." TestFlight build with crash-reporting opt-in.

### F2 — Lowercase letters + diacritics complete
**Effort:** XL (subsumes T1's full-alphabet scope) · **Priority:** P1 (post-thesis if T1 ships demo set only)

26 lowercase + Ä Ö Ü ß as full citizens, not placeholders. ~30 letters × 2–3 hours each = 60–90 person-hours.

### F3 — CloudKit sync
**Effort:** L · **Priority:** P1 (post-thesis)

`SyncCoordinator` is wired to `NullSyncService`. Implement a real CloudKit-backed `CloudSyncService` so a child using the app on multiple iPads (parent + grandparent) sees a unified streak and progress. Privacy: zone-per-participant, no PII, opt-in at first launch. Depends on F1 (privacy manifest first).

### F4 — Teacher dashboard (multi-child)
**Effort:** L · **Priority:** P2

Per-classroom view that shows N children's progress side-by-side. Auth via "School Code" (a 6-letter shared secret per teacher). Read-only initially; later add per-child homework assignment. Depends on F3.

### F5 — Numbers + basic punctuation
**Effort:** M · **Priority:** P2

Add `0–9` and the period/comma/question-mark glyphs. Infrastructure is letter-agnostic (just stroke definitions + audio); ~12 new bundled glyphs.

### F6 — Additional cursive scripts
**Effort:** L · **Priority:** P2

The `SchriftArt` enum has five cases; only Druckschrift (Primae) and Schreibschrift (Playwrite AT) are bundled. Add Grundschrift, Vereinfachte Ausgangsschrift, and Schulausgangsschrift once a license-compatible font ships. The code path is already in place — just unblock with font licensing.

### F7 — Apple Watch streak companion
**Effort:** M · **Priority:** P3

A single complication that shows the current streak. Tapping opens the Schule world. Implementation: WatchKit extension + WCSession to read `streak.json` from the App Group. Depends on F1.

### F8 — Mac Catalyst
**Effort:** M · **Priority:** P3

`Package.swift` already targets `macOS 15.0`. Polish keyboard mappings (arrow keys for letter nav, Return to advance) and ship a Catalyst build. Depends on F1.

### F9 — Localization beyond German
**Effort:** M · **Priority:** P3

Architecture is German-only by design (curriculum-specific). For German-speaking children abroad, English UI labels with German letter content might help bilingual classrooms. Wrap UI strings in `Localizable.strings`; ship `de` (canonical) and `en` (UI only — letter content stays German).

### F10 — Switch Control + AssistiveTouch overlay
**Effort:** S–M · **Priority:** P3

For motor-impaired children, expose the direct-phase dot tap as a Switch Control target and render a parallel "Switch Control hint" overlay that highlights the next-expected dot in high contrast.

---

## Summary of the implementation pass

The earlier T2..T8, P2 P3 P4 P7, U1 U2 U3 U6 U7 U8 U9, D2 D4 D5 D6 D9 items, plus partial U10 + D3, are **shipped on `main`** across commits `59acad9` → `276474b` (with `cca4914` as the isolation hot-fix). U5 and P1-infrastructure + P6-infrastructure are on **branch `roadmap-v5-tier12`** awaiting your review and asset work.

D7 was investigated and reversed to **verified-skip** — the LESSONS.md policy is correct because the three remaining XCTest files use `XCTMetric` + `XCTSkip-in-setUp` + `expectation/wait`, none of which Swift Testing has equivalents for. The deeper analysis lives in `docs/ROADMAP_V5_DEFERRED_NOTES.md`.

---

## Recommended ordering for the next sprint

1. **D1** (3–5 days, your branch + my reviews per slice) — clean architecture before the bigger features land.
2. **T1 demo lowercase set** (14–21 hours, your iPad + ElevenLabs) — minimum thesis floor for the four-phase claim.
3. **P1 UI** (1 PR, 1–2 days from me, with your review) — surfaces the retrieval-practice claim that pairs with the existing spaced-practice claim.
4. **P6 recordings** (your ElevenLabs work, parallel with the above) — unlocks the phonemic-awareness toggle that's already wired.

D8 / U10 / U11 are post-thesis polish. F1–F10 are post-thesis full features.

---

_Update this file by removing rows as they ship, not by adding ✅ markers — the deferred / open list should always read as a forward-looking work log, not an archive. Shipped items live in commit history + `docs/ROADMAP_V5_DEFERRED_NOTES.md` for the historical context._
