#!/bin/sh
# install-forge-verdict-bridge.sh — install the scheduled forge CI verdict bridge on Yo-Mama.
#
# RUN ON: Yo-Mama (macOS) as the operator user, from the repository checkout:
#
#   PLAN  (default, mutates nothing):  sh scripts/install-forge-verdict-bridge.sh
#   APPLY:                             sh scripts/install-forge-verdict-bridge.sh --apply
#   REMOVE:                            sh scripts/install-forge-verdict-bridge.sh --remove --apply
#
# OPTIONS (all optional; a value already in bridge.env is kept, never overwritten):
#   --cadence N          seconds between polls for a FRESH install (default 900)
#   --heartbeat-url URL  dead-man's-switch ping on success (see THE RESIDUAL below)
#   --ntfy-url URL       notification endpoint for a FAILED run
#
# PLAN IS THE DEFAULT AND THE GATE ABORTS. Without --apply this prints what it
# would do and exits 0. With --apply but a failed pre-check it exits non-zero and
# changes nothing. Nothing above the dry-run exit mutates.
#
# WHY NOT lib/opnsense.sh: that library is OPNsense-specific (ol_savepoint writes
# config.xml, ol_configtest drives HAProxy). The target here is a macOS user agent
# and two shell scripts, so the discipline is carried standalone — plan default,
# aborting gate, savepoint before the change, verification on the RESOLVED state,
# stderr never discarded. Same reasoning as homelab-ops bin/w340-bundle-push.sh.
#
# --apply (not --go): the 2026-08-01 ruling makes --apply the canonical gate for
# NEW scripts. --go is reserved for the existing gitflow.sh family.
#
# WHAT IT DOES, in order:
#   1. live pre-checks (below) and sha256 of every artefact, printed
#   2. savepoint: back up any installed copy before overwriting it, idempotently
#   3. deploy the poller and runner to ~/Library/Application Support/forge-verdict-bridge
#   4. re-hash the deployed copies and compare with the source (believe files)
#   5. write bridge.env ONLY if absent
#   6. lint the plist, then copy it and bootstrap the agent
#   7. kickstart one run and read the job back out of launchctl
#   ... rolling the agent back out if the bootstrap fails
#
# THE RESIDUAL, STATED RATHER THAN HIDDEN. Yo-Mama is NOT a scrape target and the
# estate's Healthchecks instance is not reachable from it (MEASURED 2026-10-16:
# 192.168.10.16:8000 answers 404 on /, /ping/<uuid> and /api/v1/checks/). So there
# is no machine that notices this unit going quiet: if it dies, the forge keeps the
# last verdict it posted and nothing says so. That is the estate's known absence
# floor, and it is why the runner delivers a FAILURE as a positive notification
# (--ntfy-url) rather than relying on anyone noticing an absence. Supply
# --heartbeat-url with a dead-man's check you can reach and the residual closes.
#
# POSIX sh. Requires: sh, curl, jq, gh, launchctl, plutil.

set -u
export LC_ALL=C

APPLY=0
REMOVE=0
HEARTBEAT_URL=''
NTFY_URL=''

for a in "$@"; do
	case "$a" in
		--apply) APPLY=1 ;;
		--remove) REMOVE=1 ;;
		--heartbeat-url=*) HEARTBEAT_URL="${a#--heartbeat-url=}" ;;
		--ntfy-url=*) NTFY_URL="${a#--ntfy-url=}" ;;
		--help|-h) sed -n '2,40p' "$0"; exit 0 ;;
		*) echo "FATAL: unknown argument '$a' (try --help)"; exit 2 ;;
	esac
done

# ---------------------------------------------------------------- layout
SRC=$(cd "$(dirname "$0")" && pwd) || exit 1
SRC_POLLER="$SRC/forge_ci_verdict_bridge.sh"
SRC_RUNNER="$SRC/forge-verdict-bridge-runner.sh"
SRC_PLIST="$SRC/../deploy/launchd/com.flamingistan.forge-verdict-bridge.plist"

