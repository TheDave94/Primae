#!/bin/sh
# forge_ci_verdict_bridge.sh — carry the GitHub Actions verdict onto the forge.
#
# USAGE
#   scripts/forge_ci_verdict_bridge.sh              plan every branch, write nothing
#   scripts/forge_ci_verdict_bridge.sh --go         write
#   scripts/forge_ci_verdict_bridge.sh --go main    write, one branch only
#   scripts/forge_ci_verdict_bridge.sh --self-test  prove both verdicts
#
# ---------------------------------------------------------------- why PULL
#
# Forgejo is this repository's origin and the only place a pull request is
# opened, reviewed or merged; GitHub carries a push mirror and runs CI. The
# gap being closed here is that nothing carried GitHub's verdict back.
#
# THE OBVIOUS DESIGN CANNOT WORK, AND THAT IS MEASURED, NOT ASSUMED. Having
# GitHub Actions POST the status to the forge was tried and shipped, and it
# never delivered. From a GitHub-hosted runner the connection never completes:
#
#   curl: (28) Failed to connect to git.flamingistan.com port 443 after
#   133601 ms: Couldn't connect to server
#
# Two attempts each burned ~134 s inside TCP connect and the job was then
# killed by its own timeout, which GitHub reports as `cancelled` — so an
# otherwise-green run read as cancelled, which is worse than no bridge at all.
# An 8-node external probe (check-host.net) splits cleanly along geography:
#
#   ch2 CH, it2 IT, nl1 NL, pt1 PT, uk1 UK   -> 403 Forbidden (the forge answered)
#   us3 US, br1 BR, ir7 IR, ca1 CA           -> Connection timed out
#
# BOTH HALVES OF THAT SPLIT ARE DOCUMENTED POLICY, NOT A FAULT, and naming their
# source closed a question this seat had left open. homelab-ops
# `docs/systems/edge.md:8` — "pf: igb0 :80/:443 only from <GEO_ALLOW_EU> (~25 EU
# countries). Rules SILENT — read pf counters, never filterlog." That is the
# TIMEOUT: a US source is dropped at pf before any later layer sees it. The same
# document's layer 3 (`edge.md:15`) is the 403 — "http-request deny unless
# <local-src>||<host-exemption>" — an EU probe is not an estate source, so
# HAProxy answers it and refuses. Measurement and policy line up exactly.
#
# Opening the forge to GitHub therefore means editing GEO_ALLOW_EU: widening a
# deliberate country policy so that a home service answers a public cloud, and
# breaking SILENTLY later when those ranges drift — because a stale allowlist
# looks exactly like a working bridge. So the verdict is PULLED from inside the
# network instead of PUSHED from outside it.
#
# WHY NO SHA MAPPING IS NEEDED. A push mirror copies commits verbatim, so the
# forge's commit and GitHub's commit are the SAME object. MEASURED 2026-10-15:
# forge main == github main == 72c8a02cf8b24a75e0ec0c29949d99a4b4049daf.
#
# WHAT IT DOES, per branch of the forge repository:
#   1. read the branch head SHA from the forge
#   2. read GitHub's check-runs for that same SHA
#   3. skip unless the set is non-empty AND fully completed
#   4. collapse it to a single success/failure
#   5. write ONE commit status, and only when the value actually changed
#
# IT IS A REPORT, NEVER A GATE. main's branch protection carries
# `enable_status_check: false`, so nothing posted here can block a merge, and
# making it required is a separate deliberate act on the forge. The exit code
# reports whether this SCRIPT worked, never whether CI passed.
#
# IT WARNS INSTEAD OF FAILING. A delivery failure must not redden anything, so
# the scheduled caller wraps it and a missing credential exits 0 with a
# `::warning`. That is the same shape the removed push reporter had, and it is
# deliberate: a bridge that reports and cannot deliver must stay quiet.
#
# POSIX sh. Requires: curl, jq.
#
# TOKENS, never printed:
#   FORGE_TOKEN      or FORGE_TOKEN_FILE   (default ~/.config/forgejo/push-security.token)
#   GH_TOKEN         or GH_TOKEN_FILE      (default: `gh auth token`)
#
# ENVIRONMENT
#   FORGE_BASE  default https://git.flamingistan.com/api/v1   (include /api/v1)
#   FORGE_REPO  default David/Primae
#   GH_REPO     default TheDave94/Primae
#   CONTEXT     default ci/github-actions

set -eu

TOKEN=SELFTEST_REACHABLE

