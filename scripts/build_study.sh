#!/bin/sh
# build_study.sh — the blessed way to produce a Primae study build.
#
# STUDY_BUILD is unconditional in Package.swift (2026-09-14) — every
# build of the PrimaeNative package IS a study build now, including one
# driven from the Xcode UI (⌘R on the Primae scheme, Debug-Study
# configuration, now genuinely works — see CLAUDE.md "Study builds").
# That was NOT always true: a project-level SWIFT_ACTIVE_COMPILATION_
# CONDITIONS reaches the app target but never reached this SwiftPM
# package target (measured, spike ed055db — app=ON / package=OFF), so
# until this date the flag could only arrive as an xcodebuild COMMAND-
# LINE override, which Xcode's own UI has no way to supply — hence this
# script existing at all, and hence ⌘R used to fail at link time on the
# missing `_primae_build_identity_study` symbol. That specific failure
# mode is gone; this script survives it as the convenient, scriptable,
# non-interactive path (device installs, CI, the Release-Study pilot
# artefact), not as the ONLY path anymore.
#
# There is exactly one scheme now, named "Primae" (2026-09-14) — the
# OLD "Primae" scheme built the casual Debug/Release configuration,
# which can no longer link at all once STUDY_BUILD is unconditional
# (it demanded `_primae_build_identity_normal`, a symbol the package
# can no longer produce), so it was deleted rather than left as a
# scheme that fails every time someone picks it. "Primae-Study" was
# renamed to "Primae" to take its place — a second scheme naming a
# distinction that no longer exists was worse than inert, it read as a
# broken project. If a doc or a habit still says "Primae-Study", that
# scheme no longer exists.
#
# The identity-symbol pair (`_primae_build_identity_{study,normal}`,
# `-u`-required per configuration, in StudyBuild.swift) is unaffected by
# any of this — it still proves which binary you're holding via `nm`,
# still guards Debug-Study/Release-Study from linking the wrong half.
# What changed is only how STUDY_BUILD reaches the package, not what the
# identity guard does once it's there.
#
# Usage:
#   scripts/build_study.sh build  [extra xcodebuild args...]
#   scripts/build_study.sh test   [extra xcodebuild args...]
#
# Env:
#   PRIMAE_CONFIGURATION  Debug-Study (default) or Release-Study
#   PRIMAE_DESTINATION    xcodebuild -destination (default: generic simulator)
#   PRIMAE_DERIVED_DATA   -derivedDataPath       (default: /tmp/DerivedData-Primae-Study)
#   PRIMAE_CODE_SIGNING   NO (default, simulator) or YES (device)
#
# THE PILOT ARTEFACT is Release-Study on a device. Debug-Study is a DEBUG
# build: `#if DEBUG` surfaces are compiled IN, -Onone, ENABLE_TESTABILITY.
# It is for the simulator and for CI, not for a child's iPad. The full
# device procedure — including which toolchain it must be pinned to, and
# why that matters — is in CLAUDE.md under "Study builds".
set -eu

ACTION="${1:-build}"
[ $# -gt 0 ] && shift

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION="${PRIMAE_CONFIGURATION:-Debug-Study}"
DESTINATION="${PRIMAE_DESTINATION:-generic/platform=iOS Simulator}"
DERIVED="${PRIMAE_DERIVED_DATA:-/tmp/DerivedData-Primae-Study}"
SIGNING="${PRIMAE_CODE_SIGNING:-NO}"

case "$CONFIGURATION" in
    Debug-Study|Release-Study) ;;
    *) echo "FATAL: PRIMAE_CONFIGURATION must be Debug-Study or Release-Study (got '$CONFIGURATION')" >&2
       exit 1 ;;
esac

# Record what was actually built. A study binary whose provenance is a
# shell history entry is not a provenance.
echo "build_study.sh: action=$ACTION configuration=$CONFIGURATION signing=$SIGNING"
echo "build_study.sh: destination=$DESTINATION"
echo "build_study.sh: xcodebuild=$(xcodebuild -version | tr '\n' ' ')"

# No SWIFT_ACTIVE_COMPILATION_CONDITIONS override here (removed
# 2026-09-14) — STUDY_BUILD is unconditional in Package.swift now, so
# passing it again on the command line would be a redundant no-op, and
# a future reader finding it here would reasonably conclude it's still
# the mechanism, which it no longer is.
exec xcodebuild "$ACTION" \
    -project "$ROOT/Primae/Primae.xcodeproj" \
    -scheme Primae \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED="$SIGNING" \
    ENABLE_DEBUG_DYLIB=NO \
    "$@"
