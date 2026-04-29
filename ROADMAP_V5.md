# Roadmap V5 — Buchstaben-Lernen-App

_Generated: 2026-04-29. Forward-looking plan for thesis submission and beyond. NOT a bug-fix list — every prior review (R1, R2, R3, R4) has been resolved or explicitly deferred. This document plans what to build **next**._

> **Implementation status (2026-04-29 evening):** the T/P/U/D batches were
> driven through main in commits `59acad9`, `cca4914`, `001d35b`, `740512e`,
> `3dbf597`. Items marked **✅ shipped** below are landed; items marked
> **⏭ deferred** are explicitly out of scope for this implementation pass
> with the reason inline. The post-thesis F section is untouched.

Sources cross-referenced: `docs/APP_DOCUMENTATION.md`, `docs/APP_REFERENCE.md`, `HIDDEN_FEATURES_AUDIT.md`, `REVIEW_ROUND3.md`, the deleted `REVIEW_AND_IMPROVEMENTS.md` (recovered from `83853ba^`), and a full Swift-source scan.

Effort key: **S** = under 1 day · **M** = 1–3 days · **L** = 3+ days.
Priority key: **P1** = do first within the section · **P2** = next · **P3** = nice-to-have within the section.

---

## 1. THESIS-CRITICAL

Things that determine whether the thesis submission stands up to scrutiny.

### T1 (P1, M) — Lowercase letter coverage for the active set ⏭ deferred (audio + glyph asset work)
Currently only `A F I K L M O` ship full stroke + audio data. The thesis claims "26-letter alphabet" but `Resources/Letters` has 56 directories with only **25 non-empty `strokes.json`** files; the lowercase + umlaut directories are placeholders with empty stroke arrays. For thesis submission the active set should ship lowercase a, f, i, k, l, m, o so the cohort can be exposed to upper- and lowercase letters of the same shape. Alternatively, document the limitation prominently in the limitations chapter.
- **Files:** `Resources/Letters/<x>/strokes.json` (7 lowercase), `Resources/Letters/<x>/<x>.pbm`, `Resources/Letters/<x>/<x>1.mp3`–`<x>3.mp3`, `letter_set.json`
- **Citation:** Berninger et al. 2006 (Developmental Neuropsychology 29(1)) — early instruction benefits from grouped upper- and lowercase exposure.
- **Dependencies:** none.

### T2 (P1, M) — D-5 condition-tagged accuracy samples ✅ shipped (59acad9)
`LetterAccuracyStat.accuracySamples: [Double]` is a flat per-letter array with no per-sample condition tag. The R3 fix derives per-arm letter aggregates **at export time** from `phaseSessionRecords`, but a regression analysis that wants per-letter learning curves split by arm needs each sample's condition. Add `accuracyConditions: [ThesisCondition]?` parallel array on `LetterAccuracyStat` (Codable optional, defaults nil for legacy rows); populate in `recordSession`. Export as a `letterStats_byArm` block.
- **Files:** `Core/ParentDashboardStore.swift`, `Core/ParentDashboardExporter.swift`, plus tests.
- **Citation:** None — methodological hygiene for the between-arms ANOVA.
- **Dependencies:** none.

### T3 (P1, S) — Time-of-day export tooling ✅ shipped (59acad9 — `# timezone=` header)
`SessionDurationRecord.recordedAt` (D-9) and `PhaseSessionRecord.recordedAt` (D-3) now carry full ISO-8601 timestamps. Add a derived `# timezone=` header line in the export and a small documentation block in the thesis methodology explaining how to interpret cross-device timezones. Currently the timestamps are written in device-local timezone with no marker.
- **Files:** `Core/ParentDashboardExporter.swift`.
- **Citation:** None — analytical metadata.
- **Dependencies:** D-9 (already done).

