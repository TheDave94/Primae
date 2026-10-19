"""Safety tests for the forge CI verdict bridge (audit 2026-10-18, lane L-G).

Four defects, each pinned by a stub run — no network, no keychain, no launchd:
the stubs are `git`, `curl`, `gh` and `launchctl` on PATH, and HOME/TMPDIR are
temp directories.

1. install-forge-verdict-bridge.sh pre-checked
   `~/.config/forgejo/push-security.token` — an ADMIN credential (David, id 1,
   per #59's own header) — while the poller posts as the keychain account
   `push-security`. The gate could pass on a box where the poller had no
   credential at all. It must resolve the poller's own credential.
2. forge_ci_verdict_bridge.sh ran `git credential fill` with no bound: a helper
   that never answers hung the launchd job silently. It must be killed after
   CRED_MAX seconds and reported as a loud failure.
3. Both scripts passed `-H "Authorization: …"` on the curl command line, i.e.
   in argv, visible to any process through `ps`. Headers must travel in a 0600
   file (`-H @file`) that is removed on exit.
4. The installer's savepoint loop wrote the bridge.env pair in the wrong
   direction, so bridge.env was never backed up before deployment overwrote
   the file's neighbours.

`PRIMAE_BRIDGE_SCRIPTS_DIR` points the whole module at another copy of the
scripts (used to run these same checks against main's pre-fix scripts).

Run: python3 scripts/tests/test_forge_verdict_bridge_safety.py -v
"""

from __future__ import annotations

import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
SRC_DIR = Path(os.environ.get("PRIMAE_BRIDGE_SCRIPTS_DIR", SCRIPTS)).resolve()
POLLER = SRC_DIR / "forge_ci_verdict_bridge.sh"
INSTALLER = SRC_DIR / "install-forge-verdict-bridge.sh"
PLIST = SRC_DIR.parent / "deploy" / "launchd" / "com.flamingistan.forge-verdict-bridge.plist"

FORGE_TOKEN = "POLLERTOKEN-nonadmin"
ADMIN_CANARY = "ADMINCANARY-must-not-be-read"
GH_TOKEN = "GHTOKEN-stub"
SHA = "1111222233334444555566667777888899990000"

GIT_STUB = """#!/bin/sh
{ printf 'git'; for a in "$@"; do printf ' %s' "$a"; done; printf '\\n'; } >> "$STUB_LOG"
if [ "$1" = credential ] && [ "$2" = fill ]; then
	if [ "${STUB_GIT_HANG:-0}" = 1 ]; then exec sleep 20; fi
	if [ "${STUB_GIT_FAIL:-0}" = 1 ]; then cat >/dev/null; exit 128; fi
	cat >/dev/null
	if [ -n "${STUB_GIT_DELAY:-}" ]; then /bin/sleep "$STUB_GIT_DELAY"; fi
	printf 'protocol=https\\nhost=git.flamingistan.com\\nusername=push-security\\npassword=%s\\n' "${STUB_FORGE_TOKEN}"
	exit 0
fi
exit 1
"""

GH_STUB = """#!/bin/sh
printf 'gh %s\\n' "$*" >> "$STUB_LOG"
if [ "$1" = auth ] && [ "$2" = token ]; then printf '%s\\n' "${STUB_GH_TOKEN}"; exit 0; fi
exit 1
"""

