# Roadmap — Buchstaben-Lernen-App

_Single forward-looking work log. Last updated 2026-04-29 against `main`. Only items still requiring work appear here — every shipped item has been removed. Where a row says "infrastructure shipped, asset work pending", the code-side foundation is in place and the remaining work is content authoring (audio, glyph definitions) on your side._

Each item has a short summary line plus a deeper-context section below it (effort, file list, citations, failure modes). The two were previously split across `ROADMAP_V5.md` + `docs/ROADMAP_V5_DEFERRED_NOTES.md`; they're now unified here.

Effort key: **S** = under 1 day · **M** = 1–3 days · **L** = 3+ days · **XL** = multi-week
Priority key: **P1** = thesis-blocking · **P2** = thesis-strengthening · **P3** = post-thesis polish

---

## 1. THESIS-CRITICAL

### T1 — Lowercase letter coverage *(asset work + on-device authoring)*
**Effort:** XL · **Priority:** P1

`Resources/Letters/` has 56 directories (26 upper + 26 lower + Ä Ö Ü ß). 25 have non-empty `strokes.json`; 31 have **empty** stroke arrays as placeholders. The empty-stroke fallback path is correct (`LearningPhaseController` skips observe + direct phases when strokes are empty), but it means the four-phase pedagogy that the thesis demonstrates **does not actually run** for 31 of 56 letters. The thesis claim "Vier-Phasen-Pädagogik for Volksschule 1. Klasse" is exposed: a reviewer who picks `q` gets the empty-strokes fallback.

**What's needed per letter.**
1. **Stroke definition.** 1–3 strokes per letter, each with 5–15 checkpoints in 0–1 cell-local coordinates. Author by:
   - Open the app in Debug mode (long-press the phase indicator on SchuleWorldView)
   - Open the calibration overlay (long-press again)
   - Drag-place each checkpoint visually over the rendered glyph
   - The calibration store writes to `Application Support/BuchstabenNative/calibration/`
   - Export the calibrated checkpoints into the bundle's `Resources/Letters/<x>/strokes.json`
2. **PBM bitmap fallback.** Optional but the validator complains without it.
3. **Audio takes.** 3 mp3 recordings of the letter name (`<x>1.mp3`, `<x>2.mp3`, `<x>3.mp3`).
4. **Phoneme audio.** P6 infrastructure is in place; you need 3 phoneme takes per letter. See Appendix C in `docs/APP_DOCUMENTATION.md` for the convention and ElevenLabs prompt template.

**Per-letter budget.** ~2–3 hours, mostly the calibration session + audio editing.

**Two viable scopes.**
- **Demo lowercase set** (`a f i k l m o`): 7 letters × 2–3 hours = 14–21 hours. **Thesis-floor minimum.**
- **Full alphabet** (26 lowercase + 19 missing uppercase + 4 umlauts/ß = 49 letters): ~100–150 hours. Post-thesis or a multi-week dedicated authoring sprint.

**What you can do without a device.** Pre-generate stroke definitions from CoreText measurements run on macOS (small `swift run` script that loads Primae, renders each glyph, samples the path). Won't be perfect (Primae's glyph metrics depend on font-loading order) but gets you 80% of the way as a starting point for device calibration. Audio generation via ElevenLabs is fully offline-able.

**Citation.** Berninger et al. 2006 (*Developmental Neuropsychology* 29(1)) — early instruction benefits from grouped upper- and lowercase exposure.

---

### P1 — Spaced retrieval testing prompts *(infrastructure on main; UI pending)*
**Effort:** M (UI only) · **Priority:** P1

The app implements spaced *practice* (Cepeda 2006) via `LetterScheduler` but not spaced *retrieval*. Roediger & Karpicke (2006) showed retrieval tests produce better long-term retention than additional study — generating an answer beats re-encoding it. Adding retrieval extends the thesis pedagogical claim from "spacing exposure" to "spacing recall".

