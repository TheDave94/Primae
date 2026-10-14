#!/bin/sh
# deploy_verified_pilot_build.sh — provenance-attributable pilot build,
# for a seat with no Xcode UI.
#
# NOT DAVID'S PATH (supervisor ruling, 2026-09-15, correcting an earlier
# version of this same ruling that handed him this script). David was
# explicit: the device path is Xcode's own Run button, not a Terminal
# script. The provenance requirement this script was built to satisfy —
# the binary on the iPad must be attributable to a commit — is now
# enforced from inside the build itself: the Primae scheme's own
# Pre-action (scripts/check_project_invariants.py --autofix,
# gate_provenance()) refuses the build when the tree can't be attributed
# and prints commit/branch/configuration into Xcode's own build log
# before anything installs. That is David's path; use it.
#
# This script still exists for a seat that has git and a shell but no
# Xcode UI to press Run in — CI-adjacent tooling, a headless build
# machine, or a future automated pilot-artefact pipeline. It is kept
# working and current, just not the thing to hand a person at a keyboard
# with Xcode open.
#
# WHY IT WAS BUILT (supervisor ruling, 2026-09-15, still the real
# problem this solves for a scriptable seat). A device listen against a
# binary nobody can attribute to a commit is worthless, and worse if it
# passes: this session found the working tree carrying unrelated,
# uncommitted Xcode rewrites (an iOS 27 deployment-target bump, a reverted
# landscape lock, a reverted study/casual display-name split) at least
# twice, at times a build could plausibly have been running from that
# exact tree. If the iPad's current install came from one of those trees,
# nothing observed on it is evidence of anything.
#
# This script:
#   1. refuses to build from anything but a clean, fully-committed tree
#      (and reports whether HEAD is reachable from origin/main)
#   2. finds the connected iPad itself via `devicectl list devices
#      --json-output` — no UDID to copy/paste, no placeholder to fill in
#   3. builds the pilot artefact (Release-Study, -O, code-signed)
#   4. verifies the build identity BEFORE installing (the only reliable
#      proof of which binary you're holding — CLAUDE.md "Study builds"),
#      checks the toolchain major against bin/toolchain.pin and records the
#      exact Xcode build and the binary's sha256
#   5. UNINSTALLS the previous install (behind an explicit confirmation —
#      it destroys every unexported child's data on the device), re-verifies
#      the sha256, then installs, then prints exactly which commit is now
#      on the device
#
# That printout is the provenance record for the listen.
#
# WHY THE UNINSTALL (R-058, audit 2026-10-13). An over-install preserves the
# app container — UserDefaults, Application Support/PrimaeNative progress,
# enrolment and archive — so participant IDs, arm assignment and archived
# children from an earlier (dry-run) install would ride into the pilot while
# the old record claimed the earlier install was void. CLAUDE.md's clean-slate
# sequence is uninstall, re-verify sha256 + nm, reinstall; this script now
# does exactly that. EXPORT FIRST: nothing is recoverable after the uninstall.
# Confirmation: type the bundle identifier at the prompt, or set
# PRIMAE_CONFIRM_WIPE to the bundle identifier for a non-interactive run.
# --first-install skips the uninstall (nothing is installed yet); it is an
# explicit statement by the operator, never inferred.
#
# STEP 2 HISTORY (R-058). Device discovery used to pipe `xctrace list
# devices` into `python3 - <<'PY'`; with a pipe AND a here-document the
# here-document wins stdin, so the listing was discarded and the script could
# never find an iPad. Parsing now lives in scripts/pilot_find_ipad.py, which
# takes the JSON file path as an argument. The JSON schema in it is written
# from devicectl's documented shape, NOT from a capture of the study iPad:
# if step 2 reports NONE with a device attached, the raw JSON is dumped for
# a one-line fix. scripts/test_deploy_verified_pilot_build.sh reproduces the
# stdin defect and pins the selection rules against stub devicectl output.
#
# RUN THIS FROM YOUR OWN TERMINAL (a sandboxed seat cannot reach device
# discovery reliably). Steps 3-4 reuse scripts/build_study.sh and the nm
# identity check from the documented pilot procedure (CLAUDE.md "Study builds").
#
# Usage:
#   scripts/deploy_verified_pilot_build.sh                 full run
#   scripts/deploy_verified_pilot_build.sh --first-install no uninstall step
#   scripts/deploy_verified_pilot_build.sh --find-device-only
#                                   step 2 only; prints the UDID and exits
#   scripts/deploy_verified_pilot_build.sh --confirm-wipe-only
#                                   the confirmation gate only (testing)
# Env:
#   PRIMAE_DEVICECTL       devicectl command (default: xcrun devicectl)
#   PRIMAE_CONFIRM_WIPE    the bundle identifier, to confirm the uninstall
# Requires: unlocked, connected iPad, and only that one iOS device
# attached; -allowProvisioningUpdates signing (matches the documented
# pilot-artefact procedure).
set -eu

BUNDLE_ID=com.flamingistan.primae.study
DEVICECTL="${PRIMAE_DEVICECTL:-xcrun devicectl}"

