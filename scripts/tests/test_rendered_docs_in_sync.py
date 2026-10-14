"""The committed HTML renderings of two markdown docs must equal what their
renderer produces today (audit 2026-10-13, G3-15): `docs/testing_checklist.html`
had not been regenerated since 2026-05-14 while TESTING_CHECKLIST.md changed
on 2026-10-01 (62 current lines missing), so the page a proctor ticks boxes in
was the stale one. Same pattern as test_design_tokens_sync.py.

Fix a failure with `python3 scripts/render_checklist.py` /
`python3 scripts/render_dryrun.py`, then commit the HTML.

Pure standard library.

Run: python3 scripts/tests/test_rendered_docs_in_sync.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))
import render_checklist  # noqa: E402
import render_dryrun  # noqa: E402


def _rendered(mod) -> str:
    body = mod.render(mod.SRC.read_text(encoding="utf-8"))
    return mod.HTML_SHELL.replace("__CONTENT__", body)


class RenderedDocsInSyncTests(unittest.TestCase):

    def _check(self, mod, script):
        self.assertEqual(
            mod.OUT.read_text(encoding="utf-8"), _rendered(mod),
            f"{mod.OUT.name} is stale vs {mod.SRC.name}: run "
            f"`python3 scripts/{script}` and commit the result")

    def test_testing_checklist_html_is_current(self):
        self._check(render_checklist, "render_checklist.py")

    def test_study_device_dryrun_html_is_current(self):
        self._check(render_dryrun, "render_dryrun.py")


if __name__ == "__main__":
    unittest.main()
