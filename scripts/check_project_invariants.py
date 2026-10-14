#!/usr/bin/env python3
"""check_project_invariants.py — drift tripwire + build provenance gate.

WHY THIS EXISTS. Xcode has repeatedly rewritten Primae/Info.plist and/or
Primae/Primae.xcodeproj/project.pbxproj on open or save, silently
discarding decided settings: the study/casual display-name split, the
landscape-only orientation lock, UIRequiresFullScreen, and once an
outright iOS 27 deployment-target bump — a study-instrument change nobody
decided, landed by an editor, not a person.

RULING (supervisor, 2026-09-15): the CONTENTS of these two files are not
Xcode's to author — they're git's, checked in, decided. This is
unchanged and does not mean "don't build via Xcode's UI"; that build
stays, and stayed working the whole time. The two are different claims.

THE DEVICE PATH IS XCODE'S UI, NOT A SCRIPT (supervisor ruling,
2026-09-15, correcting scripts/deploy_verified_pilot_build.sh being
handed to David as the way to get a provenance-attributable build onto
the iPad — David was explicit the device path is the Run button, and a
provenance requirement can be satisfied there just as well). This script
is now also where that requirement lives: gate_provenance(), called at
the end of every --autofix run, refuses the build outright when the tree
can't be attributed to a commit, and otherwise prints the commit,
branch, and resolved configuration into the build log where David reads
it before installing. See gate_provenance()'s own docstring for exactly
what is and isn't satisfiable at that point in the build.

THREE THINGS THIS SCRIPT DOES NOW, IN ONE RUN (--autofix): heal known
drift, gate provenance, never fail for the first reason, always fail for
the second. They are different failure classes on purpose — see below.

TWO MODES, because a local UI build and a CI dispatch have different
correct responses to the exact same drift finding (supervisor ruling,
2026-09-15, correcting the first version of this script — that version
hard-failed a local Clean for a rewrite David never asked for, which
made the guard itself the outage):

  --autofix (the Primae scheme's Pre-actions script; local, interactive):
    for DRIFT matching a KNOWN decided-shape violation (every check
    below), restore the file from HEAD via `git checkout --`, print
    exactly what was wrong and what was restored — a rewrite Xcode
    performs unprompted overrides no one, so undoing it is not an
    authoring act either. Before each restore the working copy is saved
    under the common git dir's primae-autofix-backups/<worktree>/<timestamp>/
    (newest 20 runs kept) and the path is printed; if that backup cannot be made, the file is NOT restored (R-057:
    the restore used to erase uncommitted edits with no copy kept). Anything this script cannot positively
    identify (an exception while parsing, a shape it has no check for)
    is reported and left untouched. None of that fails the build. Then
    gate_provenance() runs regardless, and THAT can fail the build — see
    its own docstring for why that is not the same mistake as before.

  (default, no flag; CI): report every drift finding and exit 1. A red CI
    run costs nobody a waiting build — this is where "fail" on drift is
    still the right verb, and auto-fixing here would let a bad push look
    clean. CI never calls gate_provenance() — a pushed commit is already
    attributable by definition; the provenance question only exists for
    an interactive install off a possibly-dirty local tree.

ACTION=clean: skipped entirely, unconditionally, before any file is even
read. A Clean produces no build settings and ships nothing; running this
against a Clean is where the first version of this script actually broke
David's UI — Xcode runs a scheme's Pre-actions on Clean too, measured
directly (a Clean triggered the hard-fail on his machine), not assumed.

MID-BUILD FILE-WRITE — PARTIALLY MEASURED, THE REST REASONED, KEPT
DISTINCT (2026-09-15). What was actually measured: a local `xcodebuild
build -destination 'generic/platform=iOS Simulator'` (no
CoreSimulatorService/CoreDeviceService needed for a generic destination —
unlike `test`/install actions) reached this script mid-build against the
real, live-corrupted tree this incident produced, and the script's
(pre-autofix) hard-fail correctly stopped the build right there — proof
the Pre-action genuinely executes inside a real xcodebuild invocation,
not just in isolation. That same local xcodebuild access then turned out
NOT reliable: three subsequent attempts (including one built specifically
to inspect the FINAL built Info.plist's CFBundleDisplayName after an
--autofix restore) all failed earlier, at package resolution, with
`error: permissionDenied` — matching this project's own already-
documented finding that this sandboxed seat's Xcode/CoreSimulatorService
access is intermittent, not the reliable capability the one earlier
success looked like. The mid-build question itself is therefore NOT
independently confirmed by measurement; it is reasoned from Xcode's
documented build model: project.pbxproj defines the build-settings graph
Xcode resolves ONCE, before any Pre-action runs, so a same-build
self-heal of a pbxproj value is very unlikely — while Info.plist is
merged later in the same build (builtin-infoPlistUtility runs after
Pre-actions), so a same-build self-heal is more plausible there. Treat
the pbxproj half as the safer assumption to design around (a second
build may be required) until someone actually observes the built
artifact and can say so from measurement, not reasoning.

SELF-CHECK: the local half of the wiring above lives inside
Primae.xcscheme, itself a file Xcode rewrites. check_scheme_wiring()
below runs from CI (which does not depend on the scheme's Pre-action
being intact to be reached) and fails loudly there if the wiring goes
missing — a guard that cannot detect its own removal is the same defect
this script exists to fix. There is nothing to restore for this one
locally (a missing Pre-action can't run itself to notice its own
absence) — CI is the only backstop for this specific finding, by
construction, not by omission.
"""
import argparse
import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
INFO_PLIST = ROOT / "Primae" / "Info.plist"
PBXPROJ = ROOT / "Primae" / "Primae.xcodeproj" / "project.pbxproj"
XCSCHEME = ROOT / "Primae" / "Primae.xcodeproj" / "xcshareddata" / "xcschemes" / "Primae.xcscheme"

