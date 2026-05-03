
### dont-add-redundant-imports
<!-- added by lessons-agent 2026-05-03 -->
The AI repeatedly attempts to add `@testable import StrokeRecognizer` when it's already present. Before adding imports, verify their absence in the target file to avoid redundant declarations.

### verify-search-replace-difference
<!-- added by lessons-agent 2026-05-03 -->
The AI generated a `SEARCH/REPLACE` block where the old and new content were identical. Always ensure that the `REPLACE` section introduces a tangible change from the `SEARCH` section, otherwise the fix is a no-op.

### dont-redefine-production-types-in-tests
<!-- added by lessons-agent 2026-05-03 -->
The AI is attempting to fix compiler errors in test files by redefining production types or fundamental test dependencies (e.g., `EuclideanStrokeDistance`). This indicates a fundamental misunderstanding of the test's purpose or the project structure. Test fixes should leverage existing code, mock dependencies properly, or correct usage of production types, not redefine them.