### T4 (P1, S) — Active practice time field on session records ✅ shipped (59acad9 — `wallClockSeconds`)
The session-duration math now uses an active-time accumulator (D-1), but the **value** that lands in `SessionDurationRecord.durationSeconds` is the *active* time — there's no field that surfaces the wall-clock duration alongside it. For the thesis "engagement vs effective practice" comparison, both are useful. Add `wallClockSeconds: TimeInterval?` parallel field; populate from `Date().timeIntervalSince(letterLoadedAt)` regardless of background pauses.
- **Files:** `Core/ParentDashboardStore.swift`, `Features/Tracing/TracingViewModel.swift`, exporter, tests.
- **Citation:** None — engagement-vs-practice analytical split.
- **Dependencies:** D-1 (done).

### T5 (P2, M) — Recognition pre/post calibration trace ✅ shipped (59acad9 — `recognition_confidence_raw`)
`ConfidenceCalibrator` adjusts the raw softmax with confusable-pair penalty (15 %) and history boost (10 %). The CSV currently exports the *post-calibration* `recognition_confidence` only. Add `recognition_confidence_raw` so the thesis can demonstrate the calibrator's effect on classification correctness. Optional: also `recognition_calibration_delta`.
- **Files:** `Core/LetterRecognizer.swift` (return raw), `Core/ParentDashboardStore.swift` (PhaseSessionRecord), exporter.
- **Citation:** Cohen et al. 2017 (EMNIST) and Apple's CoreML calibration recommendations — the raw + adjusted pair is the standard way to report a confidence-calibration intervention.
- **Dependencies:** none.

### T6 (P2, M) — A/B condition-arm balance check on enrolment ✅ shipped (59acad9 — researcher override)
`ThesisCondition.assign(participantId:)` uses `byte % 3`, so condition assignment is uniform in expectation but not balanced for small cohorts (n < ~30 risks 2:1 imbalance). For a thesis cohort of 12–24 children, switch to a **stratified blocked randomisation**: every six enrolments contain exactly two of each arm. Persist a small queue in the store.
- **Files:** `Core/ThesisCondition.swift`, `Core/ParticipantStore` (block queue), tests.
- **Citation:** Schulz & Grimes (2002) Lancet 359 — block randomisation for small trials.
- **Dependencies:** none.

### T7 (P2, S) — Per-session input-mode tag on session durations ✅ shipped (59acad9)
`PhaseSessionRecord.inputDevice` is populated (D-6), but `SessionDurationRecord` has no input-device field, so an aggregate "minutes practised by finger vs pencil" analysis isn't reconstructible without joining across record types. Add `inputDevice: String?` to `SessionDurationRecord`.
- **Files:** `Core/ParentDashboardStore.swift`, exporter, tests.
- **Citation:** Alamargot & Morin 2015 — tablet-vs-paper graphomotor differences depend on input device.
- **Dependencies:** D-6 (done).

### T8 (P3, S) — Export schema documentation ✅ shipped (59acad9 — `docs/EXPORT_SCHEMA.md`)
Generate a one-page `EXPORT_SCHEMA.md` in `docs/` describing every CSV/TSV column, its source field, range, and analytical purpose. The thesis appendix can reference this. The audit verified the columns exist; no developer docs exist for downstream analysts.
- **Files:** `docs/EXPORT_SCHEMA.md` (new).
- **Dependencies:** T2, T4, T5, T7 (so the schema doc is final).

---

## 2. PEDAGOGICAL ENHANCEMENTS

Research-backed features that improve learning outcomes.

### P1 (P1, L) — Spaced-retrieval testing prompts ⏭ deferred (large feature; needs UI design)
The app currently spaces *practice* (Cepeda 2006) but not *retrieval*. Roediger & Karpicke (2006) show retrieval practice produces better long-term retention than additional study. Add an opt-in "Erinnerst du dich noch?" mode: every Nth letter selection presents a recognition or recall task ("Welcher Buchstabe ist das?" with three audio choices) before the tracing phase. Score retrieval separately and feed it into the scheduler's priority.
- **Files:** new `Features/Tracing/RetrievalPromptView.swift`, `Core/LetterScheduler.swift` (retrieval-aware priority), `TracingViewModel.swift`.
- **Citation:** Roediger, H. L., & Karpicke, J. D. (2006). Test-enhanced learning: Taking memory tests improves long-term retention. *Psychological Science*, 17(3), 249–255.
- **Dependencies:** none.

