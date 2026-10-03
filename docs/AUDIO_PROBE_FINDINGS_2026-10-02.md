# Audio probe: what was MEASURED on 2026-10-02

Working notes from driving the `AudioSignalProbe` to a working device
measurement. Every claim here is measured, not inferred. Companion to
`CLAUDE.md`'s test-infrastructure section.

## 1. The crash: `SIGTRAP` on AVFAudio's realtime thread

Three device crashes, identical stack:

```
_dispatch_assert_queue_fail
  -> _swift_task_checkIsolatedSwift
    -> closure #1 in AudioSignalProbe.arm(on:)
      -> AVAudioNodeTap::TapMessage::RealtimeMessenger_Perform()
```

AVFAudio calls a tap closure on its **realtime** thread. Under
`.defaultIsolation(MainActor.self)` a closure literal written inside a
`@MainActor` method **inherits** `@MainActor`, so Swift's isolation
check traps the moment the audio thread calls it.

Two failed fixes before the right one, both worth remembering:

| Attempt | Change | Why it did not work |
|---|---|---|
| 1 | counters moved into a lock-backed box | the closure literal was **still lexically** inside `arm(on:)` |
| 2 | `nonisolated` on the factory only | `AudioSignalCounters.record` was *still* `@MainActor` — default isolation applies to plain classes too |

The rule: **what must be non-isolated is where the closure is FORMED,
not what it captures.** The counters type needs `nonisolated` as well,
and that layer surfaces as a **compile** error once the handler is
non-isolated — the cheap way to find it.

## 2. The mutation check found a test that could not fail

`AudioSignalProbeTests.handlerIsCallableFromTheRealtimeThread` is
load-bearing for the *handler*. It is **blind to the call site** —
proven by mutation: restoring the inline closure literal in `arm(on:)`
compiles cleanly and every test in the file still passes. There is no
compile-time diagnostic for it.

So the file also carries a **source-level** guard,
`tapIsNotInstalledWithAnInlineClosureLiteral`, which fails on exactly
that shape. Mutation-verified RED:

```
✘ "the tap is never installed with an inline closure literal"
  Expectation failed: !code.contains("installTap(...) {")
✘ Expectation failed: code.contains("block: handler")
```

The other five tests stayed green under mutation, so it fails for the
right reason.

## 3. `SilentAudio` swallows every measurement

`TracingViewModel.init` substitutes `SilentAudio()` for `audio` when
`armIsSilent` (ruling C3-2). `SilentAudio` **inherits the no-op
extension defaults**, so any probe call routed through the VM's `audio`
vanished without a word:

```swift
audio.emitAudioSignalSummary(label:) {}   // extension default
```

This is the worst possible failure shape — the silent arm is precisely
the arm whose output most needs asserting. The probe now routes to
`deps.audio` (the real engine) via a dedicated `audioSignalProbeSink`.
Read-only; playback behaviour untouched.

## 4. An empty log proves nothing on its own

Three device runs produced **no file at all**, which was only
consistent with `isArmedByLaunchArgument` being false — and every write
path was gated on it, so **the gate hid the evidence it was suspected
of**. `writeLineUnconditionally` now exists with no guard, and a
DEBUG-only unconditional dump of the real launch arguments settles
"never armed" vs "armed but never asked" in one run.

Lesson: when a diagnostic instrument reports nothing, suspect the
instrument's own guards first.

## 5. A phase that never ends has no boundary to report at

`emitAudioSignalSummary` fired only on phase transitions. A 16-second
observe phase never transitions, so the log stayed empty for the exact
phase the proctor was watching. Added a 2 s ticker
(`startAudioSignalTicker`), which also yields a **time series** rather
than one number per boundary — that is what makes "it went quiet halfway
through" visible.

Also: the ticker hung off `startGuideAnimation`, which is only reached
when **advancing into** observe. A session's *first* letter goes through
`load(letter:)`'s own observe branch, so the first letter had no
measurement at all. Both sites now start it.

## 6. The iPad's enrolled child draws the SILENT arm

MEASURED from the device's own preferences: participant
`F5A6440A-C8B0-43FB-9397-60CA060E23E6`, byte 15 = `0xE6` = 230,
230 % 3 = 2 -> `.silent`. So there was **correctly no sound to
measure**. A measurement run must pin a sound arm explicitly:

```swift
app.launchArguments += ["-de.flamingistan.primae.audioConditionOverride", "phoneme"]
```

`-key value` seeds `UserDefaults` from launch arguments, which is
exactly the key `ParticipantStore.audioConditionOverride` reads.

## 7. The measurement is now an ASSERTION

MEASURED on the physical iPad, phoneme arm:

```
AUDIO-SIGNAL observe nonSilent=16 total=19 peak=0.31476486
```

Four more device-only faults stood between that number and a test that
asserts it. All four produce the SAME symptom - no measurement - and each
looked like "the audio was silent":

