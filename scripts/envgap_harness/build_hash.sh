#!/bin/sh
# ENVGAP bit-identity proof build: the production DSP module (optionally from alternate TDPSOLA2 sources, T2DIR) plus
# HashMode.swift only. Usage: [T1DIR=dir] [T2DIR=dir] [HASHFLAGS=file] build_hash.sh <outdir>; run: [HASH_LISTEN=1] PRIMAE_RES=... <outdir>/envgap_hash
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:?out dir}
mkdir -p "$OUT/mcache"; export CLANG_MODULE_CACHE_PATH="$OUT/mcache"; MC="-module-cache-path $OUT/mcache"
S=$ROOT/PrimaeNative/Core/Sonification
T2DIR=${T2DIR:-$S/TDPSOLA2}; T1DIR=${T1DIR:-$S/TDPSOLA}; HASHFLAGS=${HASHFLAGS:-$ROOT/scripts/envgap_harness/HashFlags.swift}
PROD="$S/SonificationRenderer.swift $S/SonificationSource.swift $S/StrokeEnvelopeTuning.swift $S/PhonemeOnsets.swift $T1DIR/*.swift $T2DIR/*.swift $S/SonificationAtomics.swift $ROOT/PrimaeNative/Core/PitchCoupling.swift $ROOT/PrimaeNative/Core/AudioEngine+Loudness.swift $ROOT/scripts/envgap_harness/shim/Shims.swift"
swiftc $MC -O -wmo -parse-as-library -module-name PrimaeNative -swift-version 6 -D STUDY_BUILD -default-isolation MainActor \
  -enable-testing -emit-module -emit-module-path "$OUT/PrimaeNative.swiftmodule" -emit-library -static \
  -o "$OUT/libPrimaeNative.a" $PROD
printf 'import Foundation\ntry MainActor.assumeIsolated { if ProcessInfo.processInfo.environment["HASH_LISTEN"] != nil { try listenMode() } else { try hashMode() } }\n' > "$OUT/main.swift"
swiftc $MC -O -wmo -module-name EnvgapHash -swift-version 5 -default-isolation MainActor -D STUDY_BUILD -I "$OUT" -L "$OUT" -lPrimaeNative \
  -o "$OUT/envgap_hash" "$OUT/main.swift" "$ROOT"/scripts/envgap_harness/HashMode.swift "$HASHFLAGS"
echo built "$OUT/envgap_hash"
