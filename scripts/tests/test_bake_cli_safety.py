"""Write-safety tests for `generate_strokes_auto.py` (audit 2026-10-13,
G3-11):

* `--font X` without `--out` baked into the production directory
  (`PrimaeNative/Resources/Letters/Regular/`) and rewrote its `_meta.json`
  with the sha256 of the override font, silently labelling the shipped
  directory with a font it was not baked from. It must now require `--out`.
* strokes.json / _meta.json were written with the locale encoding while the
  content is `ensure_ascii=False` (keys like "Ä", "ß"); a C-locale run could
  mis-encode them. They are written as UTF-8, via temp-file + rename so a
  crash cannot leave a truncated file next to a good one.

Run: python3 scripts/tests/test_bake_cli_safety.py
"""

from __future__ import annotations

import contextlib
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))
import generate_strokes_auto as g  # noqa: E402


class FontOverrideTests(unittest.TestCase):

    def _main(self, *argv):
        saved = sys.argv
        sys.argv = ["generate_strokes_auto.py", *argv]
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
                rc = g.main()
        finally:
            sys.argv = saved
        return rc, out.getvalue()

    def test_font_override_without_out_is_refused(self):
        rc, text = self._main("--font", "/nonexistent/Other.otf", "A")
        self.assertEqual(rc, 2)
        self.assertIn("--out", text)
        self.assertNotIn("Baking weight", text)      # refused before any work

    def test_font_override_with_out_is_not_refused_by_this_guard(self):
        # With --out the run proceeds to the font check (which fails on the
        # fake path): rc 1 "Font not found", NOT the guard's rc 2.
        rc, text = self._main("--font", "/nonexistent/Other.otf",
                              "--out", "/tmp/primae-nowhere", "A")
        self.assertEqual(rc, 1)
        self.assertIn("Font not found", text)


class FontOverrideOutsideProductionTests(unittest.TestCase):
    _main = FontOverrideTests._main
    """Review 2026-10-13: `--font` + `--out` pointing INTO the production
    Letters tree (or into it via `..` / a symlink) is the same hazard the
    `--out` requirement was added to stop - the override font's sha256 would
    be written into the shipped _meta.json - so it is refused too."""

    def _inside_cases(self):
        prod = g.OUTPUT_BASE
        tmp = Path(tempfile.mkdtemp(prefix="primae-prodlink-"))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        link = tmp / "looks-harmless"
        link.symlink_to(prod, target_is_directory=True)
        return {
            "the Letters dir itself": str(prod),
            "a subdirectory": str(prod / "Regular"),
            "a not-yet-existing subdirectory": str(prod / "Scratch" / "x"),
            "dotdot back in": str(prod / "Regular" / ".."),
            "a symlink to it": str(link),
            "relative form": str(Path("PrimaeNative/Resources/Letters")),
        }

    def test_out_inside_the_production_tree_is_refused(self):
        import os
        cwd = os.getcwd()
        os.chdir(g.REPO_ROOT)                  # the relative case needs this
        self.addCleanup(os.chdir, cwd)
        for label, out in self._inside_cases().items():
            rc, text = self._main("--font", "/nonexistent/Other.otf",
                                  "--out", out, "A")
            self.assertEqual(rc, 2, label)
            self.assertIn("production", text, label)
            self.assertNotIn("Font not found", text, label)   # refused first

    def _case_cases(self):
        """Wrong-case spellings of the production tree. On a case-insensitive
        volume (default macOS APFS) they name the SAME directory, which a
        string comparison of realpaths cannot know. Skips on a
        case-sensitive filesystem, where they are different (absent) paths."""
        prod = str(g.OUTPUT_BASE)
        swapped = prod.replace("PrimaeNative/Resources/Letters",
                               "primaenative/resources/letters")
        if swapped == prod or not Path(swapped).exists():
            self.skipTest("case-sensitive filesystem: wrong-case paths are "
                          "different paths here")
        return {
            "all lower case": swapped,
            "upper-case Letters": prod[:-len("Letters")] + "LETTERS",
            "wrong-case nested": prod.replace("Resources/Letters",
                                              "RESOURCES/letters")
                                 + "/Regular",
            "wrong-case, not-yet-existing child":
                swapped + "/NoSuchScratch/deeper",
        }

    def test_wrong_case_out_inside_production_is_refused(self):
        for label, out in self._case_cases().items():
            rc, text = self._main("--font", "/nonexistent/Other.otf",
                                  "--out", out, "A")
            self.assertEqual(rc, 2, f"{label}: {out}")
            self.assertNotIn("Font not found", text, label)

    def test_is_inside_uses_on_disk_identity_not_spelling(self):
        for label, out in self._case_cases().items():
            self.assertTrue(g._is_inside(Path(out), g.OUTPUT_BASE), label)

    def test_missing_child_of_an_existing_production_dir_is_inside(self):
        out = g.OUTPUT_BASE / "NoSuchScratch" / "deeper" / "still"
        self.assertFalse(out.exists())
        self.assertTrue(g._is_inside(out, g.OUTPUT_BASE))

    def test_parents_of_production_and_unrelated_dirs_are_not_inside(self):
        self.assertFalse(g._is_inside(g.OUTPUT_BASE.parent, g.OUTPUT_BASE))
        self.assertFalse(g._is_inside(Path(tempfile.gettempdir()) / "scratch",
                                      g.OUTPUT_BASE))
        self.assertFalse(g._is_inside(Path(str(g.OUTPUT_BASE) + "-scratch"),
                                      g.OUTPUT_BASE))

    def test_out_beside_the_production_tree_is_not_refused(self):
        # A sibling that merely shares the name prefix is not inside it.
        sibling = str(g.OUTPUT_BASE) + "-scratch"
        rc, text = self._main("--font", "/nonexistent/Other.otf",
                              "--out", sibling, "A")
        self.assertEqual(rc, 1)
        self.assertIn("Font not found", text)


class AtomicUtf8WriteTests(unittest.TestCase):

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="primae-bake-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_writes_utf8_regardless_of_locale_default(self):
        target = self.tmp / "strokes.json"
        g.write_text_atomic(target, json.dumps({"letter": "Ä ß"},
                                               ensure_ascii=False))
        self.assertEqual(target.read_bytes(),
                         '{"letter": "Ä ß"}'.encode("utf-8"))

    def test_replaces_an_existing_file_completely(self):
        target = self.tmp / "strokes.json"
        target.write_text("old content that is much longer than the new")
        g.write_text_atomic(target, "new")
        self.assertEqual(target.read_text(), "new")

    def test_no_temp_file_is_left_behind(self):
        g.write_text_atomic(self.tmp / "a.json", "x")
        self.assertEqual([p.name for p in self.tmp.iterdir()], ["a.json"])

    def test_failed_replace_leaves_the_original_intact_and_no_temp(self):
        from unittest import mock
        target = self.tmp / "strokes.json"
        target.write_text("GOOD")
        with mock.patch.object(g.os, "replace",
                               side_effect=OSError("simulated crash")):
            with self.assertRaises(OSError):
                g.write_text_atomic(target, "partial")
        self.assertEqual(target.read_text(), "GOOD")
        self.assertEqual([p.name for p in self.tmp.iterdir()],
                         ["strokes.json"])


if __name__ == "__main__":
    unittest.main()
