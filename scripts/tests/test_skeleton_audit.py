"""Tests for `skeleton_audit.py`'s anchor-spec check (audit 2026-10-13,
G3-03): every `LETTERS` entry is a static artifact, the bake refuses those,
so the check silently skipped all 37 and the bake primitives had no CI
execution. `include_static=True` lifts the guard for the dry bake.

Run: python3 scripts/tests/test_skeleton_audit.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))
import skeleton_audit as sa  # noqa: E402


class AnchorSpecGuardTests(unittest.TestCase):

    def setUp(self):
        self.saved = sa.bake_letter
        self.addCleanup(setattr, sa, "bake_letter", self.saved)
        self.calls: list[dict] = []

        def fake_bake(letter, font_path, *, _suppress_static_guard=False):
            self.calls.append({"letter": letter,
                               "suppress": _suppress_static_guard})
            if letter == "BAD":
                raise ValueError("anchor does not resolve")
            if letter == "STATIC" and not _suppress_static_guard:
                raise KeyError(f"{letter!r} ships as a static artifact; "
                               "bake is intentionally not authored.")
            return {}, {}
        sa.bake_letter = fake_bake

    def test_default_skips_a_static_letter_without_baking_it(self):
        self.assertIsNone(sa.check_anchor_spec("STATIC", Path("f.otf")))
        self.assertFalse(self.calls[0]["suppress"])

    def test_include_static_actually_bakes_it(self):
        result = sa.check_anchor_spec("STATIC", Path("f.otf"),
                                      include_static=True)
        self.assertEqual(result, [])             # baked: ok, not skipped
        self.assertTrue(self.calls[0]["suppress"])

    def test_include_static_surfaces_a_real_bake_failure(self):
        result = sa.check_anchor_spec("BAD", Path("f.otf"),
                                      include_static=True)
        self.assertEqual(len(result), 1)
        self.assertIn("anchor does not resolve", result[0])

    def test_unrelated_keyerror_is_an_error_not_a_skip(self):
        def boom(letter, font_path, *, _suppress_static_guard=False):
            raise KeyError("missing anchor 'FOO'")
        sa.bake_letter = boom
        result = sa.check_anchor_spec("X", Path("f.otf"), include_static=True)
        self.assertIsNotNone(result)
        self.assertTrue(result)


if __name__ == "__main__":
    unittest.main()