| Fault | Why it looked like silence |
|---|---|
| `traceAudioSignalProbe` was **extension-only** | an extension member dispatches **statically**, so an `AudioControlling`-typed call hit the no-op default and never reached `AudioEngine`. The file already recorded this exact trap for `setSpatialPitch` |
| `AudioSignalProbe` was not `@Observable` | the value was set correctly; SwiftUI never re-rendered, so the readout never appeared |
| `.hidden()` on the readout | removes the a11y node as well as the view |
| the test polled only at the END | the loud windows are the EARLY ones, so a late poll reads the silence |

The file's own lesson applies with force: the protocol already said a
conformer's implementation is invisible behind an extension-only
declaration. Read it before adding the next member.

Two channels were tried and rejected for getting numbers to the test:
a shared file via the launch environment (the app's tmp is sandboxed
per-app and there is **no App Group** in this project), and a plain
`devicectl` copy (fine for a human reading it, useless to XCTest). The
accessibility tree is the channel that already crosses the boundary.

### It is load-bearing

Mutation-verified: forcing the probe never to see a signal turns the test
RED across four phases including `guided`. A green run is evidence.

### A stale test caught on the way

`AudioArmRoutingTests.studyFreeWrite_isSoundOff` failed once the
freeWrite sound-off gate was lifted on David's instruction (`13208e6c`).
The test pinned the OLD rule. Rewritten to pin the new one, and joined by
the control that makes it meaningful: the SILENT arm must stay silent
through the same drive.

## 8. The full-suite sweep, and four stale tests found

Running the WHOLE suite (875 tests / 80 suites, in three chunks because
the tool window cuts a single run off) turned up four failures. All four
were stale TESTS, not broken code — but two of them were hiding a real
defect, and one was breaking a suite it had never run beside.

| Failure | Verdict |
|---|---|
| `ComparisonConfigurationStampTests` x2 | stale: set `spokenFeedbackInStudy = true` to differ from a default that is now `true` |
| `StudyCleanConfigTests` speech/prompts | stale: asserted "study mode nulls speech", true only while the switch defaulted OFF |
| `StudyCleanConfigTests` overlays | **real defect** — see below |
| `AuditThirdPassTests` unenrolled gate | stale: pinned the literal "Neuer Teilnehmer", replaced when the copy was rewritten to name the rail |

### The real defect the stale test was covering for

`isLastLetterOfSet` was true for EVERY letter when the practice pool held
one letter, so the new end-of-set celebration fired per letter — exactly
the per-letter reward ruling C2 suppresses, and it would have told a
proctor that every child "finished" after a single letter. Found only
because a stale assertion failed and forced the question. The property now
requires more than one letter in the pool.

### A test that was editing its neighbours

`StudyComparisonSwitchesTests.resetToDefaults` writes the real global
store — legitimately, it is about the store — but never restored it.
`resetToDefaults()` REMOVES keys rather than writing values, so the
global was left unset and every suite running in PARALLEL then read the
*current* default, flipping `silenceSpeech` in a VM being built elsewhere
and breaking `OncePerConditionTests`. It now snapshots and fully restores
(removing added keys first, because `set(_:forKey:)` merges).

**Pattern worth keeping.** Four of these five failures came from tests
that hardcoded a value which had legitimately changed. Deriving the
non-default from `defaults` rather than typing `true`/`false` makes such
a test survive the next flip — which is the entire purpose of a
completeness check.

## RESOLVED 2026-10-03: both "still open" questions, answered from source

The two items left open by the 2026-10-03 measurement are now settled.
Neither needed a new device run: both were decidable by reading the
audio paths, and one of them turned out to be an instrument defect
rather than a finding about the app.

### `guided` was never silent — it is silent until the child MOVES

MEASURED that run: 6 `observe` samples (max peak 0.3150, 2 carrying
signal) against 34 `guided` samples, every one `peak=0.0`.

`guided`'s only sound source is the **trace coupling**:
`TouchDispatcher.updateAdaptivePlayback` maps stroke velocity and canvas
position onto playback rate and pan, and that is the sole thing that
drives the engine while a child traces. It is called from `updateTouch`,
i.e. from MOVEMENT. The phase-entry paths sound nothing — every
`speech.speak` in `PhaseTransitionCoordinator` sits inside an
`if !vm.studyMode` arm, and study mode nulls the prompt player.

So `guided` is **stroke-conditional, not silent**. A session sitting in
guided with nobody drawing must measure `peak=0.0`, and the run that
produced those 34 samples drew nothing: it tapped the observe area to
unpark the session, slept, and read.

There is already a unit-level positive control for the other half of
this claim: `AudioArmRoutingTests.studyGuided_stillCouples` drives a
guided pass and asserts `playCount > 0` for both sound arms. Guided
sounds; the measurement simply never triggered it.

**What is still NOT established**, unchanged by this: whether `guided`
*should* be audible to a child who is tracing. That is a design
question under C1/C2, not a measurement.

