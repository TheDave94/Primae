#!/bin/sh
# forge-verdict-bridge-runner.sh — the scheduled entry point for the forge CI verdict bridge.
#
# RUN ON: Yo-Mama (macOS), as the operator user. Installed to
#         ~/Library/Application Support/forge-verdict-bridge/ and invoked by launchd
#         every START_INTERVAL seconds. Safe to run by hand at any time:
#
#             sh scripts/forge-verdict-bridge-runner.sh
#
# WHY IT EXISTS. The forge owns pull requests and merges; GitHub carries a push
# mirror and runs CI. Nothing carried GitHub's verdict back across that gap except
# a script someone had to remember to run. This runner is what makes it run itself.
#
# WHY THIS SHAPE AND NOT THE TWO OBVIOUS ONES — both MEASURED, do not re-derive:
#
#   * A GitHub-hosted runner CANNOT reach the forge. The edge drops US sources at
#     pf before any later layer sees them (homelab-ops docs/systems/edge.md:8), and
#     the push reporter that shipped on that route burned ~134 s inside TCP connect
#     and was killed by its own timeout — reported as `cancelled`, so a green run
#     read as cancelled. That route was removed in #55.
#
#   * A forge-side scheduled workflow needs `has_actions` on the repository.
#     MEASURED 2026-10-16: `has_actions=false` on David/Primae, so
#     `.forgejo/workflows/ci-verdict-bridge.yml` is DORMANT — and every estate repo
#     that DOES have the unit on reports `{"workflow_runs":[],"total_count":0}`:
#     the instance's single runner has never executed a job. It remains the better
#     long-term home and it is not the verifiable one today.
#
# IT WARNS AND EXITS 0, ALWAYS. A delivery failure must never redden a CI job or a
# launchd job. The exit code reports whether THIS RUNNER worked; the poller's exit
# code reports whether the POLLER worked; neither reports whether CI passed.
#
# STDERR IS NEVER DISCARDED — both streams append to $BRIDGE_LOG.
#
# POSIX sh. Requires: the poller beside it, plus whatever the poller needs
# (curl, jq, gh). curl here is used only for the optional notices below.

set -u
export LC_ALL=C

BRIDGE_HOME=${BRIDGE_HOME:-"$HOME/Library/Application Support/forge-verdict-bridge"}
BRIDGE_LOG=${BRIDGE_LOG:-"$HOME/Library/Logs/forge-verdict-bridge.log"}
POLLER="$BRIDGE_HOME/forge_ci_verdict_bridge.sh"
ENVFILE="$BRIDGE_HOME/bridge.env"

# Optional configuration. Read from bridge.env if the installer wrote one. A value
# already in the environment WINS, so a hand run can point at a test endpoint
# without editing the installed file — the saved copies below restore it after the
# source, since `.` would otherwise overwrite what the caller exported.
: "${NTFY_URL:=}"
: "${HEARTBEAT_URL:=}"
: "${POLLER_ARGS:=}"
_env_ntfy=$NTFY_URL _env_heart=$HEARTBEAT_URL _env_args=$POLLER_ARGS
[ -r "$ENVFILE" ] && . "$ENVFILE"
[ -n "$_env_ntfy" ] && NTFY_URL=$_env_ntfy
[ -n "$_env_heart" ] && HEARTBEAT_URL=$_env_heart
[ -n "$_env_args" ] && POLLER_ARGS=$_env_args
POLLER_ARGS=${POLLER_ARGS:---go}

stamp(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
say(){ printf '%s %s\n' "$(stamp)" "$*"; }

# The log directory must exist before the first append; launchd creates the file
# but not a missing parent beyond ~/Library/Logs, which always exists.
mkdir -p "$(dirname "$BRIDGE_LOG")" 2>/dev/null || true

{
	say "=== bridge run start ==="

	if [ ! -r "$POLLER" ]; then
		say "FAIL: poller not found or unreadable at $POLLER"
		say "      re-install with: sh scripts/install-forge-verdict-bridge.sh --apply"
		RC=66
	else
		# The poller's own output is the record; append it verbatim.
		# POLLER_ARGS is deliberately unquoted: it is a word list, default `--go`.
		# shellcheck disable=SC2086
		sh "$POLLER" $POLLER_ARGS
		RC=$?
	fi
	say "=== bridge run end rc=$RC ==="
} >> "$BRIDGE_LOG" 2>&1

if [ "$RC" -eq 0 ]; then
	# A successful run. Ping the dead-man's switch IF one is configured.
	# Without HEARTBEAT_URL this line is the unit's only liveness record, and its
	# silence is NOT detectable — stated in the delivery, not hidden here.
	if [ -n "$HEARTBEAT_URL" ]; then
		curl -fsS --max-time 15 -o /dev/null "$HEARTBEAT_URL" >> "$BRIDGE_LOG" 2>&1 \
			|| say "WARN: heartbeat ping failed ($HEARTBEAT_URL)" >> "$BRIDGE_LOG" 2>&1
	fi
else
	# A failure. Deliver it as a POSITIVE signal where one is configured, so a
	# reader sees a notification rather than having to notice an absence — the
	# failure mode the estate recorded for its own forgejo-monitor.
	say "WARN: poller exited $RC; see $BRIDGE_LOG" >> "$BRIDGE_LOG" 2>&1
	if [ -n "$NTFY_URL" ]; then
		curl -fsS --max-time 15 -o /dev/null \
			-H "Title: Primae CI verdict bridge FAILED" \
			-H "Priority: high" \
			-H "Tags: warning" \
			-d "the scheduled forge CI verdict bridge exited $RC on $(hostname -s) at $(stamp)" \
			"$NTFY_URL" >> "$BRIDGE_LOG" 2>&1 \
			|| say "WARN: ntfy notice also failed ($NTFY_URL)" >> "$BRIDGE_LOG" 2>&1
	fi
fi

# Never propagate a failure out of the scheduled runner.
exit 0