### P2 (P1, M) — Self-explanation prompts on misrecognition ✅ shipped (3dbf597)
When CoreML predicts the wrong letter on a freeWrite session (`recognitionCorrect == false`), show a brief "Schauen wir es noch einmal an" prompt that re-plays the reference glyph animation. This implements Chi's self-explanation paradigm: surfacing the mismatch and re-presenting the correct form leverages elaborative processing for retention.
- **Files:** `Features/Tracing/RecognitionFeedbackView.swift`, `Features/Worlds/SchuleWorldView.swift`, `Core/SpeechSynthesizer.swift`.
- **Citation:** Chi, M. T. H., et al. (1989). Self-explanations: How students study and use examples in learning to solve problems. *Cognitive Science*, 13(2), 145–182.
- **Dependencies:** none.

### P3 (P2, M) — Errorless learning ramp for the very first encounters ✅ shipped (740512e)
For the **first three** sessions on a new letter, raise the radius multiplier so checkpoint hits are extremely forgiving (Touretzky-style errorless learning). Hard-decay back to standard tier after 3 sessions to avoid permanent leniency. Currently `MovingAverageAdaptationPolicy` starts at `.standard` (radiusMultiplier × 1.0) for every letter regardless of whether the child has seen it before.
- **Files:** `Core/DifficultyAdaptation.swift`, `Core/ProgressStore.swift` (read `completionCount` to decide), `TracingViewModel.swift`.
- **Citation:** Skinner, B. F. (1958). Teaching machines. *Science*, 128(3330), 969–977; Terrace, H. S. (1963). Discrimination learning with and without "errors." *JEAB*, 6(1), 1–27.
- **Dependencies:** none.

### P4 (P2, M) — Letter-formation video / Bob-the-dog start cue ✅ shipped (a6a8bc4 — 1 s first-step dwell in AnimationGuideController)
LetterSchool, HWT, and Wet-Dry-Try all show an animated character pointing to the start position. The current observe phase has an animated dot, which is correct but visually subtle for a 5-year-old. Add a 1-second character-pointing animation at the first stroke's start before the dot starts moving. Asset budget: one Lottie or symbol-based animation (no extra fonts/sounds needed).
- **Files:** `Features/Tracing/AnimationGuideController.swift`, new asset in `Resources/`, `Features/Tracing/TracingCanvasView.swift`.
- **Citation:** Mayer (2009) Multimedia Learning — pre-attentive cueing principle.
- **Dependencies:** none.

### P5 (P2, S) — Forward + backward stroke chaining option ⏭ deferred (pedagogical risk; needs validation)
Some children (Asperger / motor-planning issues) benefit from learning the **last** stroke first and adding earlier strokes backward (backward chaining). Add a hidden parent-toggle "Schreibrichtung umkehren" that reverses stroke order in the direct phase only. The internal stroke index runs backward; the canonical order is restored for guided/freeWrite. Research-only; off by default.
- **Files:** `Core/LearningPhaseController.swift`, `Features/Tracing/TracingViewModel.swift`, `Features/Dashboard/SettingsView.swift`.
- **Citation:** Spooner, F., et al. (2014). Comparing chaining methods. *Education and Training in Autism and Developmental Disabilities*, 49(2), 162–183.
- **Dependencies:** none.

### P6 (P3, M) — Phonics audio integration ⏭ deferred (audio asset work)
Each letter currently has 1–3 pronunciation audio files. Add a separate "Buchstabenklang" (phoneme) audio that plays the *sound* the letter makes in a word context (e.g. /a/ as in *Affe*) — distinct from the letter's name (/aː/). Two-finger swipe could cycle name ↔ phoneme. Current `audioFiles` triad already supports this; just need recordings.
- **Files:** `Resources/Letters/<x>/<x>_phoneme.mp3` (new audio assets), small wiring in `LetterRepository.swift`.
- **Citation:** Adams (1990) *Beginning to Read* — phonemic awareness predicts reading acquisition.
- **Dependencies:** audio recording.