**What's already in code (on `main`).**
- `Core/RetrievalScheduler.swift` — every-Nth-letter cadence with `interval` (default 3), `minimumPriorCompletions` (default 1, skips testing on never-seen letters), persisted counter so cadence survives relaunch.
- `LetterProgress.retrievalAttempts: [Bool]?` rolling outcome log (cap 10) on `ProgressStore`.
- `JSONProgressStore.recordRetrievalAttempt(letter:correct:)` write path.
- Stub default on `ProgressStoring` so older mocks compile.

**What's still needed.**
1. **`RetrievalPromptView`** (new file in `Features/Tracing/`). Three-button German recognition test: "Welcher Buchstabe ist das?" with audio plays the letter (or phoneme — useful overlap with P6) and three candidate buttons (the correct letter + two distractors from the same motor-similarity cluster — `LetterOrderingStrategy.motorSimilarity` ordering gives you the cluster automatically). On tap, record the outcome and dismiss.
2. **Settings opt-in.** `enableRetrievalPrompts: Bool` UserDefaults key in `TracingDependencies`, mirrored toggle in SettingsView under a "Erinnerungstest" / "Forschung" section. Default off — opt-in research feature.
3. **VM wiring.** In `loadRecommendedLetter()`, before `load(letter:)`, call `retrievalScheduler.shouldPrompt(for: letter, progress: progress)`. When `true`, push a `.retrievalPrompt(letter:)` overlay onto the queue ahead of the actual letter load. The retrieval prompt's `onComplete` runs the load.
4. **`CanvasOverlay.retrievalPrompt(letter: String)`** case on `OverlayQueueManager`. Modal (no auto-dismiss).
5. **CSV export.** Add `retrievalAccuracy` column to the per-letter aggregate row in `ParentDashboardExporter.swift`. Update Appendix B in `docs/APP_DOCUMENTATION.md`.
6. **Tests.** RetrievalScheduler unit tests (interval cadence, minimum-prior-completions skip, counter reset). RetrievalPromptView is integration-tested through the queue.

**Citation.** Roediger, H. L., & Karpicke, J. D. (2006). Test-enhanced learning: Taking memory tests improves long-term retention. *Psychological Science*, 17(3), 249–255.

---

### P6 — Phoneme audio recordings *(infrastructure on main; audio assets pending)*
**Effort:** XL (recording + voice direction work) · **Priority:** P1

Phonemic awareness (Adams 1990) predicts later reading acquisition; pairing handwriting practice with the *sound* the letter makes (`/a/` as in *Affe*) instead of just its name (`/aː/`) is curriculum-aligned for German Volksschule.

**What's already in code (on `main`).**
- `LetterAsset.phonemeAudioFiles: [String]` — populated by `LetterRepository.partitionPhonemeAudio` from the bundle scan.
- `enablePhonemeMode: Bool` UserDefaults toggle, threaded through `TracingDependencies` and the VM.
- All 7 audio call sites (replay, variants, autoplay, begin-touch reload, direct-phase first-tap, load() prime) routed through `activeAudioFiles(for:)` helper. Toggle-on with no phoneme recordings → silent fallback to letter-name set.
- SettingsView "Lautwert" section with the toggle + Adams 1990 caption.

**What's still needed.**
1. **Audio recordings** following the convention `<base>_phoneme<n>.<ext>` per Appendix C in `docs/APP_DOCUMENTATION.md`. Three takes per letter (different voices for child preference). 30 letters × 3 takes = 90 recordings.
2. ElevenLabs prompt template + per-letter IPA reference table is in the appendix. Generation should be straightforward; clean-up (trim silence, normalise to -16 LUFS, export at 44.1 kHz mp3) is the per-file labour.
3. **Bundle wiring.** Drop the files into `BuchstabenNative/Resources/Letters/<base>/`. Repository scan picks them up automatically; no Swift code changes required.
4. **Verification checklist** (in the appendix): toggle on → tap → phoneme plays; two-finger swipe cycles through takes; toggle off → name resumes.