CURL_STUB = """#!/bin/sh
out=''; want_code=0; url=''
while [ $# -gt 0 ]; do
	case "$1" in
		-o) shift; out="$1" ;;
		-w) shift; want_code=1 ;;
		-H)
			shift
			case "$1" in
				@*)
					hf="${1#@}"
					if [ -f "$hf" ]; then
						printf 'HDRFILE %s mode=%s names=%s\\n' "$hf" \\
							"$(stat -f %Lp "$hf" 2>/dev/null)" \\
							"$(sed -n 's/:.*//p' "$hf" | tr '\\n' ',')" >> "$STUB_LOG"
					else
						printf 'HDRMISSING %s\\n' "$hf" >> "$STUB_LOG"
					fi ;;
				*) printf 'HDRINLINE %s\\n' "$1" >> "$STUB_LOG" ;;
			esac ;;
		-X) shift ;;
		-m|-w) shift ;;
		--data) shift ;;
		-*) ;;
		*) url="$1" ;;
	esac
	shift
done
{ printf 'curl'; for a in "$@"; do printf ' %s' "$a"; done; printf '\\n'; } >> "$STUB_LOG"
body=''; code=200
case "$url" in
	*/statuses/*) body='{"ok":true}'; code=201 ;;
	*/statuses) body='[]' ;;
	*/check-runs*) body='{"total_count":1,"check_runs":[{"status":"completed","conclusion":"success"}]}' ;;
	*/branches*) body='[{"name":"main","commit":{"id":"1111222233334444555566667777888899990000"}}]' ;;
	*/repos/David/Primae) body='{"full_name":"David/Primae"}' ;;
	*/repos/TheDave94/Primae) body='{"full_name":"TheDave94/Primae"}' ;;
	*) body='{}'; code=404 ;;
esac
if [ -n "${STUB_CURL_HOLD:-}" ]; then
	: > "$STUB_HOLD_MARK"
	/bin/sleep "$STUB_CURL_HOLD"
fi
if [ -n "$out" ]; then printf '%s' "$body" > "$out" 2>/dev/null; fi
if [ "$want_code" = 1 ]; then printf '%s' "$code"; else printf '%s' "$body"; fi
exit 0
"""

# Records the pid of every `sleep <STUB_SLEEP_WATCH>` (the credential watchdog's
# own sleep) and then becomes the real sleep, so the pid is the sleep's pid.
SLEEP_STUB = """#!/bin/sh
if [ "$1" = "${STUB_SLEEP_WATCH:-none}" ]; then echo $$ >> "$STUB_SLEEP_PIDS"; fi
exec /bin/sleep "$@"
"""

LAUNCHCTL_STUB = """#!/bin/sh
printf 'launchctl %s\\n' "$*" >> "$STUB_LOG"
case "$1" in
	print) [ -f "$STUB_LAUNCHCTL_STATE" ] && exit 0 || exit 113 ;;
	bootstrap) : > "$STUB_LAUNCHCTL_STATE"; exit 0 ;;
	bootout) rm -f "$STUB_LAUNCHCTL_STATE"; exit 0 ;;
esac
exit 0
"""


