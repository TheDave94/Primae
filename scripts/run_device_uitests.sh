#!/bin/sh
# run_device_uitests.sh — Layer 4 (Device-XCUITest) driver.
#
# WHY THIS EXISTS. The CI four-layer split (ios-build.yml, top-of-file
# comment) narrowed the push-triggered `xcode_test` job to PrimaeNativeTests
# only: a simulator's software audio stack does not reproduce real
# AVAudioSession activation timing, so a green PrimaeUITests run on CI's
# simulator matrix is structurally incapable of proving the thing that
# matters most for this app and actively launders false confidence instead.
# PrimaeUITests still COMPILES on every push (xcode_test builds-for-testing
# the whole scheme; -only-testing: filters what RUNS, not what builds), so a
# Swift/API regression in the test code itself is still caught for free.
# Running the suite for real — against a real device, real hardware audio,
# real touch/pencil input — is this script's job, and it is deliberately
# NOT wired into ios-build.yml: GitHub's hosted runners have no iPad
# attached, and this needs one. Dispatch it by hand, periodically or before
# a pilot session, from whichever seat actually has device access.
#
# Usage:
#   xcrun devicectl list devices                  # find the target UDID
#   scripts/run_device_uitests.sh <UDID> [extra xcodebuild args...]
#
# Env:
#   PRIMAE_CONFIGURATION  Debug-Study (default) or Release-Study
#   PRIMAE_DERIVED_DATA   -derivedDataPath       (default: /tmp/DerivedData-Primae-DeviceUITests)
#
# Requires -allowProvisioningUpdates and an unlocked, connected iPad — same
# physical-device precondition as scripts/build_study.sh's pilot-artefact
# path (CLAUDE.md "Study builds"). Not automated, and never was.
set -eu

UDID="${1:-}"
if [ -z "$UDID" ]; then
    echo "FATAL: pass the target device's UDID (xcrun devicectl list devices)" >&2
    exit 1
fi
shift

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION="${PRIMAE_CONFIGURATION:-Debug-Study}"
DERIVED="${PRIMAE_DERIVED_DATA:-/tmp/DerivedData-Primae-DeviceUITests}"

case "$CONFIGURATION" in
    Debug-Study|Release-Study) ;;
    *) echo "FATAL: PRIMAE_CONFIGURATION must be Debug-Study or Release-Study (got '$CONFIGURATION')" >&2
       exit 1 ;;
esac

echo "run_device_uitests.sh: device=$UDID configuration=$CONFIGURATION"
echo "run_device_uitests.sh: xcodebuild=$(xcodebuild -version | tr '\n' ' ')"

exec xcodebuild test \
    -project "$ROOT/Primae/Primae.xcodeproj" \
    -scheme Primae \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS,id=$UDID" \
    -derivedDataPath "$DERIVED" \
    -only-testing:PrimaeUITests \
    -allowProvisioningUpdates \
    "$@"