GH_REPO="${GH_REPO:-TheDave94/Primae}"
GH_API="${GH_API:-https://api.github.com}"
GH_WEB="${GH_WEB:-https://github.com}"
FORGE_REPO="${FORGE_REPO:-David/Primae}"
FORGE_BASE="${FORGE_BASE:-https://git.flamingistan.com/api/v1}"
CONTEXT="${CONTEXT:-ci/github-actions}"
FORGE_TOKEN_FILE="${FORGE_TOKEN_FILE:-$HOME/.config/forgejo/push-security.token}"
GH_TOKEN_FILE="${GH_TOKEN_FILE:-}"
TMP="${TMPDIR:-/tmp}"
NET_MAX="${NET_MAX:-25}"

log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
die() { printf 'FATAL: %s\n' "$*" >&2; exit 70; }

# ------------------------------------------------------- the collapse, alone
#
# Split out from the network code so --self-test can drive it directly. It
# prints "<state> <total> <bad> <pending>" and nothing else.
#
# FORGEJO DOES NOT VALIDATE `state`. MEASURED 2026-10-15: posting state
# "banana" returned HTTP 201 and stored the row, so a misspelling here is
# accepted silently and renders as an unknown marker rather than an error. The
# only two strings this may emit are `success` and `failure`.
#
# `skipped` and `neutral` ARE NOT FAILURES. A job that never ran, or that ran
# advisory-only, made no claim about this commit.
collapse() { # $1 = path to a check-runs document
	_total=$(jq -r '.total_count // 0' "$1")
	if [ "$_total" -eq 0 ]; then
		printf 'empty 0 0 0\n'
		return 0
	fi
	_pending=$(jq -r '[.check_runs[] | select(.status != "completed")] | length' "$1")
	if [ "$_pending" -ne 0 ]; then
		printf 'pending %s 0 %s\n' "$_total" "$_pending"
		return 0
	fi
	_bad=$(jq -r '[.check_runs[]
		| select(.conclusion == "failure"
			or .conclusion == "cancelled"
			or .conclusion == "timed_out"
			or .conclusion == "startup_failure"
			or .conclusion == "action_required"
			or .conclusion == "stale")] | length' "$1")
	if [ "$_bad" -eq 0 ]; then
		printf 'success %s 0 0\n' "$_total"
	else
		printf 'failure %s %s 0\n' "$_total" "$_bad"
	fi
}

# ---------------------------------------------------------------- self-test
#
# Drives BOTH verdicts. A collapse that has only ever been seen to return
# `success` asserts nothing: the failure arm is the one that decides whether a
# red build can ever reach the forge, so it is driven here against fixtures
# that carry the defect.
self_test() {
	_d=$(mktemp -d "${TMPDIR:-/tmp}/verdict-selftest.XXXXXX")
	_pass=0
	_fail=0

	# $1 label, $2 wanted state, $3 wanted total, $4 wanted bad, $5 fixture
	st() {
		printf '%s' "$5" > "$_d/f.json"
		_got=$(collapse "$_d/f.json")
		if [ "$_got" = "$2 $3 $4 0" ]; then
			_pass=$((_pass + 1))
			echo "  pass  $1 -> $_got"
		else
			_fail=$((_fail + 1))
			echo "  FAIL  $1 -> wanted '$2 $3 $4 0', got '$_got'"
		fi
	}

	echo "forge_ci_verdict_bridge.sh --self-test"
	st "three green" success 3 0 \
		'{"total_count":3,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"skipped"}]}'
	st "one failure among three" failure 3 1 \
		'{"total_count":3,"check_runs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"success"}]}'
	st "one cancelled" failure 2 1 \
		'{"total_count":2,"check_runs":[{"status":"completed","conclusion":"cancelled"},{"status":"completed","conclusion":"success"}]}'
	st "one timed_out" failure 2 1 \
		'{"total_count":2,"check_runs":[{"status":"completed","conclusion":"timed_out"},{"status":"completed","conclusion":"success"}]}'
	st "one startup_failure" failure 2 1 \
		'{"total_count":2,"check_runs":[{"status":"completed","conclusion":"startup_failure"},{"status":"completed","conclusion":"success"}]}'
	st "neutral is not a failure" success 2 0 \
		'{"total_count":2,"check_runs":[{"status":"completed","conclusion":"neutral"},{"status":"completed","conclusion":"success"}]}'
	st "no check-runs at all" empty 0 0 \
		'{"total_count":0,"check_runs":[]}'

	# The pending arm prints a different shape, so it is driven directly.
	_p() {
		printf '%s' "$3" > "$_d/f.json"
		_got=$(collapse "$_d/f.json" | cut -d' ' -f1)
		if [ "$_got" = "$2" ]; then
			_pass=$((_pass + 1))
			echo "  pass  $1 -> $_got"
		else
			_fail=$((_fail + 1))
			echo "  FAIL  $1 -> wanted '$2', got '$_got'"
		fi
	}
	_p "still running is not a verdict" pending \
		'{"total_count":2,"check_runs":[{"status":"in_progress","conclusion":null},{"status":"completed","conclusion":"success"}]}'
	_p "queued is not a verdict" pending \
		'{"total_count":2,"check_runs":[{"status":"queued","conclusion":null},{"status":"completed","conclusion":"success"}]}'

	echo "  fixtures: $_d (kept deliberately)"
	if [ "$_fail" -eq 0 ]; then
		echo "SELF-TEST: PASS — $_pass/$_pass"
		return 0
	fi
	echo "SELF-TEST: FAIL — $_fail of $((_pass + _fail))"
	return 1
}

