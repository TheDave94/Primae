# Code Review & Improvement Proposals

A 6-agent council reviewed the codebase in parallel:

1. **TracingViewModel + crash + concurrency**
2. **Scoring + recognition correctness**
3. **Persistence + data integrity**
4. **UI + accessibility + German text**
5. **Performance, memory, redraw**
6. **Tests + dead code + invariants**

This document synthesises their findings. Severity legend:

- 🔴 **Must fix** — crashes, data loss, wrong thesis data, child-facing
  UX violation
- 🟡 **Should fix** — user-facing quality issue, potential perf
  regression, missing test coverage on a thesis-critical path
- 🟢 **Nice to have** — code-quality cleanup, micro-optimisation,
  documentation polish

A second commit (after this doc lands) applies every 🔴 fix.

---

## Summary table — all findings sorted by severity

| # | Sev | Area | Finding | File:Line |
|--:|:--:|------|---------|-----------|
| 1 | 🔴 | Persistence | `"ß".uppercased()` returns `"SS"` — `ß` progress is keyed under `SS`, colliding with the (non-existent) capital ß and breaking per-letter analytics for the only German letter that doesn't round-trip through `.uppercased()`. | `ProgressStore.swift:159, 167, 188, 197, 227, 235`; `StreakStore.swift:105` |
| 2 | 🔴 | Child UI | `ProgressPill` shows `"Fortschritt 47%"` to children. Thesis spec mandates verbal/visual feedback only — no percentages. | `TracingCanvasView.swift:382` |
| 3 | 🔴 | Accessibility | World-switch animation in `MainAppView` is not gated on `accessibilityReduceMotion`. | `MainAppView.swift:85` |
| 4 | 🔴 | Accessibility | Direct-phase dot pulse animation ignores `accessibilityReduceMotion`. | `TracingCanvasView.swift:429, 457` |
| 5 | 🔴 | Logic | `StrokeTracker.isComplete` returns `true` when `definition.strokes.isEmpty == true` (vacuous truth). Currently masked by a guard in `TracingViewModel:942`, but the API itself is wrong. | `StrokeTracker.swift:29-32` |
| 6 | 🟡 | Recognition | Confusable list omits the `I/l/i` triad — a notorious first-grade handwriting confusion in German. | `ConfidenceCalibrator.swift:77-80` |
| 7 | 🟡 | Persistence | `phaseSessionRecords` and `completionDates` arrays are unbounded — long-running thesis devices accumulate thousands of entries. | `ParentDashboardStore.swift:101`; `ProgressStore.swift:108` |
| 8 | 🟡 | Performance | `TracingCanvasView` body reads ~11 reactive `vm` properties; any one mutation invalidates the whole canvas. During a touch event (`activePath`, `pencilPressure`, `progress` all mutating at ~100 Hz), this is heavy. | `TracingCanvasView.swift:10-219` |
| 9 | 🟡 | Performance | `ParentDashboardStore.recordPhaseSession()` `persist()`s synchronously on every phase row — ~20 disk writes per typical 4-letter session. | `ParentDashboardStore.swift:312-324` |
| 10 | 🟡 | Performance | `JSONEncoder().encode(store)` runs on the main actor before the detached write task. Encoding is small (~8 KB after 10 sessions), <5 ms — but still on main. | `ProgressStore.swift:289`; `ParentDashboardStore.swift:347` |
| 11 | 🟡 | Performance | `PrimaeLetterRenderer` image cache key is `(letter, width, height)` — missing `schriftArt`. A font swap across the cache window can serve stale glyphs. (Mitigated by `clearCache()` on schriftArt change, but the key itself is a footgun.) | `PrimaeLetterRenderer.swift` (CacheKey struct) |
| 12 | 🟡 | TracingViewModel | `runRecognizerForFreeWrite` and `recognizeFreeformLetter` set `isRecognizing = true` synchronously, then the late-completing Task can write to a freshly-cleared FreeformController if the user advanced letters mid-recognition. Not a crash (writes target the live controller), but UI state can briefly stick. | `TracingViewModel.swift:1166, 1865` |
| 13 | 🟡 | Concurrency | `Task` in `enterFreeformMode` (model-availability probe) lacks idempotency — rapid double calls spawn two probes. | `TracingViewModel.swift:1762-1768` |
| 14 | 🟡 | UI | Fixed-size fonts (`.font(.system(size: 30))`, `.font(.system(size: 34))`) on child-facing letter glyphs ignore Dynamic Type. Children with low-vision needs can't enlarge them. | `LetterWheelPicker.swift:66`; `FreeformWritingView.swift:181` |
| 15 | 🟡 | Tests | Multiple new components have **zero** tests: `FreeWritePhaseRecorder.assess()`, `OverlayQueueManager.enqueueBeforeCelebration`, `FreeformController.clearBuffers()`, `enablePaperTransfer` end-to-end wiring, `PaperTransferView` button→score mapping. | `BuchstabenNativeTests/` |
| 16 | 🟡 | Tests | 10+ tests use real `Task.sleep` (150 ms – 1.2 s) instead of injected sleepers — flakiness risk on slow runners. | `EndToEndTracingSessionTests.swift`, `AccessibilityContractTests.swift`, `AnimationGuideControllerTests.swift`, `TransientMessagePresenterTests.swift` |
| 17 | 🟢 | TracingViewModel | `updateTouch` is ~159 lines and orchestrates: canvas resync, velocity smoothing, normalisation, tracker update, freeWrite recording, haptics, audio panning, cell advancement, completion. Readable but a candidate for splitting into `dispatchTouch` + `updateAudio` + `updateProgress`. | `TracingViewModel.swift:818-979` |
| 18 | 🟢 | TracingViewModel | `runRecognizerForFreeWrite` and `recognizeFreeformLetter` share ~70% of their structure — could extract a `_runRecogniser(points:size:expected:onResult:)` helper. | `TracingViewModel.swift:1162, 1861` |
| 19 | 🟢 | Scheduler | `LetterScheduler` priority ties resolve in input-array order (Swift's stable sort) — undocumented. A test or comment naming this would prevent future surprise. | `LetterScheduler.swift:62-65` |
| 20 | 🟢 | Performance | `GridLayoutCalculator.cellFrames(...)` is a pure function with zero caching, called per Canvas redraw. A 2-entry `(canvasSize, preset) → [CGRect]` cache would eliminate redundant computation. | `GridLayoutCalculator.swift` |
| 21 | 🟢 | Cleanup | `LetterGuideGeometry` + `LetterGuideRenderer` are referenced only by `LetterGuideRendererTests` / `LetterGuideSnapshotTests` / one assertion in `BuchstabenNativeTests`. Production code does not use them. Can be removed once those tests are replaced or the geometry helpers are wired into a calibration helper. | `Features/Tracing/LetterGuideGeometry.swift`, `LetterGuideRenderer.swift` |
| 22 | 🟢 | Cleanup | `CloudSyncService` / `NullSyncService` / `SyncCoordinator` is wired into `TracingDependencies` and `TracingViewModel`, but the only call (`syncCoordinator.pushAll()`) goes to the `NullSyncService` and silently no-ops. Either implement CloudKit or document the dormant scaffolding explicitly. | `Core/CloudSyncService.swift` |
| 23 | 🟢 | Tests | `StubLetterRecognizer.alwaysReturn(predicted:confidence:isCorrect:)` accepts an `isCorrect` parameter that callers must set truthfully — no auto-validation that `isCorrect == (predicted == expected)`. | `LetterRecognizer.swift` (StubLetterRecognizer) |

**Counts:** 5 🔴, 11 🟡, 7 🟢.

---

## 🔴 Critical findings — exact fixes

### #1 — `"ß"` key collision (data integrity, German-app footgun)

**What's wrong.** `"ß".uppercased()` in Swift returns `"SS"` (canonical
Unicode rule, German ß has no historical capital form). Every store
that keys per-letter progress by `letter.uppercased()` therefore stores
the eszett's data under `"SS"`, where it collides with **nothing else**
today (no SS letter) — but the per-letter dashboard query
`progress(for: "ß")` then looks under `"ß"` and finds nothing.