# (file, message) — grouped by file so --autofix knows what to restore.
findings: list[tuple[pathlib.Path, str]] = []


# The decided shape of Primae/Info.plist: (key, value element). Any other key,
# or a changed value, fails check_info_plist().
# R-063 (audit 2026-10-13): UIFileSharingEnabled and
# LSSupportsOpeningDocumentsInPlace are deliberately NOT here. They exposed
# Documents/ in Files/Finder for the calibrator, which no build compiles;
# a reappearance is reported as an unexpected key.
INFO_PLIST_EXPECTED = [
    ("ITSAppUsesNonExemptEncryption", "<false/>"),
]

# R-112 (audit 2026-10-13). One team, everywhere: a dead project-level team
# (XMX37BH48B, no account on the build machine) already broke two targets
# (b1ab17a, 51f29ac5) because only per-target overrides hid it.
EXPECTED_TEAM = "J7JH8FJK2W"
EXPECTED_DEPLOYMENT_TARGET = "27.0"
# IPHONEOS_DEPLOYMENT_TARGET entries in project.pbxproj (bin/toolchain.pin:
# "all 12"). Counted, not searched: one unanchored `re.search` passed with
# eleven of twelve reverted.
EXPECTED_DEPLOYMENT_TARGET_COUNT = 12
# Xcode 27.x (DTXcode 27xx). With 2640 Xcode 27 offers "Update to recommended
# settings" and rewrites the file; a reviewed bump stops the prompt. Checked
# by MAJOR (27xx), not exactly: an Xcode 27.3 upgrade writes 2730, and an exact
# pin would make the pre-action autofix revert the project file over it.
EXPECTED_UPGRADE_MARKER_MAJOR = "27"


def upgrade_marker_ok(markers: list) -> bool:
    return (len(markers) == 1
            and re.fullmatch(rf"{EXPECTED_UPGRADE_MARKER_MAJOR}\d\d", markers[0]) is not None)
