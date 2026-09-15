#!/usr/bin/env python3
"""check_project_invariants.py — drift tripwire for Info.plist / project.pbxproj.

WHY THIS EXISTS. Three times in one session (2026-09-15), Xcode rewrote
Primae/Info.plist and/or Primae/Primae.xcodeproj/project.pbxproj on open or
save, silently discarding decided settings: the study/casual display-name
split, the landscape-only orientation lock, UIRequiresFullScreen, and once
an outright iOS 27 deployment-target bump — a study-instrument change
nobody decided, landed by an editor, not a person. Each was caught only
because a seat happened to run `git status` right after. That is not a
mechanism; it is luck.

RULING (supervisor, 2026-09-15): Xcode's GUI is no longer an authoring
surface for these two files. This script is the enforcement, wired into
two places that don't depend on any seat remembering to check:
  1. The `Primae` scheme's Pre-actions build script — runs on every local
     build (Cmd-R, Cmd-B, test, archive), fails the build immediately.
  2. `ios-build.yml`'s `unwired_guards` job — runs on every CI dispatch.
Exit 0 and print "ok" on a clean match; exit 1 and name every specific
drifted value otherwise. Silence on failure would be the same bug again.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
INFO_PLIST = ROOT / "Primae" / "Info.plist"
PBXPROJ = ROOT / "Primae" / "Primae.xcodeproj" / "project.pbxproj"

failures: list[str] = []


def check_info_plist() -> None:
    text = INFO_PLIST.read_text()
    # The decided shape: exactly these three keys, this value each. Not
    # "at least these" — a fourth key or a reordered/reformatted file is
    # itself a sign Xcode's plist editor touched the file (see the script
    # header), so the count is checked too, not just presence.
    required = [
        ("UIFileSharingEnabled", "<true/>"),
        ("LSSupportsOpeningDocumentsInPlace", "<true/>"),
        ("ITSAppUsesNonExemptEncryption", "<false/>"),
    ]
    for key, expected in required:
        if not re.search(rf"<key>{re.escape(key)}</key>\s*{re.escape(expected)}", text):
            failures.append(f"Info.plist: <key>{key}</key> {expected} missing or altered")
    key_count = len(re.findall(r"<key>", text))
    if key_count != len(required):
        failures.append(
            f"Info.plist: expected exactly {len(required)} keys, found {key_count} "
            f"— a key was added or removed (Xcode's plist editor rewrites the whole "
            f"file and drops comments; this count catches that even if the specific "
            f"keys above still happen to match)")


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
        failures.append(
            "project.pbxproj: IPHONEOS_DEPLOYMENT_TARGET = 27.x found — the iOS 27 "
            "move is gated behind the on-device audio listen and has not been opened")

    # These two keys belong in Info.plist only; Xcode's INFOPLIST_KEY_*
    # auto-generation is a second, competing encoding of the same facts
    # and has produced a real drift incident once already.
    for forbidden in ("INFOPLIST_KEY_ITSAppUsesNonExemptEncryption",
                      "INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace"):
        if forbidden in text:
            failures.append(
                f"project.pbxproj: {forbidden} must not exist — this key lives in "
                f"Info.plist only, not as an auto-generated build setting")

    study_blocks = [(name, body) for name, body in _BLOCK_RE.findall(text)
                     if _APP_MARKER in body]
    if len(study_blocks) != 2:
        failures.append(
            f"project.pbxproj: expected exactly 2 app-target Study build "
            f"configurations (Debug-Study, Release-Study), found "
            f"{len(study_blocks)} — the parser's block pattern may need "
            f"updating, or a configuration was added/removed")

    for name, body in study_blocks:
        if 'INFOPLIST_KEY_CFBundleDisplayName = "Primae Studie";' not in body:
            failures.append(
                f'project.pbxproj: {name} (app target) — CFBundleDisplayName is '
                f'not "Primae Studie" (on-device study/casual distinctness, '
                f'CLAUDE.md "On-device distinctness")')
        if "INFOPLIST_KEY_UIRequiresFullScreen = YES;" not in body:
            failures.append(
                f"project.pbxproj: {name} (app target) — UIRequiresFullScreen = "
                f"YES is missing")
        orientations = re.search(
            r'INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "([^"]*)";', body)
        if not orientations:
            failures.append(
                f"project.pbxproj: {name} (app target) — "
                f"UISupportedInterfaceOrientations_iPad is missing")
        elif "Portrait" in orientations.group(1):
            failures.append(
                f"project.pbxproj: {name} (app target) — iPad orientations "
                f'include Portrait ("{orientations.group(1)}"); the study '
                f"configuration is landscape-only (a mid-session rotation "
                f"re-maps checkpoints and changes the letter's physical size)")


def main() -> int:
    check_info_plist()
    check_pbxproj()
    if failures:
        print("FAIL — project-settings drift detected. Xcode is not an authoring "
              "surface for these two files (see this script's header).")
        for f in failures:
            print(f"  - {f}")
        print()
        print("Fix: git checkout -- Primae/Info.plist Primae/Primae.xcodeproj/project.pbxproj")
        return 1
    print("ok — Info.plist and project.pbxproj match the decided invariants")
    return 0


if __name__ == "__main__":
    sys.exit(main())
