#!/bin/sh
# ENVGAP-A offline Swift Testing run: the production DSP module (as build.sh compiles it) plus the named test files
# and the repo's SonificationTestSupport.swift, linked with Xcode's Testing.framework through __swiftPMEntryPoint.
# Usage: build_tests.sh <outdir> <test.swift>...; run: PRIMAE_RES=<Resources> <outdir>/envgap_tests [--filter <suite>]
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT=${1:?out dir}; shift
mkdir -p "$OUT/mcache"; export CLANG_MODULE_CACHE_PATH="$OUT/mcache"; MC="-module-cache-path $OUT/mcache"
S=$ROOT/PrimaeNative/Core/Sonification
PROD="$S/SonificationRenderer.swift $S/SonificationSource.swift $S/StrokeEnvelopeTuning.swift $S/PhonemeOnsets.swift $S/TDPSOLA/*.swift $S/TDPSOLA2/*.swift $S/SonificationAtomics.swift $ROOT/PrimaeNative/Core/PitchCoupling.swift $ROOT/PrimaeNative/Core/AudioEngine+Loudness.swift $ROOT/scripts/envgap_harness/shim/Shims.swift"
swiftc $MC -O -wmo -parse-as-library -module-name PrimaeNative -swift-version 6 -D STUDY_BUILD -default-isolation MainActor \
  -enable-testing -emit-module -emit-module-path "$OUT/PrimaeNative.swiftmodule" -emit-library -static \
  -o "$OUT/libPrimaeNative.a" $PROD
FW=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks
LIB=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib
PLUG=$(xcode-select -p)/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing
printf 'import Testing\nimport Foundation\n@main struct Runner { static func main() async { exit(await Testing.__swiftPMEntryPoint()) } }\n' > "$OUT/runner.swift"
swiftc $MC -Onone -parse-as-library -module-name EnvgapTests -swift-version 5 -default-isolation MainActor -D STUDY_BUILD \
  -I "$OUT" -L "$OUT" -lPrimaeNative -F "$FW" -framework Testing -plugin-path "$PLUG" -L "$LIB" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
  -o "$OUT/envgap_tests" "$OUT/runner.swift" "$ROOT/PrimaeNativeTests/Sonification/SonificationTestSupport.swift" "$@"
echo built "$OUT/envgap_tests"
