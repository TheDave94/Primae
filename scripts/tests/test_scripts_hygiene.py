"""Repository-hygiene checks for scripts/ (audit 2026-10-13).

* G3-17 / D2-10: no script or doc under scripts/ may teach
  `export ELEVENLABS_API_KEY=<value>` - that form writes the literal key to
  shell history, and CLAUDE.md ("Credentials") mandates `read -s`.
* G3-12: `audio_variants/` is where both ElevenLabs scripts write paid MP3s
  (relative to the CWD). It must be git-ignored: untracked files make the
  Xcode scheme's provenance pre-action refuse the build.
* The old `BuchstabenNative` path (pre-rebrand) must not be taught.

Pure standard library + git.

Run: python3 scripts/tests/test_scripts_hygiene.py
"""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent.parent
REPO_ROOT = SCRIPTS.parent
THIS_FILE = Path(__file__).resolve()


def _script_files():
    for p in sorted(SCRIPTS.rglob("*")):
        if (p.is_file() and p.resolve() != THIS_FILE
                and p.suffix in {".py", ".sh", ".md", ""}
                and "__pycache__" not in p.parts):
            yield p


class ScriptHygieneTests(unittest.TestCase):

    def test_no_script_teaches_exporting_the_key_as_a_literal(self):
        pattern = re.compile(r"export\s+ELEVENLABS_API_KEY\s*=")
        offenders = [f"{p.relative_to(REPO_ROOT)}:{n}"
                     for p in _script_files()
                     for n, line in enumerate(
                         p.read_text(encoding="utf-8", errors="replace")
                         .splitlines(), 1)
                     if pattern.search(line)]
        self.assertEqual(offenders, [])

    def test_the_read_s_pattern_is_what_is_taught(self):
        for name in ("generate_letter_audio.py", "generate_prompts.py"):
            text = (SCRIPTS / name).read_text(encoding="utf-8")
            self.assertIn('read -s -p "ELEVENLABS_API_KEY: "', text, name)

    def test_no_pre_rebrand_buchstabennative_path(self):
        offenders = [str(p.relative_to(REPO_ROOT)) for p in _script_files()
                     if "BuchstabenNative" in p.read_text(
                         encoding="utf-8", errors="replace")]
        self.assertEqual(offenders, [])

    def test_audio_variants_is_git_ignored(self):
        for path in ("audio_variants/Emilia/A/A1.mp3",
                     "audio_variants/Emilia/prompts/praise_4.mp3"):
            # `git check-ignore -q` accepts a single pathname only.
            result = subprocess.run(["git", "check-ignore", "-q", path],
                                    cwd=REPO_ROOT)
            self.assertEqual(result.returncode, 0,
                             f"{path} is not git-ignored (rc "
                             f"{result.returncode}; 1 = not ignored)")


if __name__ == "__main__":
    unittest.main()