**Citations.**
- Adams, M. J. (1990). *Beginning to Read: Thinking and Learning about Print*. MIT Press.
- Krech, E.-M. et al. (2009). *Deutsches Aussprachewörterbuch*. de Gruyter.

---

## 2. PEDAGOGICAL — DEFERRED

### P5 — Forward + backward stroke chaining toggle
**Effort:** S–M · **Priority:** P3

**Why deferred.** Spooner et al. 2014 is about *special-needs interventions* (autism, motor-planning disorders), not the typical Volksschule cohort. Adding it as an opt-in parent toggle is plausible but reads as feature creep without IRB / curriculum justification. It also adds complexity to the direct-phase order tracking (the "next-expected" index has to flip direction) for a feature your thesis cohort won't use.

**If you decide to do it anyway.** Settings toggle "Schreibrichtung umkehren" (off by default), `LearningPhaseController.directDotOrder` reading the toggle and flipping the iteration. The change is local to the direct phase only; guided/freeWrite always run canonical order. ~1 day.

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

### U5 — Apple Pencil 2 squeeze *(wired on main; needs device validation)*
**Effort:** S (already done in code) — but **0–1 days for device validation** · **Priority:** P3

**Status.** Wired into `PencilAwareCanvasOverlay`. `UIPencilInteraction` is installed lazily; squeeze and double-tap both trigger `vm.replayAudio()`. Devices without `UIPencilInteraction` support pass nil and the interaction is never installed.

**What's needed before merging to main.** Real iPad with Apple Pencil 2nd gen, in your hand. Check:
- Squeeze fires the audio replay (not a "switch tools" default action).
- Double-tap (the legacy gesture) also fires the audio replay.
- Finger-only sessions never invoke the handler.
- Audio doesn't double-fire when squeeze + finger-tap occur in rapid succession.

If any of those fails on device, the fix is a tweak in `Coordinator.pencilInteractionDidTap`.

---

### U10 — Accessibility audit *(partial shipped; full audit needs device)*
**Effort:** S–M · **Priority:** P3

**What's already done (on `main`).**
- Schreibqualität dimension rows collapse to one VoiceOver element per row ("Form, 78 Prozent") instead of three separate focuses.
- Reward badges, daily-goal pill, settings additions, celebration overlay all carry combined-element labels + hints.
- Sparkline view is `accessibilityHidden(true)`.

**What's still needed (real iPad with VoiceOver enabled).**
- Walk every screen in VoiceOver order. Watch for skipped elements, misordered focus, ambiguous labels.
- Verify the order of focus in `SchuleWorldView` after a phase advance — does the "Weiter" button get focus before the celebration is announced, or vice versa?
- Switch Control routing — direct-phase dot taps need to be reachable via the switch.
- AssistiveTouch overlay — confirm the touch-handler hierarchy doesn't block AssistiveTouch's hit-testing.
- Dynamic Type stress test — the dashboard rows should not clip at the largest accessibility text size.

**Recommendation.** Schedule 2–3 hours with VoiceOver enabled on the iPad before submitting the thesis to anyone external.

---

### U11 — Dark-mode parity
**Effort:** M (~1 day code + ≥2 hr device validation) · **Priority:** P3

**Why deferred.** `FortschritteWorldView` and the freeform writing canvas pin `.preferredColorScheme(.light)` because their card surfaces use opaque `Color.white`. In dark mode without the pin, the cards turn near-black but the text styles (which rely on `.primary`) flip to white — the white text on white-because-pinned-light cards already works, but the card edges and shadows lose contrast.

`SchuleWorldView`, `WerkstattWorldView`, and the parent dashboards adapt fine in dark mode; only Fortschritte and Freeform are pinned.

**The change.**

```swift
// Today
.background(Color.white, in: RoundedRectangle(cornerRadius: 24))

// After
.background(
    Color(uiColor: .secondarySystemGroupedBackground),
    in: RoundedRectangle(cornerRadius: 24)
)
```

`secondarySystemGroupedBackground` is white in light mode, dark grey in dark mode — auto-adapts. After the swap, remove the `.preferredColorScheme(.light)` pin.

