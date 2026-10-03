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

## Still open

### MEASURED 2026-10-03: `guided` carried NO signal in any sample

Pulled off the physical iPad (`00008103-000E60311AE8801E`) after
`testPhonemeArmRequestsAudioDuringObserve` and
`testSpatialArmRequestsAudioDuringObserve` both passed, from
`Application Support/PrimaeNative/audio-signal-probe.log`:

| phase   | samples | max peak | samples carrying signal |
|---------|---------|----------|-------------------------|
| observe | 6       | 0.3150   | 2                       |
| guided  | 34      | 0.0000   | **0**                   |

The two lines that carried anything were both `observe`
(`nonSilent=17/18 peak=0.3150`, `nonSilent=5/20 peak=0.2890`). **Every one
of the 34 `guided` samples was `peak=0.0`.**

So this is no longer "measured but not asserted per phase" — the
per-phase measurement now exists and it is asymmetric. `observe` is
audible in the arm conditions; `guided` is silent in every sample taken.

**What is NOT established here, and must not be read as established:**

- Whether `guided` *should* be audible. That is a design question
  (C1/C2 silenced per-letter rewards), not a measurement, and this
  document does not answer it.
- Whether the probe is even ARMED during `guided`, as opposed to the
  phase genuinely being silent. The 34 zero-peaked samples are
  consistent with both. The observe samples prove the probe and the
  engine work on this device, so the instrument is sound — but
  "armed" is not the same as "attached to the guided phase's callbacks".
- `freeWrite` produced **no samples at all** in this run, so it
  remains unmeasured rather than measured-silent.

**The next step is to disambiguate arming from silence**, not to write an
assertion: confirm the guided phase's tick callbacks reach the probe. An
assertion written before that would encode a guess as a specification.

### Also still open

- `freeWrite` is unmeasured, not silent (see above).
- The `Release-Study` artefact on the iPad is no longer stale: it was
  rebuilt, verified with `nm` (`_primae_build_identity_study`), and
  reinstalled on 2026-10-03 after a device test run replaced it with a
  Debug-Study build. See CLAUDE.md for why that restore is mandatory.

## The end-of-set celebration is UNVERIFIED, and why (2026-10-02)

David's proctor reported "no end congratulations animation". The branch
(`PhaseTransitionCoordinator.recordSessionCompletion`, the
`else if vm.isLastLetterOfSet` arm) exists and the guard is correct, but
**no test in the suite can reach it**, and that is measured, not assumed.

`isLastLetterOfSet` needs `visibleLetterNames.count > 1`. MEASURED on the
`studyDeps()` fixture:

    DIAG pool=["A"] letters=["A"] studyMode=true failure=none

The fixture's repository returns exactly ONE letter, so
`deps.allFiveLetters = true` (a real seam) does not widen the pool —
`letters` is already `[A]` before the subset filter runs. The only
existing reader of `isLastLetterOfSet` is therefore the *negative* test
("a one-letter pool never reports the end of a set"), and the
celebration branch could be dead code with the whole suite green.

Two tests were written for this (last letter celebrates + hands the
device back; a letter short of the end does neither) and both fail on
the fixture, not on the production code. They are NOT committed — a red
suite is worse than an honest gap.

**What closing it needs.** `TracingViewModel.repo` is a concrete
`LetterRepository` built inside `init` (`:792`) with no injection seam,
so there is no way to hand a test a multi-letter pool. The fix is one
optional field on `TracingDependencies` (`letterRepository: LetterRepository?`,
nil = today's behaviour) plus a `LetterResourceProviding` stub over the
app bundle serving A/F/I/L/M. `LetterRepository.init` already takes that
protocol (`:168`), so only the deps seam is new.

Until then the end-of-set celebration is **device-verified only**, and it
has not been seen on the iPad.
