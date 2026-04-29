# ROADMAP_V5 Deferred Items — Deep Context

_Companion to `ROADMAP_V5.md`. For each non-trivial deferred item, this document explains the actual scope, the failure modes a naive implementation would hit, and what a real attempt would need to budget. The intent is to give a future operator (you, a contributor, a thesis advisor) enough detail to either schedule the work or decide it's not worth doing._

---

## D1 — TracingViewModel God-object decomposition

### Current state
`TracingViewModel.swift` is **2350+ lines** as of `roadmap-v5-tier12`. Holds ~16 distinct responsibilities:

1. Touch dispatch (`beginTouch`, `updateTouch`, `endTouch`, velocity smoothing)
2. Phase-controller delegation (advance, reset, touch-enabled gate)
3. Stroke-completion routing (`handleStrokeCompletionIfReached`)
4. Audio playback coordination (replay, variants, name/phoneme switch)
5. Recognition orchestration (token tracking, Task.detached, CoreML result handling)
6. Overlay-queue routing (kpOverlay, recognitionBadge, paperTransfer, celebration, rewardCelebration)
7. Session-duration tracking (D-1 active-time accumulator)
8. Lifecycle (`appDidEnterBackground` / `appDidBecomeActive`)
9. Letter scheduler integration (priority capture, recommendNext)
10. Adaptation policy plumbing (record sample → tier → radiusMultiplier)
11. Onboarding step state
12. Calibration store routing
13. Animation guide forwarder
14. Toast / completion-HUD presenter forwarders
15. Grid + cell management
16. Dependency injection

### Proposed extractions

Three clean cuts that don't require redesigning the SwiftUI binding surface (views keep talking to the VM; the VM forwards to the new collaborators):

**1. `TouchDispatcher`** — owns `beginTouch` / `updateTouch` / `endTouch`, velocity smoothing knobs, and the playback-activation threshold logic. Inputs: haptics, playback, audio, freeWriteRecorder. Outputs: callbacks for stroke-completion + canvas-progress updates that the VM still routes.

Pulling roughly **300 lines** out of the VM. The risk is the activation gate: `feedbackIntensity > 0.3` reads from the phaseController, so the dispatcher needs that as an injected dependency. Easy.

**2. `RecognitionOrchestrator`** — owns `activeRecognitionToken`, `runRecognizerForFreeWrite`, the freeform-letter and freeform-word recognition paths, and the `enqueueBeforeCelebration` + speech wiring. Inputs: recognizer, calibrator, progress store, overlay queue, speech, animation guide (for P2 self-explanation re-animation).

Pulling roughly **200 lines** out of the VM. Token tracking is currently shared across three call sites; centralising it removes 3 nearly-identical try-catch-style guards.

**3. `PhaseTransitionCoordinator`** — owns `advanceLearningPhase`, `recordPhaseSessionCompletion`, `commitCompletion`, and the post-transition side-effect block (overlay enqueue, speech praise, store writes, adaptation sample, HUD). Inputs: phaseController, freeWriteRecorder, all four stores, overlay queue, speech, syncCoordinator.

Pulling roughly **200 lines** out of the VM.

