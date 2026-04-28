#!/usr/bin/env bash
set -euo pipefail

REPO="/opt/repos/Buchstaben-Lernen-App"
cd "$REPO"

echo "═══════════════════════════════════════════════════════"
echo "  iOS Code Review Council — $(date)"
echo "═══════════════════════════════════════════════════════"

# ─────────────────────────────────────────────────────────
# AGENT 1: Architecture & Code Quality Critic
# ─────────────────────────────────────────────────────────
echo ""
echo "🏗️  [1/5] Architecture & Code Quality Critic..."

cat << 'PROMPT1' | claude -p --dangerously-skip-permissions --model claude-sonnet-4-6 --output-format text > /tmp/council-review-1.md
You are a senior iOS architect reviewing this codebase for structural problems. Read CLAUDE.md first, then the full directory tree, then read every Swift file.

Write your findings as Markdown. Focus ONLY on:

1. **TracingViewModel audit**: Count lines, @Published properties, responsibilities. Is it a God object? What should be extracted? Any properties set but never observed? Any methods >50 lines?

2. **Dependency graph**: What creates TracingViewModel, TracingDependencies, stores? Is dependency injection consistent? Any circular dependencies?

3. **Dead code**: Files never imported, methods never called, commented-out blocks, deprecated code still present (old ContentView?).

4. **State consistency**: Can any combination of @Published vars be contradictory? Can enum switches be non-exhaustive? Can the app get into an impossible state?

5. **Protocol conformance**: Are protocols used consistently? Any protocol methods with default implementations that hide bugs?

For each finding, rate: 🔴 CRITICAL 🟡 WARNING 🟢 INFO
Provide exact file paths and line numbers.
PROMPT1
echo "  ✅ Architecture review complete"

# ─────────────────────────────────────────────────────────
# AGENT 2: Safety & Crash Risk Auditor
# ─────────────────────────────────────────────────────────
echo ""
echo "🛡️  [2/5] Safety & Crash Risk Auditor..."

cat << 'PROMPT2' | claude -p --dangerously-skip-permissions --model claude-sonnet-4-6 --output-format text > /tmp/council-review-2.md
You are a safety auditor looking for crash risks, data loss, and concurrency bugs. Read every Swift file in this codebase.

Write your findings as Markdown. Focus ONLY on:

1. **Force-unwrap audit**: Find EVERY instance of !, try!, as!, force array indexing like [0] without bounds check. For each: can it crash? Under what input? Provide the exact fix.

2. **Concurrency audit**: Find every Task { }, async/await, DispatchQueue, @MainActor. Are @Published vars ever set from background threads? Any data races? Is CoreML inference properly dispatched?

3. **Memory audit**: Check closures in views for retain cycles (especially [weak self] in structs, which is wrong). Is freeWritePath cleared properly? Can any array grow unbounded? Is the CoreML model cached or loaded per-inference?

4. **Persistence robustness**: What happens if ProgressStore JSON is corrupted? Missing fields from schema changes? First launch with no data? Disk write failures? Is there schema versioning?

5. **Edge cases**: 0 letters loaded, 0 strokes, 0 checkpoints, empty freeWritePath, nil recognition result, missing ML model, missing font file, missing strokes.json.

For each finding, rate: 🔴 CRITICAL 🟡 WARNING 🟢 INFO
Provide exact file paths and line numbers. For 🔴 items, provide the EXACT fix code.
PROMPT2
echo "  ✅ Safety review complete"

# ─────────────────────────────────────────────────────────
# AGENT 3: Scientific Methods & Thesis Accuracy Reviewer
# ─────────────────────────────────────────────────────────
echo ""
echo "📚  [3/5] Scientific Methods & Thesis Accuracy Reviewer..."

cat << 'PROMPT3' | claude -p --dangerously-skip-permissions --model claude-sonnet-4-6 --output-format text > /tmp/council-review-3.md
You are a research methodology reviewer checking that scientific implementations match their cited papers. Read every Swift file in this codebase.

Write your findings as Markdown. For EACH scientific method below, verify the implementation is correct and complete:

1. **Gradual Release of Responsibility** (Pearson & Gallagher 1983): Does the 4-phase model (observe→direct→guided→freeWrite) properly implement I Do→We Do→You Do? Is the direct phase a valid addition?

2. **Guidance Hypothesis / Fading Feedback** (Schmidt & Lee 2005): Does feedbackIntensity actually reduce feedback across phases? Are ALL feedback channels gated (haptics, audio, visual)? Is freeWrite truly feedback-free during tracing?

3. **Knowledge of Performance** (Danna & Velay 2015): Does the KP overlay show process-level feedback? Is it in the right coordinate space? Does it actually compare child's path vs reference?

4. **Fréchet Distance** (Alt & Godau 1995): Is the algorithm mathematically correct? Edge cases: single point, empty path, very short stroke? Does normalization affect accuracy?

5. **Schreibmotorik 4 Dimensions** (Marquardt & Söhl 2016): Do ALL four dimensions (formAccuracy, tempoConsistency, pressureControl, rhythmScore) produce meaningful scores? Does tempoConsistency handle <3 data points? Does rhythmScore handle long pauses? Do weights sum to 1.0?

6. **Spaced Repetition** (Ebbinghaus 1885, Cepeda 2006): Does LetterScheduler actually use recency decay? Does it differentiate between letters at different mastery levels?