LABEL='com.flamingistan.forge-verdict-bridge'
BRIDGE_HOME="$HOME/Library/Application Support/forge-verdict-bridge"
BRIDGE_LOG="$HOME/Library/Logs/forge-verdict-bridge.log"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BAK="$BRIDGE_HOME/backup-$STAMP"

RC=0
step(){ printf '\n--- %s\n' "$*"; }
ok(){ printf '    ok   %s\n' "$*"; }
bad(){ printf '    FAIL %s\n' "$*"; RC=1; }
note(){ printf '         %s\n' "$*"; }

dryrun_exit(){
	if [ "$APPLY" -eq 0 ]; then
		printf '\nPLAN ONLY — nothing above was executed and nothing was written.\n'
		printf 'Re-run with --apply to make these changes.\n'
		exit "$1"
	fi
}

# ================================================================ STEP 0
# Live pre-checks. Stated with their measured values; a script that is correct
# against a box that has drifted is the commonest way a correct script does damage.
step "STEP 0 — live pre-checks on $(hostname -s) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

[ "$HOME" = "/Users/musicbox" ] \
	&& ok "operator home is /Users/musicbox (the plist hardcodes this path)" \
	|| bad "operator home is $HOME, but the plist hardcodes /Users/musicbox — edit both or run as the right user"

for b in curl jq gh launchctl plutil; do
	p=$(command -v "$b" 2>/dev/null || true)
	[ -n "$p" ] && ok "$b -> $p" || bad "$b not found on PATH"
done

if command -v gh >/dev/null 2>&1; then
	if gh auth token >/dev/null 2>&1; then
		ok "gh auth token resolves ($(gh auth token 2>/dev/null | wc -c | tr -d ' ') chars, not printed)"
	else
		bad "gh auth token does not resolve — the poller needs a GitHub read credential"
	fi
fi

FTF="${FORGE_TOKEN_FILE:-$HOME/.config/forgejo/push-security.token}"
[ -r "$FTF" ] && ok "forge token readable at $FTF" || bad "forge token not readable at $FTF"

for f in "$SRC_POLLER" "$SRC_RUNNER" "$SRC_PLIST"; do
	[ -r "$f" ] && ok "source artefact present: $(basename "$f")" || bad "source artefact MISSING: $f"
done

# The two calls the poller actually makes, authenticated. An unauthenticated
# /api/v1/version returns 403 here, so the pre-check must carry the token.
if [ -r "$FTF" ]; then
	FT=$(cat "$FTF")
	c=$(curl -s -m 10 -H "Authorization: token $FT" -o /dev/null -w '%{http_code}' \
		"${FORGE_BASE:-https://git.flamingistan.com/api/v1}/repos/David/Primae" 2>/dev/null || echo 000)
	[ "$c" = "200" ] && ok "forge authenticated read -> 200" || bad "forge authenticated read -> $c"
	FT=''
fi
if command -v gh >/dev/null 2>&1; then
	GH=$(gh auth token 2>/dev/null || true)
	c=$(curl -s -m 10 -H "Authorization: Bearer $GH" -H 'Accept: application/vnd.github+json' \
		-o /dev/null -w '%{http_code}' \
		"https://api.github.com/repos/TheDave94/Primae/commits/565ed158/check-runs" 2>/dev/null || echo 000)
	[ "$c" = "200" ] && ok "github check-runs read -> 200" || bad "github check-runs read -> $c"
	GH=''
fi

plutil -lint "$SRC_PLIST" >/dev/null 2>&1 && ok "delivered plist passes plutil -lint" || bad "delivered plist FAILS plutil -lint"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
	ok "agent already loaded (re-install will bootout then bootstrap)"
else
	ok "agent not loaded (fresh install)"
fi

step "sha256 of every artefact, read off disk now"
for f in "$SRC_POLLER" "$SRC_RUNNER" "$SRC_PLIST"; do
	printf '    %s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" "$(basename "$f")"
done