# All four XCConfigurationLists default to the study configuration; "Release"
# is the casual configuration, which cannot link (CLAUDE.md "Study builds").
EXPECTED_DEFAULT_CONFIGURATION = "Release-Study"


def check_info_plist() -> None:
    text = INFO_PLIST.read_text()
    # The decided shape: exactly the keys in INFO_PLIST_EXPECTED, this value
    # each. Not "at least these" — an extra key or a reordered/reformatted file is
    # itself a sign Xcode's plist editor touched the file (see the module
    # docstring), so the count is checked too, not just presence.
    required = INFO_PLIST_EXPECTED
    for key, expected in required:
        if not re.search(rf"<key>{re.escape(key)}</key>\s*{re.escape(expected)}", text):
            findings.append((INFO_PLIST, f"<key>{key}</key> {expected} missing or altered"))
    # R-112 (G2-09c): the key SET is the table above, and a deviation names
    # the key. It used to compare a bare count, which said "expected exactly
    # 3 keys, found 4" without saying which. Changing the plist's shape on
    # purpose is now one edit to INFO_PLIST_EXPECTED, in the same commit.
    allowed = {k for k, _ in required}
    present = re.findall(r"<key>([^<]*)</key>", text)
    for key in sorted(set(present) - allowed):
        findings.append((INFO_PLIST,
            f"unexpected key <key>{key}</key> — not in INFO_PLIST_EXPECTED "
            f"(Xcode's plist editor rewrites the whole file and drops comments; "
            f"a deliberate new key needs the checker table changed with it)"))
    for key in sorted({k for k in present if present.count(k) > 1}):
        findings.append((INFO_PLIST, f"duplicate key <key>{key}</key>"))


# Only the Primae APP target's own build configurations carry an app icon;
# PrimaeNativeTests/PrimaeUITests configs of the same name must not be
# checked against app-identity keys they were never meant to carry.
_APP_MARKER = "ASSETCATALOG_COMPILER_APPICON_NAME"
_BLOCK_RE = re.compile(
    r"\n\t\t[0-9A-Za-z]+ /\* (Debug-Study|Release-Study) \*/ = \{\n(.*?)\n\t\t\};",
    re.DOTALL,
)


