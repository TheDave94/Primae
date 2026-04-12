# iOS Council — Lessons from failed proposals

### no-code-payload
The proposer sometimes outputs analysis with no Swift code. This always fails.
Every response must contain complete, compilable Swift code.

### @MainActor missing on ObservableObject
Every class with @Published properties must be @MainActor.
Forgetting this causes Swift 6 compile failures.

### Bare Task { } closures
Task { } closures are non-isolated by default. For @MainActor-isolated classes,
direct calls are already safe — do NOT wrap them in Task { @MainActor in }.
Only use Task { @MainActor in } for truly non-isolated contexts (e.g. callbacks
from background threads). Adding it to already-@MainActor functions causes race
conditions with debounce logic.

### showGhost regression
showGhost must reset to false when currentLetterName changes via nextLetter()/
prevLetter()/randomLetter(). Any proposal touching TracingViewModel must verify this.

### XCTestExpectation overuse
Use Swift Testing (#expect, #require, async @Test) for new tests.
XCTestExpectation is only acceptable for callback-based APIs that cannot be async.

### New files / new packages
Only modify existing files. Do not create new Swift files or add SPM packages
without explicit human approval.

### Do not migrate existing XCTest to Swift Testing
Existing XCTest files must stay as XCTest. Only new test code should use Swift Testing.
Do not mix @Test and XCTestCase in the same file.

### Do not migrate ObservableObject to @Observable
Existing ObservableObject types must stay as-is unless explicitly asked.
New types should use @Observable, but never migrate existing ones unprompted.

### Never modify .github/workflows/
CI workflow files are infrastructure, not application code.
Any proposal that modifies .github/workflows/ must be rejected.
The council does not have permission to change CI configuration.
Invalid actions syntax changes break all future runs — deprecations are handled by Dependabot PRs.

### CRITICAL: load(letter:) must be synchronous
load(letter:) in TracingViewModel MUST call audio.loadAudioFile and setPlaybackState
synchronously — NEVER inside a Task { } or Task { @MainActor in } wrapper.
The function is already @MainActor isolated. Adding a Task wrapper creates a race
condition where the async Task fires after updateTouch queues a 30ms debounce,
resetting playback state and causing playCount == 0 in tests.
Any proposal that wraps calls in load(letter:) inside a Task must be REJECTED.

### OSLog-Logger-has-no-shared
Logger from OSLog does NOT have a `.shared` singleton. Never use `Logger.shared`.
Always instantiate with `Logger(subsystem: "BuchstabenNative", category: "...")` or
keep `print()` for debug output. Any proposal using `Logger.shared` must be REJECTED.

## CRITICAL: ci_fix runaway (2026-03-23)
- ci_fix pushed 20 bad commits overnight because it kept seeing CI as failing
- Root cause 1: `_ci_status` returned the latest run regardless of commit SHA — all running tasks saw the same failing run
- Root cause 2: `check_pending_ci` had multiple tasks in `running` state simultaneously
- Root cause 3: ci_fix had no limit on how many commits it would push per episode
- LESSON: Never allow more than 1 task in `running` state at a time for iOS
- LESSON: Always match CI run to commit SHA, not just latest run
- LESSON: ci_fix must stop after MAX_ATTEMPTS even if CI is still failing

## CRITICAL: AudioEngine.swift is fragile (2026-03-23)
- ci_fix repeatedly broke AudioEngine.swift with malformed Swift (missing `{` after catch, extraneous `}`)
- This file has complex AVAudioSession/AVAudioEngine setup that is easy to break
- LESSON: AudioEngine.swift changes must be minimal and surgical — never rewrite catch blocks
- LESSON: If CI fails on AudioEngine.swift syntax errors, REVERT rather than attempt further fixes
- LESSON: ci_fix should stop after 2 failed attempts on the same file and alert instead

## AudioEngine.swift — deinit (2026-03-23, fixed 2026-03-27)
- ✅ FIXED: deinit now uses `nonisolated deinit { Self.removeObservers(for: self) }` — correct Swift 6 pattern
- ✅ FIXED: observer store uses static dict keyed by ObjectIdentifier — avoids @MainActor isolation in deinit
- DO NOT add conformances, refactor catch blocks, or restructure init/deinit in this file

## Tests must match actual implementation behavior (2026-03-23)
- AutoCoder added a test expecting `.strict` tier after promotion+demotion but the actual policy returns `.standard`
- LESSON: When adding tests, first READ the implementation to understand what it actually does
- LESSON: Never write tests that assert a behavior you haven't verified exists in the code
- LESSON: Test coverage tasks should add tests that PASS against the current implementation, not tests that describe desired future behavior

### No-op SEARCH/REPLACE blocks waste apply attempts
- AutoCoder generated blocks 4+5 that were identical SEARCH and REPLACE (no actual change)
- LESSON: Never generate a SEARCH/REPLACE block where the content is identical — if nothing changes, omit the block entirely
- LESSON: The deep-dive audit blocks for StrokeTracker were unnecessary since Progress: Sendable and @MainActor were already correct

### CRITICAL: Never replace hypot() with distSq in StrokeTracker
In `StrokeTracker.update()`, the line `let dist = hypot(dx, dy)` must NEVER be
replaced with `let distSq = dx*dx + dy*dy`. Although mathematically equivalent,
this change breaks `fastVelocity_triggersPlayAfterDebounce` and `fastTouch_triggersPlay`
CI tests because the fast drag test path does not hit checkpoints under the squared
comparison. This optimization was tried and reverted twice — do not attempt again.

### CRITICAL: git revert can truncate files — always verify closing braces
A `git revert --no-commit` of multiple commits that touched the same file
(StrokeTracker.swift) left the file missing its closing `}` class brace.
The SWIFT_TYPECHECK_FAIL gate caught syntax errors but not missing EOF braces
because the file was syntactically ambiguous (missing `}` is only caught at build time).
LESSON: After any revert operation, verify Swift files end with `}` before pushing.
LESSON: The ci_fix job must check for truncated files (file ends mid-class) before committing.
LESSON: Never chain multiple reverts on the same file in one `git revert --no-commit` call.

### identical-search-replace-no-op
<!-- added by lessons-agent 2026-04-12 -->
Do not propose SEARCH/REPLACE blocks where SEARCH and REPLACE content are identical. This occurs repeatedly in AudioEngine.swift and StrokeTracker.swift when the AI misreads existing code or tries to 'fix' already-correct lines. Each such proposal wastes apply attempts and creates noise. Always verify the SEARCH content differs from REPLACE before proposing.

### wrong-method-modification
<!-- added by lessons-agent 2026-04-12 -->
When tasked to modify a specific method (e.g., setPlaybackState(_:immediate:) in TracingViewModel), ensure changes are made to that exact method, not a different one. Multiple proposals incorrectly modified unrelated methods because the AI mislocated the target. Always double-check the method signature matches the task description before writing SEARCH/REPLACE blocks.

### audioengine-init-cast-typo-fixes
<!-- added by lessons-agent 2026-04-12 -->
Stop attempting to 'fix' optional casts in AudioEngine.swift's interruptionTask/routeChangeTask. Tasks requesting replacements like `(as? UInt)` vs `as? UInt` or adding `self.` prefixes to already-correct lines have failed repeatedly because the code is already correct. AudioEngine.swift's notification handlers are stable; do not propose syntactic tweaks to these lines unless there is a clear compile error.

### speculative-ci-fix-without-logs
<!-- added by lessons-agent 2026-04-12 -->
When tasked to 'Fix CI build failure', never propose changes without analyzing actual error logs. Multiple proposals guessed at missing braces or added redundant showGhost resets, failing because they didn't address the root cause. If logs are unavailable, state that analysis is impossible rather than guessing. Only propose fixes when you can see the specific error message.

### streakstore-json-wiring-failures
<!-- added by lessons-agent 2026-04-12 -->
Wiring JSONStreakStore into TracingDependencies has repeatedly caused SWIFT_TYPECHECK_FAIL due to extraneous braces or mismatched SEARCH blocks. This is an architectural integration that requires careful coordination across files. Future attempts must be preceded by a manual audit of TracingDependencies.swift and StreakStore.swift to understand the correct injection pattern.