**Affected files.**
- `Features/Worlds/FortschritteWorldView.swift` — 4 cards (starCount, streak, dailyGoal, fluencyFooter) + the rewards row
- `Features/Tracing/FreeformWritingView.swift` — canvas chrome + result popups
- Possibly `Features/Tracing/CompletionCelebrationOverlay.swift` — gradient stays; white scrim opacity might need tuning

**Failure modes.** `AppSurface.starGold` pops against white but might look harsh on dark grey. Letter glyph rendered as `Color.primary` over the card → white-on-grey in dark mode (verify legibility for a 5-year-old: 7:1 body-text contrast, 3:1 large-text). Material backgrounds inside `List` already adapt; double-adapting can render weirdly.

**Recommendation.** Worth doing post-thesis. Children use the app in classroom / daylight conditions; the dark-mode population is parents reviewing the dashboard at night. Low pedagogical priority.

---

## 4. TECHNICAL DEBT

### D1 — TracingViewModel God-object decomposition *(deliberate multi-day refactor; needs your in-the-loop review)*
**Effort:** L (3–5 days, one PR per extraction) · **Priority:** P1

`TracingViewModel.swift` is **2350+ lines** as of `main`. ~16 distinct responsibilities. Every subsequent thesis-supporting feature lands in this file — once you commit to T1 (lowercase) or P1 UI, every change cuts through this God object. **Ship D1 first or pay the per-feature tax forever.**

**Three clean extractions** (each = one PR, CI green between them):

**1. `TouchDispatcher`** — owns `beginTouch` / `updateTouch` / `endTouch`, velocity smoothing knobs, and the playback-activation threshold logic. Inputs: haptics, playback, audio, freeWriteRecorder, phaseController (for `feedbackIntensity`). Outputs: callbacks for stroke-completion + canvas-progress updates. **~300 lines** moved out.

**2. `RecognitionOrchestrator`** — owns `activeRecognitionToken`, `runRecognizerForFreeWrite`, the freeform-letter and freeform-word recognition paths, the `enqueueBeforeCelebration` + speech wiring. Inputs: recognizer, calibrator, progress store, overlay queue, speech, animation guide (for the P2 self-explanation re-animation). Token tracking is currently shared across three call sites; centralising it removes 3 nearly-identical guards. **~200 lines** moved out.

**3. `PhaseTransitionCoordinator`** — owns `advanceLearningPhase`, `recordPhaseSessionCompletion`, `commitCompletion`, the post-transition side-effect block (overlay enqueue, speech praise, store writes, adaptation sample, HUD). Inputs: phaseController, freeWriteRecorder, all four stores, overlay queue, speech, syncCoordinator. **~200 lines** moved out.