class StubHome:
	"""Temp HOME + TMPDIR + a PATH whose first entries are the stubs."""

	def __init__(self):
		self._tmp = tempfile.TemporaryDirectory(prefix="bridge-stubs.")
		self.root = Path(self._tmp.name)
		self.home = self.root / "home"
		self.tmp = self.root / "tmp"
		self.bin = self.root / "bin"
		for d in (self.home, self.tmp, self.bin,
		          self.home / "Library" / "LaunchAgents",
		          self.home / "Library" / "Logs"):
			d.mkdir(parents=True)
		self.log = self.root / "stub.log"
		self.log.write_text("")
		self.state = self.root / "launchctl.state"
		for name, text in (("git", GIT_STUB), ("gh", GH_STUB),
		                   ("curl", CURL_STUB), ("launchctl", LAUNCHCTL_STUB),
		                   ("sleep", SLEEP_STUB)):
			p = self.bin / name
			p.write_text(text)
			p.chmod(0o755)
		self.bridge = self.home / "Library" / "Application Support" / "forge-verdict-bridge"

	def env(self, **extra):
		env = {
			"HOME": str(self.home),
			"TMPDIR": str(self.tmp) + "/",
			"PATH": f"{self.bin}:{os.environ.get('PATH', '/usr/bin:/bin')}",
			"LC_ALL": "C",
			"STUB_LOG": str(self.log),
			"STUB_FORGE_TOKEN": FORGE_TOKEN,
			"STUB_GH_TOKEN": GH_TOKEN,
			"STUB_LAUNCHCTL_STATE": str(self.state),
			"OPERATOR_HOME": str(self.home),
			"STUB_HOLD_MARK": str(self.root / "hold.mark"),
			"STUB_SLEEP_PIDS": str(self.root / "sleep.pids"),
		}
		env.update({k: str(v) for k, v in extra.items()})
		return env

	def seed_admin_token_file(self, content=ADMIN_CANARY):
		d = self.home / ".config" / "forgejo"
		d.mkdir(parents=True, exist_ok=True)
		(d / "push-security.token").write_text(content + "\n")

	def seed_bridge_env(self, content="KEEP_ME=1\n"):
		self.bridge.mkdir(parents=True, exist_ok=True)
		(self.bridge / "bridge.env").write_text(content)

	def run(self, argv, timeout=30, **extra_env):
		"""Run to completion; returns (rc, stdout, stderr)."""
		p = subprocess.run(argv, cwd=str(self.root), env=self.env(**extra_env),
		                   capture_output=True, text=True, timeout=timeout)
		return p.returncode, p.stdout, p.stderr

	def run_bounded(self, argv, limit, **extra_env):
		"""Run with a wall-clock cap; a hung child is killed and reported."""
		started = time.monotonic()
		out_path = self.root / "bounded.out"
		err_path = self.root / "bounded.err"
		with open(out_path, "wb") as fo, open(err_path, "wb") as fe:
			p = subprocess.Popen(argv, cwd=str(self.root), env=self.env(**extra_env),
			                     stdout=fo, stderr=fe)
			timed_out = False
			try:
				rc = p.wait(timeout=limit)
			except subprocess.TimeoutExpired:
				timed_out = True
				p.kill()
				p.wait()
				rc = None
		elapsed = time.monotonic() - started
		return (rc, out_path.read_text(errors="replace"),
		        err_path.read_text(errors="replace"), elapsed, timed_out)

	def run_and_signal(self, argv, signum, limit=25, **extra_env):
		"""Start argv, wait until a stub curl is holding (the script is mid-run),
		send `signum` to the script itself, return (rc, out, err, elapsed_after_signal).
		rc is None if the script was still running after `limit` seconds."""
		mark = self.root / "hold.mark"
		out_path, err_path = self.root / "sig.out", self.root / "sig.err"
		with open(out_path, "wb") as fo, open(err_path, "wb") as fe:
			p = subprocess.Popen(argv, cwd=str(self.root), env=self.env(**extra_env),
			                     stdout=fo, stderr=fe)
			deadline = time.monotonic() + 15
			while not mark.exists() and time.monotonic() < deadline and p.poll() is None:
				time.sleep(0.05)
			sent = time.monotonic()
			p.send_signal(signum)
			try:
				rc = p.wait(timeout=limit)
			except subprocess.TimeoutExpired:
				p.kill()
				p.wait()
				rc = None
		return (rc, out_path.read_text(errors="replace"),
		        err_path.read_text(errors="replace"), time.monotonic() - sent)

	def argv_log(self):
		return self.log.read_text(errors="replace")


# The scripts themselves are macOS-only (keychain, launchctl, BSD stat), so a
# run elsewhere skips rather than reporting shell noise as failures.
needs_macos = unittest.skipUnless(sys.platform == "darwin",
                                  "the bridge scripts are macOS-only")