# ================================================================ REMOVE
if [ "$REMOVE" -eq 1 ]; then
	step "REMOVE — boot the agent out and delete its plist (the support dir is kept)"
	note "launchctl bootout $DOMAIN/$LABEL     (failure ignored: it may not be loaded)"
	note "rm -f \"$AGENT_PLIST\""
	note "the support dir $BRIDGE_HOME is NOT removed; delete it by hand for a purge"
	dryrun_exit 0
	launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
	rm -f "$AGENT_PLIST" || { bad "could not remove $AGENT_PLIST"; exit 1; }
	if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
		bad "agent still loaded after bootout — investigate before assuming removal"
		exit 1
	fi
	printf '\nREMOVED. Accepted: launchctl print gui/%s/%s reports no such service.\n' "$(id -u)" "$LABEL"
	exit 0
fi

if [ "$RC" -ne 0 ]; then
	printf '\n'
	bad "a pre-check failed — with --apply this would have aborted here, having changed nothing"
	dryrun_exit 1
	exit 1
fi

# ================================================================ APPLY
step "STEP 2 — savepoint"
note "mkdir -p \"$BRIDGE_HOME\" \"$BAK\"   (0700)"
note "back up any already-installed poller, runner, plist and bridge.env into $BAK"
note "backups are written only if absent, so a re-run cannot overwrite a good copy with a broken one"

step "STEP 3 — deploy the two scripts and re-hash the deployed copies"
note "cp \"$SRC_POLLER\" -> \"$BRIDGE_HOME/forge_ci_verdict_bridge.sh\"   (0700)"
note "cp \"$SRC_RUNNER\" -> \"$BRIDGE_HOME/forge-verdict-bridge-runner.sh\"   (0700)"
note "then shasum both deployed files and compare with the source hashes printed above"

step "STEP 4 — configuration file"
note "$BRIDGE_HOME/bridge.env is written ONLY if absent; an existing one is kept verbatim"
[ -n "$HEARTBEAT_URL" ] && note "would set HEARTBEAT_URL=$HEARTBEAT_URL"
[ -n "$NTFY_URL" ] && note "would set NTFY_URL=$NTFY_URL"
[ -z "$HEARTBEAT_URL" ] && note "no --heartbeat-url given: the unit's silence stays undetectable (see THE RESIDUAL)"

step "STEP 5 — install the agent"
note "plutil -lint the deploy copy, then cp it to \"$AGENT_PLIST\""
note "launchctl bootout $DOMAIN/$LABEL   (failure ignored)"
note "launchctl bootstrap $DOMAIN \"$AGENT_PLIST\"   -> ABORTS AND ROLLS BACK on failure"

step "STEP 6 — verify by reading the resolved state back"
note "launchctl print $DOMAIN/$LABEL must show the label"
note "shasum \"$AGENT_PLIST\" must equal the delivered plist's hash"
note "launchctl kickstart -p $DOMAIN/$LABEL  -> one run now"
note "tail -40 \"$BRIDGE_LOG\"  -> the run's own record"

dryrun_exit 0

# ---- from here on, mutating ------------------------------------------------