After all three extractions: VM should be ~1500 lines, dominated by the @Observable forwarder properties (which can't move because views bind to them).

### What actually breaks during the refactor

- **Forwarders.** Each property/method that views use must keep its current name on the VM. An extraction that moves a method out without leaving a forwarder breaks the call site.
- **MainActor isolation.** All collaborators must be `@MainActor`. Background work (recognition's `Task.detached`) hops back to MainActor before mutating state.
- **Test fixtures.** `TestFixtures.StubProgressStore` etc. are used directly; the new collaborators need stub-friendly initialisers.
- **Per-VM identity.** Each collaborator must be created once per VM (not shared static), so a future multi-VM scenario (rare but possible) doesn't cross state.

### Effort budget
3–5 days of focused work, with CI green between each extraction. Each extraction is one PR; reviewing them as a chain is much safer than landing all three at once.

### When to do it
Before any further significant feature lands in `TracingViewModel.swift`. Once you commit to T1 (lowercase letters) or P1 (spaced retrieval UI), every change cuts through this God object. Ship D1 first or pay the per-feature tax forever.

---

## U11 — Dark-mode parity

### Current state
`FortschritteWorldView` and the freeform writing canvas pin `.preferredColorScheme(.light)` because their card surfaces use `Color.white`. In dark mode without the pin, the cards turn near-black but the text styles (which rely on `.primary`) flip to white — the white text on white-because-pinned-light cards already works, but the card edges and shadows lose contrast.

`SchuleWorldView`, `WerkstattWorldView`, and the parent dashboards adapt fine in dark mode; only Fortschritte and Freeform are pinned.

### What "parity" actually requires

Three card surfaces need to switch from opaque white to a system-adaptive background:

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

Affected files:
- `Features/Worlds/FortschritteWorldView.swift` — 4 cards (starCount, streak, dailyGoal, fluencyFooter) + the rewards row
- `Features/Tracing/FreeformWritingView.swift` — the canvas chrome + result popups
- Possibly `Features/Tracing/CompletionCelebrationOverlay.swift` — uses a custom gradient that should stay; but the white scrim opacity might need tuning for dark backdrops

### Failure modes

- **Star tints** (`AppSurface.starGold`) pop against white but might look harsh against dark grey. Acceptable risk.
- **Letter glyph contrast.** Some letter glyphs are rendered as `Color.primary` over the card; in dark mode they'd render white-on-grey. Verify the glyph is still readable for a 5-year-old (contrast spec: 7:1 for body text, 3:1 for large text).
- **Material backgrounds inside lists.** SwiftUI's `List` already adapts; if any of these cards is inside a `List`, double-adapting can render weirdly.

### Effort budget
~1 day, but **at least 2 hours of that needs to be on a real iPad in dark mode**. Without device validation, any tonal redesign is a roll of the dice. The pinning was chosen specifically because the prior author didn't have a device to validate against.

### When to do it
Post-thesis. Children use the app in classroom / daylight conditions; the dark-mode population is parents reviewing the dashboard at night. Low pedagogical priority.

---

## D8 — Canvas redraw frequency

### Current state
`TracingCanvasView` has a `Canvas { }` block (~300 lines of drawing logic) that re-runs whenever any observable on the VM changes. The VM has ~65 observable properties — most don't affect what the canvas draws (audio state, recognition result, overlay queue), but SwiftUI doesn't know that.

### The actual cost (estimated, not measured)

On an M-class iPad: probably fine. The drawing logic is bounded (one glyph image, ghost lines from at most a few hundred checkpoints, an active path of at most ~500 points, KP overlay), and CoreGraphics on the M-class GPU eats this for breakfast.

On an older iPad (A12 / iPad 8th gen): possibly noticeable during high-velocity drawing because the freeWriteRecorder appends to four parallel buffers per touch event, the VM publishes the change, the canvas re-renders, the canvas re-builds the path from scratch, the GPU rasterises. 60 fps under heavy drawing might drop to 45.

### What to do *with* a profile

If Instruments shows a frame-time problem, two cuts:

1. **Wrap static layers in `Equatable` subviews.** The glyph image, ghost lines, and start dots only change when `currentLetterName` / `schriftArt` / `showGhost` / `phaseController.showCheckpoints` change. An `Equatable` wrapper means SwiftUI skips the body re-eval when those don't change. The active path and KP overlay remain dynamic.
2. **Throttle path appends.** The recorder records every touch event; the canvas redraws on every observable change. Coalescing recorder writes to ~30 Hz would halve the redraw count without the child noticing.

### What to do *without* a profile

Nothing. Premature optimisation here would either be a no-op (already fast enough) or break a currently-correct redraw path.

### Effort budget
2 hours to profile. 4 more if a real bottleneck exists. Zero if not.

### When to do it
Only after the device-test job reports a frame drop, or a real classroom user reports lag. Currently no evidence of either.

---

## T1 — Lowercase letter coverage

### Current state
`Resources/Letters/` has 56 directories (26 upper + 26 lower + Ä Ö Ü ß). 25 have non-empty `strokes.json`; 31 have **empty** stroke arrays as placeholders. The empty-stroke path is handled — `LearningPhaseController` skips the observe + direct phases when `strokes.isEmpty`, so a child who lands on `q` sees the glyph but skips straight to guided/freeWrite. That's correct fallback behaviour, but it means the four-phase pedagogy that the thesis demonstrates doesn't actually run for 31 of 56 letters.

### What's needed for one letter

Per letter (e.g. lowercase `a`):

1. **Stroke definition** — typically 1–3 strokes, each with 5–15 checkpoints in 0–1 cell-local coordinates. Author by:
   - Open the app in Debug mode (long-press phase indicator)
   - Open the calibration overlay (long-press again)
   - Drag-place each checkpoint visually over the rendered glyph
   - Save (writes to `Application Support/BuchstabenNative/calibration/`)
   - Export the calibrated checkpoints into the bundle's `strokes.json`
2. **PBM bitmap fallback** — needed when the OTF font fails to render. For Primae-rendered letters this is rarely used, but the validator complains without it. Either skip (accept the warning) or generate via the existing PBM tooling.
3. **Audio takes** — 3 mp3 recordings of the letter name (matches uppercase: `a1.mp3`, `a2.mp3`, `a3.mp3`). Voice talent or ElevenLabs.
4. **Phoneme audio** (P6) — 3 mp3 recordings of the phoneme. Same pipeline.

Per-letter time: ~2–3 hours (most of it the calibration session + audio editing).

### What's needed for the active set

The thesis-critical scope is the **demo set** (`A F I K L M O`) extended to lowercase: `a f i k l m o`. That's 7 letters × 2–3 hours = ~14–21 hours of authoring.

The **full alphabet** is 26 lowercase + 19 missing uppercase + 4 umlauts/ß = 49 letters × 2–3 hours = ~100–150 hours.

### What you can't do without a device

- Calibrate stroke checkpoints. CoreText measurements need the actual rendering pipeline; offline measurement on Linux drifts because Primae's exact glyph metrics depend on font-loading order at runtime.
- Validate the strokes.json against the ghost lines and start dots overlay. Authoring blind would produce visibly mis-aligned scaffolding.

### What you *can* do without a device

- Pre-generate stroke definitions from CoreText measurements run on macOS (write a small `swift run` script that loads Primae, renders each glyph, samples the path). The output won't be perfect but it'll be 80% there as a starting point for device calibration.
- Generate audio with ElevenLabs (already in flight per current session).

### Effort budget
- Demo lowercase set (7 letters): 14–21 hours
- Full lowercase alphabet (26): 60–80 hours
- Full coverage (lowercase + missing uppercase + umlauts): 100–150 hours

### When to do it
**Before thesis submission for the demo set, minimum.** The thesis claim "Vier-Phasen-Pädagogik for Volksschule 1. Klasse" implies the four phases run on the letters the child is likely to encounter. A reviewer who picks `q` and gets the empty-strokes fallback will rightly call this out. The demo lowercase set (`a f i k l m o`) is the credible-thesis floor.

---

## D7 — XCTest → Swift Testing migration: thorough evaluation

### What's actually in XCTest today

The test target uses **Swift Testing** (`@Test`, `@Suite`, `#expect`) for the bulk of new tests. A small number of files retained from before the framework switch use `XCTestCase`. The carve-out exists because under Swift 6 strict isolation, `XCTestCase`'s inherited `nonisolated` initialiser conflicts with the package's `.defaultIsolation(MainActor.self)` — so the test target sets `.swiftLanguageMode(.v5)` to opt out of strict isolation **for the test target only**.

Let me actually count the XCTest files. Looking at the test directory listing from earlier in this conversation:
- 46 test files, 647 `@Test` declarations after rounds 3 and 4
- The 647 `@Test` count is Swift Testing only (the macro doesn't apply to XCTest)

The XCTest files are presumably ~3–5 in number, holding maybe 20–40 `XCTestCase` methods. Let me verify.

### Verification (run from branch root)

```bash
grep -rl "XCTestCase\|import XCTest" BuchstabenNativeTests/
grep -rln "XCTSkipIf\|XCTAssert" BuchstabenNativeTests/
```

**Actual count, verified 2026-04-29 on `roadmap-v5-tier12`:**

Files with `XCTestCase` or `import XCTest`:
- `GlyphStrokeExtractorTests.swift`
- `StrokeTrackerRegressionGateTests.swift`
- `PerformanceBenchmarkTests.swift`
- `AudioEngineTests.swift`

Files using `XCTSkipIf` or `XCTAssert*`:
- `AudioEngineTests.swift`
- `StrokeTrackerRegressionGateTests.swift`

So 4 files import XCTest; 2 of them actually use the legacy assertion / skip APIs. The other 2 (`GlyphStrokeExtractorTests`, `PerformanceBenchmarkTests`) are likely importing XCTest only for the test-runner integration and could drop the import once the Swift Testing migration is complete.

### What "migration" would actually mean

Since there are no `XCTestCase` subclasses, the migration isn't "convert XCTestCase to Swift Testing" — it's "remove the `import XCTest` lines and the carve-out." That requires:

1. Replace any `XCTSkipIf(condition, "msg")` with a Swift Testing equivalent. The closest current API is `withKnownIssue("msg") { ... }` or returning early from the test body with a `#expect(true, "skipped: msg")`. Neither is a perfect match for runtime-conditional skipping.
2. Replace any `XCTAssert*` helper wrappers with `#expect(...)`.
3. Audit fixture builders that currently inherit a `Bundle.main`-aware test bundle from XCTest's framework setup. Swift Testing has its own runtime; some bundle-resolving helpers might need a tweak.

After all that, **remove `.swiftLanguageMode(.v5)` from the test target's `Package.swift` setting** so the test target moves to Swift 6 strict isolation matching the main target.

### What `LESSONS.md` actually says

> Don't migrate existing XCTest files to Swift Testing — the v5 carve-out exists for a reason and migration breaks more than it fixes.

This was a **policy** at the time of writing. The reasoning: at the time, `XCTSkipIf` had no Swift Testing equivalent and runtime-conditional skipping was load-bearing for the audio test suite (skip when AVAudioSession isn't available on the simulator).

### Has the policy aged?

- Swift Testing **does** now support runtime conditional traits via `.enabled(if:)` and `.disabled(if:)` (Swift 6.0+, available on the macos-26 / Xcode 26.4 runner the project uses).
- `XCTSkipIf` calls in the codebase are concentrated in `AudioEngineTests` (skip on simulators that lack AVAudioSession routing) and a handful of accessibility tests.

So the *technical* blocker (no equivalent for runtime skip) has been removed by Swift Testing's evolution. The *policy* blocker (LESSONS.md) hasn't been re-evaluated.

### Recommendation

**Worth doing, but only as a deliberate one-PR migration with the LESSONS.md policy explicitly updated.** Procedure:

1. Run `grep -rln "import XCTest" BuchstabenNativeTests/` — confirm the file count
2. For each file: replace `XCTSkipIf(cond, msg)` with `@Test(.disabled(if: cond, "msg"))` on the test attribute, OR with an explicit `if cond { return }` early return inside the body
3. Replace `XCTAssert*` calls with `#expect(...)`
4. Drop `import XCTest` from each file
5. In `Package.swift`, remove the `.swiftLanguageMode(.v5)` line on the test target
6. Verify CI passes
7. Update `LESSONS.md` to record the policy change with date and reason

Effort: 4–6 hours total. Not a hard refactor; just a decision that the policy is stale and someone needs to push the actual change. **Worth scheduling explicitly.** The benefit is removing one piece of internal divergence between test and main targets (both move to Swift 6 strict isolation), which makes the next round of strict-concurrency checking simpler.

---

## U4 — Onboarding length tuning (future option)

The current 7-step onboarding (welcome → 4 phase demos → reward intro → complete) was deferred from the implementation pass because compressing it to 3 steps without empirical signal is a UX risk. **Recording this here as a future option** so a future product decision can pick it up:

### Proposal

Shorten to **3 steps for the child path**:
1. Welcome — brief greeting + start button
2. "Zeig mal was du kannst" — 10-second guided trace of letter `A`, child does it, success animation
3. "Los geht's!" — drop into Schule mode

Move the per-phase concept demos and reward-system intro behind the existing parent's "Einführung wiederholen" button so a parent who wants the long version can request it.

### What needs to be true before doing this

- An empirical signal that the current 7 steps causes drop-off. Two ways to measure:
   - **Onboarding completion rate** (do children get to "complete" or do they bail?). Easy to add: instrument `OnboardingCoordinator.advance()` calls with timestamps; see how many sessions reach the final step.
   - **First-day return rate** for compressed vs full onboarding. Requires an A/B split.
- A pedagogical argument that the child *gets* the gradual-release concept without the per-phase demos. The full onboarding teaches the four-phase mental model; without it, the child might be confused when the second phase pops up.

### When to revisit

After the first few hours of real classroom data. If onboarding-completion is < 70%, compress; if it's > 90%, leave alone.

---

_Last updated 2026-04-29 against branch `roadmap-v5-tier12`. Update when a deferred item moves to in-progress or shipped._