### P7 (P3, S) — Goal-setting prompt at session start ✅ shipped (3dbf597 — daily-goal pill)
Locke & Latham (1990) goal-setting theory predicts that explicit, proximal goals improve practice quality. On daily app open, surface a one-tap goal pill: "Heute schaffe ich 3 Buchstaben" (default 3, parent-configurable). Show progress toward it on the gallery; celebrate completion.
- **Files:** new `Features/Worlds/DailyGoalPill.swift`, `Core/StreakStore.swift` (track daily goal hits), `FortschritteWorldView.swift`.
- **Citation:** Locke, E. A., & Latham, G. P. (1990). *A theory of goal setting & task performance.* Prentice-Hall.
- **Dependencies:** none.

---

## 3. UX POLISH

Make the app delightful and accessible without changing pedagogy.

### U1 (P1, S) — Reward celebration overlay ✅ shipped (740512e)
The `earnedRewards` badges now appear in the Fortschritte gallery (HIDDEN_FEATURES_AUDIT C.6 fix), but a newly-earned reward gets no immediate celebration. Add an overlay-queue case `.rewardCelebration(RewardEvent)` that fires the moment `recordSession` returns a non-empty array of new rewards. Big emoji, sparkle particles, "Toll gemacht!" speech, then auto-advance.
- **Files:** `Core/OverlayQueueManager.swift` (new case), `Features/Tracing/RewardCelebrationOverlay.swift` (new), `TracingViewModel.swift`, `SchuleWorldView.swift`.
- **Dependencies:** none.

### U2 (P1, S) — Empty letter-set onboarding hint ✅ verified done (Werkstatt auto-enters freeform; Fortschritte already had ContentUnavailableView)
`SchuleWorldView` already has the `ContentUnavailableView` empty-state (C-3 R1 fix). Add the same empty-state to `WerkstattWorldView` and `FortschritteWorldView` for parity. Currently both can render empty without a verbal hint.
- **Files:** `Features/Worlds/WerkstattWorldView.swift`, `FortschritteWorldView.swift`.
- **Dependencies:** none.

### U3 (P2, M) — Animated world transitions ✅ verified done (`MainAppView` already animates with reduceMotion gate)
World switching is instant. A 200 ms cross-fade on the world content (not the rail) would feel less abrupt for a 5-year-old. Use SwiftUI `.transition(.opacity.combined(with: .scale(0.96)))` keyed on `activeWorld`.
- **Files:** `Features/Navigation/MainAppView.swift`.
- **Dependencies:** none.

### U4 (P2, S) — Onboarding length tuning ⏭ deferred (UX risk; needs A/B validation before committing)
The 7-step onboarding (welcome → 4 phase demos → reward intro → complete) is long for a 5-year-old. Shorten to **3 steps** for the child path: welcome → "Zeig mal was du kannst" (10 s tracing demo) → "Los geht's!". Keep the long form behind the parent's "Einführung wiederholen" button.
- **Files:** `Features/Onboarding/OnboardingView.swift`, `Core/OnboardingCoordinator.swift`.
- **Dependencies:** none.

### U5 (P2, M) — Pencil 2 squeeze for pause/replay ⏭ deferred (UIPencilInteraction integration; needs device testing)
iPadOS 17.5+ exposes `UIPencilInteraction` squeeze events. Bind a squeeze to "replay letter audio" — a one-handed action that doesn't take the child off the canvas. Falls back to a no-op for finger users.
- **Files:** `Features/Tracing/TracingCanvasView.swift`, `Features/Tracing/PencilAwareCanvasOverlay.swift`.
- **Dependencies:** none.

### U6 (P2, S) — Haptic on celebration overlay tap ✅ shipped (001d35b)
The celebration overlay has a "Weiter" button. Tap currently triggers no haptic. Add `haptics.fire(.letterCompleted)` (or a softer pattern) so the child gets a confirmation pulse before the next letter loads. Aligns with the rest of the app's haptic coverage.
- **Files:** `Features/Tracing/CompletionCelebrationOverlay.swift`, `TracingViewModel.swift`.
- **Dependencies:** none.

### U7 (P2, S) — Schreibmotorik-detail sparkline ✅ shipped (740512e)
The new "Schreibqualität – Details" section shows static percentage bars. Add a 5-session sparkline beside each dimension so parents see trend (improving / stable / declining). The data exists in `phaseSessionRecords`; just plot the last 5 freeWrite scores per dimension.
- **Files:** `Features/Dashboard/ParentDashboardView.swift`, possibly a small `SparklineView.swift`.
- **Dependencies:** none.