def check_pbxproj() -> None:
    text = PBXPROJ.read_text()

    # The iOS 27 deployment-target move WAS gated here behind the on-device
    # audio listen (supervisor ruling, 2026-09-15) — it opened on evidence,
    # not because an editor bumped a build setting while the project was open.
    #
    # GATE OPENED 2026-10-01 on David's explicit instruction, in the same
    # session as the F11 toolchain pin (bin/toolchain.pin). 27.0 is now the
    # EXPECTED value, and the tripwire is INVERTED rather than deleted: Xcode
    # has silently rewritten this file before, so what is worth failing on now
    # is the value being MISSING, not present.
    #
    # This was a deliberate change to a supervisor control, not a bug fix.
    # Read the commit message before touching it. Revisiting the iOS 26
    # device-support exclusion (a school iPad still on iOS 26.x cannot install
    # this build) is a separate decision with its own evidence — not something
    # to undo quietly here.
    targets = re.findall(r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([^;\s]+);", text)
    wrong = [t for t in targets if t != EXPECTED_DEPLOYMENT_TARGET]
    if wrong or len(targets) != EXPECTED_DEPLOYMENT_TARGET_COUNT:
        findings.append((PBXPROJ,
            f"IPHONEOS_DEPLOYMENT_TARGET = {EXPECTED_DEPLOYMENT_TARGET} expected in "
            f"all {EXPECTED_DEPLOYMENT_TARGET_COUNT} entries (pinned 2026-10-01, see "
            f"bin/toolchain.pin); found {len(targets)} entries, "
            f"{len(wrong)} with another value {sorted(set(wrong))} — this file "
            f"has been silently rewritten before; restore with git rather than "
            f"re-deriving"))

    # R-112 (G2-09a): every DEVELOPMENT_TEAM, project level included.
    teams = re.findall(r"DEVELOPMENT_TEAM\s*=\s*([^;\s]+);", text)
    foreign = sorted({t for t in teams if t != EXPECTED_TEAM})
    if foreign:
        findings.append((PBXPROJ,
            f"DEVELOPMENT_TEAM must be {EXPECTED_TEAM} everywhere; found {foreign} "
            f"— a team with no account on the build machine fails signing for "
            f"any target that inherits it"))

    # R-112 (G2-20): see EXPECTED_DEFAULT_CONFIGURATION.
    defaults = re.findall(r"defaultConfigurationName\s*=\s*([^;\s]+);", text)
    bad_defaults = sorted({d for d in defaults if d != EXPECTED_DEFAULT_CONFIGURATION})
    if bad_defaults or not defaults:
        findings.append((PBXPROJ,
            f"defaultConfigurationName must be {EXPECTED_DEFAULT_CONFIGURATION} in "
            f"every XCConfigurationList; found {bad_defaults or 'none'} — a bare "
            f"xcodebuild/-showBuildSettings would resolve to a configuration "
            f"that cannot link"))

    # R-112 (G2-14): the key does nothing (the build system has no such
    # INFOPLIST_KEY entry; fonts are registered by PrimaeFonts.registerAll())
    # and invites the false belief that fonts are registered by plist.
    if "INFOPLIST_KEY_UIAppFonts" in text:
        findings.append((PBXPROJ,
            "INFOPLIST_KEY_UIAppFonts must not exist — it is not a supported "
            "generated key, and fonts are registered in code "
            "(PrimaeFonts.registerAll)"))

    # R-112 (G2-09d)
    upgrade = re.findall(r"LastUpgradeCheck\s*=\s*([^;\s]+);", text)
    if not upgrade_marker_ok(upgrade):
        findings.append((PBXPROJ,
            f"LastUpgradeCheck must be {EXPECTED_UPGRADE_MARKER_MAJOR}xx; found {upgrade}"))

    # Xcode's INFOPLIST_KEY_* auto-generation is a second, competing
    # encoding of plist facts and has produced a real drift incident more
    # than once. ITSAppUsesNonExemptEncryption lives in Info.plist only;
    # LSSupportsOpeningDocumentsInPlace must not be set at all (R-063), and
    # this is the one route by which it could return without touching
    # Info.plist.
    for forbidden in ("INFOPLIST_KEY_ITSAppUsesNonExemptEncryption",
                      "INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace"):
        if forbidden in text:
            findings.append((PBXPROJ,
                f"{forbidden} must not exist — this key lives in Info.plist "
                f"only, not as an auto-generated build setting"))

    study_blocks = [(name, body) for name, body in _BLOCK_RE.findall(text)
                     if _APP_MARKER in body]
    if len(study_blocks) != 2:
        findings.append((PBXPROJ,
            f"expected exactly 2 app-target Study build configurations "
            f"(Debug-Study, Release-Study), found {len(study_blocks)} — the "
            f"parser's block pattern may need updating, or a configuration "
            f"was added/removed"))

    for name, body in study_blocks:
        if 'INFOPLIST_KEY_CFBundleDisplayName = "Primae Studie";' not in body:
            findings.append((PBXPROJ,
                f'{name} (app target) — CFBundleDisplayName is not "Primae '
                f'Studie" (on-device study/casual distinctness, CLAUDE.md '
                f'"On-device distinctness")'))
        if "INFOPLIST_KEY_UIRequiresFullScreen = YES;" not in body:
            findings.append((PBXPROJ,
                f"{name} (app target) — UIRequiresFullScreen = YES is missing"))
        orientations = re.search(
            r'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "([^"]*)";', body)
        if not orientations:
            findings.append((PBXPROJ,
                f"{name} (app target) — UISupportedInterfaceOrientations_iPad "
                f"is missing"))
        elif "Portrait" in orientations.group(1):
            findings.append((PBXPROJ,
                f'{name} (app target) — iPad orientations include Portrait '
                f'("{orientations.group(1)}"); the study configuration is '
                f"landscape-only (a mid-session rotation re-maps checkpoints "
                f"and changes the letter's physical size)"))


def check_scheme_wiring() -> None:
    text = XCSCHEME.read_text()
    if "check_project_invariants.py" not in text or "<PreActions>" not in text:
        # Deliberately NOT paired with a file to restore: this finding
        # means the mechanism that would restore anything locally isn't
        # running, so it can only ever be seen from CI. See module
        # docstring, "SELF-CHECK".
        findings.append((None,
            "Primae.xcscheme: the Pre-actions build script wiring this "
            "checker into every local build is missing — CI is the only "
            "thing that can still see this finding"))


def check_scheme_upgrade_markers() -> None:
    """R-112 (G2-09d): every shared scheme carries the reviewed upgrade
    marker (see EXPECTED_UPGRADE_MARKER_MAJOR)."""
    for scheme in sorted(XCSCHEME.parent.glob("*.xcscheme")):
        found = re.findall(r'LastUpgradeVersion\s*=\s*"([^"]*)"', scheme.read_text())
        if not upgrade_marker_ok(found):
            findings.append((scheme,
                f"LastUpgradeVersion must be {EXPECTED_UPGRADE_MARKER_MAJOR}xx; found {found}"))


def run_all_checks() -> None:
    findings.clear()
    check_info_plist()
    check_pbxproj()
    check_scheme_wiring()
    check_scheme_upgrade_markers()


def backup(path: pathlib.Path, run_dir: pathlib.Path) -> pathlib.Path:
    """Copy the working-tree file into this run's backup directory before
    restore() overwrites it, and return the copy's path. R-057: restore()
    is `git checkout --`, which discards every uncommitted edit in the file,
    deliberate ones included, and the provenance gate runs only AFTER it, so
    it never sees what was erased. The directory lives inside the common
    git dir (see backup_run_dir()), so the copy never shows in `git status`
    and cannot trip gate_provenance(). Raises on any
    failure; the caller then refuses to restore.
    """
    check_backup_tree(run_dir)
    dest = run_dir / path.relative_to(ROOT)
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dest)
    if dest.read_bytes() != path.read_bytes():
        raise OSError(f"backup copy {dest} does not match {path}")
    return dest