The dashboard already lists `"ß"` in `StreakStore`'s
`allLettersComplete` reward set (line 117), so the streak system
expects the letter; but `recordSession` immediately mangles it before
storing.

**Fix.** Add a private helper that special-cases `"ß"`. Apply it at
every `letter.uppercased()` site that's used as a dictionary key.

In `BuchstabenNative/Core/ProgressStore.swift`, add:

```swift
/// Canonical key used by progress dictionaries. `letter.uppercased()`
/// would collapse the German `ß` to `SS` (Unicode canonical rule),
/// destroying per-letter analytics for that letter. Special-case `ß`
/// to preserve its identity; everything else uppercases as before.
private static func canonicalKey(_ letter: String) -> String {
    letter == "ß" ? "ß" : letter.uppercased()
}
```

…and replace all six `letter.uppercased()` call sites in
`ProgressStore.swift` (lines 159, 167, 188, 197, 227, 235) with
`Self.canonicalKey(letter)`.

In `BuchstabenNative/Core/StreakStore.swift`, replace line 105:

```swift
// before
lettersCompleted.forEach { state.completedLetters.insert($0.uppercased()) }
// after
lettersCompleted.forEach { state.completedLetters.insert($0 == "ß" ? "ß" : $0.uppercased()) }
```

### #2 — Child sees a percentage progress pill

