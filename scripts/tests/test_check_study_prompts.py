"""check_study_prompts.py must fail when the recorded study prompts drift.

The five MP3s a study child hears are an instrument component (D15, r9):
the voice, the wording and the timing are fixed by these bytes. The checker
is run against a throwaway copy of PrimaeNative/Resources/Prompts with ONE
mutation each and must name it; the unmutated copy must pass (a checker
that never passes proves nothing either).

Run: python3 -I -m unittest scripts.tests.test_check_study_prompts
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
SCRIPT = REPO / "scripts" / "check_study_prompts.py"
PROMPTS = REPO / "PrimaeNative" / "Resources" / "Prompts"


class CheckStudyPrompts(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory(prefix="r9-")
        self.dir = Path(self._tmp.name) / "Prompts"
        shutil.copytree(PROMPTS, self.dir)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_check(self) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-I", str(SCRIPT), "--dir", str(self.dir)],
            capture_output=True, text=True)

    def test_real_set_passes(self) -> None:
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_changed_bytes_fail(self) -> None:
        f = self.dir / "retry_cue.mp3"
        f.write_bytes(f.read_bytes() + b"\x00")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("retry_cue.mp3", r.stdout)

    def test_missing_file_fails(self) -> None:
        (self.dir / "celebration.mp3").unlink()
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("celebration.mp3", r.stdout)

    def test_extra_mp3_fails(self) -> None:
        (self.dir / "praise_4.mp3").write_bytes(b"x")
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("praise_4.mp3", r.stdout)

    def test_manifest_set_id_must_match_files(self) -> None:
        m = json.loads((self.dir / "MANIFEST.json").read_text())
        m["setId"] = "rec:kiki:000000000000"
        (self.dir / "MANIFEST.json").write_text(json.dumps(m))
        r = self.run_check()
        self.assertEqual(r.returncode, 1, r.stdout)
        self.assertIn("setId", r.stdout)


if __name__ == "__main__":
    unittest.main()