@needs_macos
class CredentialSourceTests(unittest.TestCase):
	"""Defect 1: the installer must pre-check the poller's credential."""

	def test_precheck_resolves_the_pollers_credential_not_the_admin_file(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		h.seed_admin_token_file()
		rc, out, err = h.run(["/bin/sh", str(INSTALLER)])
		log = h.argv_log()
		self.assertIn("git credential fill", log,
		              f"the installer never called `git credential fill`\n"
		              f"--- stdout ---\n{out}\n--- stderr ---\n{err}")
		self.assertIn("forge credential for the poller resolves via git credential fill",
		              out,
		              f"pre-check did not report the poller's credential path\n"
		              f"--- stdout ---\n{out}")
		self.assertNotIn(ADMIN_CANARY, log,
		         f"the admin token file was read and reached curl argv:\n{log}")
		self.assertNotIn(ADMIN_CANARY, out + err)
		self.assertNotIn("push-security.token", out,
		         f"the admin-file path is still mentioned by the pre-check:\n{out}")
		self.assertEqual(rc, 0, f"plan run should pass its pre-checks\n{out}\n{err}")

	def test_installer_does_not_read_the_admin_file_when_it_is_the_only_one(self):
		# No credential helper answer at all, admin file present: the old gate
		# passed here and the poller then failed every run. Now it must FAIL.
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		h.seed_admin_token_file()
		rc, out, err = h.run(["/bin/sh", str(INSTALLER)],
		                     STUB_FORGE_TOKEN="")
		self.assertNotEqual(rc, 0,
			f"a box with only the admin file must not pass the gate\n{out}")
		self.assertIn("no forge credential for the poller", out,
		              f"expected a loud missing-credential failure\n{out}")


@needs_macos
class CredentialTimeoutTests(unittest.TestCase):
	"""Defect 2: a hung `git credential fill` must not hang the job."""

	def test_hung_helper_is_killed_and_reported(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		rc, out, err, elapsed, timed_out = h.run_bounded(
			["/bin/sh", str(POLLER), "--plan"],
			limit=10,
			GH_TOKEN=GH_TOKEN, CRED_MAX="2", STUB_GIT_HANG="1")
		self.assertFalse(timed_out,
		    f"the poller was still running after 10s with a hung credential "
		    f"helper (CRED_MAX=2) — elapsed {elapsed:.1f}s\n{err}")
		self.assertEqual(rc, 70,
			f"expected FATAL/70, got rc={rc}\n--- stdout ---\n{out}\n--- stderr ---\n{err}")
		self.assertIn("did not answer within 2s", err,
		              f"the timeout was not reported loudly\n{err}")
		self.assertLess(elapsed, 8,
		                f"the kill took {elapsed:.1f}s for CRED_MAX=2")


@needs_macos
class AuthHeaderTests(unittest.TestCase):
	"""Defect 3: no secret in argv; header file is 0600 and removed."""

	def _assert_no_secret_in_argv(self, h, stdout, stderr):
		log = h.argv_log()
		self.assertNotIn(FORGE_TOKEN, log,
		    f"the forge token reached curl's argv:\n{log}\n--- stdout ---\n{stdout}")
		self.assertNotIn(GH_TOKEN, log,
		    f"the GitHub token reached curl's argv:\n{log}\n--- stdout ---\n{stdout}")
		self.assertNotIn("HDRINLINE Authorization", log,
		    f"an Authorization header was passed inline (visible in ps):\n{log}")
		self.assertIn("HDRFILE", log,
		              f"curl was never given a header file:\n{log}\n{stderr}")
		files = [ln.split()[1] for ln in log.splitlines()
		         if ln.startswith("HDRFILE ")]
		self.assertTrue(files, log)
		for line in log.splitlines():
			if line.startswith("HDRFILE "):
				self.assertIn("mode=600", line,
				              f"header file is not 0600: {line}")
				self.assertIn("names=Authorization", line,
				              f"header file does not carry Authorization: {line}")
		return files

	def _assert_files_removed(self, files):
		for f in files:
			self.assertFalse(os.path.exists(f),
			                 f"the auth header file survived the run: {f}")

	def test_poller_plan_keeps_the_token_out_of_argv(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		rc, out, err = h.run(["/bin/sh", str(POLLER), "--plan"])
		self.assertEqual(rc, 0, f"{out}\n{err}")
		files = self._assert_no_secret_in_argv(h, out, err)
		self._assert_files_removed(files)

	def test_poller_post_keeps_the_token_out_of_argv(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		rc, out, err = h.run(["/bin/sh", str(POLLER), "--go"])
		self.assertEqual(rc, 0, f"{out}\n{err}")
		self.assertIn("POSTED  success", out, out)
		files = self._assert_no_secret_in_argv(h, out, err)
		self._assert_files_removed(files)

	def test_installer_keeps_the_token_out_of_argv(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		h.seed_admin_token_file()
		rc, out, err = h.run(["/bin/sh", str(INSTALLER)])
		log = h.argv_log()
		self.assertNotIn(FORGE_TOKEN, log, f"forge token in argv:\n{log}\n{out}")
		self.assertNotIn(GH_TOKEN, log, f"gh token in argv:\n{log}\n{out}")
		self.assertNotIn("HDRINLINE Authorization", log,
		                 f"inline Authorization in argv:\n{log}")
		self.assertIn("HDRFILE", log, log + err)
		files = [ln.split()[1] for ln in log.splitlines()
		         if ln.startswith("HDRFILE ")]
		self._assert_files_removed(files)
		self.assertEqual(rc, 0, f"{out}\n{err}")


@needs_macos
class SavepointTests(unittest.TestCase):
	"""Defect 4: --apply must back up bridge.env before deploying."""

	def test_apply_backs_up_bridge_env(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		h.seed_admin_token_file()
		h.seed_bridge_env("KEEP_ME=1\n")
		rc, out, err = h.run(["/bin/sh", str(INSTALLER), "--apply"])
		self.assertEqual(rc, 0, f"apply failed\n--- stdout ---\n{out}\n--- stderr ---\n{err}")
		backups = sorted(h.bridge.glob("backup-*/bridge.env"))
		self.assertTrue(backups,
			f"bridge.env was not backed up before deployment; "
			f"support dir now holds {sorted(p.name for p in h.bridge.iterdir())}"
			f"\n--- stdout ---\n{out}")
		self.assertEqual(backups[0].read_text(), "KEEP_ME=1\n",
		                 "the backup is not the installed file's content")
		# the deployed copy still exists and bridge.env was kept verbatim
		self.assertEqual((h.bridge / "bridge.env").read_text(), "KEEP_ME=1\n")
		self.assertIn("bootstrap", h.argv_log(), h.argv_log())

	def test_apply_is_idempotent_and_savepoint_never_overwrites_a_good_backup(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		h.seed_admin_token_file()
		h.seed_bridge_env("FIRST=1\n")
		rc, out, err = h.run(["/bin/sh", str(INSTALLER), "--apply"])
		self.assertEqual(rc, 0, f"{out}\n{err}")
		# A second install in the same second must reuse the backup, not
		# clobber it with a copy of something else.
		rc, out, err = h.run(["/bin/sh", str(INSTALLER), "--apply"])
		self.assertEqual(rc, 0, f"{out}\n{err}")
		# Every savepoint (there may be one per run) holds the file's original
		# content; none was overwritten with the freshly deployed neighbours.
		backups = sorted(h.bridge.glob("backup-*/bridge.env"))
		self.assertTrue(backups, "no bridge.env savepoint at all")
		for b in backups:
			self.assertEqual(b.read_text(), "FIRST=1\n", str(b))


HOLD = 3  # seconds each stub curl holds; a script that carries on runs several


@needs_macos
class SignalTests(unittest.TestCase):
	"""A terminating signal must END the script, not just trigger cleanup.

	A trap handler that returns lets the script continue: a TERM/HUP mid-run
	used to leave the poller finishing with its header files already deleted,
	and a TERM into `--apply` ran on through `launchctl bootstrap`. The script
	acts on the signal when the foreground stub curl returns (POSIX defers a
	trap until the current foreground command ends), so a correct run ends
	after ONE held curl, never the several a run-to-completion needs.
	"""

	def _leftovers(self, h):
		return sorted(p.name for p in h.tmp.iterdir())

	def _assert_stopped(self, h, rc, expected_rc, label):
		curls = [ln for ln in h.argv_log().splitlines() if ln == "curl" or ln.startswith("curl ")]
		self.assertEqual(rc, expected_rc,
		    f"{label}: expected rc {expected_rc}, got {rc} (None = still running)\n"
		    f"{h.argv_log()}")
		self.assertEqual(len(curls), 1,
		    f"{label}: the script went on to later curl calls after the signal "
		    f"({len(curls)} curls):\n{h.argv_log()}")
		self.assertNotIn("HDRMISSING", h.argv_log(),
		    f"{label}: a later curl found its header file already deleted")
		self.assertEqual(self._leftovers(h), [],
		    f"{label}: temp files survived the signal: {self._leftovers(h)}")

	def _poller_signal(self, signum, expected_rc):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		rc, out, err, after = h.run_and_signal(
			["/bin/sh", str(POLLER), "--plan"], signum,
			STUB_CURL_HOLD=str(HOLD), GH_TOKEN=GH_TOKEN)
		self._assert_stopped(h, rc, expected_rc, f"poller {signum.name}")
		self.assertLess(after, HOLD + 3, f"poller took {after:.1f}s to stop")

	def test_poller_stops_on_term(self):
		self._poller_signal(signal.SIGTERM, 143)

	def test_poller_stops_on_hup(self):
		self._poller_signal(signal.SIGHUP, 129)

	def test_poller_stops_on_int(self):
		self._poller_signal(signal.SIGINT, 130)

	def test_installer_apply_stops_on_term_before_bootstrap(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		h.seed_admin_token_file()
		rc, out, err, after = h.run_and_signal(
			["/bin/sh", str(INSTALLER), "--apply"], signal.SIGTERM,
			STUB_CURL_HOLD=str(HOLD))
		self._assert_stopped(h, rc, 143, "installer --apply TERM")
		self.assertNotIn("launchctl bootstrap", h.argv_log(),
		    f"TERM did not stop --apply: it reached launchctl bootstrap\n{h.argv_log()}")
		self.assertFalse(h.state.exists(), "the stub agent was bootstrapped")
		self.assertLess(after, HOLD + 3, f"installer took {after:.1f}s to stop")


@needs_macos
class WatchdogSleepTests(unittest.TestCase):
	"""The credential watchdog must not leave its `sleep $CRED_MAX` behind."""

	def test_fast_credential_leaves_no_orphaned_sleep(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		rc, out, err = h.run(["/bin/sh", str(POLLER), "--plan"],
		                     STUB_SLEEP_WATCH="47", CRED_MAX="47",
		                     STUB_GIT_DELAY="0.5")
		self.assertEqual(rc, 0, f"{out}\n{err}")
		pids = [int(x) for x in (h.root / "sleep.pids").read_text().split()] \
			if (h.root / "sleep.pids").exists() else []
		self.assertTrue(pids, "the watchdog's sleep was never observed — the "
		                "test would be vacuous")
		deadline = time.monotonic() + 3
		alive = pids
		while alive and time.monotonic() < deadline:
			alive = [p for p in pids if _alive(p)]
			time.sleep(0.05)
		self.assertEqual(alive, [],
		    f"the watchdog's `sleep 47` outlived the run (pids {alive})")
		for p in alive:  # never leave a 47 s orphan behind a red test
			os.kill(p, signal.SIGKILL)


def _alive(pid):
	try:
		os.kill(pid, 0)
		return True
	except ProcessLookupError:
		return False


@needs_macos
class DieWordingTests(unittest.TestCase):
	"""The poller's die line must say which failure it was."""

	def test_fast_failure_is_not_called_a_timeout(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		rc, out, err = h.run(["/bin/sh", str(POLLER), "--plan"], STUB_GIT_FAIL="1",
		                     GH_TOKEN=GH_TOKEN)
		self.assertEqual(rc, 70, f"{out}\n{err}")
		self.assertIn("exited non-zero", err, err)
		self.assertNotIn("timed out", err, f"a fast failure was reported as a timeout\n{err}")

	def test_a_real_timeout_says_timed_out(self):
		h = StubHome()
		self.addCleanup(h._tmp.cleanup)
		rc, out, err = h.run(["/bin/sh", str(POLLER), "--plan"], timeout=20,
		                     STUB_GIT_HANG="1", CRED_MAX="2", GH_TOKEN=GH_TOKEN)
		self.assertEqual(rc, 70, f"{out}\n{err}")
		self.assertIn("timed out after 2s", err, err)


if __name__ == "__main__":
	unittest.main(verbosity=2)
