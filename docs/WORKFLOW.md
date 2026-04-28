# WORKFLOW.md — Skill Routing & Delivery Flow

This project uses a skill-first workflow for iOS development and release operations.

## Core Routing Map

### 1) Build / test / compile failures
- Primary: `xcodebuildmcp`
- Secondary: `swift-expert`
- Flow: reproduce -> parse -> patch -> re-run

### 2) Swift / SwiftUI implementation and refactors
- Primary: `swift-expert`
- Secondary: `pr-reviewer`
- Flow: plan -> implement -> review pass

### 3) UI / UX improvement work
- Primary: `ui-audit`
- Secondary: `swift-expert`
- Flow: audit friction -> propose deltas -> implement -> validate

### 4) Performance optimization
- Primary: `instruments-profiling`
- Secondary: `swift-expert`
- Flow: profile -> isolate bottleneck -> optimize -> verify

### 5) Security and dependency hygiene
- Primary: `security-audit-toolkit`
- Secondary: built-in `healthcheck` when host-level hardening is involved
- Flow: scan -> prioritize findings -> remediate

### 6) PR quality gate (before merge)
- Primary: `pr-reviewer`
- Secondary: `swift-expert`
- Flow: quality/risk review -> fixups -> final signoff notes

### 7) Release preparation
- Primary: `release-manager`
- Secondary: `pr-reviewer` + `security-audit-toolkit`
- Flow: release notes -> checklist -> risk pass -> ship

---

## Default Execution Loops

### Feature loop
1. `swift-expert` (code quality)
2. `ui-audit` (if user-facing)
3. `pr-reviewer` (pre-merge)
4. `release-manager` (milestone packaging)

### Bugfix loop
1. `xcodebuildmcp` (reproduce/fix compile/runtime issue)
2. `swift-expert` (safe patch)
3. `pr-reviewer` (regression check)

### Perf loop
1. `instruments-profiling`
2. `swift-expert`
3. `pr-reviewer`

---

## Operating Rules

- Always keep `main` stable.
- Do implementation work on feature branches.
- Commit in small, reviewable chunks.
- Prefer measurable UX outcomes over cosmetic-only changes.
- If blocked by environment/auth, report immediately with exact unblock command.