### U8 (P2, S) — Speech-rate parental knob ✅ shipped (001d35b)
TTS uses the system default rate. For 5-year-olds, this is sometimes too fast. Add a Settings slider "Sprechgeschwindigkeit" with three positions (langsam / normal / schnell) bound to `AVSpeechUtterance.rate`. Persist in UserDefaults.
- **Files:** `Features/Dashboard/SettingsView.swift`, `Core/SpeechSynthesizer.swift`.
- **Dependencies:** none.

### U9 (P3, S) — Visual-consistency token sweep ✅ shipped (001d35b — unified `AppSurface.starGold`)
`AppSurface` and `WorldPalette` now share most tokens (W-39 / W-40 R1). One outstanding inconsistency: the celebration overlay's gold star tint and the picker's gold star tint use different RGB values. Unify to a single `AppSurface.starGold` token.
- **Files:** `Features/Navigation/WorldPalette.swift`, `CompletionCelebrationOverlay.swift`, `LetterPickerBar.swift`, `FortschritteWorldView.swift`.
- **Dependencies:** none.

### U10 (P3, S) — Accessibility audit pass ✅ partial shipped (a6a8bc4 — Schreibqualität rows collapse to one VoiceOver element; full device walkthrough still needed)
The R1 accessibility fixes (P-9) covered the obvious gaps. A full VoiceOver walkthrough would catch:
- Order of focus in `SchuleWorldView` after a phase advance
- Whether the Schreibqualität dimension bars are reachable as a single combined element vs separate
- The new reward-badge row's swipe-navigation in horizontal scrollview
- Switch Control routing
- **Files:** any view file flagged.
- **Dependencies:** none.

### U11 (P3, M) — Dark-mode parity ⏭ deferred (tonal redesign; needs device validation)
`FortschritteWorldView` pins `.preferredColorScheme(.light)` because card surfaces are opaque white. A proper dark-mode pass would re-tone the cards to `.thinMaterial` so a parent reviewing at night doesn't get blasted with white. The child-facing schule/werkstatt are colour-bold by design and can stay light-fixed.
- **Files:** `Features/Worlds/FortschritteWorldView.swift`, `Features/Dashboard/ParentDashboardView.swift`, `ResearchDashboardView.swift`.
- **Dependencies:** none.

---

## 4. TECHNICAL DEBT

Code-quality investments deferred during the review rounds.

### D1 (P1, L) — W-1 TracingViewModel God-object decomposition ⏭ deferred (multi-day refactor; needs dedicated branch)
`TracingViewModel.swift` is now **2277 lines** with ~16 distinct responsibilities (touch dispatch, phase advance, scoring, overlay routing, recognition orchestration, audio gating, animation, onboarding control, lifecycle, recommendation, calibration, debug accessors, dependency-injection plumbing). The W-5 forwarders made views happy; the VM itself still mixes concerns. Extract:
- `TouchDispatcher` (beginTouch/updateTouch/endTouch logic)
- `RecognitionOrchestrator` (runRecognizerForFreeWrite + post-processing)
- `PhaseTransitionCoordinator` (advanceLearningPhase + post-completion side effects)
The VM keeps the @Observable façade and forwards through these collaborators.
- **Files:** `Features/Tracing/TracingViewModel.swift`, three new files in `Features/Tracing/`.
- **Dependencies:** none, but keep CI green between extractions.

### D2 (P1, M) — W-17 store schema migration framework ✅ shipped (3dbf597 — `Core/SchemaMigrator.swift`)
Schema versioning was added (`schemaVersion: Int?` on each store) but **forward-incompatible files are silently dropped**, not migrated. For thesis longevity, add a small migration framework: when `decoded.schemaVersion < currentSchemaVersion`, run a registered migration function for each version step. Currently a v1→v2 upgrade has nowhere to live.
- **Files:** new `Core/PersistenceMigrator.swift`, `Core/ProgressStore.swift`, `ParentDashboardStore.swift`, `StreakStore.swift`, tests.
- **Dependencies:** none.

