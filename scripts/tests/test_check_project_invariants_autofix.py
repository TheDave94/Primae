"""R-057: `check_project_invariants.py --autofix` must not destroy uncommitted edits.

The Primae scheme's build Pre-action runs the checker with `--autofix` on
every build. When a decided-shape check fails, autofix restores the whole
file with `git checkout --`, and that discards every uncommitted edit in it,
including a deliberate one. These tests run the REAL script inside a
throwaway git repository (a temp-dir fixture holding copies of the real
Info.plist, project.pbxproj and scheme), so the real repository's files are
never touched.

Run: python3 -m unittest scripts.tests.test_check_project_invariants_autofix
   or: python3 scripts/tests/test_check_project_invariants_autofix.py
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SCRIPT = REPO / "scripts" / "check_project_invariants.py"
FILES = [
    "Primae/Info.plist",
    "Primae/Primae.xcodeproj/project.pbxproj",
    "Primae/Primae.xcodeproj/xcshareddata/xcschemes/Primae.xcscheme",
]

# A deliberate, uncommitted developer edit that trips the decided-shape
# check (it removes the one required key; R-063 removed the file-sharing
# keys this fixture used to delete). Autofix will restore the file; the edit
# must survive somewhere.
EDIT_FROM = "    <key>ITSAppUsesNonExemptEncryption</key>\n    <false/>\n"
EDIT_MARKER = "<!-- uncommitted developer edit, R-057 fixture -->\n"


def git(cwd: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
         "-c", "commit.gpgsign=false", "-C", str(cwd), *args],
        capture_output=True, text=True, check=True)


class AutofixFixture(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="r057-")
        self.root = Path(self._tmp.name) / "repo"
        (self.root / "scripts").mkdir(parents=True)
        shutil.copy2(SCRIPT, self.root / "scripts" / SCRIPT.name)
        for rel in FILES:
            dest = self.root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / rel, dest)
        git(self.root, "init", "-q")
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "fixture")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_autofix(self, root: Path) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(root / "scripts" / SCRIPT.name), "--autofix"],
            capture_output=True, text=True)

    def make_edit(self, root: Path) -> str:
        plist = root / "Primae" / "Info.plist"
        text = plist.read_text()
        self.assertIn(EDIT_FROM, text, "fixture premise: the real Info.plist changed shape")
        edited = text.replace(EDIT_FROM, EDIT_MARKER)
        plist.write_text(edited)
        return edited

    def backup_paths(self, out: str) -> list:
        return [Path(m) for m in re.findall(r"^\s*backup: (\S.*)$", out, re.MULTILINE)]

    # -- the defect --------------------------------------------------------

    def test_uncommitted_edit_survives_autofix_restore(self) -> None:
        edited = self.make_edit(self.root)
        result = self.run_autofix(self.root)
        out = result.stdout + result.stderr

        backups = self.backup_paths(out)
        self.assertEqual(len(backups), 1,
                         f"autofix restored without announcing a backup:\n{out}")
        self.assertEqual(backups[0].read_text(), edited,
                         "the backup must hold the uncommitted edit byte for byte")

    def test_backup_lives_in_the_git_dir_so_provenance_stays_clean(self) -> None:
        self.make_edit(self.root)
        result = self.run_autofix(self.root)
        out = result.stdout + result.stderr

        backups = self.backup_paths(out)
        self.assertEqual(len(backups), 1, out)
        git_dir = Path(git(self.root, "rev-parse", "--absolute-git-dir").stdout.strip())
        self.assertTrue(str(backups[0].resolve()).startswith(str(git_dir.resolve()) + "/"),
                        f"{backups[0]} is not inside {git_dir}")
        self.assertEqual(git(self.root, "status", "--porcelain").stdout, "",
                         "the backup must not dirty the tree")
        self.assertEqual(result.returncode, 0, out)

    def test_backup_works_in_a_linked_worktree(self) -> None:
        wt = Path(self._tmp.name) / "wt" / "repo"
        git(self.root, "worktree", "add", "-q", "--detach", str(wt))
        edited = self.make_edit(wt)
        result = self.run_autofix(wt)
        out = result.stdout + result.stderr

        backups = self.backup_paths(out)
        self.assertEqual(len(backups), 1, out)
        self.assertEqual(backups[0].read_text(), edited)
        self.assertEqual(git(wt, "status", "--porcelain").stdout, "", out)

    def test_backup_survives_removal_of_its_linked_worktree(self) -> None:
        # `git worktree remove` deletes the worktree's own git dir; a backup
        # kept there would vanish with the lane. It must live in the COMMON
        # git dir, under a per-worktree folder.
        wt = Path(self._tmp.name) / "wt" / "repo"
        git(self.root, "worktree", "add", "-q", "--detach", str(wt))
        edited = self.make_edit(wt)
        out = self.run_autofix(wt).stdout
        backups = self.backup_paths(out)
        self.assertEqual(len(backups), 1, out)

        git(self.root, "worktree", "remove", "--force", str(wt))
        self.assertTrue(backups[0].exists(), f"{backups[0]} vanished with the worktree")
        self.assertEqual(backups[0].read_text(), edited)
        common = (self.root / ".git" / "primae-autofix-backups").resolve()
        self.assertEqual(backups[0].resolve().parents[2].parent, common, backups[0])

    def test_keeps_only_the_newest_20_backup_runs_per_worktree(self) -> None:
        self.make_edit(self.root)
        first = self.run_autofix(self.root).stdout
        name_dir = self.backup_paths(first)[0].parents[2]   # <common>/primae-autofix-backups/<name>
        # 25 older runs, plus an unrelated directory pruning must not touch.
        for i in range(25):
            (name_dir / f"20000101T0000{i:02d}-1").mkdir()
        (name_dir / "keep-me").mkdir()

        self.make_edit(self.root)
        newest = self.backup_paths(self.run_autofix(self.root).stdout)[0].parents[1]

        runs = sorted(p.name for p in name_dir.iterdir() if p.name != "keep-me")
        self.assertEqual(len(runs), 20, runs)
        self.assertIn(newest.name, runs)
        self.assertNotIn("20000101T000000-1", runs)          # the oldest went first
        self.assertTrue((name_dir / "keep-me").is_dir())

    def test_trim_never_touches_another_worktrees_runs(self) -> None:
        self.make_edit(self.root)
        first = self.run_autofix(self.root).stdout
        root_dir = self.backup_paths(first)[0].parents[3]    # <common>/primae-autofix-backups
        other = root_dir / "some-other-worktree-0123456789ab"
        other.mkdir()
        for i in range(25):
            (other / f"20000101T0000{i:02d}-1").mkdir()
        mine = self.backup_paths(first)[0].parents[2]
        for i in range(25):
            (mine / f"20000102T0000{i:02d}-1").mkdir()

        self.make_edit(self.root)
        self.run_autofix(self.root)

        self.assertEqual(len(list(other.iterdir())), 25,
                         "a trim for one worktree deleted another worktree's runs")
        self.assertEqual(len([p for p in mine.iterdir()]), 20, "this worktree is still trimmed")

    def test_main_and_linked_worktree_with_the_same_name_get_separate_folders(self) -> None:
        wt = Path(self._tmp.name) / "wt" / "repo"          # both are called `repo`
        git(self.root, "worktree", "add", "-q", "--detach", str(wt))
        self.make_edit(self.root)
        main_backup = self.backup_paths(self.run_autofix(self.root).stdout)
        self.make_edit(wt)
        wt_backup = self.backup_paths(self.run_autofix(wt).stdout)
        self.assertEqual((len(main_backup), len(wt_backup)), (1, 1))
        self.assertNotEqual(main_backup[0].parents[2], wt_backup[0].parents[2],
                            "two worktrees share one backup folder")

    def test_paths_that_differ_only_in_dash_versus_slash_get_separate_folders(self) -> None:
        # /x/a-b/c/repo and /x/a/b-c/repo: "/" -> "-" alone maps both to x-a-b-c-repo.
        folders = []
        for rel in ("a-b/c/repo", "a/b-c/repo"):
            wt = Path(self._tmp.name) / "wt" / rel
            wt.parent.mkdir(parents=True)
            git(self.root, "worktree", "add", "-q", "--detach", str(wt))
            self.make_edit(wt)
            backups = self.backup_paths(self.run_autofix(wt).stdout)
            self.assertEqual(len(backups), 1)
            folders.append(backups[0].parents[2])
        self.assertNotEqual(folders[0], folders[1], "distinct worktrees share a backup folder")

    def test_a_symlinked_worktree_folder_is_refused_and_nothing_outside_is_touched(self) -> None:
        self.make_edit(self.root)
        first = self.run_autofix(self.root).stdout
        folder = self.backup_paths(first)[0].parents[2]
        outside = Path(self._tmp.name) / "outside"
        outside.mkdir()
        for i in range(25):
            (outside / f"20000101T0000{i:02d}-1").mkdir()
        shutil.rmtree(folder)
        folder.symlink_to(outside)

        edited = self.make_edit(self.root)
        result = self.run_autofix(self.root)
        out = result.stdout + result.stderr

        self.assertEqual(len(list(outside.iterdir())), 25,
                         f"the trim (or mkdir) followed the symlink out of the backup tree:\n{out}")
        self.assertEqual((self.root / "Primae" / "Info.plist").read_text(), edited,
                         f"restored although no backup could be taken:\n{out}")
        self.assertIn("NOT restoring", out)
        self.assertEqual(result.returncode, 1, out)

    def test_a_symlinked_backup_root_is_refused(self) -> None:
        outside = Path(self._tmp.name) / "outside-root"
        outside.mkdir()
        (self.root / ".git" / "primae-autofix-backups").symlink_to(outside)

        edited = self.make_edit(self.root)
        result = self.run_autofix(self.root)
        out = result.stdout + result.stderr

        self.assertEqual(list(outside.iterdir()), [], f"wrote through the symlinked root:\n{out}")
        self.assertEqual((self.root / "Primae" / "Info.plist").read_text(), edited, out)
        self.assertIn("NOT restoring", out)

    @unittest.skipIf(os.geteuid() == 0, "root ignores directory permissions")
    def test_a_failed_trim_is_reported_and_the_restore_still_happens(self) -> None:
        self.make_edit(self.root)
        first = self.run_autofix(self.root).stdout
        name_dir = self.backup_paths(first)[0].parents[2]
        for i in range(25):
            (name_dir / f"20000101T0000{i:02d}-1").mkdir()
        stuck = name_dir / "20000101T000000-1"
        (stuck / "file").write_text("x")
        stuck.chmod(0o500)                                   # rmtree cannot unlink inside it

        edited = self.make_edit(self.root)
        try:
            result = self.run_autofix(self.root)
        finally:
            stuck.chmod(0o700)                               # so tearDown can delete it
        out = result.stdout + result.stderr

        self.assertIn("could not", out)
        self.assertEqual(self.backup_paths(out)[0].read_text(), edited, "the backup was still taken")
        self.assertEqual(git(self.root, "status", "--porcelain").stdout, "",
                         f"a failed trim stopped the restore:\n{out}")
        self.assertEqual(result.returncode, 0, out)

    def test_refuses_to_restore_when_the_backup_cannot_be_written(self) -> None:
        edited = self.make_edit(self.root)
        # A FILE where the backup directory must go: mkdir fails.
        (self.root / ".git" / "primae-autofix-backups").write_text("blocker")
        result = self.run_autofix(self.root)
        out = result.stdout + result.stderr

        self.assertEqual((self.root / "Primae" / "Info.plist").read_text(), edited,
                         f"restored with no backup, the edit is gone:\n{out}")
        self.assertIn("NOT restoring", out)
        # The tree stays dirty, so the provenance gate refuses the build.
        self.assertEqual(result.returncode, 1, out)

    # -- unchanged behaviour ----------------------------------------------

    def test_clean_tree_passes_without_a_backup(self) -> None:
        result = self.run_autofix(self.root)
        out = result.stdout + result.stderr
        self.assertEqual(result.returncode, 0, out)
        self.assertEqual(self.backup_paths(out), [])
        self.assertFalse((self.root / ".git" / "primae-autofix-backups").exists())


if __name__ == "__main__":
    unittest.main()