7. **Adaptive Difficulty** (Vygotsky ZPD): Does MovingAverageAdaptationPolicy have actual hysteresis? Does it adjust meaningfully?

8. **Letter Recognition** (EMNIST/Sedlmeyr CNN): Does renderToImage match training data format (white-on-black, 40×40)? Does ConfidenceCalibrator help or hurt? Are confusable pairs complete?

9. **A/B Testing** (ThesisCondition): Does .control actually disable ALL adaptive features? Are both conditions collecting the same data columns? Can condition assignment change mid-study?

10. **Speed/Automatization** (KMK 2024): Does strokesPerSecond measure the right thing? Is speedTrend capped? Does LetterScheduler actually use it?

For each: ✅ CORRECT / ⚠️ PARTIALLY CORRECT (explain gap) / ❌ INCORRECT (explain bug)
Include code snippets showing the actual implementation.
PROMPT3
echo "  ✅ Scientific review complete"

# ─────────────────────────────────────────────────────────
# AGENT 4: UX & Polish Reviewer
# ─────────────────────────────────────────────────────────
echo ""
echo "🎨  [4/5] UX & Polish Reviewer..."

cat << 'PROMPT4' | claude -p --dangerously-skip-permissions --model claude-sonnet-4-6 --output-format text > /tmp/council-review-4.md
You are a UX reviewer for a children's educational iPad app. Read every SwiftUI view file in this codebase.

Write your findings as Markdown. Focus ONLY on:

1. **German language quality**: Find EVERY user-facing string. Any English leaking through? Any typos? Any terms that are German-German instead of Austrian-German? List every string that needs fixing.

2. **Accessibility**: Does EVERY interactive element have an accessibilityLabel? Are labels in German? Does VoiceOver navigation order make logical sense for each screen? Are all touch targets ≥44pt?

3. **Overlay timing**: Are the KP overlay (3s), recognition badge (4s), celebration (2s) appropriate? Can they stack/overlap? Does auto-dismiss work correctly or can it block interaction?

4. **Settings effectiveness**: When you change SchriftArt, does the letter re-render immediately? When you change letter ordering, does the picker update? When you toggle paper transfer, does it take effect on the next letter? Test each setting path in code.

5. **Error states**: What does the user see when: no letters loaded, ML model missing, recognition fails, ProgressStore corrupt, first launch? Is there graceful degradation or blank screens?

6. **Visual consistency**: Are colors used consistently? Are font sizes appropriate for 5-6 year olds? Are animations smooth or jarring? Any hardcoded colors that should use semantic colors?

7. **Word list**: Is the freeform word list appropriate for Austrian 1st graders? Any words that are too hard? Any missing common words?

For each finding, rate: 🔴 CRITICAL 🟡 WARNING 🟢 INFO
PROMPT4
echo "  ✅ UX review complete"

# ─────────────────────────────────────────────────────────
# AGENT 5: Synthesis & Improvement Proposals
# ─────────────────────────────────────────────────────────
echo ""
echo "🔄  [5/5] Council Synthesis Agent..."

cat << PROMPT5 | claude -p --dangerously-skip-permissions --model claude-sonnet-4-6 --output-format text > /tmp/council-review-synthesis.md
You are the council synthesis agent. Read the following four review reports, then read the actual codebase to verify findings. Produce a single, authoritative document.

=== ARCHITECTURE REVIEW ===
$(cat /tmp/council-review-1.md)

=== SAFETY REVIEW ===
$(cat /tmp/council-review-2.md)

=== SCIENTIFIC METHODS REVIEW ===
$(cat /tmp/council-review-3.md)

=== UX REVIEW ===
$(cat /tmp/council-review-4.md)

Your job:
1. Cross-reference findings. Remove duplicates. Resolve contradictions by reading the actual code.
2. Produce a SINGLE Markdown document with:

## Summary Table
| # | Severity | Category | Finding | File(s) | Fix |
Sort by severity: 🔴 first, then 🟡, then 🟢

## Detailed Findings
For each finding: description, evidence (code snippet), impact, exact fix.

## Improvement Proposals (NO new features — only improve existing)
For each proposal: what's wrong now, what should change, which files, estimated effort (S/M/L), impact on thesis.

Prioritize improvements that:
- Fix crashes or data loss (🔴)
- Improve thesis data accuracy (📝)
- Make existing features more robust
- Clean up code without changing behavior

Do NOT propose new features. Only improve what exists.

3. Save as REVIEW_AND_IMPROVEMENTS.md in the repo root.
4. Apply ALL 🔴 fixes directly to the code.
5. Verify compilation with: xcodebuild build -project BuchstabenApp/BuchstabenApp.xcodeproj -scheme BuchstabenApp -destination "platform=iOS Simulator,name=iPad (A16)" -configuration Debug CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO -derivedDataPath /tmp/DerivedData-BuchstabenApp 2>&1 | tail -20
6. If compilation succeeds, commit:
   git add REVIEW_AND_IMPROVEMENTS.md && git commit -m "docs: council code review — architecture, safety, scientific, UX"
   git add -A && git commit -m "fix: apply all critical fixes from council review"
   git push origin main
PROMPT5

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Council Review Complete — $(date)"
echo "  Reports: /tmp/council-review-{1,2,3,4}.md"
echo "  Synthesis: /tmp/council-review-synthesis.md"
echo "  Final doc: REVIEW_AND_IMPROVEMENTS.md"
echo "═══════════════════════════════════════════════════════"
