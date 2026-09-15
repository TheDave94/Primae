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
    authoring act either. Anything this script cannot positively
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
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
INFO_PLIST = ROOT / "Primae" / "Info.plist"
PBXPROJ = ROOT / "Primae" / "Primae.xcodeproj" / "project.pbxproj"
XCSCHEME = ROOT / "Primae" / "Primae.xcodeproj" / "xcshareddata" / "xcschemes" / "Primae.xcscheme"

# (file, message) — grouped by file so --autofix knows what to restore.
findings: list[tuple[pathlib.Path, str]] = []


def check_info_plist() -> None:
    text = INFO_PLIST.read_text()
    # The decided shape: exactly these three keys, this value each. Not
    # "at least these" — a fourth key or a reordered/reformatted file is
    # itself a sign Xcode's plist editor touched the file (see the module
    # docstring), so the count is checked too, not just presence.
    required = [
        ("UIFileSharingEnabled", "<true/>"),
        ("LSSupportsOpeningDocumentsInPlace", "<true/>"),
        ("ITSAppUsesNonExemptEncryption", "<false/>"),
    ]
    for key, expected in required:
        if not re.search(rf"<key>{re.escape(key)}</key>\s*{re.escape(expected)}", text):
            findings.append((INFO_PLIST, f"<key>{key}</key> {expected} missing or altered"))
    key_count = len(re.findall(r"<key>", text))
    if key_count != len(required):
        findings.append((INFO_PLIST,
            f"expected exactly {len(required)} keys, found {key_count} — a key "
            f"was added or removed (Xcode's plist editor rewrites the whole file "
            f"and drops comments; this count catches that even if the specific "
            f"keys above still happen to match)"))


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

    # The iOS 27 move is explicitly gated behind the on-device audio
    # listen (supervisor ruling, 2026-09-15) — it opens on evidence, not
    # because an editor bumped a build setting while the project was open.
    if re.search(r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*27", text):
        findings.append((PBXPROJ,
            "IPHONEOS_DEPLOYMENT_TARGET = 27.x found — the iOS 27 move is gated "
            "behind the on-device audio listen and has not been opened"))

    # These two keys belong in Info.plist only; Xcode's INFOPLIST_KEY_*
    # auto-generation is a second, competing encoding of the same facts
    # and has produced a real drift incident more than once.
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


def run_all_checks() -> None:
    findings.clear()
    check_info_plist()
    check_pbxproj()
    check_scheme_wiring()


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
    for path, messages in by_file.items():
        for m in messages:
            print(f"  - {path.relative_to(ROOT) if path else '(unattributed)'}: {m}")
        if path is not None:
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
