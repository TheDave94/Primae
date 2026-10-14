"""CLI-safety test for `calibrate_g6_threshold.py` (audit 2026-10-13,
G3-10): a bare run used to rewrite
`research_data/phase2b_gates/g6_calibration_run.md` -- thesis evidence, a
load-bearing doc -- with today's date and numbers computed against current
HEAD. It must now write a file only when `--output` is given.

The expensive measurement is stubbed; this test is about where output goes.

Run: python3 scripts/tests/test_calibrate_g6_cli.py
"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))
import calibrate_g6_threshold as cal  # noqa: E402


class CalibrateG6OutputTests(unittest.TestCase):

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="primae-g6cli-"))
        corpus = self.tmp / "corpus"
        (corpus / "A").mkdir(parents=True)
        # A stand-in for the committed evidence file: must survive a bare run.
        self.committed = self.tmp / "g6_calibration_run.md"
        self.committed.write_text("COMMITTED EVIDENCE\n")
        saved = (cal.CORPUS_DIR, cal.DEFAULT_OUTPUT, cal.measure_letter,
                 cal.identity_check, cal.render_markdown, cal.REPO_ROOT)
        cal.REPO_ROOT = self.tmp
        cal.CORPUS_DIR = corpus
        cal.DEFAULT_OUTPUT = self.committed
        cal.measure_letter = lambda letter: {"letter": letter}
        cal.identity_check = lambda: {}
        cal.render_markdown = lambda m, i, today: ("NEW RUN\n", 4.5)

        def restore():
            (cal.CORPUS_DIR, cal.DEFAULT_OUTPUT, cal.measure_letter,
             cal.identity_check, cal.render_markdown, cal.REPO_ROOT) = saved
            import shutil
            shutil.rmtree(self.tmp, ignore_errors=True)
        self.addCleanup(restore)

    def _run(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cal.main(list(argv))
        return rc, out.getvalue(), err.getvalue()

    def test_bare_run_does_not_touch_the_committed_evidence_file(self):
        rc, out, err = self._run()
        self.assertEqual(rc, 0)
        self.assertEqual(self.committed.read_text(), "COMMITTED EVIDENCE\n")
        self.assertEqual(out.strip(), "4.5000")       # threshold still printed
        self.assertIn("--output", err)                # and the reason is said

    def test_explicit_output_writes_the_file(self):
        target = self.tmp / "new_run.md"
        rc, out, err = self._run("--output", str(target))
        self.assertEqual(rc, 0)
        self.assertEqual(target.read_text(), "NEW RUN\n")
        self.assertEqual(self.committed.read_text(), "COMMITTED EVIDENCE\n")

    def test_explicit_output_may_overwrite_deliberately(self):
        rc, _, _ = self._run("--output", str(self.committed))
        self.assertEqual(rc, 0)
        self.assertEqual(self.committed.read_text(), "NEW RUN\n")


if __name__ == "__main__":
    unittest.main()
