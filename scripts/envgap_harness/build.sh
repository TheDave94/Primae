#!/bin/sh
# ENVGAP offline harness build: production DSP (module PrimaeNative, -O, MainActor default isolation, Swift 6)
# + BENCH-R31 metric files (module Bench, Swift 5, @testable import PrimaeNative). macOS only, no Xcode project.
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:?out dir}
mkdir -p "$OUT/gen" "$OUT/mcache"; export CLANG_MODULE_CACHE_PATH="$OUT/mcache"; MC="-module-cache-path $OUT/mcache"
S=$ROOT/PrimaeNative/Core/Sonification
T2DIR=$S/TDPSOLA2
PROD="$S/SonificationRenderer.swift $S/SonificationSource.swift $S/StrokeEnvelopeTuning.swift $S/PhonemeOnsets.swift $S/TDPSOLA/*.swift $T2DIR/*.swift $S/SonificationAtomics.swift $ROOT/PrimaeNative/Core/PitchCoupling.swift $ROOT/PrimaeNative/Core/AudioEngine+Loudness.swift $ROOT/scripts/envgap_harness/shim/Shims.swift"
swiftc $MC -O -wmo -parse-as-library -module-name PrimaeNative -swift-version 6 -D STUDY_BUILD -default-isolation MainActor \
  -enable-testing -emit-module -emit-module-path "$OUT/PrimaeNative.swiftmodule" -emit-library -static \
  -o "$OUT/libPrimaeNative.a" $PROD
# Bench files: the in-repo bench sources themselves (lane BENCHWIN: no copies, so the harness and the
# Primae-DeviceTests bench cannot drift), minus the XCTest files; the r17 all-sources loader (needs LetterRepository)
# is dropped, the pitch bench uses pitchSources only.
BENCH=$ROOT/PrimaeNativeTests/SonificationBakeoff
rm -f "$OUT"/gen/*.swift
for f in "$BENCH"/*.swift "$ROOT"/scripts/envgap_harness/EnvgapCandidates.swift "$ROOT"/scripts/envgap_harness/EnvgapACandidates.swift; do
  case $(basename "$f") in *SelfTests.swift|SonificationBakeoffBench.swift) continue ;; esac
  python3 "$ROOT/scripts/envgap_harness/strip_all.py" "$f" "$OUT/gen/$(basename "$f")"
done
swiftc $MC -O -wmo -module-name Bench -swift-version 5 -default-isolation MainActor -D STUDY_BUILD -I "$OUT" -L "$OUT" -lPrimaeNative \
  -o "$OUT/envgap_bench" "$OUT"/gen/*.swift "$ROOT"/scripts/envgap_harness/main.swift "$ROOT"/scripts/envgap_harness/EnvDump.swift "$ROOT"/scripts/envgap_harness/LoopStages.swift "$ROOT"/scripts/envgap_harness/SeamCheck.swift "$ROOT"/scripts/envgap_harness/RenderDump.swift \
  "$ROOT"/PrimaeNativeTests/Sonification/SeamMeter.swift "$ROOT"/PrimaeNativeTests/Sonification/SeamEvaluator.swift "$ROOT"/PrimaeNativeTests/Sonification/SeamRender.swift
echo built "$OUT/envgap_bench"