**What's wrong.** `TracingCanvasView.swift:382`:

```swift
Text("Fortschritt \(Int(max(0, min(1, progress)) * 100))%")
```

Children at 5–6 don't read percentages and shouldn't see numeric
metrics — every other child-facing surface is verbal/visual only.

**Fix.** Replace the percentage with a verbal-only progress pill
(filled-bar + colour, no number). Wrap the existing struct so DEBUG
builds still get the numeric readout for engineering.

In `BuchstabenNative/Features/Tracing/TracingCanvasView.swift`, replace
the `ProgressPill.body` (~lines 379-394):

```swift
private struct ProgressPill: View {
    let progress: CGFloat
    let differentiateWithoutColor: Bool

    var body: some View {
        let p = max(0, min(1, progress))
        let tint: Color = p >= 0.99 ? .green : (p >= 0.5 ? .yellow : .blue)
        return HStack(spacing: 6) {
            Capsule()
                .fill(Color.gray.opacity(0.15))
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule().fill(tint).frame(width: geo.size.width * p)
                    }
                }
                .frame(width: 80, height: 8)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .stroke((differentiateWithoutColor ? Color.blue : tint).opacity(0.5), lineWidth: 1)
        )
        .accessibilityHidden(true)   // status communicated by ChildSpeechLibrary
    }
}
```

### #3 — World-switch animation ignores `accessibilityReduceMotion`

**What's wrong.** `MainAppView.swift:85`:

```swift
.animation(.easeInOut(duration: 0.3), value: activeWorld)
```

Users with motion sensitivity see a slide that the rest of the app
respects via `@Environment(\.accessibilityReduceMotion)`.

**Fix.** Read `reduceMotion` and gate the animation:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
…
.animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: activeWorld)
```

### #4 — Direct-phase dot pulse ignores reduceMotion

**What's wrong.** `TracingCanvasView.swift:429-431, 456-457`:

```swift
withAnimation(.easeInOut(duration: 0.25).repeatCount(3, autoreverses: true)) {
    pulseToggle = true
}
…
.scaleEffect(isNext && pulseToggle ? 1.3 : 1.0)
.animation(.spring(response: 0.25, dampingFraction: 0.5), value: pulseToggle)
```

**Fix.** Capture `accessibilityReduceMotion` in the
`DirectPhaseDotsOverlay` and gate both animations:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
…
.onChange(of: vm.directPulsingDot) { _, isPulsing in
    guard isPulsing, !reduceMotion else { pulseToggle = false; return }
    withAnimation(.easeInOut(duration: 0.25).repeatCount(3, autoreverses: true)) {
        pulseToggle = true
    }
    Task {
        try? await Task.sleep(for: .milliseconds(800))
        pulseToggle = false
    }
}
…
.scaleEffect(isNext && pulseToggle ? 1.3 : 1.0)
.animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.5), value: pulseToggle)
```

