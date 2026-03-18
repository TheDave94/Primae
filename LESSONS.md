# iOS Council — Lessons from failed proposals

### no-code-payload
The proposer sometimes outputs analysis with no Swift code. This always fails.
Every response must contain complete, compilable Swift code.

### @MainActor missing on ObservableObject
Every class with @Published properties must be @MainActor.
Forgetting this causes Swift 6 compile failures.

### Bare Task { } closures
Task { } closures are non-isolated by default. Any access to @MainActor state
requires Task { @MainActor in ... }. Most common compile error in this codebase.

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