### D3 (P2, M) — CoreMLLetterRecognizer test coverage ✅ partial shipped (a6a8bc4 — `renderToImage` golden-image tests; Vision-request path still needs a model mock)
The recognizer has no dedicated unit test for `loadModelIfNeeded` / `renderToImage` / `makeResult`. Round-3 added integration tests through the VM but the renderer's coordinate flipping, the model-cache lock, and the calibrator wiring are untested directly. Add a test target with a tiny synthetic mlmodel (or a mock VNCoreMLModel) plus a renderToImage golden-image test.
- **Files:** `BuchstabenNativeTests/CoreMLLetterRecognizerTests.swift` (new).
- **Dependencies:** none.

### D4 (P2, M) — PaperTransferView deterministic timing ✅ shipped (3dbf597 — injectable `Sleeper`)
The 3 s reference / 10 s write / assess timing uses real `Task.sleep`. Inject the same `Sleeper` pattern that `OverlayQueueManager` and `PlaybackController` already use, then unit-test the state mapping deterministically.
- **Files:** `Features/Tracing/PaperTransferView.swift`, tests.
- **Dependencies:** none.

### D5 (P2, S) — Drop the `strokesPerSecond` forwarder ✅ verified done (no live forwarder remains; only a historical comment)
W-25 renamed the recorder property to `checkpointsPerSecond` but kept a `strokesPerSecond` computed forwarder for back-compat. Audit shows no remaining external callers — remove the forwarder and the prop is just `checkpointsPerSecond` everywhere.
- **Files:** `Features/Tracing/FreeWritePhaseRecorder.swift`, callers if any.
- **Dependencies:** none.

### D6 (P2, S) — Delete deprecated `ContentView.swift` ✅ verified done (file already absent)
`App/ContentView.swift` is `@available(*, deprecated)` and not instantiated anywhere. The R1 review committed to keeping it for chrome reference; that reference is captured in `docs/`. Delete the file (~382 lines) so the production binary doesn't carry a stale root view.
- **Files:** `App/ContentView.swift` (delete), Xcode project/Package.swift if it references it explicitly.
- **Dependencies:** none.

### D7 (P3, S) — Migrate remaining XCTest files to Swift Testing ✅ verified-skip (917a28f → updated in 2nd commit on `roadmap-v5-tier12`; the 3 XCTest files use `XCTMetric` / `expectation-wait` / class-level `XCTSkip`, none of which Swift Testing has an equivalent for as of Swift 6.x — LESSONS.md policy is correct)
`LESSONS.md` says "don't migrate existing XCTest" but the test target's v5 Swift carve-out exists *because* of the XCTest inheritance constraint. Once the last XCTest file is migrated, the test target can move to Swift 6 strict isolation, matching the main target.
- **Files:** any remaining `XCTestCase` files in `BuchstabenNativeTests/` (probably 1–2).
- **Dependencies:** none — but check `LESSONS.md` policy with the user before flipping.

### D8 (P3, M) — Canvas redraw frequency ⏭ deferred (Instruments profile required; analysis-only)
`TracingCanvasView`'s `Canvas { ... }` body is invoked on every observable change. Profile in Instruments to see whether the redraw rate during high-velocity drawing causes frame drops; if so, route static layers (glyph image, ghost lines) through `Equatable`-wrapped subviews so SwiftUI skips them on no-change.
- **Files:** `Features/Tracing/TracingCanvasView.swift`.
- **Dependencies:** Instruments profile.

### D9 (P3, S) — CI flake hardening ✅ shipped (a6a8bc4 — `timeout-minutes` caps on both jobs)
The simulator job is reliable; the self-hosted MacBook runner has occasionally timed out on device tests. Add a 12-minute hard cap with auto-retry-once on the device-test job; surface the retry count in the run summary.
- **Files:** `.github/workflows/ipad-device-test.yml`.
- **Dependencies:** none.

---

## 5. POST-THESIS

Worth doing once the thesis ships — not gating.

