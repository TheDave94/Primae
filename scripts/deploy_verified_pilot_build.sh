#!/bin/sh
# deploy_verified_pilot_build.sh — the ONE command that puts a
# provenance-attributable pilot build on the iPad.
#
# WHY THIS EXISTS (supervisor ruling, 2026-09-15). A device listen against
# a binary nobody can attribute to a commit is worthless, and worse if it
# passes: this session found the working tree carrying unrelated,
# uncommitted Xcode rewrites (an iOS 27 deployment-target bump, a reverted
# landscape lock, a reverted study/casual display-name split) at least
# twice, at times a build could plausibly have been running from that
# exact tree. If the iPad's current install came from one of those trees,
# nothing observed on it is evidence of anything.
#
# This script:
#   1. refuses to build from anything but a clean, fully-committed tree
#   2. finds the connected iPad itself — no UDID to copy/paste, no
#      placeholder to fill in
#   3. builds the pilot artefact (Release-Study, -O, code-signed)
#   4. verifies the build identity BEFORE installing (the only reliable
#      proof of which binary you're holding — CLAUDE.md "Study builds")
#   5. installs it
#   6. prints exactly which commit is now on the device
#
# That printout is the provenance record for the listen. Any earlier
# install is superseded the moment this script succeeds.
#
# RUN THIS FROM YOUR OWN TERMINAL. Claude Code's sandboxed seat cannot
# reach device discovery at all — `xcrun devicectl` times out waiting on
# CoreDeviceService, `xcrun xctrace` hits a cache-permission error before
# it can even try. Steps 3-5 below (the build/verify/install machinery)
# reuse scripts/build_study.sh and the nm-nm identity check verbatim from
# the documented, previously-run-by-hand pilot procedure (CLAUDE.md
# "Study builds"). Step 2 (device discovery) is new and has NOT been run
# against a real device from any seat — its parsing logic was tested here
# against a hand-built sample matching `xcrun xctrace list devices`'
# documented output shape, not against this machine's real output, which
# this sandbox cannot produce. If it prints "could not parse device
# listing" below, paste the raw output it dumps back and it gets fixed in
# one pass, not re-derived from scratch.
#
# Usage: scripts/deploy_verified_pilot_build.sh
# Requires: unlocked, connected iPad, and only that one iOS device
# attached; -allowProvisioningUpdates signing (matches the documented
# pilot-artefact procedure).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

echo "=== 1/5 verifying the source tree is clean and committed ==="
DIRTY=$(git status --porcelain)
if [ -n "$DIRTY" ]; then
    echo "FATAL: working tree is not clean. A build from here has no" >&2
    echo "provenance — it cannot be attributed to a commit. git status:" >&2
    echo "$DIRTY" >&2
    echo "" >&2
    echo "Fix: commit, stash, or discard the changes above, then re-run." >&2
    exit 1
fi
COMMIT_SHA=$(git rev-parse HEAD)
COMMIT_SHORT=$(git rev-parse --short HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
echo "ok — clean tree at $COMMIT_SHORT ($BRANCH)"

echo ""
echo "=== 2/5 finding the connected iPad ==="
RAW_DEVICES=$(xcrun xctrace list devices 2>&1 || true)
UDID=$(printf '%s\n' "$RAW_DEVICES" | python3 - <<'PY'
import re, sys

UDID_RE = re.compile(r"\(([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})\)\s*$")

def find_candidates(raw: str):
    in_devices = False
    candidates = []
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped == "== Devices ==":
            in_devices = True
            continue
        if stripped.startswith("=="):
            in_devices = False
            continue
        if not in_devices or not stripped:
            continue
        if stripped.startswith("My Mac"):
            continue
        m = UDID_RE.search(stripped)
        if m:
            candidates.append((m.group(1), stripped))
    return candidates

raw = sys.stdin.read()
candidates = find_candidates(raw)
if len(candidates) == 0:
    print("NONE", file=sys.stderr)
    sys.exit(1)
if len(candidates) > 1:
    print("AMBIGUOUS", file=sys.stderr)
    for udid, line in candidates:
        print(f"  {line}", file=sys.stderr)
    sys.exit(1)
print(candidates[0][0])
PY
) || {
    rc=$?
    echo "FATAL: could not identify exactly one connected iPad (exit $rc)." >&2
    echo "" >&2
    echo "Raw 'xcrun xctrace list devices' output, for diagnosis:" >&2
    echo "$RAW_DEVICES" >&2
    echo "" >&2
    echo "If nothing above looks wrong: connect and unlock the target" >&2
    echo "iPad, with no other iOS device attached, and re-run. If the" >&2
    echo "output above looks reasonable but this still failed, paste it" >&2
    echo "back — the parser needs a one-line fix, not a re-derivation." >&2
    exit 1
}
echo "ok — found device UDID: $UDID"

echo ""
echo "=== 3/5 building the pilot artefact (Release-Study, -O) ==="
DERIVED=/tmp/dd-pilot-verified
rm -rf "$DERIVED"
PRIMAE_CONFIGURATION=Release-Study \
PRIMAE_CODE_SIGNING=YES \
PRIMAE_DESTINATION="platform=iOS,id=$UDID" \
PRIMAE_DERIVED_DATA="$DERIVED" \
    "$ROOT/scripts/build_study.sh" build -allowProvisioningUpdates

APP="$DERIVED/Build/Products/Release-Study-iphoneos/Primae.app"
if [ ! -d "$APP" ]; then
    echo "FATAL: build did not produce $APP" >&2
    exit 1
fi

echo ""
echo "=== 4/5 verifying build identity before install ==="
IDENTITY=$(nm -jU "$APP/Primae" 2>/dev/null | grep -x "_primae_build_identity_study" || true)
if [ -z "$IDENTITY" ]; then
    echo "FATAL: $APP/Primae does not carry _primae_build_identity_study." >&2
    echo "Refusing to install a binary that failed its own identity check." >&2
    exit 1
fi
echo "ok — _primae_build_identity_study confirmed present"

echo ""
echo "=== 5/5 installing ==="
xcrun devicectl device install app --device "$UDID" "$APP"

echo ""
echo "================================================================"
echo " INSTALLED — provenance record for the listen"
echo "================================================================"
echo " commit:     $COMMIT_SHA"
echo " branch:     $BRANCH"
echo " device:     $UDID"
echo " identity:   _primae_build_identity_study (verified before install)"
echo " installed:  $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "================================================================"
echo ""
echo "Any earlier install on this device is superseded — treat it as void."
