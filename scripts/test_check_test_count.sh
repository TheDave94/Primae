#!/bin/sh
# test_check_test_count.sh — regression test for scripts/check_test_count.sh
# (R-109). Feeds it canned xcodebuild log fragments.
#
# Usage: sh scripts/test_check_test_count.sh
# Exit 0 = every case behaved; 1 = at least one did not.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
GATE="$ROOT/scripts/check_test_count.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/primae-testcount.XXXXXX")
FAILS=0
N=0

pass() { N=$((N + 1)); echo "ok   - $1"; }
fail() { N=$((N + 1)); FAILS=$((FAILS + 1)); echo "FAIL - $1"; }

# expect NAME WANT_RC LOGTEXT MIN
expect() {
    printf '%s\n' "$3" > "$WORK/log"
    OUT=$(sh "$GATE" "$WORK/log" "$4" 2>&1); RC=$?
    if [ "$RC" -eq "$2" ]; then pass "$1"; else fail "$1 (want rc=$2, got rc=$RC: $OUT)"; fi
}

expect "full run above the floor passes" 0 \
    "􁁛  Test run with 1064 tests in 113 suites passed after 258.557 seconds with 1 known issue." 1000
expect "count equal to the floor passes" 0 \
    "Test run with 1000 tests in 100 suites passed after 1.0 seconds." 1000
expect "count one below the floor fails" 1 \
    "Test run with 999 tests in 100 suites passed after 1.0 seconds." 1000
# The documented failure: a filter that matched nothing reports success.
expect "ZERO tests (mistyped -only-testing) fails" 1 \
    "Test run with 0 tests in 1 suite passed after 0.003 seconds
** TEST SUCCEEDED **" 1000
expect "no summary line at all fails" 1 \
    "Executed 5 tests, with 0 failures
** TEST SUCCEEDED **" 1000
expect "singular forms parse (1 test in 1 suite) and fail the floor" 1 \
    "Test run with 1 test in 1 suite passed after 0.001 seconds." 1000
expect "the largest of several summaries is used" 0 \
    "Test run with 12 tests in 2 suites passed after 0.5 seconds.
Test run with 1064 tests in 113 suites passed after 258.0 seconds." 1000

printf 'x\n' > "$WORK/log"
sh "$GATE" "$WORK/log" abc >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && pass "non-numeric floor is a usage error" || fail "non-numeric floor (rc=$RC)"
sh "$GATE" "$WORK/missing" 10 >/dev/null 2>&1; RC=$?
[ "$RC" -eq 2 ] && pass "unreadable log is a usage error" || fail "unreadable log (rc=$RC)"

echo "---- $N cases, $FAILS failed"
# The scratch directory is left to the OS temp reaper: this script contains
# no recursive delete of a variable path.
[ "$FAILS" -eq 0 ]
