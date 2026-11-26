# R-104 — the 37 `AudioEngineTests` and the scheme skip

Base: `0eff852a`. Lane: `lane/audio-tests`. Every claim below is marked
**MEASURED** (I ran it or read it off disk at this base) or **RELAYED**
(recorded elsewhere, not re-verified here — the iPad is disconnected).

## The finding is real, and the skip is not the whole story

**MEASURED.** `Primae/Primae.xcodeproj/xcshareddata/xcschemes/Primae.xcscheme`
lines 86–186 carry a `<SkippedTests>` block inside the `PrimaeNativeTests`
`TestableReference`. It names the suite (`Identifier = "AudioEngineTests"`)
plus 33 of the class's 37 methods, so no `-only-testing:` filter can select
any of them on the `Primae` scheme.

**MEASURED.** `PrimaeNativeTests/AudioEngineTests.swift:49-55` independently
refuses to run on a simulator:

```swift
#if targetEnvironment(simulator)
throw XCTSkip("AudioEngine tests require real hardware — skipped in simulator")
```

So the scheme skip is one of **two** gates, and removing the scheme skip
alone cannot make a single test body execute on a simulator.

**MEASURED.** A second shared scheme, `Primae-DeviceTests`, exists for
exactly this: its `TestAction` includes `PrimaeNativeTests` with **no**
skipped tests, and its own comment says so —

> the device run path for the unit suite, INCLUDING AudioEngineTests, which
> the `Primae` scheme skips (a failing one hangs the host). Study
> configurations, so it links (R-104). Device only: the engine suite skips
> on a simulator.

That comment was written in `4ca16ee2` (r16, 2026-11-02); the scheme itself
is older.

## Origin of the skip

**MEASURED.** `git log --follow -S "AudioEngineTests" -- <scheme>` returns
one commit:

```
c27721f3b32f9d5919ae89d661bdf20815a7beff   2026-03-20 01:26:27 +0100
ci: configure BuchstabenApp scheme to exclude AudioEngineTests; add DeviceTests scheme
```

(The scheme was later renamed `BuchstabenApp.xcscheme` → `Primae.xcscheme`
in `e9c08f11`, the rebrand; that rename is why a plain `git log -S` on the
current path misses it.)

**MEASURED.** The commit has **no body** — the stated reason is the subject
alone: *"configure … scheme to exclude AudioEngineTests; add DeviceTests
scheme"*. The rationale arrives later, in the `Primae-DeviceTests` comment
quoted above: **a failing AudioEngineTest hangs the test host**. The class
documents the wedge itself (`AudioEngineTests.swift:60-80`): with
`continueAfterFailure = false`, a forced failure was recorded and then
`xcodebuild` never returned — killed at 240 s with no "Test Case … failed"
line.

## Can the suite run today, in this environment? No.

**MEASURED — this is the answer, not an inference.** I removed the
`<SkippedTests>` block, built and ran:

```
xcb-clean test -project Primae/Primae.xcodeproj -scheme Primae \
  -destination 'platform=iOS Simulator,id=5711FE27-34A7-45F3-B948-62BD477FA78C' \
  -configuration Debug-Study \
  -only-testing:PrimaeNativeTests/AudioEngineTests \
  -only-testing:PrimaeNativeTests/TracingDirectTouchTests \
  -derivedDataPath <worktree>/dd -collect-test-diagnostics never \
  CODE_SIGNING_ALLOWED=NO
```

Log: `lane-logs/audioengine.log` (authoritative — it is the only log kept;
the earlier attempts are deleted, see "Environment obstacles").

```
Test Case '-[PrimaeNativeTests.AudioEngineTests testSuspendForLifecycle_stopsPlayback]' skipped (0.006 seconds).
/…/PrimaeNativeTests/AudioEngineTests.swift:51: … : Test skipped - AudioEngine tests require real hardware — skipped in simulator
…
	 Executed 37 tests, with 37 tests skipped and 0 failures (0 unexpected) in 0.159 (1.252) seconds
✔ Test run with 4 tests in 1 suite passed after 0.006 seconds.
** TEST SUCCEEDED **
```

- **`Executed 37 tests, with 37 tests skipped`** — all 37 are *selected* and
  all 37 *skip at line 51*. **Zero test bodies execute.** The suite is not
  runnable on a simulator, and CI is a simulator.
- The `Test run with 4 tests in 1 suite passed` line is the R-091 suite
  (`TracingDirectTouchTests`), not this one. Do not read it as R-104
  evidence.
- `** TEST SUCCEEDED **` here is exactly the R-109 trap: green exit status,
  zero engine tests executed.

