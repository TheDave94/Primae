# Buchstaben App — Project Constraints

## What this app is
A classroom app for teaching German letters to children through letter tracing.
Used by multiple children / in classroom settings.

## The ONE feature that was actually planned
Letter tracing with visual guidance — a child traces a letter on screen and
gets visual feedback on whether they are following the correct stroke path.

## What is IN scope
- The tracing canvas and stroke guidance
- Audio pronunciation of letters
- Basic per-session progress (which letters were practiced today)
- Bug fixes and test coverage for existing features

## What is OUT of scope — never propose these
- VoiceOver / accessibility features (not needed for this use case)
- Gesture controls beyond basic tracing
- Offline data persistence / complex local storage
- ParentDashboard or data export
- AudioEngine pre-warming, pooling, or advanced audio architecture
- Adaptive difficulty algorithms
- Stroke replay / ghost animation beyond what already exists
- Any feature that requires a backend or server
- Any feature that was not explicitly requested by the project owner

## Hard rules for the council
- Only propose changes to files that already exist in the repo.
- Do not add new Swift packages or external dependencies without flagging for human approval.
- Do not expand the feature surface. Bug fixes and quality improvements only
  unless the project owner explicitly adds a feature to this file.
- Every proposal must state which existing file it modifies and why.
