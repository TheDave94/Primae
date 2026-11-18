# R-084 — Task cancelled and re-allocated on every active touch sample

Lane: `lane/a11y-r084`, base `0eff852a`. Date 2026-11-18.
Verdict: **code fact CONFIRMED, stated harm REFUTED, no change made (deliberate).**

Every claim below carries its instrument. MEASURED = read off the code, a test
run, or the instrument named; REASONED = derived by argument only.

## 1. The shape (MEASURED, by reading base `0eff852a`)

- `PlaybackController.request(_:immediate:)` `:215` — on an immediate `.active`
  sample whose machine state is already `.active`, calls `armStallIdle()`.
- `PlaybackController.armStallIdle()` `:236-248` — `pendingTransition?.cancel()`
  then `pendingTransition = Task { … }`. One Task allocated and one cancelled
  per call. It is the ONLY caller of `armStallIdle` (grep: `:215` + definition).
- `TouchDispatcher.updateAdaptivePlayback` `:853` —
  `playback.request(shouldBeActive ? .active : .idle, immediate: shouldBeActive)`,
  i.e. `immediate == true` exactly when the sample is active, so every ACTIVE
  sample reaches `armStallIdle` once.
- `updateAdaptivePlayback` is called once per sample (`:388`, inside the
  per-sample move handler), and a sample is delivered per *coalesced* touch
  sample — `TracingCanvasView` pencil overlay `:1278`, finger overlay `:928`:
  `event?.coalescedTouches(for:)` then a loop.

Sample rate (MEASURED from the file's own comments, `TouchDispatcher:30`):
Pencil **240 Hz**, finger **120 Hz**, every coalesced sample delivered.

Arithmetic: **240 Task allocations + 240 cancels per second of active stroking**
(finger: 120/s). A 2 s stroke = 480. A study session — writing phases only
(guided + freeWrite), ~5 letters x ~3 strokes x ~2 s, Pencil = **~14 400 arms
per session** (ESTIMATE, stroke count assumed).

What the task waits on: `sleeper(.seconds(idleDebounceSeconds))`, i.e.
`Task.sleep` (`Core/Sleeper.swift:16`) for the child's **stall cutoff** —
`idleDebounceSeconds` defaults to `SoundEnvelope.stallSeconds` = 0.3 s and is
reassigned per pen-down to `StrokeTempo.stallSeconds` = clamp(0.3 x hold/0.8,
**0.3 … 0.6 s**) (`TouchDispatcher:139`, `StrokeContext:135-136`,
`TracingViewModel:5412`). It cancels the previous pending transition — during an
active stroke that is always the previous stall arm, the only task in flight.
On fire: `machine.transition(to: .idle)` -> `.stop` -> `audio.stop()` (0.4 s fade).

## 2. The stated harm ("can never fire") is FALSE (MEASURED)

A stopped pen delivers no further samples — that is the AE-2b premise the stall
exists for. So the LAST sample's arm is never cancelled and fires.

- `PlaybackControllerTests.immediateActive_armsStallIdle_thatStopsAStationaryPen`
  passed at base: `✔ Test … passed after 0.484 seconds` (log
  `r084-baseline-stall.log`).
- Mutation (arm removed at `:215`): **RED** with 5 issues, including
  `pendingTransition != nil`, `audio.stopCount == 1`.
  `Test run with 13 tests in 1 suite failed after 0.027 seconds with 5 issues.`
- Restored: `Test run with 13 tests in 1 suite passed after 0.030 seconds.`

The detector is load-bearing and it fires today.

## 3. The remaining cost (MEASURED with a standalone instrument)

Instrument: `r084_bench2.swift` in the session temp dir (not the repo) —
replicates the exact pattern (`@MainActor`, `Task { try? await Task.sleep }`,
cancel + reallocate), `swiftc -O`, 1200 arms.

- cancel + allocate, synchronous (what the sample handler pays): **0.44 µs/arm**
  (a second run: 0.72–0.77 µs/arm). At 240 Hz = **0.10–0.18 ms per second of
  stroke** = 0.01–0.02 % of one core.
- deferred cancellation (one executor resumption per arm): all 1200 cancelled
  tasks had exited inside a 500 ms single sleep. A MainActor `Task.yield()` in
  that same command-line process measured 13.4 µs, so the pessimistic bound is
  240 x 13.4 µs = **3.2 ms per second of stroke** (0.2 ms per 60 Hz frame). The
  tool's executor is not the app's run loop, so that bound is pessimistic.
- Whole session (the ~14 400-arm estimate above): **6–11 ms of main-thread
  time**, spread over 30 s of stroking.

No frame budget is threatened and no behaviour changes. Observable harm: none
demonstrated.

## 4. Why it was not "fixed" anyway

- **Shape A** (one watcher per touch session, per-sample update only moves a
  deadline, watcher sleeps the remaining time from a clock seam): preserves the
  cutoff exactly, one allocation per session — but the loop needs a clock seam,
  and under the existing instant test sleeper (`sleep: { _ in }`) the remaining
  time never reaches zero: a busy loop on the MainActor. REASONED, not measured.
- **Shape B** (keep the task; on wake, if a sample arrived, sleep the full delay
  again): terminates under every sleeper, but pushes quiet onset to 1x–2x the
  cutoff — 0.3–0.6 s becomes up to 1.2 s. That changes what "stall" means, and
  `stallSeconds` is exported in the protocol schema: **needs a ruling**, not a
  lane.
- Per-sample arming also has one benefit: `idleDebounceSeconds` is reassigned at
  every pen-down, so a changed cutoff takes effect on the next sample. A
  single-watcher design must re-read the delay each iteration.
- `PlaybackController.swift` is flagged FRAGILE and AE-2b is a ruling. Trading a
  ruling-adjacent semantic for 0.02 % of a core is the wrong trade.

## 5. Operational notes for the next lane in this worktree

- The shared DerivedData (`~/Library/Developer/Xcode/DerivedData/Primae-…`) is
  shared by every worktree: a concurrent lane's build made CodeSign fail here
  (`PrimaeNative_PrimaeNative.bundle: bundle format unrecognized`). Use a
  private `-derivedDataPath <worktree>/dd` (gitignored) and
  `CODE_SIGNING_ALLOWED=NO`.
- The simulator UDID is shared by all lanes. Three concurrent runs produced
  `Launching PrimaeNativeTests Finished with error: … (Mach error -308 …)` — a
  RED that ran zero tests. Wait for the sim to be clear, and read
  `Test run with N tests` before believing either colour.
