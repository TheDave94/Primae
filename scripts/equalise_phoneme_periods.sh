#!/bin/sh
# usage: sh scripts/equalise_phoneme_periods.sh <in.wav> <out.wav> [--smooth s] [--protect s] [--max-db d]
# Builds the Mac tool over the engine's own pitch analysis (no new dependency) and runs it. See equalise_phoneme_periods.swift.
set -e
HERE=$(cd "$(dirname "$0")/.." && pwd)
W=$HERE/PrimaeNative/Core/Sonification
OUT=${TMPDIR:-/tmp}/equalise_phoneme_periods
mkdir -p "$OUT"
cp "$HERE/scripts/equalise_phoneme_periods.swift" "$OUT/main.swift"
swiftc -O -swift-version 6 -default-isolation MainActor -module-cache-path "$OUT/mc" \
  "$OUT/main.swift" "$W/SonificationRenderer.swift" "$W/TDPSOLA/TDPSOLAAnalysis.swift" -o "$OUT/tool"
exec "$OUT/tool" "$@"