### #5 — `StrokeTracker.isComplete` reports completion on empty strokes

**What's wrong.** `StrokeTracker.swift:29-32`:

```swift
var isComplete: Bool {
    guard let definition else { return false }
    return progress.count == definition.strokes.count && progress.allSatisfy(\.complete)
}
```

When `definition.strokes.isEmpty`, `progress.count == 0` and
`[].allSatisfy(...)` is vacuously `true`, so the tracker reports
"complete" without any user input. `TracingViewModel:942` guards the
caller, but the API itself is misleading.

**Fix.**

```swift
var isComplete: Bool {
    guard let definition, !definition.strokes.isEmpty else { return false }
    return progress.count == definition.strokes.count && progress.allSatisfy(\.complete)
}
```

After this, the `hasStrokes` guard at `TracingViewModel:942` becomes
redundant but harmless — leave it for defence in depth.

---

## 🟡 Should fix — what to change and why

### #6 — Add `I / l / i / 1` to confusable pairs

`ConfidenceCalibrator.swift:77-80` lists curve-shaped letters
(C/c, O/o, S/s, V/v, W/w, X/x, Z/z, P/p, U/u, K/k) but omits the
*vertical-line trio* I / l / i (and digit 1, which is out of the
model's class space but worth noting). For a German first-grader's
handwriting, I/l confusion is the most common error.

**Change.** Add `"I"`, `"i"`, `"l"` to `defaultConfusables`. (Lowercase
`"L"` is not in the alphabet; `"l"` is the lowercase form of capital
L.)

### #7 — Cap unbounded persistence arrays

`ParentDashboardStore.phaseSessionRecords` and
`ProgressStore.completionDates` accumulate one entry per session
forever. A 6-month thesis device records ~5,000 phase records and
~1,500 completion dates. JSON file growth is moderate but unnecessary.

**Change.** Add a rolling cap (e.g., 2,000 phase records, 1,000
completion dates) — the dashboard summaries already work off recent
windows.

### #8 — `TracingCanvasView` redraw granularity

The canvas reads ~11 properties from the VM. Every `pencilPressure`
mutation (≈100 Hz during a Pencil stroke) triggers a full canvas redraw
including ghost path + start dot construction.

**Change.** Either:
1. Wrap the Canvas in an `EquatableView` that compares only
   `(progress, activePath.count, animationGuidePoint, pencilPressure)`; or
2. Split the VM into a `CanvasRenderState` Observable with the four
   render-affecting properties only, and hand that to the Canvas.

Both are bigger refactors than the 🔴 fixes — flagged for a focused
follow-up.

### #9 — Batch `recordPhaseSession()` writes

A 4-letter session triggers up to 16 phase-record disk writes.
Coalescing them into one write per letter completion (4×) cuts I/O
significantly without changing the data shape.

### #10 — Move `JSONEncoder().encode()` off the main thread

```swift
pendingSave = Task.detached(priority: .utility) { [storeSnapshot = self.store] in
    await previous?.value
    guard !Task.isCancelled else { return }
    let data = try? JSONEncoder().encode(storeSnapshot)
    try? data?.write(to: url, options: .atomic)
}
```

…in `ProgressStore.save()` and `ParentDashboardStore.persist()`. Small
on-main work today (~5 ms after 10 sessions), but the principle is
right and pre-empts future bloat.

### #11 — Add `schriftArt` to `PrimaeLetterRenderer` cache key

The image cache currently keys on `(letter, width, height)`; the rect
cache (line 206 of the same file) already keys on
`(letter, width, height, schriftArt)`. Make the image cache match.

### #12 — Idempotent recognition state writes

In `runRecognizerForFreeWrite` (line 1166) and
`recognizeFreeformLetter` (line 1865), capture a stable token:

```swift
let token = UUID()
self.activeRecognitionToken = token
freeform.isRecognizing = true
Task { … 
    await MainActor.run {
        guard self.activeRecognitionToken == token else { return }
        self.freeform.isRecognizing = false
        …
    }
}
```

…so a late completion can't write to state cleared by an intervening
letter change.

### #13 — Idempotent model-availability probe

`enterFreeformMode` already gates with
`if isRecognitionModelAvailable == nil`, but a rapid double-tap can
spawn two probes. Add a `private var isProbingModel = false` flag that
the probe sets/clears.

### #14 — Replace fixed `.font(.system(size:))` on child glyphs

For example `LetterWheelPicker.swift:66` and
`FreeformWritingView.swift:181` use `.font(.system(size: 30/34))`.
Replace with `.font(.system(.title, design: .rounded).weight(.bold))`
so Dynamic Type still scales them.

### #15 — Add tests for the new components

Each of these should get a focused `@Test` suite (each <100 lines):

* `FreeWritePhaseRecorderTests` — `record(...)` / `assess(...)` /
  `clearAll()` round-trip with synthetic timestamps + forces.
* `OverlayQueueManagerTests` — `enqueueBeforeCelebration` slots in
  front of `.celebration` regardless of order; modal overlays don't
  auto-advance.
* `FreeformControllerTests` — `clearBuffers()` resets every field; the
  pendingRecognitionTask is cancelled.
* `TracingViewModelPaperTransferTests` — toggling
  `enablePaperTransfer` and finishing a freeWrite trial enqueues
  `.paperTransfer` exactly once.
* `PaperTransferViewTests` — three `assessButton` invocations call
  `onComplete` with `0.0 / 0.5 / 1.0` respectively.

### #16 — Replace real `Task.sleep` with injected sleepers

The pattern `sleep: { _ in }` already exists for `PlaybackController`
and `TransientMessagePresenter`. Apply the same to
`AnimationGuideController` and the timing-dependent end-to-end tests.

---

## 🟢 Nice to have — brief description

* **#17** — Split `updateTouch` (~159 lines in `TracingViewModel`) into
  `dispatchTouch` + `updateAudioBus` + `progressBookkeeping`.
* **#18** — Extract the recogniser-runner duplication into a private
  helper.
* **#19** — Document `LetterScheduler` tie-breaker (input-array order via
  Swift's stable sort) with a comment + targeted test.
* **#20** — Cache `GridLayoutCalculator.cellFrames(...)` per
  `(canvasSize, preset)`.
* **#21** — Decide on `LetterGuideGeometry` / `LetterGuideRenderer`:
  delete or wire into `StrokeCalibrationOverlay` so they're not
  test-only weight in the production binary.
* **#22** — Either implement `CloudSyncService.CloudKitSyncService` or
  document the dormancy explicitly in `Core/CloudSyncService.swift`'s
  file header.
* **#23** — Add an internal assertion to
  `StubLetterRecognizer.alwaysReturn` that `isCorrect == (predicted ==
  expected)` when `expected` is supplied to `recognize`.

---

## What lands in the second commit

Every 🔴 above (1–5) gets applied directly. Plus the 🟡 quick wins
that are one-liners and don't need a separate review:

- **#6**: Add `I / i / l` to the confusable set.

Larger 🟡 items (overlay-queue tests, redraw splitting, encoder
off-main, write batching, idempotent recognition tokens, font scaling)
are deliberately deferred — each is a focused change that benefits
from its own commit and CI run.

The 🟢 entries are tracking items only.
