#!/usr/bin/env bash
# ios-council-batch.sh — Process iOS roadmap items sequentially via Claude Code
#
# Usage:
#   cd /opt/repos/Buchstaben-Lernen-App
#   bash ios-council-batch.sh

set -euo pipefail

REPO="/opt/repos/Buchstaben-Lernen-App"
ROADMAP="$REPO/IOS_ROADMAP.yaml"
LOG="$REPO/.council-log.txt"
DONE_FILE="$REPO/.council-done"

cd "$REPO"
touch "$DONE_FILE"

echo "═══════════════════════════════════════════════════════" | tee -a "$LOG"
echo "  iOS Council Batch — $(date)" | tee -a "$LOG"
echo "═══════════════════════════════════════════════════════" | tee -a "$LOG"

# Get pending item IDs in priority order using proper YAML parsing
ITEM_IDS=$(python3 -c "
import yaml
items = yaml.safe_load(open('$ROADMAP'))
pending = [i for i in items if i.get('status') == 'pending']
pending.sort(key=lambda x: -x.get('priority', 0))
for i in pending:
    print(i['id'])
")

if [ -z "$ITEM_IDS" ]; then
    echo "No pending items in roadmap." | tee -a "$LOG"
    exit 0
fi

TOTAL=$(echo "$ITEM_IDS" | wc -l | tr -d ' ')
CURRENT=0
SUCCEEDED=0
FAILED=0

while read -r ID; do
    CURRENT=$((CURRENT + 1))

    # Skip already completed
    if grep -q "^${ID}$" "$DONE_FILE" 2>/dev/null; then
        echo "[$CURRENT/$TOTAL] ⏭️  $ID: already done, skipping" | tee -a "$LOG"
        continue
    fi

    # Build prompt from YAML using Python (handles multiline safely)
    PROMPT_FILE=$(mktemp /tmp/council-prompt-XXXXXX.txt)
    python3 -c "
import yaml
items = yaml.safe_load(open('$ROADMAP'))
item = next(i for i in items if i['id'] == '$ID')
title = item['title']
desc = item.get('description', '').strip()
criteria = chr(10).join('- ' + c for c in item.get('acceptance_criteria', []))
files = ', '.join(item.get('target_files', []))
prompt = f'''Implement this roadmap item. After making changes, verify compilation by running:
xcodebuild build -project BuchstabenApp/BuchstabenApp.xcodeproj -scheme BuchstabenApp -destination \"platform=iOS Simulator,name=iPad (A16)\" -configuration Debug CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO -derivedDataPath /tmp/DerivedData-BuchstabenApp 2>&1 | tail -20

If compilation fails, fix the errors and try again. Do NOT commit if it does not compile.
If compilation succeeds, run: git add -A && git commit -m \"{item['id']}: {title}\"

[{item['id']}] {title}

{desc}

Acceptance criteria:
{criteria}

Target files: {files}'''
with open('$PROMPT_FILE', 'w') as f:
    f.write(prompt)
"

    TITLE=$(python3 -c "
import yaml
items = yaml.safe_load(open('$ROADMAP'))
item = next(i for i in items if i['id'] == '$ID')
print(item['title'])
")

    echo "" | tee -a "$LOG"
    echo "[$CURRENT/$TOTAL] 🚀 $ID: $TITLE" | tee -a "$LOG"
    echo "  Started: $(date)" | tee -a "$LOG"

    # Run Claude Code headless with prompt from file
    cat "$PROMPT_FILE" | claude -p --dangerously-skip-permissions --model claude-sonnet-4-6 2>&1 | tee -a "$LOG"
    rm -f "$PROMPT_FILE"

    # Check if a commit was made
    LAST_COMMIT=$(git log -1 --oneline 2>/dev/null || echo "")
    if echo "$LAST_COMMIT" | grep -q "$ID"; then
        echo "  ✅ $ID committed: $LAST_COMMIT" | tee -a "$LOG"
        echo "$ID" >> "$DONE_FILE"
        SUCCEEDED=$((SUCCEEDED + 1))
        git push origin main 2>&1 | tee -a "$LOG"
    else
        echo "  ❌ $ID: no commit detected" | tee -a "$LOG"
        FAILED=$((FAILED + 1))
        echo "  STOPPING — fix manually, then re-run this script." | tee -a "$LOG"
        echo "  Remaining: $((TOTAL - CURRENT)) items" | tee -a "$LOG"
        echo "Summary: $SUCCEEDED succeeded, $FAILED failed, $((TOTAL - CURRENT)) remaining" | tee -a "$LOG"
        exit 1
    fi

    echo "  Finished: $(date)" | tee -a "$LOG"
    sleep 5

done <<< "$ITEM_IDS"

echo "" | tee -a "$LOG"
echo "═══════════════════════════════════════════════════════" | tee -a "$LOG"
echo "  Complete: $SUCCEEDED/$TOTAL succeeded" | tee -a "$LOG"
echo "═══════════════════════════════════════════════════════" | tee -a "$LOG"