### `freeWrite`'s missing samples were an INSTRUMENT defect — now fixed

`freeWrite` produced **zero** samples, and the previous note recorded it
as "unmeasured rather than measured-silent". That was right, and the
cause was the instrument's own wiring.

`startAudioSignalTicker` was called from exactly two sites, both
observe-side: `startGuideAnimation` and the observe branch of
`load(letter:)`. The H6 cold pretest opens a letter **directly** in
freeWrite, skipping observe and direct, so it reached the freeWrite
landing branch at `load(letter:)` and started nothing. No ticker means
no samples at every phase boundary afterwards too.

Fixed by collapsing both inline copies into one
`TracingViewModel.startAudioSignalTicker()` helper called from all four
landing paths. It had been wired to the wrong sites twice already, in
opposite directions (§5 above), and both times the symptom was the
instrument reporting nothing — so the sites are now enumerated by one
call rather than by whoever remembered.

Pinned by `AudioSignalTickerCoverageTests` (8 tests), which is
**mutation-verified**: deleting the freeWrite call turns two of them
RED on both the count and the phase label, with the other six
correctly unaffected.

Three things that file had to get wrong first, each recorded in its
comments because each looked like the obvious approach:

- **`resume(at: .guided)` cannot deliver a load into guided.** `load(letter:)`
  calls `phaseController.reset()` first, so any resume is overwritten
  before the landing branch is read.
- **A study fixture cannot reach the guided landing at all.**
  `TracingViewModel:1149` reads `deps.studyMode ? .threePhase :
  deps.thesisCondition`, so study mode pins the script and discards a
  `guidedOnly` override.
- **`LearningPhase.allCases` is the wrong basis for a coverage
  invariant.** It contains `direct`, which is retained for Codable and
  never active — a session runs observe → guided → freeWrite. A first
  version of the invariant demanded coverage for every `allCases` member
  and so demanded the impossible.

What replaced it is the property that can actually break, phrased over
session **entry shapes**: a session that begins without a ticker is
dark for its whole length, not merely its first phase. And a companion
test pins why three sites suffice — the ticker's label closure is
re-read on every tick, so a ticker started in observe already measures
every later phase.

### The vacuous-filter trap, reproduced on demand

A function-level `-only-testing:` filter run during this work selected
**0 tests** and printed `✔ Test run with 0 tests in 1 suite passed`.
Same shape as the entry recorded in CLAUDE.md. It is the reason every
count in this document was read out of the log rather than inferred
from a green tick.

### Still open

- Whether `guided` should be audible **to a child who is tracing** —
  a design question under C1/C2, not a measurement, and not answered
  here.
- A session-`freeWrite` measurement on a real device (the case
  `testColdFreeWriteProbeIsSilentByDesign` explicitly does not cover).
  The pretest path is now measurable; the guided→freeWrite walk of a
  normal session still is not, because it depends on per-phase entry
  gestures that would break whenever one changes.
- The `Release-Study` artefact on the iPad is no longer stale: it was
  rebuilt, verified with `nm` (`_primae_build_identity_study`), and
  reinstalled on 2026-10-03 after a device test run replaced it with a
  Debug-Study build. See CLAUDE.md for why that restore is mandatory.

## The end-of-set celebration is now TESTED (PR #28, 2026-10-03)

The 2026-10-02 note below is kept because the reasoning was sound and
the conclusion was wrong in an instructive way — the missing seam was
already there.

David's proctor reported "no end congratulations animation". The branch
(`PhaseTransitionCoordinator.recordSessionCompletion`, the
`else if vm.isLastLetterOfSet` arm) exists and the guard is correct, but
**no test in the suite could reach it**.

`isLastLetterOfSet` needs `visibleLetterNames.count > 1`, and the
`studyDeps()` fixture's repository returned exactly ONE letter:

    DIAG pool=["A"] letters=["A"] studyMode=true failure=none

So `deps.allFiveLetters = true` did not widen the pool — `letters` is
already `[A]` before the subset filter runs.

**The note's proposed fix — an optional `letterRepository` on
`TracingDependencies` — was not needed.** `deps.repo` plus
`LetterRepository.init(resources: LetterResourceProviding)` already
provided exactly that seam; the fixture simply had to use it. What was
actually missing was test-side scaffolding: a `LetterSubsetProvider`
narrowing the real bundle to A/F/I, a `NullLetterCache`, a
`StubRecognizer` (freeWrite completion is DEFERRED to the async CoreML
recognizer, so a synchronous test can never reach the celebration on its
own), and a `SpyPromptPlayer` recording keys and celebrations.

Three tests now pin it — last letter celebrates and hands the device
back; a letter short of the end does neither; a multi-letter pool
reports the end only on its last letter — all mutation-checked.

**The celebration code was CORRECT.** The proctor's report was never a
code defect; it was untested code that looked untested because it was.