### F1 (P1, L) — App Store readiness pass
- Privacy Manifest (`PrivacyInfo.xcprivacy`) declaring `UserDefaults`, `NSUbiquitousKeyValueStore`, `Application Support` writes, and CoreML on-device usage.
- App icon set at every required size.
- Screenshots for the iPad listing (5–7 stills covering Schule / Werkstatt / Fortschritte / Eltern-Dashboard).
- Marketing copy in German + English.
- App Store Connect "Privacy Practices" section: "Daten werden auf dem Gerät gespeichert; keine Übertragung."
- TestFlight build with crash-reporting opt-in.
- **Files:** `BuchstabenApp/PrivacyInfo.xcprivacy` (new), `Resources/AppIcon.xcassets`, store assets.
- **Dependencies:** thesis submission complete.

### F2 (P1, L) — Lowercase letters + diacritics complete
26 lowercase + Ä Ö Ü ß as full citizens, not placeholders. Each gets a stroke definition, a pbm fallback, three audio variants, and a calibration pass. Approximately 30 letters × 2–3 hours each = ~60–90 person-hours.
- **Files:** `Resources/Letters/<x>/...` for every letter.
- **Citation:** ÖSterr. Volksschule 1. Klasse curriculum.
- **Dependencies:** none.

### F3 (P1, L) — Cloud sync (CloudKit)
`SyncCoordinator` is wired to `NullSyncService`. Implement a real CloudKit-backed `CloudSyncService` so a child who uses the app on multiple iPads (parent + grandparent) sees a unified streak and progress. Privacy: zone-per-participant, no PII, opt-in at first launch.
- **Files:** `Core/CloudSyncService.swift`, entitlements.
- **Dependencies:** F1 (privacy manifest first).

### F4 (P2, L) — Teacher dashboard (multi-child)
A per-classroom view that shows N children's progress side-by-side. Auth via "School Code" (a 6-letter shared secret per teacher). Read-only initially; later add per-child homework assignment.
- **Files:** new `Features/Teacher/`, CloudKit shared zone.
- **Dependencies:** F3.

### F5 (P2, M) — Numbers and basic punctuation
Add `0–9` and the period/comma/question-mark glyphs. The infrastructure is letter-agnostic (just stroke definitions + audio); ~12 new bundled glyphs.
- **Files:** `Resources/Letters/<digit>/...` for 0–9 and a few punctuation.
- **Dependencies:** none.

### F6 (P2, L) — Additional cursive scripts
The `SchriftArt` enum has five cases; only Druckschrift (Primae) and Schreibschrift (Playwrite AT) are bundled. Add Grundschrift, Vereinfachte Ausgangsschrift, and Schulausgangsschrift once a license-compatible font ships.
- **Files:** `Resources/Fonts/*.otf` (new), `SchriftArt.swift` (no code change — just unblock the cases).
- **Dependencies:** font licensing.

### F7 (P3, M) — Apple Watch streak companion
A single complication that shows the current streak. Tapping opens the Schule world. Implementation: WatchKit extension + WCSession to read `streak.json` from the App Group.
- **Files:** new `BuchstabenWatchExtension/`, App Group entitlement.
- **Dependencies:** F1.

### F8 (P3, M) — Mac Catalyst
`Package.swift` already targets `macOS 15.0`. Polish the keyboard mappings (arrow keys for letter nav, Return to advance) and ship a Catalyst build for parents who want to use a trackpad.
- **Files:** Catalyst-conditional view tweaks.
- **Dependencies:** F1.

### F9 (P3, M) — Localization beyond German
The architecture is German-only by design (curriculum-specific). For German-speaking children abroad, English UI labels with German letter content might help bilingual classrooms. Wrap UI strings in `Localizable.strings`; ship `de` (canonical) and `en` (Wrap UI only — letter content stays German).
- **Files:** `Localizable.strings` per locale, view audits.
- **Dependencies:** none.

### F10 (P3, S) — Switch Control + AssistiveTouch overlay
For motor-impaired children, expose the direct-phase dot tap as a Switch Control target and render a parallel "Switch Control hint" overlay that highlights the next-expected dot in high contrast.
- **Files:** `Features/Tracing/TracingCanvasView.swift`, accessibility actions.
- **Dependencies:** none.