FIRST_INSTALL=0
MODE=full
for arg in "$@"; do
    case "$arg" in
        --first-install) FIRST_INSTALL=1 ;;
        --find-device-only) MODE=find ;;
        --confirm-wipe-only) MODE=confirm ;;
        *) echo "FATAL: unknown argument '$arg' (see header for usage)" >&2; exit 2 ;;
    esac
done

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# The wipe gate. Returns 0 only when the operator has named the bundle id,
# either via PRIMAE_CONFIRM_WIPE or by typing it at a terminal.
confirm_wipe() {
    echo "This UNINSTALLS $BUNDLE_ID from the device. Everything in its container"
    echo "(progress, enrolment, ParticipantArchive) is destroyed. Export first."
    if [ "${PRIMAE_CONFIRM_WIPE:-}" = "$BUNDLE_ID" ]; then
        echo "ok — PRIMAE_CONFIRM_WIPE matches; proceeding"
        return 0
    fi
    if [ -t 0 ]; then
        printf 'Type the bundle identifier (%s) to confirm: ' "$BUNDLE_ID"
        read -r typed || typed=""
        if [ "$typed" = "$BUNDLE_ID" ]; then
            return 0
        fi
        echo "FATAL: confirmation did not match; nothing was uninstalled." >&2
        return 1
    fi
    echo "FATAL: no terminal and PRIMAE_CONFIRM_WIPE is not set to $BUNDLE_ID;" >&2
    echo "nothing was uninstalled." >&2
    return 1
}

# Sets UDID, or prints a diagnosis and returns 1.
find_device() {
    DEVLIST=$(mktemp "${TMPDIR:-/tmp}/primae-devicectl-list.XXXXXX")
    # DEVICECTL is deliberately unquoted: it is a command with arguments.
    if ! $DEVICECTL list devices --json-output "$DEVLIST" >/dev/null 2>&1; then
        echo "FATAL: '$DEVICECTL list devices --json-output' failed." >&2
        rm -f "$DEVLIST"
        return 1
    fi
    rc=0
    UDID=$(python3 -I "$ROOT/scripts/pilot_find_ipad.py" "$DEVLIST") || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FATAL: could not identify exactly one connected iPad (exit $rc)." >&2
        echo "" >&2
        echo "Raw devicectl JSON, for diagnosis:" >&2
        cat "$DEVLIST" >&2
        echo "" >&2
        echo "Connect and unlock the target iPad, with no other iPad attached," >&2
        echo "and re-run. If the JSON above shows the iPad and this still" >&2
        echo "failed, scripts/pilot_find_ipad.py needs a one-line fix." >&2
        rm -f "$DEVLIST"
        return 1
    fi
    rm -f "$DEVLIST"
    return 0
}

if [ "$MODE" = confirm ]; then
    confirm_wipe
    exit $?
fi

if [ "$MODE" = find ]; then
    find_device || exit 1
    echo "$UDID"
    exit 0
fi

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
if git merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    ON_ORIGIN_MAIN=yes
    echo "ok — HEAD is reachable from origin/main"
else
    ON_ORIGIN_MAIN="NO (WARNING: this commit may exist nowhere but this clone, or origin/main is stale; git fetch)"
    echo "WARNING: HEAD is NOT reachable from origin/main (or origin/main is not fetched)." >&2
    echo "The installed binary would be attributed to a commit others may not be able to see." >&2
fi

echo ""
echo "=== 2/5 finding the connected iPad ==="
find_device || exit 1
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
TOOLCHAIN=$("$ROOT/scripts/check_toolchain_pin.sh" "$APP") || {
    echo "$TOOLCHAIN" >&2
    echo "FATAL: toolchain check failed; refusing to install." >&2
    exit 1
}
echo "$TOOLCHAIN"
SHA_BEFORE=$(shasum -a 256 "$APP/Primae" | cut -d' ' -f1)
echo "ok — binary sha256 $SHA_BEFORE"

echo ""
echo "=== 5/5 clean-slate install ==="
if [ "$FIRST_INSTALL" -eq 1 ]; then
    echo "--first-install given: skipping uninstall (operator states nothing is installed)"
    UNINSTALLED="skipped (--first-install)"
else
    confirm_wipe || exit 1
    $DEVICECTL device uninstall app --device "$UDID" "$BUNDLE_ID" || {
        echo "FATAL: uninstall failed. If nothing is installed yet, re-run with --first-install." >&2
        exit 1
    }
    UNINSTALLED=yes
fi
SHA_AFTER=$(shasum -a 256 "$APP/Primae" | cut -d' ' -f1)
if [ "$SHA_BEFORE" != "$SHA_AFTER" ]; then
    echo "FATAL: the binary changed between verification and install ($SHA_BEFORE -> $SHA_AFTER)." >&2
    exit 1
fi
$DEVICECTL device install app --device "$UDID" "$APP"

echo ""
echo "================================================================"
echo " INSTALLED — provenance record for the listen"
echo "================================================================"
echo " commit:         $COMMIT_SHA"
echo " branch:         $BRANCH"
echo " on origin/main: $ON_ORIGIN_MAIN"
echo " device:         $UDID"
echo " identity:       _primae_build_identity_study (verified before install)"
echo " binary sha256:  $SHA_AFTER"
echo " uninstalled:    $UNINSTALLED"
echo " installed:      $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo " toolchain:"
echo "$TOOLCHAIN" | sed 's/^/   /'
echo "================================================================"
