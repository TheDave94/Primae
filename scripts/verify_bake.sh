#!/usr/bin/env bash
# verify_bake.sh — determinism + byte-identity check for the stroke bake
# (docs/APP_DOCUMENTATION.md §13.6).
#
# STATUS (audit 2026-10-13, G3-02): NOT APPLICABLE TO THE SHIPPED CORPUS.
# Every one of the 59 Regular letters is in generate_strokes_auto.py's
# SHIPPED_AS_STATIC_ARTIFACT (the corpus is produced by the iPad
# calibrator + scripts/calibration_to_override.py, not by the bake), and
# main() skips every static letter. So there is nothing for this script
# to bake, and until now it reported "FAIL — bake errored" for that reason
# on every run: a check that could never pass, which reads as a broken
# build rather than as a retired one. It now says what is true and exits
# with a DISTINCT code instead of pretending:
#
#   0  every requested letter was baked 3x, bakes identical, matches HEAD
#   1  a check ran and FAILED (bake errored / non-deterministic / drift)
#   2  not applicable: no requested letter is bakeable (all are static
#      artifacts), or the letter tables could not be read
#
# Exit 2 is deliberately non-zero: a caller that wanted a green "the bake
# is verified" must not get one from a script that verified nothing.
#
# The checks below the preflight are UNCHANGED and only reachable for a
# letter that is in LETTERS but not static. They are unexercised against
# the committed corpus, and byte-identity vs HEAD would additionally need
# the bake's output format to match the corpus's (committed files end in a
# newline and carry checkpointRadius 0.1; the bake writes neither) -- see
# G3-02. Do not read a future "All checks passed." as covering the
# shipped strokes.json files.
#
# Usage:
#   ./scripts/verify_bake.sh                # all bakeable letters in LETTERS
#   ./scripts/verify_bake.sh M N V W b      # subset (static ones are dropped)
#
# Only Regular is verified here; Light is tracked separately when its
# tuning sweep lands.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

REQUESTED=("$@")

# Preflight: which requested letters can the bake produce at all? Read the
# two tables with the standard library only (no numpy/PIL needed), so this
# answers on any machine.
BAKEABLE=$(python3 -I - ${REQUESTED[@]+"${REQUESTED[@]}"} <<'PY'
import ast, sys
tree = ast.parse(open("scripts/generate_strokes_auto.py", encoding="utf-8").read())
letters = static = None
for node in tree.body:
    if isinstance(node, ast.AnnAssign):
        target, value = node.target, node.value
    elif isinstance(node, ast.Assign) and len(node.targets) == 1:
        target, value = node.targets[0], node.value
    else:
        continue
    if not isinstance(target, ast.Name):
        continue
    if target.id == "LETTERS" and isinstance(value, ast.Dict):
        letters = [k.value for k in value.keys if isinstance(k, ast.Constant)]
    elif target.id == "SHIPPED_AS_STATIC_ARTIFACT" and isinstance(value, ast.Call):
        static = set(ast.literal_eval(value.args[0]))
if letters is None or static is None:
    sys.exit(3)
requested = sys.argv[1:] or letters
print("\n".join(l for l in requested if l not in static))
PY
) || {
    echo "NOT APPLICABLE — could not read LETTERS / SHIPPED_AS_STATIC_ARTIFACT from scripts/generate_strokes_auto.py" >&2
    exit 2
}

if [[ -z "$BAKEABLE" ]]; then
    echo "NOT APPLICABLE — nothing to verify: every requested letter is in SHIPPED_AS_STATIC_ARTIFACT." >&2
    echo "The committed strokes.json corpus comes from the iPad calibrator, not from the bake," >&2
    echo "so this script verified NOTHING (exit 2, not a pass). See the header; audit G3-01/G3-02." >&2
    exit 2
fi
LETTERS=()
while IFS= read -r l; do LETTERS+=("$l"); done <<< "$BAKEABLE"

# Only now (past the preflight) is a scratch directory needed.
TMP=$(mktemp -d -t primae-verify-bake-XXXXXX)
trap 'rm -rf "$TMP"' EXIT

run_bake() {
    local out_dir="$1"
    mkdir -p "$out_dir"
    python3 scripts/generate_strokes_auto.py "${LETTERS[@]}" \
        --weight regular --out "$out_dir" >/dev/null 2>"$TMP/bake.err" || {
        echo "FAIL — bake errored:" >&2
        cat "$TMP/bake.err" >&2
        exit 1
    }
}

hashes_for() {
    # Hash every strokes.json under the given root, normalised by
    # letter-folder name so the three bakes can be compared.
    find "$1" -name strokes.json -print0 \
        | sort -z \
        | xargs -0 sha256sum \
        | sed "s|$1/||" \
        | sort
}

echo "Bake 1/3 → $TMP/bake1"
run_bake "$TMP/bake1"
echo "Bake 2/3 → $TMP/bake2"
run_bake "$TMP/bake2"
echo "Bake 3/3 → $TMP/bake3"
run_bake "$TMP/bake3"

H1=$(hashes_for "$TMP/bake1")
H2=$(hashes_for "$TMP/bake2")
H3=$(hashes_for "$TMP/bake3")

if [[ "$H1" != "$H2" ]] || [[ "$H1" != "$H3" ]]; then
    echo "FAIL — determinism check: 3 successive bakes diverged" >&2
    diff <(echo "$H1") <(echo "$H2") | head -20 >&2 || true
    exit 1
fi
echo "PASS — determinism: 3 bakes byte-identical"

# Restrict HEAD comparison to the folders the bake actually produced.
# Bake output paths are Regular/<letter>/strokes.json.
BAKED_FOLDERS=$(find "$TMP/bake1" -name strokes.json -printf '%h\n' \
    | sed "s|$TMP/bake1/||" | sort -u)
HEAD_HASHES=$(hashes_for "PrimaeNative/Resources/Letters")
HEAD_HASHES=$(echo "$HEAD_HASHES" | awk -v folders="$BAKED_FOLDERS" '
    BEGIN { split(folders, a, "\n"); for (i in a) keep[a[i]] = 1 }
    {
        folder = $2
        sub(/\/strokes\.json$/, "", folder)
        if (folder in keep) print
    }
')

if ! diff -q <(echo "$HEAD_HASHES") <(echo "$H1") >/dev/null; then
    echo "FAIL — byte-identity vs HEAD: bake diverged from checked-in strokes.json" >&2
    echo "Divergent letters:" >&2
    diff <(echo "$HEAD_HASHES") <(echo "$H1") | head -40 >&2 || true
    exit 1
fi
echo "PASS — byte-identity: bake matches HEAD for every letter"

# Lowercase-b firewall: explicitly assert b_l/strokes.json is unchanged.
# Redundant with byte-identity above, but called out separately so a
# failure log names the firewall directly.
B_HEAD_PATH="PrimaeNative/Resources/Letters/Regular/b_l/strokes.json"
B_BAKE_PATH="$TMP/bake1/Regular/b_l/strokes.json"
B_HEAD=$(sha256sum "$B_HEAD_PATH" | awk '{print $1}')
B_BAKE=$(sha256sum "$B_BAKE_PATH" 2>/dev/null | awk '{print $1}' || echo "(no b in bake)")
if [[ "$B_HEAD" != "$B_BAKE" ]] && [[ "$B_BAKE" != "(no b in bake)" ]]; then
    echo "FAIL — b firewall: b_l/strokes.json diverged from commit a803d9d" >&2
    exit 1
fi
echo "PASS — b firewall: b_l/strokes.json is unchanged"

echo ""
echo "All checks passed."