**After all three:** VM ~1500 lines, dominated by the @Observable forwarder properties (which can't move because views bind to them).

**Failure modes.**
- **Forwarders.** Each property/method that views currently call must keep its name on the VM after the move.
- **MainActor isolation.** All collaborators must be `@MainActor`. Background work hops back to MainActor before mutating state.
- **Test fixtures.** `TestFixtures.StubProgressStore` etc. are used directly; new collaborators need stub-friendly initialisers.
- **Per-VM identity.** Each collaborator must be created once per VM (not shared static).

**Recommendation.** This is the highest-EV technical-debt item. **Worth scheduling a dedicated week with you in the loop** — three PRs over three days, each reviewed before the next starts. Not safe autonomous work; failure mode is a test that *passes* but a runtime regression that surfaces in a real session weeks later.

---

### D3 — CoreMLLetterRecognizer Vision-request coverage *(rendering tests on main; model path still needs a mock)*
**Effort:** M · **Priority:** P3

**What's already done.** Five `renderToImage` golden-image tests in `BuchstabenNativeTests/CoreMLLetterRecognizerTests.swift` cover empty/single-point input → nil, 40×40 grayscale output for non-trivial paths, vertical-only degenerate path, centring-translation invariance.

**What's still missing.** The Vision-request path (`loadModelIfNeeded`, `makeResult`, `VNCoreMLRequest` lifecycle, `ConfidenceCalibrator` wiring). This needs either:
- A real `.mlpackage` bundled into the test target (synthetic tiny model trained on 4×4 inputs to keep size under 100 KB), or
- A mock `VNCoreMLModel` — but `VNCoreMLModel` is `final`, so this requires a protocol-typed seam in the recognizer that the tests can swap.

**Recommendation.** The mock-protocol approach is the cleaner long-term path: define `LetterClassifying` with `func classify(_ image: CGImage) async -> [VNClassificationObservation]?`, route the production call through it, swap a deterministic stub in tests. ~1 day.

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

These are worthwhile additions once the thesis ships. None of them is a thesis-blocker.

### F1 — App Store readiness pass
**Effort:** L · **Priority:** P1 (post-thesis)

Privacy Manifest (`PrivacyInfo.xcprivacy`) declaring `UserDefaults`, `NSUbiquitousKeyValueStore`, `Application Support` writes, on-device CoreML usage. App icon set at every required size. iPad screenshots (5–7 stills covering Schule / Werkstatt / Fortschritte / Eltern-Dashboard). Marketing copy in German + English. App Store Connect "Privacy Practices" section: "Daten werden auf dem Gerät gespeichert; keine Übertragung." TestFlight build with crash-reporting opt-in.

### F2 — Lowercase letters + diacritics complete
**Effort:** XL (subsumes T1's full-alphabet scope) · **Priority:** P1 (post-thesis if T1 ships demo set only)

26 lowercase + Ä Ö Ü ß as full citizens. ~30 letters × 2–3 hours each = 60–90 person-hours.

### F3 — CloudKit sync
**Effort:** L · **Priority:** P1 (post-thesis)

`SyncCoordinator` is wired to `NullSyncService`. Implement a real CloudKit-backed `CloudSyncService` so a child using the app on multiple iPads sees a unified streak and progress. Privacy: zone-per-participant, no PII, opt-in at first launch. Depends on F1.

### F4 — Teacher dashboard (multi-child)
**Effort:** L · **Priority:** P2

Per-classroom view that shows N children's progress side-by-side. Auth via "School Code" (a 6-letter shared secret per teacher). Read-only initially; later add per-child homework assignment. Depends on F3.

### F5 — Numbers + basic punctuation
**Effort:** M · **Priority:** P2

Add `0–9` and the period/comma/question-mark glyphs. Infrastructure is letter-agnostic; ~12 new bundled glyphs.

### F6 — Additional cursive scripts
**Effort:** L · **Priority:** P2

The `SchriftArt` enum has five cases; only Druckschrift (Primae) and Schreibschrift (Playwrite AT) are bundled. Add Grundschrift, Vereinfachte Ausgangsschrift, and Schulausgangsschrift once a license-compatible font ships. The code path is already in place — just unblock with font licensing.

### F7 — Apple Watch streak companion
**Effort:** M · **Priority:** P3

A single complication that shows the current streak. Tapping opens the Schule world. WatchKit extension + WCSession to read `streak.json` from the App Group. Depends on F1.

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

## Recommended ordering for the next sprint

1. **D1** (3–5 days, your branch + my reviews per slice) — clean architecture before the bigger features land.
2. **T1 demo lowercase set** (14–21 hours, your iPad + ElevenLabs) — minimum thesis floor for the four-phase claim.
3. **P1 UI** (1 PR, 1–2 days from me, with your review) — surfaces the retrieval-practice claim that pairs with the existing spaced-practice claim.
4. **P6 recordings** (your ElevenLabs work, parallel with the above) — unlocks the phonemic-awareness toggle that's already wired.

D8 / U10 / U11 are post-thesis polish. F1–F10 are post-thesis full features.

---

_Update this file by removing rows as they ship, not by adding ✅ markers — the deferred / open list should always read as a forward-looking work log. Shipped items live in commit history._
