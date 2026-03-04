#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${IOS_NATIVE_ARTIFACT_DIR:-$ROOT_DIR/ios-native-ci-artifacts}"
DESTINATION="${IOS_DESTINATION:-platform=iOS Simulator,name=iPhone 16}"
CONFIGURATION="${IOS_CONFIGURATION:-Debug}"
STRICT=0

if [[ "${1:-}" == "--strict" ]]; then
  STRICT=1
fi

cd "$ROOT_DIR"

if ! command -v xcodebuild >/dev/null 2>&1; then
  if [[ "$STRICT" -eq 1 ]]; then
    echo "[ios-native-gate] xcodebuild not found. Strict mode requires macOS + Xcode." >&2
    exit 2
  fi
  echo "[ios-native-gate] xcodebuild not found; skipping build/test (non-macOS host)."
  exit 0
fi

mkdir -p "$ARTIFACT_DIR"
SCHEMES_JSON="$ARTIFACT_DIR/spm_schemes.json"
xcodebuild -list -json > "$SCHEMES_JSON"

SCHEME=$(python3 - <<'PY' "$SCHEMES_JSON"
import json,sys
obj=json.load(open(sys.argv[1]))
for scope in (obj.get('workspace', {}), obj.get('project', {})):
    for name in scope.get('schemes', []):
        if 'BuchstabenNative' in name:
            print(name)
            raise SystemExit(0)
print("")
PY
)

if [[ -z "$SCHEME" ]]; then
  if [[ "$STRICT" -eq 1 ]]; then
    echo "[ios-native-gate] No BuchstabenNative scheme discovered." >&2
    exit 3
  fi
  echo "[ios-native-gate] No BuchstabenNative scheme discovered; skipping."
  exit 0
fi

echo "[ios-native-gate] Using scheme: $SCHEME"

echo "[ios-native-gate] Build"
set -o pipefail
xcodebuild \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration "$CONFIGURATION" \
  CODE_SIGNING_ALLOWED=NO \
  build | tee "$ARTIFACT_DIR/build.log"

echo "[ios-native-gate] Test"
xcodebuild \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration "$CONFIGURATION" \
  -resultBundlePath "$ARTIFACT_DIR/BuchstabenNativeTests.xcresult" \
  CODE_SIGNING_ALLOWED=NO \
  test | tee "$ARTIFACT_DIR/test.log"

echo "[ios-native-gate] PASS"
