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

### Never modify .github/workflows/ files
- CI workflows are infrastructure, not application code
- Invalid actions syntax (upload-artifact@v3 → v3) breaks all future runs
- Deprecations are handled by Dependabot PRs, not manual edits

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

## AudioEngine.swift — known real bugs (2026-03-23)
- deinit calls `.invalidate()` on NSObjectProtocol — wrong method, should be NotificationCenter.default.removeObserver()
- @MainActor class deinit accesses stored properties — Swift 6 actor isolation violation
- DO NOT propose speculative improvements to AudioEngine.swift until these are fixed
- DO NOT add conformances, refactor catch blocks, or restructure init/deinit in this file
