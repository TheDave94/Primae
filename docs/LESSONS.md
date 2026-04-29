# LESSONS.md — Code-level invariants

Hard-won invariants that catch regressions a typecheck won't. Read this
before touching `AudioEngine.swift`, `StrokeTracker.swift`, or the
`load(letter:)` path. (Earlier revisions of this file logged a
council-style automation pipeline's post-mortems; that pipeline is
gone, so only the invariants survived the trim.)

_Last audited 2026-04-29 against `main` after the ROADMAP_V5
implementation pass + tier-1/2 branch merge._

## Audio + tracking

### `AudioEngine.swift` is stable and fragile
- AVAudioSession + AVAudioEngine setup is intricate and full of
  syntactically-similar lines (catch blocks, optional casts, observer
  registrations). Many "fixes" that look right turn out to be no-ops
  that break compilation or runtime in subtle ways.
- Changes must be minimal and surgical. Never restructure init / deinit
  or rewrite catch blocks.
- The `deinit` uses `nonisolated deinit { Self.removeObservers(for: self) }`
  with a static observer dict keyed by `ObjectIdentifier` — this is the
  only Swift 6 pattern that keeps `@MainActor` isolation off the deinit
  path. Do not refactor it.
- If CI fails on AudioEngine syntax errors, **revert** rather than
  attempt further fixes; the file is bigger than it looks.

### Never replace `hypot()` with `distSq` in `StrokeTracker.update()`
```swift
let dist = hypot(dx, dy)   // KEEP THIS
```
Although squared distance is mathematically equivalent for the
threshold comparison, the change reliably breaks
`fastVelocity_triggersPlayAfterDebounce` and `fastTouch_triggersPlay`:
the fast-drag test path doesn't hit checkpoints under the squared
comparison because of the smoothing windows. This optimisation has
been tried and reverted twice — do not attempt again.

### `load(letter:)` must call audio synchronously
```swift
private func load(letter: LetterAsset) {
    // …
    audio.loadAudioFile(named: firstAudio, autoplay: false)   // SYNC
    playback.request(.idle, immediate: true)                  // SYNC
}
```
The function is already `@MainActor`. **Never** wrap these calls in
`Task { … }` or `Task { @MainActor in … }`. Doing so puts the audio
load behind the `updateTouch` debounce window, which resets playback
state and produces `playCount == 0` failures in
`TracingViewModelTests`.

### `showGhost` must reset on letter change
Every `nextLetter()` / `previousLetter()` / `randomLetter()` /
`loadLetter(name:)` / `loadRecommendedLetter()` path must reset
`showGhost = false`. The reset lives in `load(letter:)`; any new entry
point that bypasses `load(…)` needs its own reset.

## Concurrency (Swift 6)

### `@MainActor` on classes with `@Published`
The package uses `.defaultIsolation(MainActor.self)`, so most classes
are MainActor-implicitly. New classes that hold `@Published` properties
must remain MainActor — explicitly mark them or rely on the implicit
isolation. Forgetting causes Swift 6 strict-concurrency build failures.

### Bare `Task { }` is non-isolated
For `@MainActor`-isolated classes, a direct call from another
`@MainActor` context is already safe — do not wrap in `Task { @MainActor in }`.
Adding a Task wrapper causes ordering issues with debounce timers.
Reserve `Task { @MainActor in }` for callbacks delivered from
genuinely non-isolated contexts (delegate callbacks, completion
handlers from background frameworks).

### `OSLog.Logger` has no `.shared` singleton
```swift
// WRONG — does not compile
Logger.shared.warning("…")

// RIGHT
private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BuchstabenNative",
    category: "Recogniser"
)
```
Plain `print()` is also acceptable for short-lived debug output. Do
not invent a `.shared` accessor.

## Testing conventions

### Do not mix `@Test` and `XCTestCase` in the same file
Existing test files written in **XCTest** stay XCTest. **Swift
Testing** (`@Test`, `@Suite`, `#expect`) is for new test files only.
Do not migrate existing XCTest suites. Mixing the two frameworks in
one file produces confusing test discovery behaviour in Xcode.

**Why the existing XCTest files can't be migrated** (verified
2026-04-29 in `docs/ROADMAP_V5_DEFERRED_NOTES.md` D7 section):

- `AudioEngineTests.swift` uses `throw XCTSkip(…)` in instance
  `setUp` to mark the suite as skipped (not failed) when AVAudioSession
  isn't routed on the simulator. Swift Testing's `.disabled(if:)`
  evaluates at attribute time, not at runtime — there's no clean
  equivalent for a runtime hardware-availability gate. Also uses
  `XCTestExpectation` + `wait(for:timeout:)` for NotificationCenter
  callback synchronisation; Swift Testing's `confirmation { }` has
  different semantics.
- `StrokeTrackerRegressionGateTests.swift` and
  `PerformanceBenchmarkTests.swift` use
  `measure(metrics: [XCTClockMetric, XCTCPUMetric, XCTMemoryMetric])`
  to set CI performance regression baselines. **Swift Testing has no
  `XCTMetric` equivalent as of Swift 6.x.** Re-implementing would
  drop the regression gate or require a hand-rolled benchmark harness.

The `.swiftLanguageMode(.v5)` carve-out on the test target
(`Package.swift:32`) exists because `XCTestCase`'s inherited
nonisolated init conflicts with the package's
`.defaultIsolation(MainActor.self)` under Swift 6 strict checking.
The carve-out is load-bearing as long as any XCTest file remains.

If a future Swift Testing release ships an `XCTMetric` equivalent,
revisit the perf files first, then `AudioEngineTests`. Until then
the policy holds.

### Tests must match actual implementation behaviour
When adding tests, first read the implementation to understand what it
actually does. Do not write tests that describe desired future
behaviour and assert against the current code — they will fail. Test
coverage tasks add tests that **pass** against current code; behaviour
changes need a separate commit.

## SwiftUI / Observation

### Use `@Observable`, not `ObservableObject` / `@Published`
The migration is complete: `grep -r "ObservableObject\|@Published"
BuchstabenNative/` returns zero matches (verified 2026-04-29).
**Do not regress** any new type back to the `ObservableObject` /
`@Published` shape — it would re-introduce isolation traps under
Swift 6 strict-concurrency checking. Every new observable type uses
`@MainActor @Observable final class`.

## Repo hygiene

### `.github/workflows/` modifications need explicit user approval
CI workflow files are infrastructure, not application code. Invalid
GitHub Actions syntax breaks every future run, so changes are
high-risk. **Modify only when the user has explicitly approved the
specific change.** Dependabot handles deprecation warnings.

Approved-and-applied changes for the record:
- `a6a8bc4` (D9 ROADMAP_V5): added `timeout-minutes: 20` /
  `25` caps on the simulator + device-test jobs so a hung
  `xcodebuild` can't sit at "in_progress" until GitHub's 6-hour
  default kills it.
- `1ac48be` (ROADMAP_V5 branch CI): added `roadmap-*` to the
  `branches:` filter on push + pull_request triggers so
  feature-roadmap branches get the same build + test treatment as
  main without manual `workflow_dispatch`.

Both were minimal, targeted, and validated by the next CI run. Future
modifications should follow the same shape: small, reviewable, and
the next CI run is the verification.

### `git revert` can truncate Swift files
`git revert --no-commit` of multiple commits that touched the same
file (notably `StrokeTracker.swift`) once left the file missing its
closing `}` class brace. Swift's quick-syntax check accepted it but
the build failed.
- After **any** revert, verify the affected file ends with `}` before
  pushing.
- Never chain multiple reverts on the same file in one
  `git revert --no-commit` call — split them.
