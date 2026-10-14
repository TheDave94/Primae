"""R-112: check_project_invariants.py must catch partial drift in project settings.

The checker is run (default mode, report-only) against a throwaway copy of
the real Info.plist, project.pbxproj and both schemes, with ONE mutation each,
and must name the mutation. The unmutated copy must pass. A check that
passes when one of twelve deployment targets reverts, or when the dead
project-level team returns, is the defect this file pins (audit G2-09,
G2-14, G2-20, G3-14).

Run: python3 -m unittest scripts.tests.test_check_project_invariants_checks
   or: python3 scripts/tests/test_check_project_invariants_checks.py
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SCRIPT = REPO / "scripts" / "check_project_invariants.py"
INFO = "Primae/Info.plist"
PBX = "Primae/Primae.xcodeproj/project.pbxproj"
SCHEME = "Primae/Primae.xcodeproj/xcshareddata/xcschemes/Primae.xcscheme"
SCHEME_DT = "Primae/Primae.xcodeproj/xcshareddata/xcschemes/Primae-DeviceTests.xcscheme"
FILES = [INFO, PBX, SCHEME, SCHEME_DT]


class CheckerFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="r112-")
        self.root = Path(self._tmp.name)
        (self.root / "scripts").mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts" / SCRIPT.name)
        for rel in FILES:
            dest = self.root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, dest)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_checker(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(self.root / "scripts" / SCRIPT.name)],
            capture_output=True, text=True)

    def mutate(self, rel: str, old: str, new: str, count: int = 1) -> None:
        p = self.root / rel
        text = p.read_text()
        self.assertIn(old, text, f"fixture premise: {old!r} not in {rel}")
        p.write_text(text.replace(old, new, count))

    def assertFlags(self, needle: str) -> None:
        r = self.run_checker()
        self.assertEqual(r.returncode, 1, f"expected FAIL, got rc={r.returncode}\n{r.stdout}{r.stderr}")
        self.assertIn(needle, r.stdout, f"finding should mention {needle!r}\n{r.stdout}")


class ProjectInvariantChecks(CheckerFixture):
    def test_unmutated_copy_passes(self) -> None:
        r = self.run_checker()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_one_deployment_target_reverting_is_caught(self) -> None:
        # 1 of 12 reverts; the old unanchored `re.search` still found 11.
        self.mutate(PBX, "IPHONEOS_DEPLOYMENT_TARGET = 27.0;", "IPHONEOS_DEPLOYMENT_TARGET = 26.0;")
        self.assertFlags("IPHONEOS_DEPLOYMENT_TARGET")

    def test_a_deployment_target_entry_disappearing_is_caught(self) -> None:
        self.mutate(PBX, "\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 27.0;\n", "")
        self.assertFlags("IPHONEOS_DEPLOYMENT_TARGET")

    def test_dead_project_level_team_is_caught(self) -> None:
        self.mutate(PBX, "DEVELOPMENT_TEAM = J7JH8FJK2W;", "DEVELOPMENT_TEAM = XMX37BH48B;")
        self.assertFlags("DEVELOPMENT_TEAM")

    def test_any_foreign_team_is_caught(self) -> None:
        self.mutate(PBX, "DEVELOPMENT_TEAM = J7JH8FJK2W;", "DEVELOPMENT_TEAM = ZZZZZZZZZZ;")
        self.assertFlags("DEVELOPMENT_TEAM")

    def test_default_configuration_name_release_is_caught(self) -> None:
        self.mutate(PBX, "defaultConfigurationName = Release-Study;", "defaultConfigurationName = Release;")
        self.assertFlags("defaultConfigurationName")

    def test_dead_uiappfonts_key_is_caught(self) -> None:
        self.mutate(PBX, "\t\t\t\tPRODUCT_NAME", '\t\t\t\tINFOPLIST_KEY_UIAppFonts = "Primae-Light.otf";\n\t\t\t\tPRODUCT_NAME')
        self.assertFlags("UIAppFonts")

    def test_stale_last_upgrade_check_is_caught(self) -> None:
        self.mutate(PBX, "LastUpgradeCheck = 2720;", "LastUpgradeCheck = 2640;")
        self.assertFlags("LastUpgradeCheck")

    def test_newer_xcode_27_upgrade_marker_passes(self) -> None:
        # An Xcode 27.x "upgrade" rewrites these to its own 27xx value; that
        # must not trip the pre-action autofix into reverting the project file.
        self.mutate(PBX, "LastUpgradeCheck = 2720;", "LastUpgradeCheck = 2730;")
        self.mutate(SCHEME, 'LastUpgradeVersion = "2720"', 'LastUpgradeVersion = "2730"')
        self.mutate(SCHEME_DT, 'LastUpgradeVersion = "2720"', 'LastUpgradeVersion = "2730"')
        r = self.run_checker()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_other_major_upgrade_marker_is_caught(self) -> None:
        self.mutate(PBX, "LastUpgradeCheck = 2720;", "LastUpgradeCheck = 2810;")
        self.assertFlags("LastUpgradeCheck")

    def test_stale_scheme_last_upgrade_version_is_caught(self) -> None:
        self.mutate(SCHEME_DT, 'LastUpgradeVersion = "2720"', 'LastUpgradeVersion = "2640"')
        self.assertFlags("LastUpgradeVersion")


class InfoPlistChecks(CheckerFixture):
    def test_extra_key_is_named_not_just_counted(self) -> None:
        self.mutate(INFO, "</dict>", "    <key>UIStatusBarHidden</key>\n    <true/>\n</dict>")
        self.assertFlags("UIStatusBarHidden")

    def test_missing_key_is_named(self) -> None:
        text = (self.root / INFO).read_text()
        stripped = re.sub(r"\s*<key>ITSAppUsesNonExemptEncryption</key>\s*<false/>", "", text)
        self.assertNotEqual(text, stripped)
        (self.root / INFO).write_text(stripped)
        self.assertFlags("ITSAppUsesNonExemptEncryption")

    def test_file_sharing_keys_are_absent_and_rejected(self) -> None:
        # R-063: the study artefact must not publish its Documents folder in
        # Files/Finder. The only consumer was the calibrator, compiled out.
        text = (self.root / INFO).read_text()
        for key in ("UIFileSharingEnabled", "LSSupportsOpeningDocumentsInPlace"):
            with self.subTest(key=key):
                self.assertNotIn(f"<key>{key}</key>", text,
                                 f"{key} must not be in the decided Info.plist")
                self.mutate(INFO, "</dict>", f"    <key>{key}</key>\n    <true/>\n</dict>")
                self.assertFlags(key)
                (self.root / INFO).write_text(text)


if __name__ == "__main__":
    unittest.main()