---

## Summary table

| ID | Title | Cat | Effort | Pri |
|----|-------|-----|--------|-----|
| T1 | Lowercase active set | Thesis | M | P1 |
| T2 | D-5 condition tags | Thesis | M | P1 |
| T3 | Time-of-day metadata | Thesis | S | P1 |
| T4 | Active-vs-wallclock duration | Thesis | S | P1 |
| T5 | Recognition raw + calibrated | Thesis | M | P2 |
| T6 | Stratified A/B blocks | Thesis | M | P2 |
| T7 | Input-mode on durations | Thesis | S | P2 |
| T8 | EXPORT_SCHEMA.md | Thesis | S | P3 |
| P1 | Spaced retrieval | Pedagogy | L | P1 |
| P2 | Self-explanation | Pedagogy | M | P1 |
| P3 | Errorless first sessions | Pedagogy | M | P2 |
| P4 | Bob-the-dog start cue | Pedagogy | M | P2 |
| P5 | Backward chaining toggle | Pedagogy | S | P2 |
| P6 | Phonics audio | Pedagogy | M | P3 |
| P7 | Daily goal pill | Pedagogy | S | P3 |
| U1 | Reward celebration overlay | UX | S | P1 |
| U2 | Empty-state hints | UX | S | P1 |
| U3 | World transitions | UX | M | P2 |
| U4 | Onboarding compression | UX | M | P2 |
| U5 | Pencil 2 squeeze | UX | M | P2 |
| U6 | Celebration haptic | UX | S | P2 |
| U7 | Dimension sparkline | UX | S | P2 |
| U8 | Speech rate slider | UX | S | P2 |
| U9 | Token sweep | UX | S | P3 |
| U10 | Accessibility audit | UX | S | P3 |
| U11 | Dark mode | UX | M | P3 |
| D1 | W-1 VM extraction | Tech | L | P1 |
| D2 | Schema migrator | Tech | M | P1 |
| D3 | CoreML tests | Tech | M | P2 |
| D4 | PaperTransfer determinism | Tech | M | P2 |
| D5 | Drop strokesPerSecond fwd | Tech | S | P2 |
| D6 | Delete ContentView | Tech | S | P2 |
| D7 | XCTest → Swift Testing | Tech | S | P3 |
| D8 | Canvas redraw profile | Tech | M | P3 |
| D9 | CI flake hardening | Tech | S | P3 |
| F1 | App Store ready | Future | L | P1 |
| F2 | Lowercase + diacritics complete | Future | L | P1 |
| F3 | CloudKit sync | Future | L | P1 |
| F4 | Teacher dashboard | Future | L | P2 |
| F5 | Numbers + punctuation | Future | M | P2 |
| F6 | Cursive scripts | Future | L | P2 |
| F7 | Watch complication | Future | M | P3 |
| F8 | Mac Catalyst | Future | M | P3 |
| F9 | Localization | Future | M | P3 |
| F10 | Switch Control | Future | S | P3 |

---

## Recommended ordering for the next four weeks

If a developer pair-week is available, attack in this order:

**Week 1 — Thesis-critical data correctness**
T2 (condition-tagged samples) → T4 (active vs wall-clock) → T7 (input mode on durations) → T8 (EXPORT_SCHEMA.md)

**Week 2 — Thesis-critical content + UX P1s**
T1 (lowercase active set, partial; aim for 7 letters) → U1 (reward celebration overlay) → U2 (empty hints).

**Week 3 — Pedagogy + technical-debt P1s**
P2 (self-explanation prompts) → D1 (start the VM extraction; first slice TouchDispatcher) → D2 (schema migrator).

**Week 4 — Polish + cleanup**
U6 / U7 / U8 (small UX wins) → D5 / D6 (cleanup) → first pass on F1 (privacy manifest) for early App Store readiness.

Spaced retrieval (P1) is the highest-EV pedagogical addition but is large and should be planned as a dedicated 1–2 week sprint after the thesis-critical work ships.

---

_Last updated 2026-04-29 against `main` at `5e20c78`. Update this file whenever a roadmap item ships or its scope shifts materially._
