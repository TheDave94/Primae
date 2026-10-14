#!/bin/sh
# test_deploy_verified_pilot_build.sh — shell-level reproduction + regression
# test for R-058 (device discovery) and R-114 (toolchain pin check).
#
# Runs scripts/deploy_verified_pilot_build.sh --find-device-only and
# --confirm-wipe-only against a STUB devicectl that writes canned JSON, and
# scripts/check_toolchain_pin.sh against a STUB xcodebuild. No device, no
# Xcode, no build is touched.
#
# Usage: sh scripts/test_deploy_verified_pilot_build.sh
# Exit 0 = every case behaved; 1 = at least one case did not.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DEPLOY="$ROOT/scripts/deploy_verified_pilot_build.sh"
TOOL="$ROOT/scripts/check_toolchain_pin.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/primae-deploytest.XXXXXX")
FAILS=0
N=0

pass() { N=$((N + 1)); echo "ok   - $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "FAIL - $1"; }

# --- stub devicectl: `list devices --json-output PATH` copies $STUB_JSON_FILE.
cat > "$WORK/devicectl" <<'STUB'
#!/bin/sh
[ -n "${STUB_FAIL:-}" ] && { echo "stub: simulated failure" >&2; exit 1; }
[ "$1" = list ] && [ "$2" = devices ] && [ "$3" = --json-output ] || { echo "stub: unexpected args: $*" >&2; exit 9; }
cp "$STUB_JSON_FILE" "$4"
STUB
chmod +x "$WORK/devicectl"

# entry NAME UDID DEVICETYPE PLATFORM TUNNEL REALITY
entry() {
    printf '{"deviceProperties":{"name":"%s"},"hardwareProperties":{"udid":"%s","deviceType":"%s","platform":"%s","reality":"%s"},"connectionProperties":{"tunnelState":"%s"},"identifier":"CORE-%s"}' \
        "$1" "$2" "$3" "$4" "$6" "$5" "$2"
}
wrap() { printf '{"info":{"outcome":"success"},"result":{"devices":[%s]}}' "$1" > "$WORK/list.json"; }

run_find() {
    STUB_JSON_FILE="$WORK/list.json" PRIMAE_DEVICECTL="$WORK/devicectl" sh "$DEPLOY" --find-device-only 2>"$WORK/err"
}

# --- CASE 0: the mechanism of the original defect, pinned so the comment in
# the deploy script stays true. Pipe + here-document on one command: the
# here-document wins stdin.
GOT=$(printf 'PIPED' | python3 -I - <<'PY'
import sys
print(repr(sys.stdin.read()))
PY
)
# Under python's `-` the program itself comes from stdin; the point is that
# the piped 'PIPED' never reaches the program. A program that read stdin
# would get '' (or fail), never 'PIPED'.
case "$GOT" in
    *PIPED*) fail "CASE 0 mechanism: pipe content reached a heredoc-fed python (premise of R-058 wrong)" ;;
    *) pass "CASE 0 mechanism: pipe content is discarded when a heredoc feeds the same command" ;;
esac

# --- CASE 1: exactly one physical iPad (plus a Mac-ish and an iPhone) -> UDID.
wrap "$(entry "Studio iPad" 00008103-000E60311AE8801E iPad iOS connected physical),$(entry "Some iPhone" 00008110-AAAAAAAAAAAAAAAA iPhone iOS connected physical),$(entry "Watch" 00008006-BBBBBBBBBBBBBBBB appleWatch watchOS connected physical)"
OUT=$(run_find); RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "00008103-000E60311AE8801E" ]; then
    pass "CASE 1 one iPad among other devices -> its UDID"
else
    fail "CASE 1 expected rc=0 UDID=00008103-000E60311AE8801E, got rc=$RC out='$OUT' err='$(cat "$WORK/err")'"
fi

# --- CASE 2: no iPad at all -> NONE, rc 1, raw JSON dumped.
wrap "$(entry "Some iPhone" 00008110-AAAAAAAAAAAAAAAA iPhone iOS connected physical)"
OUT=$(run_find); RC=$?
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && grep -q "NONE" "$WORK/err" && grep -q "Raw devicectl JSON" "$WORK/err"; then
    pass "CASE 2 no iPad -> NONE + raw JSON dump, nonzero"
else
    fail "CASE 2 got rc=$RC out='$OUT' err='$(cat "$WORK/err")'"
fi

# --- CASE 3: two iPads -> AMBIGUOUS, nonzero, both listed.
wrap "$(entry "iPad A" 00008103-0000000000000001 iPad iOS connected physical),$(entry "iPad B" 00008103-0000000000000002 iPad iOS connected physical)"
OUT=$(run_find); RC=$?
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && grep -q "AMBIGUOUS" "$WORK/err" && grep -q "iPad A" "$WORK/err" && grep -q "iPad B" "$WORK/err"; then
    pass "CASE 3 two iPads -> AMBIGUOUS listing both, nonzero"
