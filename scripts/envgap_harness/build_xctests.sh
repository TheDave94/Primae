#!/bin/sh
# BENCHWIN2 offline XCTest bundle: the bench self-test classes (PitchMetricSelfTests, BakeoffMetricSelfTests) against
# the harness's production DSP (`build.sh <harness>` first; this reuses its libPrimaeNative.a and gen/ bench sources).
# testScenarioSetAndExportNames is stripped offline (it needs the SonificationBakeoffBench XCTest class).
# Usage: build_xctests.sh <harness dir> <out dir>; run: PRIMAE_RES=<Resources> xcrun xctest <out>/BenchSelfTests.xctest
set -eu
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
H=${1:?harness dir}; OUT=${2:?out dir}
B=$OUT/BenchSelfTests.xctest/Contents; mkdir -p "$B/MacOS" "$OUT/src" "$OUT/mcache"
export CLANG_MODULE_CACHE_PATH="$OUT/mcache"
FW=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks
LIB=$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib
T=$ROOT/PrimaeNativeTests/SonificationBakeoff
cp "$T/BakeoffMetricSelfTests.swift" "$OUT/src/"
python3 - "$T/PitchMetricSelfTests.swift" "$OUT/src/PitchMetricSelfTests.swift" <<'PY'
import sys, re
s = open(sys.argv[1]).read()
a = s.index("    func testScenarioSetAndExportNames()")
# drop the function: up to the next line that is exactly "    }" after a
b = s.index("\n    }\n", a) + len("\n    }\n")
open(sys.argv[2], "w").write(s[:a] + s[b:])
PY
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>bench.selftests</string><key>CFBundleExecutable</key><string>BenchSelfTests</string><key>CFBundlePackageType</key><string>BNDL</string></dict></plist>' > "$B/Info.plist"
swiftc -module-cache-path "$OUT/mcache" -O -module-name BenchSelfTests -swift-version 5 -default-isolation MainActor -D STUDY_BUILD \
  -I "$H" -I "$LIB" -L "$H" -lPrimaeNative -F "$FW" -framework XCTest -L "$LIB" -lXCTestSwiftSupport \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" -Xlinker -bundle \
  -o "$B/MacOS/BenchSelfTests" "$H"/gen/*.swift "$OUT"/src/*.swift
echo built "$OUT/BenchSelfTests.xctest"
