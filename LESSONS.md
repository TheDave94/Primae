
### dont-add-redundant-imports
<!-- added by lessons-agent 2026-05-03 -->
The AI repeatedly attempts to add `@testable import StrokeRecognizer` when it's already present. Before adding imports, verify their absence in the target file to avoid redundant declarations.

### verify-search-replace-difference
<!-- added by lessons-agent 2026-05-03 -->
The AI generated a `SEARCH/REPLACE` block where the old and new content were identical. Always ensure that the `REPLACE` section introduces a tangible change from the `SEARCH` section, otherwise the fix is a no-op.