Consequently, per the brief's instruction, **the scheme skip was restored
and no test was changed.** The measurement commit was reverted before this
file was committed; the scheme at HEAD is byte-identical to `0eff852a`'s.

**RELAYED.** On the physical iPad the suite does run and pass. `docs/DECISIONS.md`
records the most recent device run: *"`AudioEngineTests` via
`Primae-DeviceTests` Debug-Study: 37 tests, 0 failures"* (r21,
`r21/logs/ae.log`), with the same shape at r17e and r20. The iPad is
disconnected from this machine today, so I did not re-measure it.

## What blocks it, exactly

| Gate | Where | Effect |
|---|---|---|
| `#if targetEnvironment(simulator)` + `XCTSkip` | `AudioEngineTests.swift:49-55` | every test skips on any simulator; nothing executes |
| `<SkippedTests>` block | `Primae.xcscheme:86-186` | the suite cannot even be *selected* on the `Primae` scheme |
| Real audio hardware | `AVAudioEngine` crashes `AudioConverterService` in the simulator (class docstring, `CLAUDE.md` "Test Infrastructure" item 2) | the reason gate 1 exists |

Removing only gate 2 buys 37 skip lines per CI run and nothing else.
Removing gate 1 is not on the table: the class docstring and the r16 commit
record that the engine crashes the simulator's audio converter.

## Minimal path to actually running them

1. Connect the iPad, read its UDID (`xcrun devicectl list devices`).
2. Run the device scheme — not the `Primae` scheme:

   ```sh
   /Users/musicbox/bin/xcb-clean test \
     -project Primae/Primae.xcodeproj \
     -scheme Primae-DeviceTests \
     -configuration Debug-Study \
     -destination "platform=iOS,id=<UDID>" \
     -only-testing:PrimaeNativeTests/AudioEngineTests
   ```

   `Primae-DeviceTests` has no `<SkippedTests>` block and, on device,
   `#if targetEnvironment(simulator)` is false. (Since 2026-11-24 the same
   scheme also runs the R20 device instruments and
   `LoopXDiagnosisTests/testAppScenarios`, which the `Primae` scheme now
   lists in its SkippedTests; they have no environment gate.)
3. Expect the r21 shape: 37 tests, 0 failures. **Read the count** — a
   function-level `-only-testing:` filter that matches nothing still prints
   success (`CLAUDE.md`, "Test Infrastructure" item 5).

There is no simulator-only path, and adding one would mean changing
`AudioEngine` (STABLE AND FRAGILE) or the class's hardware guard — both out
of scope for an audit item, and neither would test the engine.

## Environment obstacles met on the way (worth knowing for the next lane)

**MEASURED**, in the order they hit:

1. **`xcb-clean` takes `xcodebuild`'s arguments, not the word `xcodebuild`.**
   Passing it (as the brief's command line does) fails at once:
   `xcodebuild: error: Unknown build action 'xcodebuild'`. Use
   `xcb-clean test -project …`.
2. **Code signing fails in this environment** on the SPM resource bundle:
   `PrimaeNative_PrimaeNative.bundle: bundle format unrecognized, invalid, or
   unsuitable`. Reproduced by hand, outside the build, and narrowed: a
   directory bundle containing a root `Resources` directory cannot be signed
   by `/usr/bin/codesign` here (a bundle with the same `Info.plist` and no
   `Resources` signs fine; `Resources` renamed to `res` also signs fine). CI
   and `CLAUDE.md`'s Build & Test section both pass
   `CODE_SIGNING_ALLOWED=NO`; the run needs the same flag.
3. **The scheme's pre-action gate refuses a dirty tree** — "FATAL: the
   working tree is not clean — this build cannot be attributed to a commit".
   `dd/` and `lane-logs/` are untracked, so derived data and logs must be
   locally ignored (`.git/info/exclude`, local-only, same convention as the
   existing `AUDIT.md` entry) or the build never starts.
4. **Two lanes on one simulator kill each other.** A run on the shared
   `iPad (A16)` UDID died with `Primae encountered an error (Test crashed
   with signal kill before establishing connection)` while another lane's
   `xcodebuild` was on the same device. The measurement above therefore used
   `iPad Air 13-inch (M4)` (`5711FE27-…`), which no other lane was using.
   That void log was deleted; `lane-logs/audioengine.log` is the only one.

## What would change this conclusion

- A device run in this environment → the skip stays, the suite runs there.
- An `AudioEngine` seam that lets the interruption/route state machine be
  driven without an `AVAudioSession` (the tests forge notification payloads
  already; what they need is a session) → the simulator guard could go and
  the scheme skip with it. That is a code change to a fragile file, not an
  audit fix, and it would need its own item.
