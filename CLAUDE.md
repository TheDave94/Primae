# CLAUDE.md — Primae (Letter Learning App)

> Brand: **Primae** (formerly "Buchstaben-Lernen-App"). Everything carries the new name: the GitHub repo (`TheDave94/Primae`), Xcode project, scheme, host app, host folder (`Primae/`), Swift Package target (`PrimaeNative`), test target (`PrimaeNativeTests`), bundle identifier (`de.flamingistan.primae`), and the SPM relative path (`../../Primae`). Pre-rebrand UserDefaults keys (`de.flamingistan.buchstaben.*`) moved to `de.flamingistan.primae.*` — the app is in alpha so existing test-device state is intentionally reset. The local working tree is `/opt/repos/Primae`, matching the SPM relative path.

## Project Overview
iPad app for teaching German children (ages 5-6) to trace letters. Built with SwiftUI, Swift 6.3, targeting iOS 26+ (the SPM manifest targets iOS 26.0). Academic thesis project.

## Bounded autonomy

This is a thesis project: David is the primary author, Claude Code is reviewer + executor of agreed tasks. Two collaboration patterns coexist — be explicit about which one is active before acting.

**Five principles.**
1. **Default to action within scope.** Inside an agreed spec, execute — don't re-check at every step.
2. **Spec is the contract.** What was agreed in conversation is what ships. Drift back to conversation if the work outgrows the spec.
3. **Investigate before deciding.** Read the code / data before proposing a fix. Cheap to read, expensive to undo.
4. **Preserve the working setup.** Existing patterns are load-bearing until proven otherwise. Don't refactor on a side-quest.
5. **David picks direction, Claude picks implementation.** The "what" and "why" come from David; the "how" can be Claude's call within scope.

**Two patterns.**
- **Spec-then-execute (autonomous on engineering).** David scopes the spec in conversation; Claude implements + tests + commits + pushes + watches CI. Used for tactical engineering: bake changes, UI fixes, refactors, test additions. [[feedback_visual_approval_gate]] still gates any visual change inside this pattern.
- **Review-only (Claude proposes, David executes).** Used for thesis-substance docs — anything an examiner will read for narrative or methodology rationale (e.g. a future `docs/METHODOLOGY.md`, claims, decision-log prose). Claude drafts structure / redlines / suggests phrasing; the text that ships is David's voice. Don't merge prose into thesis-substance files without David's explicit sign-off on each section.