BACKUP_RUNS_KEPT = 20
BACKUP_ROOT_NAME = "primae-autofix-backups"
_RUN_DIR_RE = re.compile(r"[0-9]{8}T[0-9]{6}-[0-9]+")


def worktree_folder_name(root: pathlib.Path) -> str:
    """One folder name per absolute worktree path, injective in practice.
    A readable slug (the path with every run of characters outside
    [A-Za-z0-9._] turned into "-", last 60 characters) so a person can tell
    the folders apart, plus the first 12 hex digits of sha256 of the exact
    path, which is what makes it one-to-one: the slug alone is not
    (`/x/a-b/c/Primae` and `/x/a/b-c/Primae` slug identically).
    """
    path = str(root)
    slug = re.sub(r"[^A-Za-z0-9._]+", "-", path).strip("-")[-60:].strip("-")
    digest = hashlib.sha256(path.encode("utf-8")).hexdigest()[:12]
    return f"{slug}-{digest}"


def check_backup_tree(run_dir: pathlib.Path) -> None:
    """Raise OSError unless <backup root>/<worktree> is a real directory
    (or absent) directly inside a real backup root. A symlinked worktree
    folder or backup root would make mkdir() write, and the trim DELETE,
    outside the backup tree; callers treat the raise as "no backup, no
    restore" and "no trim" respectively.
    """
    worktree_dir = run_dir.parent
    root = worktree_dir.parent
    if root.name != BACKUP_ROOT_NAME:
        raise OSError(f"{root} is not a {BACKUP_ROOT_NAME} directory")
    for d in (root, worktree_dir):
        if d.is_symlink():
            raise OSError(f"{d} is a symlink; refusing to use the backup tree through it")
    if worktree_dir.resolve().parent != root.resolve():
        raise OSError(f"{worktree_dir} resolves outside {root}")


