#!/bin/sh
# check_toolchain_pin.sh — make bin/toolchain.pin something that is READ.
#
# R-114 (audit 2026-10-13, G2-15): bin/toolchain.pin describes itself as "ONE
# place, read by everything", and nothing parsed it. This script is the verify
# leg: it reads `major:` from the pin, compares it with the major of the
# `xcodebuild` that is actually first on PATH, prints the exact build, and
# fails when the majors differ.
#
# Usage:
#   scripts/check_toolchain_pin.sh                  check the active xcodebuild
#   scripts/check_toolchain_pin.sh APP_PATH       ALSO print DTXcodeBuild /
#                                                   DTSDKBuild from the built
#                                                   app's Info.plist
#
# The pin is by MAJOR on purpose (it cannot tell 27.0 from 27.2), so the exact
# build is PRINTED here for the caller to record next to the artefact. Pin =
# what we accept; build stamp = what actually ran.
#
# Exit: 0 major matches; 1 mismatch / pin unreadable / xcodebuild unusable.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PIN="$ROOT/bin/toolchain.pin"

if [ ! -f "$PIN" ]; then
    echo "check_toolchain_pin: FATAL: $PIN not found" >&2
    exit 1
fi
PIN_MAJOR=$(sed -n 's/^major:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$PIN" | head -1)
if [ -z "$PIN_MAJOR" ]; then
    echo "check_toolchain_pin: FATAL: no 'major: N' line in $PIN" >&2
    exit 1
fi

# A28 (audit SURF-4): the pin's other two lines were never read. Compare them
# with what actually names them, before looking at the local Xcode.
RUNNER_LABEL=$(sed -n 's/^runner_label:[[:space:]]*\([^[:space:]]*\)[[:space:]]*$/\1/p' "$PIN" | head -1)
DEPLOY_TARGET=$(sed -n 's/^deployment_target:[[:space:]]*\([0-9][0-9.]*\)[[:space:]]*$/\1/p' "$PIN" | head -1)
if [ -z "$RUNNER_LABEL" ] || [ -z "$DEPLOY_TARGET" ]; then
    echo "check_toolchain_pin: FATAL: no 'runner_label:' / 'deployment_target:' line in $PIN" >&2
    exit 1
fi
PIN_RC=0
# Every non-ubuntu `runs-on:` (a macOS/Xcode image) must be the pinned label.
MAC_RUNS=$(cat "$ROOT"/.github/workflows/*.yml | sed -n 's/^[[:space:]]*runs-on:[[:space:]]*\([^[:space:]#]*\).*$/\1/p' | grep -v '^ubuntu' || true)
if [ -z "$MAC_RUNS" ]; then
    echo "check_toolchain_pin: FAIL: no non-ubuntu runs-on found in .github/workflows (expected $RUNNER_LABEL)" >&2
    PIN_RC=1
fi
for L in $MAC_RUNS; do
    if [ "$L" != "$RUNNER_LABEL" ]; then
        echo "check_toolchain_pin: FAIL: a workflow job runs on '$L', pin runner_label is '$RUNNER_LABEL'" >&2
        PIN_RC=1
    fi
done
# Every IPHONEOS_DEPLOYMENT_TARGET in the project must be the pinned target.
PBX="$ROOT/Primae/Primae.xcodeproj/project.pbxproj"
TARGETS=$(sed -n 's/.*IPHONEOS_DEPLOYMENT_TARGET[[:space:]]*=[[:space:]]*\([^;[:space:]]*\);.*/\1/p' "$PBX")
if [ -z "$TARGETS" ]; then
    echo "check_toolchain_pin: FAIL: no IPHONEOS_DEPLOYMENT_TARGET in $PBX" >&2
    PIN_RC=1
fi
for T in $TARGETS; do
    if [ "$T" != "$DEPLOY_TARGET" ]; then
        echo "check_toolchain_pin: FAIL: project IPHONEOS_DEPLOYMENT_TARGET '$T', pin deployment_target is '$DEPLOY_TARGET'" >&2
        PIN_RC=1
    fi
done
# Package.swift `.iOS(.vNN)` names the same major.
if ! grep -q "\.iOS(\.v${DEPLOY_TARGET%%.*})" "$ROOT/Package.swift"; then
    echo "check_toolchain_pin: FAIL: Package.swift has no .iOS(.v${DEPLOY_TARGET%%.*}) for deployment_target $DEPLOY_TARGET" >&2
    PIN_RC=1
fi
if [ "$PIN_RC" -ne 0 ]; then
    exit 1
fi
echo "check_toolchain_pin: runner_label=$RUNNER_LABEL deployment_target=$DEPLOY_TARGET agree with workflows, project and Package.swift"

VERSION_OUT=$(xcodebuild -version 2>&1) || {
    echo "check_toolchain_pin: FATAL: 'xcodebuild -version' failed:" >&2
    echo "$VERSION_OUT" >&2
    exit 1
}
ACTIVE_MAJOR=$(printf '%s\n' "$VERSION_OUT" | sed -n 's/^Xcode[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
if [ -z "$ACTIVE_MAJOR" ]; then
    echo "check_toolchain_pin: FATAL: could not read an 'Xcode N' line from:" >&2
    echo "$VERSION_OUT" >&2
    exit 1
fi

echo "check_toolchain_pin: xcodebuild=$(printf '%s' "$VERSION_OUT" | tr '\n' ' ')"
echo "check_toolchain_pin: pin major=$PIN_MAJOR active major=$ACTIVE_MAJOR"

if [ -n "${1:-}" ]; then
    PLIST="$1/Info.plist"
    if [ ! -f "$PLIST" ]; then
        echo "check_toolchain_pin: FATAL: $PLIST not found" >&2
        exit 1
    fi
    for K in DTXcode DTXcodeBuild DTSDKName DTSDKBuild; do
        V=$(plutil -extract "$K" raw -o - "$PLIST" 2>/dev/null || echo "ABSENT")
        echo "check_toolchain_pin: artefact $K=$V"
    done
fi

if [ "$PIN_MAJOR" != "$ACTIVE_MAJOR" ]; then
    echo "check_toolchain_pin: FATAL: active Xcode major $ACTIVE_MAJOR != pinned $PIN_MAJOR (bin/toolchain.pin)." >&2
    echo "Select the pinned Xcode (xcode-select / DEVELOPER_DIR); do NOT edit the pin to match." >&2
    exit 1
fi
echo "check_toolchain_pin: ok"