else
    fail "CASE 3 got rc=$RC out='$OUT' err='$(cat "$WORK/err")'"
fi

# --- CASE 4: an unavailable iPad is not a candidate.
wrap "$(entry "Gone iPad" 00008103-0000000000000003 iPad iOS unavailable physical)"
OUT=$(run_find); RC=$?
if [ "$RC" -ne 0 ] && grep -q "NONE" "$WORK/err"; then
    pass "CASE 4 unavailable iPad -> NONE"
else
    fail "CASE 4 got rc=$RC out='$OUT'"
fi

# --- CASE 5: a simulator-reality iPad is not a candidate.
wrap "$(entry "Sim iPad" 00008103-0000000000000004 iPad iOS connected simulated)"
OUT=$(run_find); RC=$?
if [ "$RC" -ne 0 ] && grep -q "NONE" "$WORK/err"; then
    pass "CASE 5 non-physical iPad -> NONE"
else
    fail "CASE 5 got rc=$RC out='$OUT'"
fi

# --- CASE 6: unparseable JSON -> nonzero, not a crash that looks like success.
printf 'not json' > "$WORK/list.json"
OUT=$(run_find); RC=$?
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && grep -q "UNPARSEABLE" "$WORK/err"; then
    pass "CASE 6 garbage JSON -> UNPARSEABLE, nonzero"
else
    fail "CASE 6 got rc=$RC out='$OUT' err='$(cat "$WORK/err")'"
fi

# --- CASE 7: devicectl itself failing -> nonzero.
wrap "$(entry "Studio iPad" 00008103-000E60311AE8801E iPad iOS connected physical)"
OUT=$(STUB_FAIL=1 STUB_JSON_FILE="$WORK/list.json" PRIMAE_DEVICECTL="$WORK/devicectl" sh "$DEPLOY" --find-device-only 2>"$WORK/err"); RC=$?
if [ "$RC" -ne 0 ] && [ -z "$OUT" ] && grep -q "failed" "$WORK/err"; then
    pass "CASE 7 devicectl failure -> nonzero, no UDID"
else
    fail "CASE 7 got rc=$RC out='$OUT'"
fi

# --- CASE 8..10: the wipe confirmation gate (no tty here: stdin from /dev/null).
sh "$DEPLOY" --confirm-wipe-only </dev/null >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && pass "CASE 8 no env, no tty -> refused" || fail "CASE 8 gate opened with no confirmation"
PRIMAE_CONFIRM_WIPE=yes sh "$DEPLOY" --confirm-wipe-only </dev/null >/dev/null 2>&1; RC=$?
[ "$RC" -ne 0 ] && pass "CASE 9 wrong PRIMAE_CONFIRM_WIPE -> refused" || fail "CASE 9 gate opened on a wrong value"
PRIMAE_CONFIRM_WIPE=com.flamingistan.primae.study sh "$DEPLOY" --confirm-wipe-only </dev/null >/dev/null 2>&1; RC=$?
[ "$RC" -eq 0 ] && pass "CASE 10 matching PRIMAE_CONFIRM_WIPE -> proceeds" || fail "CASE 10 gate refused a correct confirmation (rc=$RC)"

# --- CASE 11..13: toolchain pin check against a stub xcodebuild.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/xcodebuild" <<'STUB'
#!/bin/sh
printf 'Xcode %s\nBuild version %s\n' "$STUB_XCODE" "$STUB_BUILD"
STUB
chmod +x "$WORK/bin/xcodebuild"
OUT=$(PATH="$WORK/bin:$PATH" STUB_XCODE=27.2 STUB_BUILD=27B5019j sh "$TOOL" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "27B5019j"; then
    pass "CASE 11 Xcode 27.2 vs pin 27 -> ok, exact build printed"
else
    fail "CASE 11 rc=$RC out='$OUT'"
fi
OUT=$(PATH="$WORK/bin:$PATH" STUB_XCODE=26.4 STUB_BUILD=26E1 sh "$TOOL" 2>&1); RC=$?
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "!= pinned 27"; then
    pass "CASE 12 Xcode 26.4 vs pin 27 -> refused"
else
    fail "CASE 12 rc=$RC out='$OUT'"
fi
mkdir -p "$WORK/App.app"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>DTXcodeBuild</key><string>27B5019j</string></dict></plist>' > "$WORK/App.app/Info.plist"
OUT=$(PATH="$WORK/bin:$PATH" STUB_XCODE=27.2 STUB_BUILD=27B5019j sh "$TOOL" "$WORK/App.app" 2>&1); RC=$?
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "artefact DTXcodeBuild=27B5019j"; then
    pass "CASE 13 artefact DTXcodeBuild recorded"
else
    fail "CASE 13 rc=$RC out='$OUT'"
fi

echo "---- $N cases, $FAILS failed"
# Cleanup of the scratch directory is left to the OS temp reaper: this
# script deliberately contains no recursive delete of a variable path.
[ "$FAILS" -eq 0 ]