# ---------------------------------------------------------------- arguments
#
# The dispatch sits ABOVE the catch-all: a `--self-test` that a catch-all
# reaches first is a guard whose branch never runs, whatever the source says.
SELF_TEST=0
MODE=plan
ONLY_BRANCH=''
while [ $# -gt 0 ]; do
	case "$1" in
		--self-test) SELF_TEST=1 ;;
		--plan) MODE=plan ;;
		--go) MODE=go ;;
		-h|--help) sed -n '3,7p' "$0"; exit 0 ;;
		-*) warn "FATAL: unknown option '$1'"; exit 64 ;;
		*) ONLY_BRANCH="$1" ;;
	esac
	shift
done

if [ "$SELF_TEST" -eq 1 ]; then
	# The probe answer, as the FIRST act inside the branch. Reaching this line
	# is what the unwired-guard scan asserts; answering anything slower would
	# make every CI run pay for it.
	if [ "${GUARD_SELFTEST_PROBE:-0}" = "1" ]; then
		echo "$TOKEN"
		exit 0
	fi
	command -v jq >/dev/null 2>&1 || { warn "FATAL: jq is required"; exit 3; }
	set +e
	self_test
	_rc=$?
	set -e
	exit "$_rc"
fi

# ----------------------------------------------------- preconditions (live)
for _c in curl jq; do
	command -v "$_c" >/dev/null 2>&1 || die "'$_c' is not on PATH"
done
[ -n "$FORGE_REPO" ] || die "FORGE_REPO is empty"
[ -n "$GH_REPO" ] || die "GH_REPO is empty"

FORGE_TOKEN_V=''
if [ -n "${FORGE_TOKEN:-}" ]; then
	FORGE_TOKEN_V="$FORGE_TOKEN"
elif [ -r "$FORGE_TOKEN_FILE" ]; then
	FORGE_TOKEN_V=$(cat "$FORGE_TOKEN_FILE")
fi
[ -n "$FORGE_TOKEN_V" ] || die "no forge token (set FORGE_TOKEN or make $FORGE_TOKEN_FILE readable)"

GH_TOKEN_V=''
if [ -n "${GH_TOKEN:-}" ]; then
	GH_TOKEN_V="$GH_TOKEN"
elif [ -n "$GH_TOKEN_FILE" ] && [ -r "$GH_TOKEN_FILE" ]; then
	GH_TOKEN_V=$(cat "$GH_TOKEN_FILE")
elif command -v gh >/dev/null 2>&1; then
	GH_TOKEN_V=$(gh auth token 2>/dev/null || true)
fi
[ -n "$GH_TOKEN_V" ] || die "no GitHub token (set GH_TOKEN, or authenticate gh)"

forge_get() { curl -sS -m "$NET_MAX" -H "Authorization: token $FORGE_TOKEN_V" "$FORGE_BASE$1"; }
gh_get() {
	curl -sS -m "$NET_MAX" -H "Authorization: Bearer $GH_TOKEN_V" \
		-H 'Accept: application/vnd.github+json' \
		-H 'X-GitHub-Api-Version: 2022-11-28' "$GH_API$1"
}

log "forge  : $FORGE_BASE/repos/$FORGE_REPO"
forge_get "/repos/$FORGE_REPO" | jq -e -r '.full_name' >/dev/null 2>&1 \
	|| die "cannot read $FORGE_REPO on the forge (token scope or reachability)"