step "APPLY — savepoint"
mkdir -p "$BRIDGE_HOME" "$BAK" || { echo "FATAL: cannot create $BRIDGE_HOME"; exit 1; }
chmod 700 "$BRIDGE_HOME" "$BAK" 2>/dev/null || true
for pair in "$SRC_POLLER:$BRIDGE_HOME/forge_ci_verdict_bridge.sh" \
            "$SRC_RUNNER:$BRIDGE_HOME/forge-verdict-bridge-runner.sh" \
            "$SRC_PLIST:$AGENT_PLIST" \
            "$BRIDGE_HOME/bridge.env:$BAK/bridge.env"; do
	s=${pair%%:*}; d=${pair#*:}
	if [ -f "$d" ] && [ ! -f "$BAK/$(basename "$d")" ]; then
		cp "$d" "$BAK/$(basename "$d")" || { echo "FATAL: savepoint failed for $d"; exit 1; }
	fi
done
ok "savepoint at $BAK"

step "APPLY — deploy scripts and verify the deployed bytes"
cp "$SRC_POLLER" "$BRIDGE_HOME/forge_ci_verdict_bridge.sh" || { bad "copy poller"; exit 1; }
cp "$SRC_RUNNER" "$BRIDGE_HOME/forge-verdict-bridge-runner.sh" || { bad "copy runner"; exit 1; }
chmod 700 "$BRIDGE_HOME/forge_ci_verdict_bridge.sh" "$BRIDGE_HOME/forge-verdict-bridge-runner.sh"
for f in forge_ci_verdict_bridge.sh forge-verdict-bridge-runner.sh; do
	a=$(shasum -a 256 "$SRC/$f" | cut -d' ' -f1)
	b=$(shasum -a 256 "$BRIDGE_HOME/$f" | cut -d' ' -f1)
	if [ "$a" = "$b" ]; then ok "deployed $f matches source ($a)"; else bad "deployed $f DOES NOT match source"; exit 1; fi
done

step "APPLY — configuration"
if [ -f "$BRIDGE_HOME/bridge.env" ]; then
	ok "bridge.env exists; kept verbatim"
else
	{
		echo "# forge-verdict-bridge configuration. Sourced by the runner; environment wins."
		[ -n "$HEARTBEAT_URL" ] && echo "HEARTBEAT_URL=$HEARTBEAT_URL"
		[ -n "$NTFY_URL" ] && echo "NTFY_URL=$NTFY_URL"
		echo "POLLER_ARGS=--go"
	} > "$BRIDGE_HOME/bridge.env"
	chmod 600 "$BRIDGE_HOME/bridge.env"
	ok "wrote bridge.env"
fi

step "APPLY — lint, copy and bootstrap the agent"
plutil -lint "$SRC_PLIST" >/dev/null 2>&1 || { bad "plist fails plutil -lint"; exit 1; }
cp "$SRC_PLIST" "$AGENT_PLIST" || { bad "copy plist"; exit 1; }
plutil -lint "$AGENT_PLIST" >/dev/null 2>&1 || { bad "installed plist fails plutil -lint"; rm -f "$AGENT_PLIST"; exit 1; }
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "$DOMAIN" "$AGENT_PLIST" 2>&1; then
	bad "launchctl bootstrap failed — rolling back"
	rm -f "$AGENT_PLIST"
	[ -f "$BAK/$(basename "$AGENT_PLIST")" ] && cp "$BAK/$(basename "$AGENT_PLIST")" "$AGENT_PLIST"
	launchctl bootstrap "$DOMAIN" "$AGENT_PLIST" 2>/dev/null || true
	exit 1
fi
ok "bootstrap accepted"

step "APPLY — verify by reading the resolved state back"
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
	ok "launchctl print $DOMAIN/$LABEL resolves"
else
	bad "the agent does not print back — it is not loaded"
	exit 1
fi
a=$(shasum -a 256 "$SRC_PLIST" | cut -d' ' -f1)
b=$(shasum -a 256 "$AGENT_PLIST" | cut -d' ' -f1)
if [ "$a" = "$b" ]; then ok "installed plist matches delivered plist ($a)"; else bad "installed plist hash differs"; exit 1; fi

launchctl kickstart -p "$DOMAIN/$LABEL" >/dev/null 2>&1 || note "kickstart returned non-zero (RunAtLoad is false; the timer will still fire)"

printf '\n'
printf 'INSTALLED. Acceptance criteria, in order:\n'
printf '  1. launchctl print %s/%s   -> names the label\n' "$DOMAIN" "$LABEL"
printf '  2. tail -40 "%s"\n' "$BRIDGE_LOG"
printf '     -> a "===== bridge run start =====" / "end rc=0" pair, and status lines\n'
printf '  3. the forge shows context ci/github-actions on the current branch heads\n'
printf '\nA FAILURE looks like this and is NOT silent: the log shows rc!=0, and if\n'
printf 'bridge.env sets NTFY_URL a "bridge FAILED" notice is sent there.\n'
printf '\nREMOVE:\n  sh scripts/install-forge-verdict-bridge.sh --remove --apply\n'
exit 0