def backup_run_dir() -> pathlib.Path:
    """<common git dir>/primae-autofix-backups/<worktree>/<timestamp>-<pid>.
    The COMMON git dir, not the per-worktree one: `git worktree remove`
    deletes a linked worktree's own git dir, and the backups with it.
    <worktree> is worktree_folder_name(ROOT): every worktree of this repo
    is named `Primae` (the SPM relative path requires it), so the bare
    directory name would merge them all. The stamp is UTC so a DST change
    cannot reorder runs, and name order stays chronological.
    """
    common = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute",
                             "--git-common-dir"],
                            capture_output=True, text=True, check=True).stdout.strip()
    stamp = time.strftime("%Y%m%dT%H%M%S", time.gmtime()) + f"-{os.getpid()}"
    return pathlib.Path(common) / BACKUP_ROOT_NAME / worktree_folder_name(ROOT) / stamp


def prune_backups(run_dir: pathlib.Path) -> None:
    """Keep the newest BACKUP_RUNS_KEPT run directories for this worktree.
    Only directories named like a run (<timestamp>-<pid>) are candidates;
    the timestamp prefix makes name order chronological. Best-effort: a
    failure is reported ("could not ...") and changes nothing else.
    """
    try:
        check_backup_tree(run_dir)
        runs = sorted(p for p in run_dir.parent.iterdir()
                      if p.is_dir() and not p.is_symlink() and _RUN_DIR_RE.fullmatch(p.name))
    except OSError as e:
        print(f"  ! could not prune old autofix backups in {run_dir.parent}: {e!r}")
        return
    for old in runs[:-BACKUP_RUNS_KEPT]:
        if old == run_dir:
            continue
        try:
            shutil.rmtree(old)
        except OSError as e:
            print(f"  ! could not prune old autofix backup {old}: {e!r}")


def restore(path: pathlib.Path) -> None:
    subprocess.run(["git", "-C", str(ROOT), "checkout", "--", str(path.relative_to(ROOT))],
                   check=True)