**Stop and surface (don't proceed autonomously) when:**
1. Scope grew past the agreed spec.
2. Two valid paths exist and the choice changes the artefact materially.
3. Evidence contradicts the spec (e.g. doc says X, code does Y).
4. A change touches a load-bearing doc (CLAUDE.md, BAKE_INVARIANTS.md, LESSONS.md Part B, claims in APP_DOCUMENTATION.md §11, docs/DECISIONS.md, research_data/spec_decision/framing.md, research_data/phase2b_gates/*.md).
5. A change touches **thesis-substance prose** (METHODOLOGY.md decision sections, examiner-facing claims, supervisor sign-off lines). Always switch to review-only.

## Two-repo working setup

This Primae code repo (`/opt/repos/Primae`) has a sibling thesis repo at `/opt/repos/master-thesis` (remote on Forgejo: https://git.flamingistan.com/David/master-thesis — NOT GitHub). Each repo has a different working mode — do not mix them.

**Primae (this repo): spec-then-execute mode.** Claude Code commits autonomously within agreed scope. Standard workflow as described in the Bounded autonomy section above.

**Thesis repo: scaffold-and-assist mode ONLY.** Claude Code may:
- Read files freely for cross-reference.
- Draft baseline prose for new chapter sections (David iterates after — never ship Claude's prose as-is).
- Find citations for claims David has written; format references in APA per the KUG Leitfaden.
- Proofread wording, spelling, terminology consistency (German/English mixing especially).

Claude Code may NOT:
- Commit to the thesis repo without per-commit David approval.
- Decide what the thesis argues — substance is David's.
- Auto-sync thesis prose to match METHODOLOGY.md (the thesis chapter is a deliberate argument, not a code description; drift toward "describe current code" is a failure mode to actively avoid).
- Push to the thesis remote without explicit instruction.

When METHODOLOGY.md in Primae gets a new or revised decision entry, Claude Code may draft a corresponding prose update for the thesis chapter and surface it for David's review. The thesis chapter updates are deliberate acts, not auto-syncs.

David's stated thesis-AI workflow: baseline drafting + reference legwork + final spelling/wording pass. Substance iteration is David's. The KUG affidavit at submission will disclose this.

## Session boundaries — code work vs thesis prose

This repo and `master-thesis` share working sessions today, and that's the primary context-pressure source — recent sessions have pegged the 1M-token ceiling and `/compact`ed 13–19 times. Split deliberately:

- **One axis per session.** A session is either Swift code work (feature impl, sweep cycles, baking, CI watching) **or** thesis prose work (drafting `content/*.typ`, citation hunting, bibliography curation). Not both in one session. The two-repo working setup is also a two-session setup.
- **Phase / milestone = session boundary.** When a sweep cycle, a feature, or a chapter section wraps, summarise the outcome into `~/.claude/projects/-opt-repos-Primae/memory/project_primae.md` and start a fresh session for the next phase.
- **For thesis-only sessions, start CC from `/opt/repos/master-thesis`** rather than this tree. CC creates a separate project workspace and memory namespace there; you get a clean context budget per side.

User-level `~/.claude/CLAUDE.md` has the general output discipline (Bash caps, ranged Reads, test-output verbatim) — it applies here.

## Architecture
- **Main target**: Uses `.defaultIsolation(MainActor.self)` — all types are implicitly @MainActor
- **Test target**: Uses `.swiftLanguageMode(.v5)` — do NOT change this
- **CI**: GitHub Actions on hosted macos-26 runners with Xcode 26.4 (simulator matrix: iPad Pro 13-inch (M5) + iPad (A16))
- **Remotes**: `origin` is the Forgejo forge at `https://git.flamingistan.com/David/Primae.git` — that is where you push. The GitHub repo `TheDave94/Primae` is a **push mirror** of the forge, not the origin: branches and workflow files reach it automatically, with nobody pushing to GitHub directly. CI runs there, so `gh run list --repo TheDave94/Primae` is the right way to read results and the wrong way to imagine the data flows.
- **Learning phases**: observe → direct → guided → freeWrite (managed by PhaseController)
- **Stroke data**: JSON files in `Resources/Letters/{letter}/strokes.json` with normalized coordinates
- **Audio**: Proximity-triggered playback via AudioEngine + StrokeTracker

## Key Files
- `TracingViewModel.swift` — main VM, coordinates phases, strokes, audio, animation
- `TracingCanvasView.swift` — Canvas rendering (ghost lines, start dots, ink, KP overlay)
- `MainAppView.swift` — root host with WorldSwitcherRail + worlds
- `SchuleWorldView.swift` — World 1: guided four-phase tracing
- `WerkstattWorldView.swift` — World 2: freeform writing
- `FortschritteWorldView.swift` — World 3: child-facing star/streak/letter gallery
- `StrokeTracker.swift` — checkpoint proximity detection
- `AudioEngine.swift` — ⚠️ STABLE AND FRAGILE — do NOT modify
- `SpeechSynthesizer.swift` — German TTS for child-facing verbal feedback
- `LetterRepository.swift` — loads letters from bundle
- `PrimaeLetterRenderer.swift` — renders letter glyphs using Primae font
- `ProgressStore.swift` — persists learning progress
- `OverlayQueueManager.swift` — serialised post-freeWrite overlay scheduler
- `StrokeCalibrationOverlay.swift` — debug stroke editing UI

For the full developer-grade reference + thesis foundation see
`docs/APP_DOCUMENTATION.md` (single comprehensive doc; includes
architecture quick reference, research export schema, and phoneme
audio guide as Appendices A/B/C).
Outstanding work, deferred items, post-thesis ideas, and the pilot-study
freeze items (H1–H6) + known issues live in `docs/ROADMAP.md`.
Pilot design decisions (D-series), their evidence, and the governing
constraints live in `docs/DECISIONS.md`; the sound-asset production
procedure is `docs/SOUND_PRODUCTION_SPEC.md`. (These three absorbed the
former `PILOT_READINESS.md`, removed in the 2026-06-20 doc reorg.)
Read `docs/LESSONS.md` before touching `AudioEngine.swift`,
`StrokeTracker.swift`, or the `load(letter:)` path.

## Build & Test
```bash
cd Primae
xcodebuild test -project Primae.xcodeproj -scheme Primae \
  -destination "platform=iOS Simulator,name=iPad (A16)" \
  -configuration Debug CODE_SIGNING_ALLOWED=NO
```

## Test Infrastructure

### The test count is not a measure of evidence — MEASURED 2026-09-17

A defect shipped through a fully green `PrimaeNativeTests` run (901 tests,
90 suites) while the change under test was completely INERT: a block was
de-indented without moving its enclosing brace, so nothing about the
behaviour changed. `grep` over both test targets returned **zero** hits for
the feature's symbol, its settings key and its view-model property. The
suite was green because it never exercised the thing. Two consequences are
now standing practice here.

**1. Mutation-check every test written to pin a defect.** Break the thing
deliberately, confirm the test goes RED, restore. No tooling: muter's last
*release* is from 2023 and it only learned to detect Swift Testing kills on
unreleased `master` (2026-07-21), so a targeted manual mutation is both
cheaper and more honest. This is the only mechanism that mechanically
answers "is this test load-bearing?", and today it caught a test of our own
that failed for the WRONG reason (see below) — a test that cannot PASS is
the mirror of one that cannot fail, and just as worthless.

**2. Tests that cannot fail inflate the count.** Measured in this suite:
`AudioEngineTests`' 36 methods skip unconditionally on the simulator
(`XCTSkip` in `setUp`, correct — AVAudioEngine crashes the sim) and **CI is
a simulator**, so 36 tests contribute to the count and nothing to CI's
evidence. `PerformanceBenchmarkTests`' 5 have no assertions, and
`StrokeTrackerRegressionGateTests`' 5 are `measure`-only with no committed
baseline — CI starts clean, so each run establishes fresh baselines and
compares against nothing. Do not read "N tests passed" as N pieces of
evidence without checking what those tests can observe.

**3. A `Canvas`'s draw closure cannot be tested directly, so extract the
decisions.** `GraphicsContext` is a `@frozen struct` with **no public
initialiser** — nothing can construct it, invoke the closure, or spy on it,
and no mocking technique in Swift reaches it. The answer is structural:
compute *what to draw* in plain Swift and hand it to the closure as a value
(`TracingViewModel.CanvasDrawPlan` is the pattern), so the closure replays
decisions it does not evaluate and there is no brace whose position can be
wrong. Property assertions cannot see nesting; a value can.

**4. `ImageRenderer` does NOT render a `Canvas` inside a `GeometryReader`.**
Measured: two renders of `TracingCanvasView` — different phases, one with
the ring and one without — came back **byte-identical** (51534 "red" pixels
each). No layout pass runs, so the `Canvas` draws nothing and a pixel test
measures the paper. A faithful snapshot needs a layout pass first
(`UIHostingController` in a window, or a fixed-size proposal that bypasses
the GeometryReader).

**Hard limits worth knowing before trusting any other signal.** Swift has
NO branch coverage (swiftlang/swift#81730, open since 2025-05-23) — and the
inert defect moved no line anyway, so line, function and diff-coverage were
all green. `.timeLimit` is minutes-only, so it cannot police a sub-second
hang. Swift Testing retries re-run the WHOLE target, not just the failures
(FB20922425). And `PrimaeUITests` (6 tests) never runs in CI — Layer 3
scopes the job to `PrimaeNativeTests`.

**5. A test must not mutate global state — Swift Testing runs suites in
PARALLEL, and the failure shows up in someone else's test.** Measured the
same day, by making the mistake: `LetterWeightFallbackTests` set
`de.flamingistan.primae.fontWeight` in `UserDefaults.standard` to drive the
Light→Regular fallback, and while it was set, `StrokeGeometryGoldenTests`
loaded Light geometry and failed its frozen baseline — a test in a
different file, with nothing in its own code wrong. If a behaviour depends
on a setting, give the production type a **seam** for it
(`LetterRepository.init(weight:)` was added for exactly this) and inject
the value; never flip a global and rely on a `defer` to put it back, because
the window between the two is where every other test runs.

**MEASURED 2026-09-17 — a thorough test file that never executes.**
`StrokeCalibrationOverlayHelpersTests.swift` is wholly `#if !STUDY_BUILD`
(lines 4–151), so **none of it runs in the 907-suite**, and since
`STUDY_BUILD` is unconditional there is no other configuration to run it
in. The calibrator is the tool that PRODUCES the corpus, and it has no
running coverage at all. Nothing to fix while the casual path is paused —
recorded so the green suite is not read as covering it.

**And 32 of the app's 100 source files have ZERO references from either
test target** (a 2026-09-17 sweep; 19 of them compile into the study
build). The study-facing ones, by risk: `StoreFileQuarantine` (data-loss
prevention, wired into five stores), `CalibrationSessionLogger` (corpus
capture, writes are `try?`-and-swallow by design), `SchuleWorldView` (the
child-facing world, including its score→verdict and star thresholds),
`SettingsView` (the proctor's arm configuration), and `LetterStars` /
`PhaseDotIndicator` / `WorldSwitcherRail` (child-visible counts). Two
numbered star totals are computed independently in `SchuleWorldView` and
`WorldSwitcherRail`, each with a comment claiming they agree, and neither
is tested.

> **Note:** `xcodebuild` is NOT available on claudebox (Linux). Only Swift syntax
> checking works locally. Full build/test runs on hosted macos-26 GitHub Actions
> runners. Always verify CI passes after pushing.
> Physical-iPad testing is a deliberate LOCAL act on the Mac: it requires
> `-allowProvisioningUpdates` and an unlocked, connected iPad. It is NOT automated
> and never was.

> **LIFTED (2026-09-16, evening — sandboxed seat on this Mac). The 2026-09-03
> and 2026-09-16 blocks below are SUPERSEDED for this configuration;
> `xcodebuild` and `xcrun simctl` now work from a sandboxed seat.** Measured,
> not relayed. `~/.claude/settings.json`'s `sandbox.excludedCommands`
> (`:216-224`) now carries `xcrun simctl *`, `xcodebuild *`,
> `/Users/musicbox/.swiftpm/*`, and
> `/Users/musicbox/Library/Caches/org.swift.swiftpm/*`. What that bought,
> measured this session:
> - Bare `xcodebuild -version` → `Xcode 27.0` (`27A266a`); bare
>   `xcrun simctl list devices available` → the full device list.
> - A full clean `xcodebuild build` at a **fresh** `-derivedDataPath` (so
>   SwiftPM resolution ran from scratch, the exact thing that used to return
>   `permissionDenied`) → `** BUILD SUCCEEDED **`, 115 compile invocations,
>   zero `error:`, zero `permissionDenied`, zero `CoreSimulatorService`
>   failures.
> - `nm -jU …/Primae.app/Primae | grep primae_build_identity` →
>   `_primae_build_identity_study`, exactly one hit.
>
> Do **not** read the older blocks as current. They remain accurate about the
> configuration that produced them; re-measure before trusting either way.
>
> **The call-shape rule is NOT specific to `git` — it governs every entry in
> `excludedCommands`, and it bit this session.** The match is on the call's
> *leading top-level word*, so `rm -rf X; xcodebuild test …` runs **sandboxed**
> (`rm` leads), while `xcodebuild test …` alone runs unsandboxed. Measured
> consequence: the sandboxed variant wrote a result bundle with **no root
> `Info.plist`** — `Data/` and `Staging/` present, never finalised — which
> `xcrun xcresulttool` then refuses (`Failed to create a new result bundle
> reader`). Nothing else about that run was wrong, and the mistake is
> invisible in the command's own output. Keep `xcodebuild` / `xcrun` as the
> literal first word.
>
> **Extended 2026-09-16, same night — a variable-assignment or
> command-substitution PREFIX breaks the match too.** `C=$(xcrun simctl
> get_app_container …)` runs **sandboxed**: the call's leading word is `C=`,
> not `xcrun`. Measured symptom is the exact one the exclusions exist to
> prevent — `CoreSimulatorService connection became invalid. Simulator
> services will no longer be available` — while the identical command with
> `xcrun` bare at the front succeeds on the same device seconds later. This
> is the same class as the `cd … && git commit` and `sh -c "git …"` shapes
> above, and it is the THIRD distinct spelling of the trap to cost time:
> **anything in front of the excluded word — a wrapper, a `cd`, an
> assignment, a `$( )` capture — re-sandboxes the whole call.** Assign in one
> call, use it in the next; never capture an excluded command inside a
> substitution.
>
> **`xcrun xcresulttool` does NOT match `xcrun simctl *`.** It stays
> sandboxed, so both its `--path` and its `--output-path` must sit somewhere
> the sandbox can reach. Same for any command that is not literally
> `xcrun simctl …`.
>
> **`$TMPDIR` is NOT stable across Bash calls here, and `/tmp/claude-501` is
> a real directory, not a symlink.** Measured: `$TMPDIR` expanded to
> `/tmp/claude-501` in most foreground calls, but to
> `/var/folders/ws/544vqfxj1dbfy9vvs3mwxrr00000gn/T/` in the background shell
> and in at least one foreground call. The older claim that `$TMPDIR` is
> `/tmp/claude-501`, "a symlink to `/var/folders/ws/…/T`", is **wrong on both
> halves** — `ls -ld /tmp/claude-501` → `drwx------ … musicbox wheel`, a plain
> directory, and the two paths are different directories. A file written under
> one expansion is NOT visible under the other, which silently broke a backup
> lookup mid-session. **Do not hardcode `$TMPDIR` across the steps of a
> multi-step pass** — use an absolute path, or re-read it in each call.
>
> **Sandbox-level `/tmp` writes are still denied for NON-excluded commands**
> (re-measured): `touch /tmp/probe` → `Operation not permitted`;
> `touch $TMPDIR/probe` → OK; *reading* `/tmp` → OK. Cross-directory `mv`
> is denied for non-excluded calls too. Excluded commands are unaffected —
> they run unsandboxed and may write `/tmp` freely.
>
> **First thing a fresh seat will hit on a build: the provenance gate.** With
> ANY uncommitted change present, the `Primae` scheme's Pre-action
> (`scripts/check_project_invariants.py`, `gate_provenance()`, `:225-246`)
> fails the build outright and prints the offending `git status --porcelain`
> lines. That is by design — it is the one place `--autofix` is allowed to
> fail — so **resolve the tree, never bypass the gate.** Untracked files count;
> a fresh clone carrying two of them will not build. (2026-09-16: two untracked
> files — `.mcp.json` and `PrimaeUITests/StudyAdvanceProbeUITests.swift` —
> stopped a build dead after package resolution had already succeeded.)
>
> **`.mcp.json` state (2026-09-16).** A repo-root `.mcp.json` registering
> `xcodebuildmcp` was present and being activated via
> `.claude/settings.local.json` (`enableAllProjectMcpServers: true`) — i.e.
> F12's *declined* bridge, live, while the study configuration is frozen.
> It was moved aside (NOT deleted) to
> `/tmp/claude-501/primae-mcp.json.aside`, sha256 `d3c212f8…`, to clear the
> gate while keeping F12 declined. Note that path is a temp directory and may
> be reaped — the file is four lines and its content is recoverable from this
> entry's session transcript; if a future post-pilot session revisits F12,
> regenerate it from F12's own conditions (`docs/ROADMAP.md:411`, which
> requires it be **tracked** if ever adopted), not from the temp copy.
>
> **The 2026-09-16 simulator question is ANSWERED — the Debug-Study hang is
> `#if DEBUG`-specific and does NOT reach the pilot artefact.** (Header
> corrected same evening from "INCONCLUSIVE", once the fork was actually run
> rather than reasoned — see "RESOLVED" below.) Running the
> three-check probe (`PrimaeUITests/StudyAdvanceProbeUITests`, committed
> `62ae8bc`) end to end on the iPad Pro 11-inch (M5) / iOS 27.0 simulator:
> all three checks failed, and **none failed for the reason it was written to
> test.** The app launches without crashing and stays alive (`launchctl list`
> shows the process), but its UI freezes on a blank screen — black with a
> spinner at 8 s, white with the same spinner at 20 s, and **byte-identical**
> (`sha256 23eb09e5…`) ~6 min later, so the frame never changes. No
> `Aktueller Buchstabe …` pill ever appears, so checks 1 and 2 could not
> exercise the chevron at all; check 3's gear long-press reached the parent
> area in one run and not the next. Check 2 (per-arm audio) is void: the
> override was set and the unified log captured for each of
> `phoneme`/`spatial`/`silent`, but no arm shows any app-level playback
> request, because the app never reaches a phase in which audio is requested.
>
> **Do not read this as evidence about the three device reports.** The
> simulator is iOS 27.0 under Xcode 27.0; the pilot artefact is Release-Study
> on iOS 26.4 under Xcode 26.4, and `StudyAdvanceProbeUITests`' own header
> disclaims parity. The device is separately reported working (RELAYED, not
> measured here).
>
> **RESOLVED 2026-09-16, same evening — the fork, RUN rather than reasoned.**
> Built **Release-Study for that same simulator** (same tooling, bare
> `xcodebuild`, fresh `-derivedDataPath`) and launched it: it **renders
> correctly** — the German *"Studie kann nicht starten — Kein Teilnehmer
> eingeschrieben…"* screen, parent-area gear and rail all present
> (`/tmp/claude-501/primae-shots/10-RELEASE-sim-20s.png`). Debug-Study freezes
> on the same machine; Release-Study does not. **So the hang is Debug-only, it
> does not affect the pilot artefact, and it is not a device-relevance
> question for the study.** The DEBUG-compiled-in surfaces remain the cause
> class to investigate IF anyone later wants a working Debug build — that is a
> tooling fix, not a pilot blocker, and was deliberately not chased further.
> (Ruled out en route, so nobody re-walks it: onboarding state is NOT the
> cause. Onboarding is file-backed, not `UserDefaults`-backed —
> `OnboardingCoordinator.swift:150-158`, `Application Support/PrimaeNative/
> onboarding.json` — and that file is ABSENT on a fresh install, so
> `isOnboardingComplete` is correctly `false` and `OnboardingView()` is the
> branch that should render. `OnboardingView`'s gradient/progress-bar/footer
> never appear either, so the app is not reaching a first frame at all.)
>
> **NAMED GAP — nothing has ever run the unit-test suite against the pilot
> configuration.** `PrimaeNativeTests` structurally cannot compile against
> `Release-Study`: it references `#if DEBUG`-only members —
> `TracingViewModel.awaitPlaybackDebounce`
> (`PrimaeNativeTests/AudioArmRoutingTests.swift:284`) and
> `AudioEngine.debugShouldResumePlayback`
> (`PrimaeNativeTests/AudioEngineTests.swift:72`). With `ENABLE_TESTABILITY=NO`
> the module refuses to resolve at all
> (`Unable to resolve Swift module dependency to a compatible module:
> 'PrimaeNative'`); forcing `ENABLE_TESTABILITY=YES` on the command line
> merely moves the failure to those members. `-skip-testing:` does NOT prevent
> the BUILD, so the scheme's test action always compiles the target and
> `xcodebuild test` can therefore **never** run under Release-Study — which is
> precisely why `scripts/run_device_uitests.sh` defaults to Debug-Study.
> **Consequence, plainly: the suite has only ever validated the Debug
> configuration.** No fix proposed here, deliberately — recorded so the next
> session sees it.
>
> **HAZARD — `xcodebuild test` overwrites the artefact you just verified.** A
> test run rebuilds into the same `-derivedDataPath`, replacing the signed app
> with an unsigned/testability variant. Measured: `devicectl device install`
> then failed with `0xe800801c (No code signature found)` and `nm -jU`
> returned no identity symbol at all. **Verify first, then build elsewhere** —
> give `test` a different `-derivedDataPath` than the artefact you intend to
> install.
>
> **HAZARD — `scripts/run_device_uitests.sh` cannot be invoked from a
> sandboxed seat.** Its documented usage passes the target UDID as the
> script's first argument, so the call's leading word is the script PATH — not an entry in
> `excludedCommands` — so the whole call runs sandboxed and dies on
> CoreDeviceService. Issue the underlying bare `xcodebuild test …` instead;
> the exact command is the script's own `exec` line.
>
> **FOUR findings from the 2026-09-16 late session. The third is the one
> most likely to cost a future seat a wrong conclusion rather than just
> time.**
>
> **1. `PrimaeNativeTests` structurally cannot build under `Release-Study`,
> so the unit-test suite has only ever validated the DEBUG configuration.**
> It references `#if DEBUG`-only members — `TracingViewModel
> .awaitPlaybackDebounce` (`PrimaeNativeTests/AudioArmRoutingTests.swift:284`)
> and `AudioEngine.debugShouldResumePlayback`
> (`PrimaeNativeTests/AudioEngineTests.swift:72`). With
> `ENABLE_TESTABILITY=NO` the module refuses to resolve at all
> (`Unable to resolve Swift module dependency to a compatible module:
> 'PrimaeNative'`); forcing `ENABLE_TESTABILITY=YES` on the command line
> merely moves the failure to those members. `-skip-testing:` does NOT
> prevent the BUILD, so the scheme's test action always compiles the target
> and `xcodebuild test` can therefore **never** run under Release-Study.
> That is exactly why `scripts/run_device_uitests.sh` defaults to
> Debug-Study. No fix proposed — recorded so the gap is visible.
>
> **2. Unit tests on the physical iPad — FIXED 2026-09-17, and the
> recorded cause was wrong.** This entry used to read "cannot be RUN on the
> physical iPad from this seat … a device-verified unit test is not
> available as an instrument". The symptom was real and is quoted below,
> but it was never a seat limitation and never a platform one: it was two
> `DEVELOPMENT_TEAM` values disagreeing inside this project.
>
> Symptom, for recognition: the injected bundle failed to load with
> `code signature … not valid for use in process: mapping process and
> mapped file (non-platform) have different Team IDs`, producing
> `Failed to load the test bundle`, after which xcodebuild ran only
> `PrimaeUITests` and reported nothing about the unit bundle — which is
> why it read as "unit tests just don't work on device". UI tests were
> unaffected because they run in a separate runner process.
>
> Cause, measured: the app target sets `DEVELOPMENT_TEAM = J7JH8FJK2W` in
> both Study configurations, while the unit-test target set NO team, so it
> inherited the PROJECT-level default `XMX37BH48B`. Two teams. Building
> and reading the signatures back showed it plainly —
> `Primae.app TeamIdentifier=J7JH8FJK2W` against
> `PrimaeNativeTests.xctest TeamIdentifier=XMX37BH48B`.
>
> Fix (`b1ab17a`): set the unit-test target's `DEVELOPMENT_TEAM` to the
> app's in Debug-Study and Release-Study. Both bundles now sign
> `J7JH8FJK2W`, and the full suite runs on the device:
> `✔ Test run with 901 tests in 90 suites passed after 186.966 seconds.`
> **A device-verified unit test IS available as an instrument now** — it is
> the strongest check this project has, and it costs one `xcodebuild test`
> with `-destination "platform=iOS,id=<UDID>"`. Reach for it before the
> simulator when the question is about real hardware.
>
> Still true: `xcrun devicectl device copy from` has no `bundleContainer`
> domain, so the INSTALLED binary still cannot be pulled for `nm`.
>
> **3. Anything measured under a UI test measures the HARNESS, not the
> app.** This one produced a wrong number tonight, and the error was 2×.
> The UI-test build injects `PrimaeNativeTests.xctest`, which carries **its
> own copies of the letter resources**: measured in a Debug-Study device
> build, `strokes.json` appears **348 times across FOUR trees** (the app's
> `PrimaeNative_PrimaeNative.bundle`, a `Frameworks/` copy, and two inside
> `PlugIns/PrimaeNativeTests.xctest`) against **87 in the shipped app**.
> `Bundle.main.resourceURL` enumeration descends into `PlugIns/` and
> `Frameworks/`, so it collects all four. A count taken under test is
> therefore inflated by the harness itself. **Measure the shipped
> configuration or you are measuring the test rig.** The way that worked:
> build `Release-Study` for the device, have the app write the numbers into
> its own container, launch it with `devicectl`, and read them back with
> `xcrun devicectl device copy from --domain-type appDataContainer
> --domain-identifier com.flamingistan.primae.study`.
>
> **4. The resource over-collection: cause, fix, and the numbers.**
> `BundleLetterResourceProvider.searchBundles` lists the module bundle AND
> the app bundle, and the app bundle *contains* the module bundle, so
> `allResourceURLs()` returned every letter file twice. Fixed at the source
> by de-duplicating on `resolvingSymlinksInPath().path` — **not**
> `standardizedFileURL`, because iOS containers appear as both `/var/…`
> and `/private/var/…` and the latter does not resolve symlinks (measured;
> the first attempt at this fix therefore removed only half the
> duplication). Measured on the physical iPad in Release-Study, before →
> after: **assets 118 → 59**, **repoLoad 14236 ms → 7069 ms**, **footprint
> 136.6 MB → 82.7 MB**. 118 is exactly 2×59; 59 is exactly the Regular
> weight's letter count, i.e. one asset per letter. Load halves and
> footprint falls 39% on every launch. Commit `84f6704`.
>
> **The chevron fix (`17178c0`) — the duplicate navigation pool.**
> `visibleLetterNames` returned FIFTEEN entries for a three-letter
> trained subset (five copies of each) because `allResourceURLs()`
> collected every letter file repeatedly. `nextLetter()` navigates that
> pool BY INDEX — `visible[(idx + 1) % count]` — so from the first `"I"`
> the successor was the second `"I"`, `load(letter:)` reloaded the same
> letter, and the chevron looked dead on every tap. That was the whole of
> report 1. Fixed at the navigation layer by de-duplicating the ordered
> pool, and at the source by `84f6704` above.
>
> **DON'T "FIX" THE SPATIAL GLISSANDO — IT IS THE SPECIFICATION.**
> Reported 2026-09-16 as a bug: the Raumklang arm plays a high→low→high
> sweep *before* the child touches. It is the pre-task axis
> demonstration, and it is required. `04-implementation.typ:17`
> specifies it verbatim — "a scripted sweep point, independent of the
> letter's shape and of the guide dot, runs once from the top of the
> canvas to the bottom and back while the carrier's pitch follows it,
> and once from the centre to the right edge, back through the centre to
> the left edge, and back to the centre, a quarter-cycle out of phase".
> `PreTaskDemonstration.axisSweep` implements exactly that
> (`y = 0.5 - 0.5·cos 2πt`, `x = 0.5 - 0.5·cos(2πt + π/2)`) and
> `SpatialSonification.pitchCents` maps it to 880→220→880 Hz. The header
> gives the reason it must exist and must be matched across arms: "a
> demonstration can INSTALL a crossmodal mapping rather than reveal one
> already there... that arm's later tracing-task audio wouldn't just be
> the arm's sound — it would be the arm's sound, already taught."
> Removing or deferring it is a PROTOCOL change requiring the thesis to
> move with it, not a code fix. Verified point-by-point against the spec
> on 2026-09-17; the code conforms on every clause.
>
> **The spatial demonstration now fails loudly instead of skipping in
> silence (`5a59c36`).** `armPreTaskDemonstration`'s `.spatial` branch
> opened with `guard !samples.isEmpty else { return }` — unlike
> `.phoneme`, which cannot reach its demonstration without a file because
> the preconditions refuse the session first. That guard was the only
> thing between the arm and a demonstration that never plays, and it
> returned silently: no sound, no on-screen signal, nothing in the
> record, so a session could run and be analysed as though the arm had
> been delivered. Now logs a fault, matching "a fault, not a quiet skip
> (C1-6)" — the standard this codebase already states for the phoneme
> branch's equivalent case. Chosen under the 2026-09-16 standing rule
> (prefer the option with no new audible artifact, no confound, no risk
> to data validity, even at extra cost); it changes nothing audible,
> because the path is currently unreachable.
>
> **Report 2's audio finding, and its limit.** Both sound arms were
> driven on the physical device and both were shown to RESOLVE the right
> asset and REQUEST playback: `arm=phoneme` → the letter's
> `I_phoneme1.wav`; `arm=spatial` → the shared letter-independent
> `spatial_carrier.wav`, `autoplay=true`, 2.0 s window, 40 axis samples.
> **That establishes the engine was ASKED to play. It does not establish
> that sound left the speaker** — no XCUITest can, on simulator or
> device, and this is the caveat that must travel with the result. It was
> later confirmed by ear that the spatial arm is audible.

> **Correction (2026-09-03, measured from a sandboxed Claude Code seat on this
> Mac — a different environment than claudebox above).** Neither `swift build`
> nor `xcodebuild` works from here; there is no local fallback because only
> `test` is blocked — **build is blocked too.** A claim otherwise, relayed
> from another seat or a prior session, did not reproduce; re-measure before
> trusting it again:
> - `swift build` fails at manifest compilation: `couldn't create cache file
>   '.../xcrun_db-*' (errno=Operation not permitted)`, and
>   `~/Library/org.swift.swiftpm/*` reports not accessible/writable.
> - `xcodebuild build` and even a bare `xcodebuild -resolvePackageDependencies`
>   (default derived-data path, no override) fail identically: `CoreSimulatorService
>   connection became invalid` (the XPC connection itself is refused) followed by
>   `error: permissionDenied` on package resolution. Not a `-derivedDataPath`
>   artifact — reproduces with Xcode's own default path.
> - Only CI (hosted macos-26 runner) can build or test this project from a
>   sandboxed seat. Prepare the change, then hand off to a build-capable seat
>   or David's terminal — don't spend a round trip re-discovering this.
> - `gh run list` (and `gh api .../actions/runs`) also fails locally with a
>   Go-TLS certificate error specific to that endpoint; `curl` with the token
>   from `gh auth token` against the same URL works. Use curl for reading CI
>   results from a sandboxed seat.

> **Follow-up (2026-09-16, sandboxed seat) — the block above, located
> precisely, plus one call shape that silently loses the simulator.**
> Measured while trying to run a simulator UI-test pass. It refines the
> 2026-09-03 note; it does not contradict it (`xcodebuild` is still
> blocked), but the block is narrower than "Simulator services will no
> longer be available" reads — see D.
>
> **A. The `permissionDenied` on package resolution is the SwiftPM
> home-directory state, probed directly.** `touch
> ~/Library/Caches/org.swift.swiftpm/primae-probe` and `touch
> ~/.swiftpm/probe` both return `Operation not permitted`. SwiftPM names
> the same targets itself in the lock files it drops in `$TMPDIR`:
> `_Users_musicbox_Library_Caches_org.swift.swiftpm_manifests_manifest.db.lock`
> and `_Users_musicbox_.swiftpm.lock`. It is not fetching: `Package.swift`
> declares zero remote dependencies, and the project references only
> `XCLocalSwiftPackageReference "../../Primae"`. Five build attempts,
> four distinct levers — fresh `-derivedDataPath`, a clone of an
> already-resolved derived data (286 MB, `SourcePackages` present),
> `-packageCachePath "$TMPDIR/…"`, `HOME` relocation, and
> `-disableAutomaticPackageResolution
> -onlyUsePackageVersionsFromResolvedFile` — all returned `BUILD_RC=74`
> with the identical `xcodebuild: error: Could not resolve package
> dependencies: error: permissionDenied` (twice). None of them redirects
> the denied writes. Those lock files also show an earlier seat
> resolving successfully against `/tmp/dd-sim-drive`, so this is
> seat/sandbox state, not a property of the project.
>
> **B. Simulator access is scoped by CALL SHAPE, exactly as the signing
> section below documents for `git commit` — same failure mode, a
> different rule underneath.** A bare `xcrun simctl list devices
> available` works, foreground *and* background, and returns the full
> device list including a booted device. The same command inside a
> nested shell does not: `sh -c 'xcrun simctl list devices available'` →
> `CoreSimulatorService connection became invalid … Connection refused`.
> Reproduced across two runs. This alone kills `/tmp/primae-sim-pass.sh`
> as written, since its own usage line is `sh /tmp/primae-sim-pass.sh …`
> — making its first `simctl` call a grandchild of the Bash tool call.
>
> **C. `/tmp` is not writable from this seat; `$TMPDIR` is — and they
> are the same directory.** `touch /tmp/primae-probe-write` →
> `Operation not permitted`; `touch "$TMPDIR/primae-probe"` succeeds.
> `$TMPDIR` is `/tmp/claude-501`, a symlink to `/var/folders/ws/…/T`, so
> `simctl io … screenshot "$TMPDIR/x.png"` reports its own output path as
> `/var/folders/…/x.png` — one file, not a redirect. The sim pass
> hardcodes `/tmp` for every log and for `-derivedDataPath`, so it cannot
> run here as written; substituting `$TMPDIR` throughout is the fix.
>
> **D. Measured as NOT blocked, so don't over-read B:** `xcrun simctl
> install`, `launch`, `io … screenshot`, and `spawn … log show` all
> succeed (rc=0, with real app log lines returned). The unified-log
> channel is reachable, so an audio-arm check's *instrument* is sound —
> what a sandboxed seat cannot do is build the test bundle that would
> drive the flow. "CoreSimulatorService connection became invalid"
> printed by an `xcodebuild` run is not a statement about `simctl`.

> **Commit signing runs IN a Claude Code session — invoking `git commit`
> directly is not a handover. The physical touch reaching David is a
> separate, less reliable step, and a failure there is not the same claim
> as "signing is impossible from here."** Both halves are measured, not
> assumed — read them as two distinct findings, not one:
>
> 1. `ls`/`cat` on `~/.ssh` return `Operation not permitted` from a
>    sandboxed Bash tool call, which looks like a hard block on reading the
>    signing key — it is not one for `git commit` itself. Six commits
>    signed and pushed directly from this session on 2026-09-03
>    (`b2d5397` through `a4f4c9b`, later squash-merged as `881116b`), each
>    confirmed genuine with `git log --show-signature` (`Good "git"
>    signature ... ED25519-SK key`), completed synchronously with no hang
>    and no visible prompt delay. The earlier same-day claim that this was
>    structurally impossible was never re-tested before being written down,
>    and did not hold up.
> 2. The SAME evening, a seventh attempt (via `land.sh`, same repo, same
>    key) failed differently: `yubi-sign` — the wrapper that signs and cues
>    David — threw an AppleScript error trying to raise the notification
>    ("NOTE notification channel unavailable... syntax error"), then
>    reported the public key as unreadable, and `git commit` never wrote
>    the object. Nothing was committed or pushed; land.sh's own failure
>    discipline caught it cleanly. This is real, and it is not the same
>    finding as (1) reversed — six clean signs and one failed notification
>    cue are consistent with "direct invocation works, the cue-to-David
>    path is not yet fully reliable," which is narrower than either "always
>    works" or "structurally blocked."
>
> Run the commit directly from the session; that part holds. If a commit
> fails or stalls, that is new information about the notification/signing
> path specifically to record and investigate on its own terms — not proof
> the retracted claim was right, and not something to silently retry past
> without noting it happened.
>
> **2026-09-04 — WHY the direct route works, mechanically, and why a
> diagnostic probe of "signing capability" using `ssh-keygen`/`ssh-add`
> directly is not a valid test of it.** MEASURED off this machine's own
> `~/.claude/settings.json` (global, one file, governs every project —
> confirmed by reading it directly, not relayed):
> `sandbox.excludedCommands: ["git", "git *"]`. Claude Code's sandbox
> exclusion is evaluated **per Bash call, over that call's leading
> top-level statement** — a call whose command STARTS WITH `git` runs
> **entirely unsandboxed** (full filesystem read, including `~/.ssh`;
> real agent-socket access), and any other call — including a bare
> `ssh-keygen -Y sign -f ~/.ssh/id_ed25519_sk_homelab.pub ...` or
> `ssh-add -l` run directly to "test whether signing works" — does **not** match, stays
> fully sandboxed, and fails on the exact same `~/.ssh` denyRead this
> section's finding 1 already named. **That failure is not a capability
> regression — it is proof the probe wasn't a git-led call, nothing
> more.** (Cross-referenced against `~/repos/homelab-ops/docs/
> NOTE-proviant-signing-mechanism-2026-09-02.md` and
> `~/repos/homelab-ops/docs/systems/git-security.md`, which independently
> derived and named the identical mechanism against the identical
> settings file from a sibling project on this machine — corroborating,
> not the source of this finding.)
>
> **Practical corollary: to sign a commit in a DIFFERENT repo than the
> current working directory without breaking the exclusion, use `git -C
> /path/to/other-repo commit -S ...`, never `cd /path/to/other-repo &&
> git commit -S ...`.** `cd` as the leading statement makes the WHOLE
> compound not git-led, and the commit inside it runs sandboxed and
> fails — indistinguishable, from the outside, from "signing doesn't
> work here," when the actual cause is call shape. `git -C
> /path/to/other-repo ...` keeps `git` as the literal leading word of
> the call, preserving the exclusion, while still targeting the other
> repo. If a signing attempt ever needs to be handed to David
> instead of run directly, that handover is itself a finding worth
> recording (which specific call shape failed, and why) — not a default
> to fall back on when the first shape tried happens not to be git-led.
>
> **The rule generalises past `cd`, and stating it only for `cd` invites
> the same mistake in a different wrapper.** The exclusion keys on
> `sandbox.excludedCommands` matching the Bash tool call's LEADING
> TOP-LEVEL WORD — literally whatever the Bash tool call's command
> string starts with. `cd /path && git commit -S ...` fails because
> `cd` is that leading word. **`bash -lc "git commit -S ..."` fails for
> the identical reason**: the leading word of THAT call is `bash`, not
> `git`, even though a `git` command sits right there inside the
> string — the match is on the call shape, not on whether `git` appears
> anywhere in it. Any other wrapper has the same failure mode: `sh -c
> "..."`, a shell function that internally runs `git`, a script invoked
> as `sh some-script.sh` whose body calls `git`. **The one shape that
> keeps the exclusion is the Bash tool's command string beginning with
> the literal word `git` — nothing between the start of the string and
> that word, no shell invoked to interpret it first.** This is why a
> signing capability can look like it vanished between one attempt and
> the next when nothing about the sandbox or the key changed: the call
> SHAPE changed, and that alone flips the outcome. Before concluding
> signing doesn't work, check the exact command string that was sent,
> not just that it "used git somewhere."

1. **Swift compilation check** (claudebox Linux — basic syntax check only, SwiftUI/QuartzCore won't link):
   ```bash
   swift build 2>&1 | head -20
   ```

2. **Full build** (CI runner or local Mac):
   ```bash
   xcodebuild build -project Primae/Primae.xcodeproj -scheme Primae \
     -destination "platform=iOS Simulator,name=iPad (A16)" \
     -configuration Debug CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
     -derivedDataPath /tmp/DerivedData-Primae 2>&1 | tail -20
   ```

3. **Full test suite** (CI runner or local Mac):
   ```bash
   xcodebuild test -project Primae/Primae.xcodeproj -scheme Primae \
     -destination "platform=iOS Simulator,name=iPad (A16)" \
     -configuration Debug CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
     -derivedDataPath /tmp/DerivedData-Primae 2>&1 | tail -30
   ```

4. **strokes.json validation** (works anywhere with python3):
   ```bash
   python3 -c "import json, pathlib; [json.loads(f.read_text()) for f in pathlib.Path('PrimaeNative/Resources/Letters').rglob('strokes.json')]; print('All strokes.json valid')"
   ```

5. **CI status**:
   ```bash
   gh run list --repo TheDave94/Primae --limit 3
   ```

## Study builds

A **study build** compiles the non-study surfaces out and defaults `studyMode`
ON (B2).

**`STUDY_BUILD` is unconditional as of 2026-09-14** — defined directly in
`Package.swift`'s `swiftSettings` for both the `PrimaeNative` and
`PrimaeNativeTests` targets, not gated on any build setting or command-line
flag. Every build of the package IS a study build now, full stop; see "STUDY_BUILD
made unconditional" below "The casual path is paused" for the reasoning, what
this took with it, and why the OLDER mechanism (an xcodebuild command-line
override, because a project-level `SWIFT_ACTIVE_COMPILATION_CONDITIONS` never
reached this SwiftPM package target — measured, spike `ed055db`) is now
historical, not current. `scripts/build_study.sh` remains the blessed way to
produce a device/CI build non-interactively (it still picks the right scheme,
configuration, derived-data path, and prints the toolchain version) — it is
no longer the *only* way a build can carry STUDY_BUILD, which is the whole
point: Xcode's own ⌘R now works too.

**Two configurations, and they are not interchangeable:**

| | `Debug-Study` | `Release-Study` |
|---|---|---|
| Purpose | simulator + CI | **the pilot artefact** |
| Optimisation | `-Onone` | `-O` |
| `#if DEBUG` surfaces | compiled IN | compiled out |
| `ENABLE_TESTABILITY` | YES | NO |

`Debug-Study` is a DEBUG build. Do **not** put it on a child's iPad: `DEBUG` is
defined, so every `#if DEBUG` surface ships. (One of those was a live numeric
accuracy readout on the child-facing tracing canvas — now additionally gated on
`!STUDY_BUILD`, but the general hazard stands.)

**Producing the pilot artefact on a physical iPad** — a deliberate LOCAL act,
never automated. Requires an unlocked, connected iPad:

```bash
PRIMAE_CONFIGURATION=Release-Study \
PRIMAE_CODE_SIGNING=YES \
PRIMAE_DESTINATION='platform=iOS,name=<iPad name>' \
PRIMAE_DERIVED_DATA=/tmp/dd-pilot \
  scripts/build_study.sh build -allowProvisioningUpdates
```

Then verify the artefact rather than trusting the label — the identity is a
link-enforced symbol, so this is a fact the linker had to agree with:

```bash
nm -jU /tmp/dd-pilot/Build/Products/Release-Study-iphoneos/Primae.app/Primae \
  | grep primae_build_identity
# must print _primae_build_identity_study, and nothing else
```

**Pressing ⌘R on the `Primae` scheme (Debug-Study configuration) now
produces a study build (2026-09-14).** This was NOT true before that date —
it used to fail at link time on the missing `_primae_build_identity_study`
symbol, because the package needed the flag and Xcode's UI had no channel to
supply it. There is exactly one scheme now, named `Primae` — the OLD `Primae`
scheme (which built the casual Debug/Release configuration) was deleted, and
`Primae-Study` was renamed to `Primae` to take its place; a leftover second
scheme naming a distinction that no longer exists failed at link on a symbol
that no longer exists, which reads as a broken project rather than a retired
scheme, and cost a real debugging round trip the same day it was found. If
anything still says `Primae-Study`, that scheme doesn't exist anymore — fix
the reference, don't recreate the scheme. See "STUDY_BUILD made unconditional"
below for what changed and why. The identity symbols themselves are
unaffected: every configuration still names its own
`_primae_build_identity_{study,normal}` via `-u`, so `nm`
still attests which binary you're holding — what changed is only how
STUDY_BUILD reaches the package, not what the identity guard verifies once
it's there.

**Installing it.** `build_study.sh` only builds — it does not push the result
onto a device. Locate the iPad and install the *verified* `.app` (verify
before install, not after — the `nm` check above is the only way to know
which binary you're holding, and it's useless once it's already on the
home screen):

```bash
xcrun devicectl list devices   # note the target iPad's UDID from the listing
UDID=REPLACE_WITH_UDID_FROM_PREVIOUS_COMMAND
xcrun devicectl device install app --device "$UDID" \
  /tmp/dd-pilot/Build/Products/Release-Study-iphoneos/Primae.app
```

**If `devicectl`/Device Hub sit stuck establishing the tunnel, or the
device never reaches `available (paired)` — root cause found and closed
2026-09-16, recorded here so the next seat doesn't lose an afternoon to
it. An earlier version of this note named `pkill remoted` as the fix;
that masked the symptom rather than fixing it and has been replaced
below, not left alongside it.**

**Root cause: `CoreDeviceService` caches a stale tunnel address in the
device's own published record.** The CoreDevice tunnel to a USB-connected
device is a real, working link-local-IPv6 interface (`utun5`, MTU 16000,
in the confirming session) — but the address CoreDeviceService hands out
in the device record it publishes to every consumer (`devicectl`'s State
column, Device Hub, Xcode's run-destination picker) can drift out of sync
with the tunnel's actual live address. Every one of those consumers reads
the stale record, tries to dial an address with no route in the table at
all, and reports the device unreachable — `devicectl device info details`
hangs for exactly this reason, dialling nowhere. The device is fine, the
cable is fine; the daemon is holding a wrong address for its own tunnel.

**Diagnostic that identifies it** — compare the daemon's own
`tunnelIPAddressString` (visible via `devicectl device info details
--json-output -` or `devicectl list devices --json-output -`, per-device,
under the connection properties) against what the interface is actually
using:
```bash
ifconfig | grep -A3 "^utun"        # find the CoreDevice tunnel (large MTU, e.g. 16000) and its live address
netstat -rn -f inet6 | grep utun   # confirm whether a route exists for the CACHED address's /64 at all
```
If the cached `tunnelIPAddressString` has no matching route and doesn't
match the live `ifconfig` address on the large-MTU `utun*` interface,
that mismatch — not the cable, not the device — is the fault.

**Fix, run on the Mac** (not from a sandboxed Claude Code seat — killing
a system daemon needs a real, unsandboxed terminal):
```bash
sudo pkill -f CoreDeviceService
```
This resolved it for David's iPad on 2026-09-16 — device went from
unreachable in every consumer to `connected` immediately after, and
simulators for an unrelated project that were also mis-registering
recovered at the same moment — same cache, same daemon, same fault.

**Environment worth knowing, since it's plausibly relevant to how the
address gets confused in the first place, not just decoration:** this
estate has nine other `utun` interfaces up at once from Tailscale and
Proton VPN — confirmed independently the same day (`ifconfig` on this
machine: ten `utun` interfaces total, of which the CoreDevice tunnel is
one; a Tailscale-shaped `100.64.0.0/10` address on another). The
CoreDevice tunnel itself installs a **default route** (also confirmed
independently: `netstat -rn` shows `default ... utun5`), into a routing
table already carrying several other VPN-installed default routes. A
crowded, competing default-route environment is a plausible contributor
to an allocator handing out or caching the wrong address; it is not
proven to be the mechanism, only named as present and worth ruling in or
out if this recurs.

**Standing hazard, kept for the separate, still-real reason it names:**
per Apple TN3158, Xcode reaches a USB-connected device over link-local
IPv6 in the first place. A VPN doing packet filtering, or configured with
`includeAllNetworks`, can block that traffic outright — a different
failure shape than the stale-cache one above (no address to be stale;
the tunnel never comes up at all), but indistinguishable from it by
symptom alone unless you check both. If the `pkill` above doesn't clear
a stuck session, try again with the VPN fully disconnected, not just
split-tunneled, before assuming a hardware or cable fault.

**On-device distinctness (2026-09-07).** The study build ships under its own
bundle identifier, display name, and icon — `com.flamingistan.primae.study` /
"Primae Studie" / `AppIcon-Study` (amber, role-swapped accent dot, a navy
"STUDIE" ribbon; same design for the light and dark appearances on purpose,
so the signal doesn't depend on the device's appearance setting) — set on the
app target's `Debug-Study`/`Release-Study` configurations only, distinct from
`com.flamingistan.primae` / "Primae" / `AppIcon` on `Debug`/`Release`. This
was NOT true before that date: all four configurations shared one bundle ID,
so a study build silently replaced whatever Primae build was already on the
device, same icon, same name, nothing on the home screen to tell them apart —
found when David asked how to install the study build and it became clear
`nm` (a pre-install, terminal-only check) was the only way to know which one
a device was running. Coexistence, not just detectability, was the point: a
distinct bundle ID means the two can be installed side by side and never
overwrite each other, and — as a side effect — the entire `UserDefaults`
store is separately sandboxed per bundle ID by iOS regardless of the
`de.flamingistan.primae.*` key-prefix strings used internally, so a study
install can never inherit or contaminate a casual install's state.
`ios-build.yml`'s identity-scan step now asserts `CFBundleIdentifier` and
`CFBundleDisplayName` differ between the two built bundles' OWN generated
`Info.plist` (not the pbxproj source — a build setting that never reached the
plist protects nobody) and fails the build if they don't; `CFBundleIconName`
is checked the same way when present, best-effort.

**The App Group question this split raised — CLOSED, measured, 2026-09-11.**
Splitting the bundle identifier means Study and Casual now get separate iOS
sandboxes (separate `UserDefaults`, separate Application Support) with no
implicit sharing between them. The question was whether anything in Primae
depended on that implicit sharing and would silently break once it was gone —
answer: no. Measured directly, not assumed: no `.entitlements` file exists
anywhere in the repo (`find . -iname "*.entitlements"`), no
`CODE_SIGN_ENTITLEMENTS` or `com.apple.security.application-groups` capability
in `project.pbxproj`, no `UserDefaults(suiteName:)` call anywhere in
`PrimaeNative`/`Primae`, and no
`containerURL(forSecurityApplicationGroupIdentifier:)` call either — there was
never a shared container for the split to cut off. No App Group is needed now
or after the split. Full isolation between Study and Casual is also the
correct end state on its own terms, independent of whether anything would
have broken: a study instrument should not read or write the casual app's
data.

**Same question, asked of every other identity-scoped resource — also CLOSED,
same pass.** App Groups are one of several iOS mechanisms scoped to a bundle
identifier (or a keychain-access-group derived from it); a split that's safe
for one isn't automatically safe for the others. Checked directly: no
Keychain usage anywhere (`Keychain`/`kSecClass`/`SecItem`, zero hits) —
nothing to have a keychain-access-group collide or split on. No remote push
(`registerForRemoteNotifications`, `aps-environment`, zero hits) — the one
notification hit in the repo (`LocalNotificationScheduler.swift`) is
`UNUserNotificationCenter` for **local**, not remote, notifications, which are
sandboxed per bundle ID with no entitlement and nothing to reconfigure. No
CloudKit, no Sign in with Apple, no `UIBackgroundModes` or
`com.apple.developer.*` capability of any kind in `project.pbxproj`. The
bundle-ID split has no other identity-scoped surface to have broken.

### The casual path is paused, on this same line, not on a branch (2026-09-13)

**Decision, with the pilot running (a participant was being enrolled when this
was made):** the casual `Debug`/`Release` configuration stops being built,
tested, or reasoned about — not deleted, paused. `STUDY_BUILD` is the only
configuration this repo actively maintains from here until a deliberate,
post-thesis restoration. No separate branch was created for this.

**Why not a branch, judged rather than assumed.** A branch only reduces
dual-build reasoning if it *also* drops the casual configs to get any
simplification — at which point it's the identical subtraction made here,
plus a cost this line doesn't have: two diverging histories to reconcile at
cherry-pick time instead of one paused line to additively restore. If it
*keeps* both configs to stay mergeable, it hasn't removed any reasoning at
all, just relocated it. A branch also makes CI branch-aware (a real fork —
one more place to get the branch wrong) and adds a second thing a future
session can confuse for the first — a demonstrated failure mode on this
project already (the 2026-09-08/11 credential and pbxproj-editing incidents),
not a hypothetical one.

**What actually changed, in `ios-build.yml`'s `study_build` job:**
- **Removed:** "CONTROL B — Debug WITH the flag must FAIL to link" (existed
  to prove the casual configuration's own identity-symbol integrity — no
  longer a thing being maintained) and "Build the normal build for
  comparison" (built `Debug` solely so the identity/surfaces scan had
  something to diff against).
- **Kept:** CONTROL A (proves `STUDY_BUILD` reaching the package requires
  `build_study.sh`'s command-line override, not a property of the casual
  build at all — orthogonal to this decision) and the pilot-artefact build.
- **Rewritten:** the identity-scan step now asserts everything about the
  STUDY bundle alone — its own identity symbol present and the `normal` one
  absent, the compiled-out `SURFACES` list absent, `CFBundleIdentifier` /
  `CFBundleDisplayName` equal to the expected literal constants — instead of
  diffing against a normal bundle that no longer gets built. The
  vacuity-guard the old SURFACES check had ("missing from normal too" catches
  a renamed symbol silently passing) is gone with it — an accepted,
  documented reduction in coverage, not a silent one.
- **Untouched, deliberately, as of 2026-09-13 — superseded 2026-09-14, see
  below:** the main `xcode_test` job kept building and testing under plain
  `Debug` at the time this decision was made. That is no longer current; see
  the next section for what changed and why the "may not even compile"
  concern below did not hold up once it was actually checked.

### STUDY_BUILD made unconditional (2026-09-14) — the deliberate next step above, taken

David wanted to build and install from the Xcode UI rather than the
terminal; the `-u` identity guard correctly refused every Xcode-driven build,
because `STUDY_BUILD` only ever reached the package via `build_study.sh`'s
command-line override, which the Xcode UI has no way to supply (spike
`ed055db`). The reframe that unblocked this: with the casual path paused,
there is exactly one configuration worth building, so the question was not
"how does Xcode supply the flag" but "should this still be a flag at all."

**Measured before changing anything, not assumed:**
- Every symbol `STUDY_BUILD` compiles out of the package (the
  `ios-build.yml` `SURFACES` list, plus the `AppWorld.werkstatt`/`.fortschritte`
  cases and several other view types found by a full sweep of the package's
  25 `#if STUDY_BUILD` files) — checked against every file in
  `PrimaeNativeTests`. Exactly one hit: `StrokeCalibrationOverlay`, referenced
  only inside `StrokeCalibrationOverlayHelpersTests.swift`, which is ALREADY
  wrapped in `#if !STUDY_BUILD` at the file level (compiles to nothing under
  the flag; its own header says so). The other three test files that already
  reference `STUDY_BUILD` (`IsCalibratingStudyBuildTests`, `StudyBuildTests`,
  `TogglePersistenceTests`) are already written per-branch (`#if STUDY_BUILD
  ... #else ... #endif`) asserting the correct behaviour either way.
- No test file constructs a bare, unpinned `TracingDependencies()` or
  `TracingViewModel()` that would pick up `StudyBuild.resolveStudyMode()`'s
  compile-time-driven default — every VM-building test goes through `.stub`
  (which pins `studyMode: false` explicitly) or an explicit
  `.with(studyMode:)` override. The "12 of 72 test files... may not even
  compile" concern recorded in the superseded bullet above did not hold up:
  it was a reasonable precaution at the time, not something that had been
  checked, and a full measurement now says otherwise.
- The REAL, structural cost was a different one, found by checking the
  linker requirement, not the test contents: `Debug`/`Release` (the casual
  configuration) names `-u _primae_build_identity_normal`, and the package
  can no longer produce that symbol once `STUDY_BUILD` is unconditional (it
  only ever compiles the `study` half of that identity pair now). This
  means the casual configuration **cannot link at all anymore** — a step
  further than "paused" (CI stopped exercising it) to "structurally
  unbuildable" (nothing can link it, on purpose, matching "the casual path
  is paused" taken to its conclusion now that there is genuinely one
  configuration). This is why `xcode_test` could not stay on plain `Debug`.

**What changed:**
- `Package.swift`: `.define("STUDY_BUILD")` added to both the
  `PrimaeNative` and `PrimaeNativeTests` targets' `swiftSettings`,
  unconditional — this is the actual mechanism now, not an xcodebuild flag.
- `scripts/build_study.sh`: the `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
  command-line override removed (redundant now, and misleading to leave —
  a future reader would reasonably conclude it's still the mechanism).
  Header rewritten to explain the current state; the script itself is
  otherwise unchanged and still the non-interactive path for device/CI
  builds.
- `ios-build.yml`: the main `xcode_test` job moved from `-configuration
  Debug` to `-configuration Debug-Study` — the one configuration that
  still links. `CONTROL A` ("Debug-Study without the flag must FAIL to
  link") removed from the `study_build` job: its entire premise — that a
  flagless Debug-Study build was constructible and had to be shown
  failing — stopped being true, so keeping it would have asserted nothing
  (a "guard" against a state that can no longer be reached is not a
  weaker guard, it's an inert one). The identity/SURFACES scan in that
  same job is untouched and still does real work: it verifies the
  SHIPPED artefact's actual composition, which is independent of how the
  flag reached the package.
- Verified by a real CI round-trip (not assumed): all five `ios-build.yml`
  jobs green on the changed workflow, including the full `Debug-Study`
  test run under the new scheme/configuration.

**Same-day follow-up: the scheme itself, not just the configuration, had
the same problem.** The fix above still passed `-scheme Primae-Study` (the
scheme that already pointed at Debug-Study/Release-Study) everywhere — it
did NOT touch the separate, older `Primae` scheme, whose Launch/Test/
Profile/Archive actions still pointed at the now-unlinkable Debug/Release.
That scheme is the one David actually had selected, and pressing Run on it
failed at link on `_primae_build_identity_normal` — a symbol that no
longer exists, so it read as a broken project rather than a retired
configuration. A stale scheme name left in a doc, or a habit of picking
the "wrong" one, would have kept recreating this. Fixed by collapsing to
one scheme rather than by telling David to remember which of two to pick:
the old `Primae` scheme was deleted, and `Primae-Study` was renamed to
`Primae`. Every reference to `-scheme Primae-Study` in this repo
(`build_study.sh`, `ios-build.yml`, this file, `ROADMAP.md`,
`StudyBuild.swift`'s header comment) was updated to `Primae`. Verified by
the thing that actually failed, not by a script build: `ios-build.yml`
now has a dedicated CI step ("Scheme-driven build, no -configuration
override") that builds `-scheme Primae` with NO `-configuration` flag —
exactly what Xcode's Run button does — and confirms via `nm` that it
resolves to the study identity.

**What this does NOT change:** the identity-symbol guard itself
(`_primae_build_identity_{study,normal}`, `-u`-required per app
configuration, `nm`-verifiable) is untouched — it still exists, still
enforces that Debug-Study/Release-Study can only link against the study
half. What changed is purely how `STUDY_BUILD` reaches the *package*; the
guard survives exactly as designed, and now has nothing left to catch
Xcode's UI doing wrong, because there is no longer a wrong way to reach it
from there.

### ⚠️ The pilot artefact is built by a toolchain CI does not exercise

This workstation runs **Xcode 27 beta**; `ios-build.yml` pins **Xcode 26.4** on
`macos-26`. A device build made here is therefore compiled by a compiler no CI
job has ever run. That gap matters more than usual for `Release-Study`, because
it is the only `-O` build in the project and `-O` + `-default-isolation MainActor`
is the exact configuration of the known inliner crash swiftlang/swift#88173
(ROADMAP F11).

Until a toolchain pin lands (see ROADMAP F11), **record the toolchain with the
artefact** — `build_study.sh` prints `xcodebuild -version` on every run, so
capture that output alongside the build. A pilot binary whose compiler version
is unknown is not a reproducible artefact, and the thesis will be asked which
one built it.

## Credentials and the ELEVENLABS_API_KEY pattern

*Based on `/opt/autocoder/CREDENTIAL_CONVENTIONS_TEMPLATE.md` (canonical), adapted for this repo.*

This repo has exactly one credential surface: the `ELEVENLABS_API_KEY` used by `scripts/generate_letter_audio.py` and `scripts/generate_prompts.py`. **No `.env.local`** — the key is entered manually each session, not persisted. The rationale is workflow-shaped: audio generation is a deliberate, paid, low-frequency act ("I am consciously about to spend money") and removing the manual gate would dull that signal.

**Preferred entry pattern** (avoids bash-history leak):

```bash
read -s -p "ELEVENLABS_API_KEY: " ELEVENLABS_API_KEY && export ELEVENLABS_API_KEY
python3 scripts/generate_letter_audio.py …
```

`read -s` suppresses terminal echo; the value enters the shell as an env var without ever landing in `~/.bash_history`. Do **not** use the older `export ELEVENLABS_API_KEY=…<value>…` pattern — that writes the literal value into history, where it persists until rotation.

**Rotation.** `/opt/autocoder/ROTATION_RUNBOOK.md` covers the ElevenLabs key under "manual, not on disk." If a session inadvertently used the `export FOO=…` antipattern, rotate the key.

**`.gitignore`** already covers `.env` and `.env.*` (excluding `.env.example`) — no change needed here.

## DO NOT
- Do NOT modify `AudioEngine.swift` — it is stable and fragile
- Do NOT introduce new dependencies or frameworks
- Do NOT change `.swiftLanguageMode(.v5)` in the test target
- Do NOT change `.defaultIsolation(MainActor.self)` in the main target
- Do NOT modify the strokes.json coordinate format
- Do NOT modify `StrokeTracker.swift` unless the task explicitly targets it
- Do NOT use `UIColor(dynamicProvider:)` for design tokens — under Swift 6 default isolation the closure inherits MainActor and traps when SwiftUI samples it from `com.apple.SwiftUI.AsyncRenderer`. Design tokens go through Asset-Catalog colorsets (see `Primae/Primae/Assets.xcassets/Colors/` + `scripts/gen_colorsets.py`), which iOS resolves per trait collection without invoking any Swift code.
- Do NOT register an Xcode MCP bridge while the study configuration is frozen — see ROADMAP F12 for the reasoning and the conditions for revisiting it post-pilot.

## Conventions
- All new views go in `Features/Tracing/` unless they're core infrastructure
- Use existing protocols (AudioControlling, ProgressStoring) — don't create parallel interfaces
- Animations use SwiftUI `.transition()` and `withAnimation {}`
- Debug features gated on `vm.showDebug`
- German UI text (the app is for German-speaking children)
- Child-facing screens (Schule / Werkstatt / Fortschritte / Onboarding / overlays during practice) must work via icons + animation + TTS, not text — the target audience is 5–6 yr-old Volksschule 1. Klasse children who can't or barely read. Text is fine for parent-area screens (Settings, ParentDashboard, ResearchDashboard, Datenexport).
- Design tokens: read from `PrimaeNative/Theme/{Colors, Radii, Fonts}.swift`. Color values are auto-flipping light/dark via `Color("name")` (Asset-Catalog colorsets); fonts via `Font.display(_:weight:)` / `Font.body(_:weight:)` / `Font.cursive(_:)`. The picker for the appearance override lives in the parent area as "Erscheinungsbild" (System / Hell / Dunkel).
- Run `git config core.quotePath false` in every fresh clone. 35 of the ~500 tracked paths carry umlauts (`PrimaeNative/Resources/Letters/F/Föhn.mp3`, `.../Regular/Ä/strokes.json`, …); under git's default `quotePath=true` those come back octal-escaped and double-quoted (`"…/F\303\266hn.mp3"`), so any instrument that greps or diffs tracked paths silently drops exactly the letter assets that matter. This setting lives in `.git/config`, which is untracked — a fresh clone does NOT inherit it, which is why it is written down here.

## Visual sweep workflow

For any geometric or visual question with finite candidate options or a single tunable parameter, default to **render-and-compare BEFORE proposing or committing a specific construction**.

Workflow:
1. Identify candidate constructions or parameter values (4-6 typically; include current `main` as the baseline column).
2. Implement each, bake the target letters.
3. Compute sweep-renderer gauges (overshoot, reversal, max-turn — see `docs/BAKE_INVARIANTS.md` §3) per candidate. Gauges are diagnostic, not ship gates; the bake itself writes output regardless. A candidate that fails a gauge gets a labelled `SKIPPED` cell in the sweep grid for visual comparison; it does NOT auto-reject from being shippable.
4. Render PNGs of all candidates through the bake pipeline at iPad-equivalent style (dark ink ~#2D3748, red polyline ~#E53E3E).
5. Build a contact-sheet grid (rows = letters, columns = candidates) at `/tmp/sweep/grid.png`.
6. Present to David. Wait for selection.
7. Set chosen value, bake, commit, push as a **single** commit.

Numeric gates filter; visual judgment decides. Don't write prose arguments about which candidate is "correct" — let the grid speak.

This applies to: joint construction parameters, arm strategy choice, anchor placement values, curve-fit primitive selection, and any other geometric question where multiple constructions are plausible.

Primitives are registered in `scripts/generate_strokes_auto.py`:
- `ARM_STRATEGIES`: `chord`, `bfs_raw`, `lsq_line`, `smoothed_medial_axis`
- `JOINT_STRATEGIES`: `sharp`, `family_a_fillet`, `quadratic_bezier_at_V`, `cubic_bezier_clamped`
- `DEFAULT_ARM_STRATEGY` / `DEFAULT_JOINT_STRATEGY` control the line-kind default; sweep via per-spec `"arms"` / `"joints"` overrides, not by mutating the defaults.
