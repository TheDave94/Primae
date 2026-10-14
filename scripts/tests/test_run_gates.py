"""Tests for `run_gates.py` letter enumeration (audit 2026-10-13, G3-06).

`enumerate_letters` used to list only the working tree, so a PR that
deleted a letter folder -- or its strokes.json -- was never visited by any
gate and passed. It now takes the union of the working tree and the git
refs being compared. These tests build a throwaway git repository laid out
like `PrimaeNative/Resources/Letters/<Weight>/<folder>/strokes.json` and
point `run_gates.REPO_ROOT` at it, so they need git but not the real corpus.

Run: python3 scripts/tests/test_run_gates.py
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))
import run_gates as rg  # noqa: E402

STROKES = {"letter": "x", "checkpointRadius": 0.1,
           "strokes": [{"id": 1, "checkpoints": [
               {"x": 0.1, "y": 0.1}, {"x": 0.9, "y": 0.9}]}]}


def _git(root: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid",
         "-c", "commit.gpgsign=false", "-c", "core.quotePath=false",
         "-C", str(root), *args],
        check=True, capture_output=True)


class EnumerateLettersTests(unittest.TestCase):

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="primae-rg-"))
        self.addCleanup(shutil.rmtree, self.root, ignore_errors=True)
        self.letters = self.root / "PrimaeNative" / "Resources" / "Letters"
        # Committed at the reference: A, B, a_l, Ä, ß_l. Plus a stray
        # file that is not a letter folder.
        for folder in ("A", "B", "a_l", "Ä", "ß_l"):
            self._write(folder)
        (self.letters / "Regular" / "_meta.json").write_text("{}")
        _git(self.root, "init", "-q")
        _git(self.root, "add", "-A")
        _git(self.root, "commit", "-q", "-m", "reference")
        self._orig_root = rg.REPO_ROOT
        rg.REPO_ROOT = self.root
        self.addCleanup(setattr, rg, "REPO_ROOT", self._orig_root)

    def _write(self, folder: str, weight: str = "Regular") -> None:
        d = self.letters / weight / folder
        d.mkdir(parents=True, exist_ok=True)
        (d / "strokes.json").write_text(json.dumps(STROKES))

    def _delete(self, folder: str, weight: str = "Regular") -> None:
        shutil.rmtree(self.letters / weight / folder)

    def _enum(self, refs=()):
        return rg.enumerate_letters("regular", self.letters, refs=refs)

    def test_worktree_only_lists_folders_and_decodes_names(self):
        self.assertEqual(sorted(self._enum()),
                         sorted(["A", "B", "a", "Ä", "ß"]))

    def test_deleted_letter_folder_is_still_enumerated(self):
        # The G3-06 reproduction: B is deleted in the working tree but
        # exists at HEAD. The old worktree-only listing dropped it.
        self._delete("B")
        self.assertNotIn("B", self._enum())            # old behaviour
        self.assertIn("B", self._enum(refs=(rg.WORKTREE_SENTINEL, "HEAD")))

    def test_deleted_letter_fails_as_missing_candidate(self):
        self._delete("B")
        result = rg.run_gate_for_letter(
            "B", "g4", "regular", rg.WORKTREE_SENTINEL, "HEAD", 40.0,
            self.letters)
        self.assertFalse(result["pass"])
        self.assertEqual(result["error"], "missing_candidate")

    def test_deleted_lowercase_and_umlaut_folders_are_enumerated(self):
        self._delete("a_l")
        self._delete("Ä")
        self._delete("ß_l")
        letters = self._enum(refs=(rg.WORKTREE_SENTINEL, "HEAD"))
        for expected in ("a", "Ä", "ß"):
            self.assertIn(expected, letters)

    def test_letter_added_only_in_worktree_is_still_enumerated(self):
        self._write("C")
        self.assertIn("C", self._enum(refs=(rg.WORKTREE_SENTINEL, "HEAD")))

    def test_no_duplicates_when_both_sides_have_the_letter(self):
        letters = self._enum(refs=(rg.WORKTREE_SENTINEL, "HEAD"))
        self.assertEqual(len(letters), len(set(letters)))
        self.assertEqual(sorted(letters), sorted(["A", "B", "a", "Ä", "ß"]))

    def test_unknown_ref_contributes_nothing_and_does_not_raise(self):
        self.assertEqual(sorted(self._enum(refs=("no-such-ref",))), [])
        # ...and a letter only at an unknown ref cannot be conjured, but the
        # worktree side still lists its own folders.
        self.assertEqual(
            sorted(self._enum(refs=(rg.WORKTREE_SENTINEL, "no-such-ref"))),
            sorted(["A", "B", "a", "Ä", "ß"]))

    def _run_main(self, *extra: str, gate: str = "g4"):
        """Drive `run_gates.main` end to end with the raster step stubbed
        (these tests are about which letters are visited, not about ink)."""
        import contextlib
        import io
        font = Path(__file__)       # any file that exists
        saved = (rg.g.FONTS, rg.g.rasterize, rg.g.bbox_from_mask)
        rg.g.FONTS = {"regular": font, "light": font}
        rg.g.rasterize = lambda letter, font_path: None
        rg.g.bbox_from_mask = lambda mask: (0, 0, 100, 100)
        self.addCleanup(lambda: (setattr(rg.g, "FONTS", saved[0]),
                                 setattr(rg.g, "rasterize", saved[1]),
                                 setattr(rg.g, "bbox_from_mask", saved[2])))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = rg.main(["--gate", gate, "--letters-dir", str(self.letters),
                          "--reference-ref", "HEAD", "--json", *extra])
        return rc, json.loads(out.getvalue())

    def test_main_unchanged_tree_passes_every_letter(self):
        rc, report = self._run_main()
        self.assertEqual(rc, 0)
        self.assertEqual(report["summary"], {"pass": 5, "fail": 0, "total": 5})

    def test_main_fails_when_a_letter_folder_is_deleted(self):
        # THE G3-06 REPRODUCTION. Before the fix `main` enumerated the
        # working tree, never saw B, and exited 0 with 4/4.
        self._delete("B")
        rc, report = self._run_main()
        self.assertEqual(rc, 1)
        self.assertEqual(report["summary"]["total"], 5)
        self.assertFalse(report["letters"]["B"]["pass"])
        self.assertEqual(report["letters"]["B"]["error"], "missing_candidate")

    def test_main_fails_when_only_the_strokes_file_is_deleted(self):
        (self.letters / "Regular" / "A" / "strokes.json").unlink()
        rc, report = self._run_main()
        self.assertEqual(rc, 1)
        self.assertEqual(report["letters"]["A"]["error"], "missing_candidate")

    def _reverse_in_worktree(self, folder: str) -> list:
        path = self.letters / "Regular" / folder / "strokes.json"
        doc = json.loads(path.read_text())
        doc["strokes"][0]["checkpoints"].reverse()
        path.write_text(json.dumps(doc))
        return doc["strokes"][0]["checkpoints"]

    def _allowlist_for(self, ref_cps, cand_cps, letter="A") -> Path:
        import hashlib
        def digest(cps):
            blob = json.dumps([[c["x"], c["y"]] for c in cps],
                              separators=(",", ":"))
            return hashlib.sha256(blob.encode()).hexdigest()
        path = self.root / "allow.json"
        path.write_text(json.dumps({"version": 1, "entries": [{
            "letter": letter, "weight": "regular", "stroke": 0,
            "referenceCommit": "a" * 40, "candidateCommit": "b" * 40,
            "referenceStrokeSha256": digest(ref_cps),
            "candidateStrokeSha256": digest(cand_cps),
            "reason": "intended in test", "date": "2026-10-13"}]}))
        return path

    def test_main_g7_fails_a_reversed_stroke_and_honours_the_allow_list(self):
        ref_cps = json.loads((self.letters / "Regular" / "A"
                              / "strokes.json").read_text()
                             )["strokes"][0]["checkpoints"]
        cand_cps = self._reverse_in_worktree("A")
        saved = rg.G7_ALLOWLIST_PATH
        self.addCleanup(setattr, rg, "G7_ALLOWLIST_PATH", saved)

        rg.G7_ALLOWLIST_PATH = self.root / "absent.json"
        (self.root / "absent.json").write_text('{"version": 1, "entries": []}')
        rc, report = self._run_main(gate="g7")
        self.assertEqual(rc, 1)
        self.assertFalse(report["letters"]["A"]["pass"])
        self.assertTrue(report["letters"]["A"]["per_stroke"][0]["reversed"])

        rg.G7_ALLOWLIST_PATH = self._allowlist_for(ref_cps, cand_cps)
        rc, report = self._run_main(gate="g7")
        self.assertEqual(rc, 0)
        self.assertEqual(report["letters"]["A"]["n_allowed"], 1)
        self.assertEqual(report["letters"]["A"]["per_stroke"][0]["allowed"],
                         "intended in test")

        # Same entry, different letter -> does not apply.
        rg.G7_ALLOWLIST_PATH = self._allowlist_for(ref_cps, cand_cps, "B")
        rc, report = self._run_main(gate="g7")
        self.assertEqual(rc, 1)

    def test_candidate_ref_side_is_listed_too(self):
        self._delete("B")
        _git(self.root, "add", "-A")
        _git(self.root, "commit", "-q", "-m", "delete B")
        # candidate = HEAD (B gone), reference = HEAD~1 (B present).
        letters = rg.enumerate_letters("regular", self.letters,
                                       refs=("HEAD", "HEAD~1"))
        self.assertIn("B", letters)


if __name__ == "__main__":
    unittest.main()