def gate_provenance() -> int:
    """--autofix only, called after drift handling completes either way.
    THE PROVENANCE REQUIREMENT (supervisor ruling, 2026-09-15): the binary
    this build installs must be attributable to a commit. This is not
    satisfied by "the two known files match HEAD" alone — any OTHER
    uncommitted change anywhere in the tree means the build still isn't
    attributable, and unlike Xcode's own unprompted rewrites, that dirt IS
    something a person chose (or a real other process did), so it is not
    this script's to silently override. This is the one place --autofix
    is allowed to fail the build — refusing an unattributable install is
    about the artefact, not about punishing anyone for Xcode's rewrites.
    """
    dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain"],
                            capture_output=True, text=True, check=True).stdout
    if dirty.strip():
        print("FATAL: the working tree is not clean — this build cannot be "
              "attributed to a commit, and installing it would be a wasted "
              "listen (or worse, if it passes).")
        print(dirty, end="" if dirty.endswith("\n") else "\n")
        print(f"Fix: commit or discard the changes above (git -C {ROOT} status), "
              f"then build again.")
        return 1

    sha = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"],
                          capture_output=True, text=True, check=True).stdout.strip()
    branch = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--abbrev-ref", "HEAD"],
                             capture_output=True, text=True, check=True).stdout.strip()
    # CONFIGURATION is a standard xcodebuild build setting; Xcode exports
    # the full build-settings environment to a scheme Pre-action that
    # names a target via EnvironmentBuildable (the same mechanism ACTION
    # already relies on, in the scheme's own shell wrapper) — reasoned
    # from Xcode's documented Pre-action behavior, NOT independently
    # re-confirmed live: this sandbox's local xcodebuild access proved too
    # unreliable this session (intermittent CoreSimulatorService/package-
    # resolution failures) to capture a real environment dump. Coded
    # defensively rather than assumed present, precisely because of that.
    configuration = os.environ.get("CONFIGURATION", "<unknown — $CONFIGURATION was not set>")
    print("================================================================")
    print("PROVENANCE — this build is about to install:")
    print(f"  commit:        {sha} ({sha[:7]})")
    print(f"  branch:        {branch}")
    print(f"  configuration: {configuration}")
    print("================================================================")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--autofix", action="store_true",
                         help="restore drifted files from HEAD and never fail "
                              "(the local, interactive mode)")
    args = parser.parse_args()

    try:
        run_all_checks()
    except Exception as e:  # noqa: BLE001 — deliberately broad, see docstring
        if args.autofix:
            print(f"could not evaluate project-settings invariants: {e!r} "
                  f"— reporting only, not touching anything")
            return gate_provenance()
        print(f"FAIL — could not evaluate project-settings invariants: {e!r}")
        return 1

    if not findings:
        print("ok — Info.plist and project.pbxproj match the decided invariants")
        return gate_provenance() if args.autofix else 0

    by_file: dict = {}
    for path, message in findings:
        by_file.setdefault(path, []).append(message)

    if not args.autofix:
        print("FAIL — project-settings drift detected. These two files are not "
              "Xcode's to author (see this script's module docstring).")
        for path, messages in by_file.items():
            label = path.relative_to(ROOT) if path else "(no single file — see below)"
            for m in messages:
                print(f"  - {label}: {m}")
        restorable = [p.relative_to(ROOT) for p in by_file if p]
        print()
        if restorable:
            print("Fix: git -C " + str(ROOT) + " checkout -- "
                  + " ".join(str(p) for p in restorable))
        else:
            print("Fix: no single file to restore for the finding(s) above — see "
                  "each one for what to do.")
        return 1

    # --autofix: restore what can be restored, report what can't, never fail.
    print("Project-settings drift found — restoring from HEAD (Xcode's rewrite "
          "is not an authoring act; this does not override a decision):")
    restored: list[pathlib.Path] = []
    run_dir = None
    for path, messages in by_file.items():
        for m in messages:
            print(f"  - {path.relative_to(ROOT) if path else '(unattributed)'}: {m}")
        if path is not None:
            # No backup, no restore (R-057): leave the file as it is. The
            # tree then stays dirty and gate_provenance() refuses the build,
            # which costs a rebuild, not somebody's edit.
            try:
                if run_dir is None:
                    run_dir = backup_run_dir()
                saved = backup(path, run_dir)
            except Exception as e:  # noqa: BLE001 — any failure means no restore
                print(f"  ! NOT restoring {path.relative_to(ROOT)}: could not back up "
                      f"the working copy first ({e!r}); left untouched")
                continue
            print(f"  backup: {saved}")
            prune_backups(run_dir)
            try:
                restore(path)
                restored.append(path)
            except subprocess.CalledProcessError as e:
                print(f"  ! could not restore {path.relative_to(ROOT)}: {e}")

    if restored:
        run_all_checks()
        still_broken = {p for p, _ in findings if p in restored}
        for path in restored:
            if path in still_broken:
                print(f"! restored {path.relative_to(ROOT)}, but it still doesn't "
                      f"match — see the finding above, not auto-fixable")
            else:
                print(f"ok — restored {path.relative_to(ROOT)} to the committed state")
        if PBXPROJ in restored:
            print("NOTE: project.pbxproj defines this build's settings before any "
                  "Pre-action runs, so this fix very likely landed on disk too late "
                  "for THIS build to use it (reasoned from Xcode's build model, not "
                  "independently observed — see module docstring). Build again.")

    return gate_provenance()


if __name__ == "__main__":
    sys.exit(main())
