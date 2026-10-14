#!/bin/sh
# check_test_count.sh — fail a CI test step that EXECUTED too few tests.
#
# R-109 (audit 2026-10-13, G2-05). CLAUDE.md "Test Infrastructure" item 5
# records an `-only-testing:` filter that matched nothing and printed
# "Test succeeded" after running ZERO tests. xcodebuild's exit status cannot
# tell an empty run from a full one, so CI has to read the count itself.
#
# Usage: scripts/check_test_count.sh LOGFILE MINIMUM
#
# Reads the Swift Testing summary line
#     Test run with 1064 tests in 113 suites passed after 258.557 seconds
# (an xcodebuild log prefixes it with a status glyph; the match is not
# anchored). If the log carries several such lines the LARGEST count is used,
# so a re-run cannot inflate it and a partial one cannot hide it.
#
# Exit: 0 count >= MINIMUM; 1 no summary line, or count below MINIMUM;
#       2 bad usage / unreadable log.
#
# MINIMUM is a floor, not an expectation: it sits below the current count so
# an honest test removal does not need a CI edit, while an empty or truncated
# run (0 tests, a mistyped filter, a target that stopped compiling its
# sources) cannot pass. Raise it when the suite grows for good.
set -eu

if [ $# -ne 2 ]; then
    echo "usage: check_test_count.sh LOGFILE MINIMUM" >&2
    exit 2
fi
LOG=$1
MIN=$2
case "$MIN" in
    ''|*[!0-9]*) echo "check_test_count: MINIMUM must be a non-negative integer, got '$MIN'" >&2; exit 2 ;;
esac
if [ ! -r "$LOG" ]; then
    echo "check_test_count: cannot read log '$LOG'" >&2
    exit 2
fi

COUNT=$(sed -n 's/.*Test run with \([0-9][0-9]*\) tests* in [0-9][0-9]* suites*.*/\1/p' "$LOG" | sort -n | tail -1)
if [ -z "$COUNT" ]; then
    echo "check_test_count: FAIL — no 'Test run with N tests in M suites' line in $LOG." >&2
    echo "The run did not report a Swift Testing summary; a green exit status proves nothing." >&2
    exit 1
fi
if [ "$COUNT" -lt "$MIN" ]; then
    echo "check_test_count: FAIL — $COUNT tests executed, below the floor of $MIN." >&2
    echo "A filter that matches nothing, or a target that lost its sources, looks exactly like this." >&2
    exit 1
fi
echo "check_test_count: ok — $COUNT tests executed (floor $MIN)"