log "github : $GH_API/repos/$GH_REPO"
gh_get "/repos/$GH_REPO" | jq -e -r '.full_name' >/dev/null 2>&1 \
	|| die "cannot read $GH_REPO on GitHub (token scope)"
log "verdict: reading GitHub check-runs directly (no SHA mapping - the mirror shares objects)"
log "mode   : $MODE   context: $CONTEXT"
log ''

# -------------------------------------------------------- branch heads
if [ -n "$ONLY_BRANCH" ]; then
	PAIRS=$(forge_get "/repos/$FORGE_REPO/branches/$ONLY_BRANCH" 2>/dev/null \
		| jq -r 'select(.name != null) | "\(.name) \(.commit.id)"' 2>/dev/null || true)
else
	PAIRS=$(forge_get "/repos/$FORGE_REPO/branches?limit=50" 2>/dev/null \
		| jq -r '.[]? | "\(.name) \(.commit.id)"' 2>/dev/null || true)
fi
[ -n "$PAIRS" ] || die "no branches read from the forge"

FAILED=0
# A here-doc, not a pipe: a pipe would run this loop in a subshell and swallow
# FAILED, so a failed POST would still exit 0.
while read -r BR SHA; do
	[ -n "${BR:-}" ] || continue
	[ -n "${SHA:-}" ] || { log "$BR: no head sha"; continue; }
	SHA8=$(printf '%s' "$SHA" | cut -c1-8)

	CR=$(gh_get "/repos/$GH_REPO/commits/$SHA/check-runs?per_page=100" 2>/dev/null || true)
	if [ -z "$CR" ] || ! printf '%s' "$CR" | jq -e -r '.total_count' >/dev/null 2>&1; then
		log "$BR  $SHA8  skip: GitHub check-runs unreadable"
		continue
	fi
	printf '%s' "$CR" > "$TMP/forge_verdict_checkruns.json"

	# shellcheck disable=SC2046
	set -- $(collapse "$TMP/forge_verdict_checkruns.json")
	STATE=$1
	TOTAL=$2
	BAD=$3

	case "$STATE" in
		empty)
			log "$BR  $SHA8  skip: no check-runs (CI never ran for this commit)"
			continue ;;
		pending)
			log "$BR  $SHA8  skip: CI still running"
			continue ;;
		success) DESC="$TOTAL/$TOTAL check runs succeeded" ;;
		failure) DESC="$BAD of $TOTAL check runs did not succeed" ;;
		*) die "internal: collapse returned '$STATE'" ;;
	esac

	# Idempotence. Forgejo keeps every row, so re-posting an unchanged verdict
	# every ten minutes would bury the history in duplicates. Only the newest
	# row per context decides the combined state, so this compares against it.
	CUR=$(forge_get "/repos/$FORGE_REPO/commits/$SHA/statuses" 2>/dev/null \
		| jq -r --arg c "$CONTEXT" \
			'[.[]? | select(.context == $c)] | sort_by(.id) | last
			 | if . == null then "none|none" else (.status + "|" + .description) end' \
			2>/dev/null || printf 'none|none')
	if [ "$CUR" = "$STATE|$DESC" ]; then
		log "$BR  $SHA8  unchanged ($STATE) - nothing to do"
		continue
	fi

	TARGET="$GH_WEB/$GH_REPO/commit/$SHA/checks"
	if [ "$MODE" = plan ]; then
		log "$BR  $SHA8  PLAN  $STATE  \"$DESC\"   (currently: $CUR)"
		continue
	fi

	HTTP=$(curl -sS -m "$NET_MAX" -o "$TMP/forge_verdict_post.json" -w '%{http_code}' \
		-X POST "$FORGE_BASE/repos/$FORGE_REPO/statuses/$SHA" \
		-H "Authorization: token $FORGE_TOKEN_V" \
		-H 'Content-Type: application/json' \
		--data "{\"state\":\"$STATE\",\"context\":\"$CONTEXT\",\"description\":\"$DESC\",\"target_url\":\"$TARGET\"}" \
		2>/dev/null || printf '000')
	case "$HTTP" in
		2??) log "$BR  $SHA8  POSTED  $STATE  \"$DESC\"" ;;
		*)
			log "$BR  $SHA8  FAILED  HTTP $HTTP $(head -c 200 "$TMP/forge_verdict_post.json" 2>/dev/null)"
			FAILED=1 ;;
	esac
done <<EOF
$PAIRS
EOF

if [ "$MODE" = plan ]; then
	log ''
	log 'plan only - nothing was written. re-run with --go to post.'
fi
exit "$FAILED"
