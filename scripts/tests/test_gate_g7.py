"""Unit tests for G7 (stroke start/end position drift: direction + start
point). Added by the 2026-10-13 audit, finding G3-05.

Why it exists: G1/G3/G4/G6 are all invariant to reversing a polyline, yet
the stroke START decides the start dot, the observe animation and the
tracing order. Measured: commit caff3472 reversed A strokes 0 and 1 and
every other gate stayed green - a change that was DELIBERATE (top-down
correction), which is why it is the first entry of scripts/g7_allowlist.json
(see TestG7AllowList), not a defect fixture. The headline test is
`test_reversed_straight_stroke_fails`; reversed loops (O, Ö, o, ö, q) are
covered by TestG7ReversedLoops.

Run: python3 scripts/tests/test_gate_g7.py
"""

from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR))
import audit_invariants as ai  # noqa: E402

BBOX = (0, 0, 1000, 1000)          # 1 rel unit == 1000 px
THRESHOLD = ai.G7_DEFAULT_THRESHOLD_PX


def line(x0, y0, x1, y1, n=21):
    return [(x0 + (x1 - x0) * i / (n - 1), y0 + (y1 - y0) * i / (n - 1))
            for i in range(n)]


class TestG7PerStroke(unittest.TestCase):

    def test_identical_stroke_passes_with_zero_shift(self):
        s = line(0.1, 0.1, 0.9, 0.9)
        r = ai.gate_g7_per_stroke(s, s, BBOX, THRESHOLD)
        self.assertTrue(r["pass"])
        self.assertEqual(r["start_shift_px"], 0.0)
        self.assertEqual(r["end_shift_px"], 0.0)
        self.assertFalse(r["reversed"])

    def test_reversed_straight_stroke_fails(self):
        # THE G3-05 REPRODUCTION. A straight stroke traced the other way
        # has an identical shape; only its direction differs.
        ref = line(0.2, 0.1, 0.2, 0.9)                 # top -> bottom stem
        cand = list(reversed(ref))                      # bottom -> top
        r = ai.gate_g7_per_stroke(cand, ref, BBOX, THRESHOLD)
        self.assertFalse(r["pass"])
        self.assertTrue(r["reversed"])
        self.assertAlmostEqual(r["start_shift_px"], 800.0, places=3)
        self.assertAlmostEqual(r["end_shift_px"], 800.0, places=3)

    def test_small_nudge_within_threshold_passes(self):
        ref = line(0.1, 0.1, 0.9, 0.1)
        cand = line(0.1 + 0.02, 0.1, 0.9, 0.1 - 0.02)   # 20 px each end
        r = ai.gate_g7_per_stroke(cand, ref, BBOX, THRESHOLD)
        self.assertTrue(r["pass"])

    def test_start_moved_past_threshold_fails_but_is_not_a_reversal(self):
        ref = line(0.1, 0.1, 0.9, 0.1)
        cand = line(0.1 + 0.1, 0.1, 0.9, 0.1)           # start 100 px off
        r = ai.gate_g7_per_stroke(cand, ref, BBOX, THRESHOLD)
        self.assertFalse(r["pass"])
        self.assertFalse(r["reversed"])
        self.assertAlmostEqual(r["start_shift_px"], 100.0, places=3)
        self.assertAlmostEqual(r["end_shift_px"], 0.0, places=3)

    def test_end_moved_past_threshold_fails(self):
        ref = line(0.1, 0.1, 0.9, 0.1)
        cand = line(0.1, 0.1, 0.9 - 0.1, 0.1)           # end 100 px off
        r = ai.gate_g7_per_stroke(cand, ref, BBOX, THRESHOLD)
        self.assertFalse(r["pass"])
        self.assertAlmostEqual(r["start_shift_px"], 0.0, places=3)
        self.assertAlmostEqual(r["end_shift_px"], 100.0, places=3)

    def test_threshold_is_inclusive(self):
        # Binary-exact fractions of a 640 px bbox so "exactly 40 px" is.
        bbox = (0, 0, 640, 640)
        ref = line(0.125, 0.5, 0.875, 0.5)
        cand = line(0.125 + 0.0625, 0.5, 0.875, 0.5)    # exactly 40 px
        self.assertTrue(ai.gate_g7_per_stroke(cand, ref, bbox, 40.0)["pass"])
        self.assertFalse(ai.gate_g7_per_stroke(cand, ref, bbox, 39.9)["pass"])

    def test_shift_is_measured_in_bbox_px(self):
        # Same relative move, bigger bbox => bigger px shift.
        ref = line(0.0, 0.0, 1.0, 0.0)
        cand = line(0.05, 0.0, 1.0, 0.0)
        small = ai.gate_g7_per_stroke(cand, ref, (0, 0, 200, 200), 40.0)
        big = ai.gate_g7_per_stroke(cand, ref, (100, 100, 1100, 1100), 40.0)
        self.assertTrue(small["pass"])                  # 10 px
        self.assertFalse(big["pass"])                   # 50 px
        self.assertAlmostEqual(small["start_shift_px"], 10.0, places=6)
        self.assertAlmostEqual(big["start_shift_px"], 50.0, places=6)

    def test_single_point_dot_compared_by_position(self):
        self.assertTrue(ai.gate_g7_per_stroke(
            [(0.5, 0.2)], [(0.5, 0.2)], BBOX, THRESHOLD)["pass"])
        self.assertFalse(ai.gate_g7_per_stroke(
            [(0.5, 0.9)], [(0.5, 0.2)], BBOX, THRESHOLD)["pass"])

    def test_both_empty_is_vacuous_pass(self):
        r = ai.gate_g7_per_stroke([], [], BBOX, THRESHOLD)
        self.assertTrue(r["pass"])
        self.assertEqual(r["reason"], "empty_stroke")

    def test_one_side_empty_fails(self):
        s = line(0.1, 0.1, 0.9, 0.9)
        r = ai.gate_g7_per_stroke([], s, BBOX, THRESHOLD)
        self.assertFalse(r["pass"])
        self.assertEqual(r["reason"], "empty_candidate_stroke")
        r = ai.gate_g7_per_stroke(s, [], BBOX, THRESHOLD)
        self.assertFalse(r["pass"])
        self.assertEqual(r["reason"], "empty_reference_stroke")


class TestG7Letter(unittest.TestCase):

    def _lambda(self):
        return [line(0.1, 0.9, 0.5, 0.1), line(0.9, 0.9, 0.5, 0.1),
                line(0.3, 0.5, 0.7, 0.5)]

    def test_identical_letter_passes(self):
        r = ai.gate_g7(self._lambda(), self._lambda(), BBOX, THRESHOLD)
        self.assertTrue(r["pass"])
        self.assertEqual(len(r["per_stroke"]), 3)
        self.assertEqual(r["letter_score"], 0.0)

    def test_one_reversed_stroke_fails_the_letter_and_names_it(self):
        cand = self._lambda()
        cand[1] = list(reversed(cand[1]))
        r = ai.gate_g7(cand, self._lambda(), BBOX, THRESHOLD)
        self.assertFalse(r["pass"])
        self.assertEqual([s["pass"] for s in r["per_stroke"]],
                         [True, False, True])
        self.assertTrue(r["per_stroke"][1]["reversed"])
        self.assertEqual([s["stroke"] for s in r["per_stroke"]], [0, 1, 2])
        self.assertGreater(r["letter_score"], 700.0)

    def test_swapped_stroke_order_fails(self):
        # Same strokes, order exchanged: every endpoint now sits where a
        # different stroke's endpoint was.
        cand = self._lambda()
        cand[0], cand[1] = cand[1], cand[0]
        r = ai.gate_g7(cand, self._lambda(), BBOX, THRESHOLD)
        self.assertFalse(r["pass"])

    def test_iterates_the_common_stroke_range_only(self):
        # Extra strokes are run_gates' stroke_count_mismatch to report.
        r = ai.gate_g7(self._lambda()[:2], self._lambda(), BBOX, THRESHOLD)
        self.assertTrue(r["pass"])
        self.assertEqual(len(r["per_stroke"]), 2)
        self.assertEqual((r["n_strokes_candidate"], r["n_strokes_reference"]),
                         (2, 3))

    def test_registered_in_run_gates_with_provisional_default(self):
        import run_gates as rg
        meta = rg.GATE_METADATA["g7"]
        self.assertIs(meta["function_without_mask"], ai.gate_g7)
        self.assertFalse(meta["needs_mask"])
        self.assertEqual(meta["default_threshold"], THRESHOLD)
        self.assertEqual(meta["comparison"], "≤")


def _corpus_strokes(folder: str, weight: str = "Regular"):
    """Strokes of the committed corpus file in the working tree."""
    import json
    path = (REPO_ROOT / "PrimaeNative" / "Resources" / "Letters" / weight
            / folder / "strokes.json")
    return [[(c["x"], c["y"]) for c in s["checkpoints"]]
            for s in json.loads(path.read_text(encoding="utf-8"))["strokes"]]


# Estimated glyph-bbox px for the bake's render scale (819 px / 2700 font
# units = 0.303 px/unit; width = (advance - 2*lsb), heights from OS/2 cap
# 1600 and x 959 units): O/Ö 349x485, o/ö 243x291, q 253x291.
LOOP_BBOX = {"O": (0, 0, 349, 485), "Ö": (0, 0, 349, 485),
             "o_l": (0, 0, 243, 291), "ö_l": (0, 0, 243, 291),
             "q_l": (0, 0, 253, 291)}


class TestG7ReversedLoops(unittest.TestCase):
    """Review 2026-10-13: an endpoint-only G7 cannot see a reversed LOOP
    letter. Reversing a stroke moves its first/last checkpoints by
    |first - last|, which is tiny for a closed bowl (O 21 px, ö 22, q 23,
    Ö 28, o 31 against the 40 px threshold), so the path itself - points at
    fixed arc-length fractions - must be compared too."""

    def test_reversed_loop_letters_fail(self):
        for folder, bbox in LOOP_BBOX.items():
            ref = _corpus_strokes(folder)
            cand = [list(reversed(s)) for s in ref]       # every stroke reversed
            r = ai.gate_g7(cand, ref, bbox, THRESHOLD)
            self.assertFalse(r["pass"], folder)
            bowl = r["per_stroke"][0]
            self.assertTrue(bowl["reversed"], folder)
            self.assertGreater(bowl["path_shift_px"], 100.0, folder)

    def test_the_endpoints_alone_would_have_passed_a_reversed_O(self):
        # Documents WHY the path check exists: at the real O bbox the
        # reversed bowl's endpoints move less than the threshold.
        ref = _corpus_strokes("O")
        r = ai.gate_g7_per_stroke(list(reversed(ref[0])), ref[0],
                                  LOOP_BBOX["O"], THRESHOLD)
        self.assertLess(r["start_shift_px"], THRESHOLD)
        self.assertLess(r["end_shift_px"], THRESHOLD)
        self.assertFalse(r["pass"])

    def test_every_regular_stroke_fails_when_reversed(self):
        # Corpus-wide, at a bbox smaller than any real glyph's (243 x 291
        # px, the narrowest/shortest estimate), so a pass here cannot be
        # an artefact of a large frame.
        import glob
        small = (0, 0, 243, 291)
        survivors = []
        for path in sorted(glob.glob(str(
                REPO_ROOT / "PrimaeNative/Resources/Letters/Regular/*/"
                "strokes.json"))):
            folder = Path(path).parent.name
            for i, stroke in enumerate(_corpus_strokes(folder)):
                if len(stroke) < 2:
                    continue                      # diacritic dots
                r = ai.gate_g7_per_stroke(list(reversed(stroke)), stroke,
                                          small, THRESHOLD)
                if r["pass"]:
                    survivors.append((folder, i))
        self.assertEqual(survivors, [])

    def test_mid_stroke_reshape_with_fixed_endpoints_fails_but_is_not_reversed(self):
        ref = line(0.1, 0.5, 0.9, 0.5)
        bulge = [(x, y - 0.2 * (1 - abs(2 * (x - 0.1) / 0.8 - 1)))
                 for x, y in ref]                      # endpoints unchanged
        r = ai.gate_g7_per_stroke(bulge, ref, BBOX, THRESHOLD)
        self.assertFalse(r["pass"])
        self.assertFalse(r["reversed"])
        self.assertEqual(r["start_shift_px"], 0.0)
        self.assertGreater(r["path_shift_px"], THRESHOLD)

    def test_drift_at_only_one_of_the_two_fractions_still_fails(self):
        # A localized bump at ONE of the sample points (x = 0.3 for the 25 %
        # point, x = 0.7 for the 75 % point); the two points move by
        # different amounts.
        ref = line(0.1, 0.5, 0.9, 0.5, n=201)
        for centre in (0.3, 0.7):
            cand = [(x, y - 0.2 * max(0.0, 1 - abs(x - centre) / 0.05))
                    for x, y in ref]               # endpoints unchanged
            r = ai.gate_g7_per_stroke(cand, ref, BBOX, THRESHOLD)
            self.assertFalse(r["pass"], centre)
            self.assertGreater(r["path_shift_px"], THRESHOLD, centre)
            fractions = ai._path_distances(ai._poly_px(cand, BBOX),
                                           ai._poly_px(ref, BBOX))[0]
            # The reported shift is the WORST of the sample points, not the
            # best or the mean (the two differ here by construction).
            self.assertGreater(max(fractions) - min(fractions), 10.0, centre)
            self.assertAlmostEqual(r["path_shift_px"], max(fractions), 9)

    def test_small_mid_stroke_drift_passes(self):
        ref = line(0.1, 0.5, 0.9, 0.5)
        nudged = [(x, y + 0.02) for x, y in ref[1:-1]]
        cand = [ref[0]] + nudged + [ref[-1]]           # <= 20 px mid drift
        r = ai.gate_g7_per_stroke(cand, ref, BBOX, THRESHOLD)
        self.assertTrue(r["pass"])
        self.assertLess(r["path_shift_px"], 25.0)   # 20 px nudge + arc-length re-spacing

    def test_zero_length_and_single_point_strokes_skip_the_path_check(self):
        dot = [(0.5, 0.5)]
        r = ai.gate_g7_per_stroke(dot, dot, BBOX, THRESHOLD)
        self.assertTrue(r["pass"])
        self.assertIsNone(r["path_shift_px"])
        same = [(0.5, 0.5)] * 5
        r = ai.gate_g7_per_stroke(same, same, BBOX, THRESHOLD)
        self.assertTrue(r["pass"])
        self.assertIsNone(r["path_shift_px"])


def _corpus_at(rev: str, folder: str, weight_dir: str = "Regular"):
    """strokes of Regular/<folder> at git `rev`, or None if the history
    is unavailable (shallow clone)."""
    import json
    r = subprocess.run(
        ["git", "show", f"{rev}:PrimaeNative/Resources/Letters/{weight_dir}/"
                        f"{folder}/strokes.json"],
        capture_output=True, text=True, cwd=REPO_ROOT)
    if r.returncode != 0:
        return None
    return [[(c["x"], c["y"]) for c in s["checkpoints"]]
            for s in json.loads(r.stdout)["strokes"]]


class TestG7AllowList(unittest.TestCase):
    """INTENDED direction changes are recorded in scripts/g7_allowlist.json
    and honoured (reported as `allowed`). The first entry is the A change
    in commit caff3472: strokes 0 and 1 of Regular/A (and Light/A) were
    reversed to run apex-down, a deliberate top-down correction (verified
    by independent review against the current app: A runs apex-down, then
    the crossbar left-to-right). Needs full git history (bake-gates.yml
    checks out with fetch-depth 0); skipped on a shallow clone."""

    WEIGHTS = (("regular", "Regular"), ("light", "Light"))

    def _pair(self, weight_dir="Regular"):
        before = _corpus_at("caff3472~1", "A", weight_dir)
        after = _corpus_at("caff3472", "A", weight_dir)
        if before is None or after is None:
            self.skipTest("git history for caff3472 not available")
        return before, after

    def _entries(self, weight):
        import run_gates as rg
        return rg.g7_allowlist_for(rg.load_g7_allowlist(), "A", weight)

    def test_without_the_allow_list_the_A_reversal_fails(self):
        before, after = self._pair()
        r = ai.gate_g7(after, before, (100, 100, 900, 900), THRESHOLD)
        self.assertFalse(r["pass"])
        self.assertEqual([s["pass"] for s in r["per_stroke"]],
                         [False, False, True])
        self.assertTrue(r["per_stroke"][0]["reversed"])
        self.assertTrue(r["per_stroke"][1]["reversed"])

    def test_the_committed_allow_list_admits_exactly_that_change(self):
        for weight, weight_dir in self.WEIGHTS:
            before, after = self._pair(weight_dir)
            r = ai.gate_g7(after, before, (100, 100, 900, 900), THRESHOLD,
                           allowlist=self._entries(weight))
            self.assertTrue(r["pass"], weight)
            self.assertEqual([bool(s.get("allowed"))
                              for s in r["per_stroke"]], [True, True, False],
                             weight)
            self.assertEqual(r["n_allowed"], 2)
            self.assertIn("top-down", r["per_stroke"][0]["allowed"])
            # The measurements are still reported, not zeroed.
            self.assertGreater(r["per_stroke"][0]["start_shift_px"], 100.0)

    def test_an_edit_on_top_of_the_allowed_change_is_not_allowed(self):
        before, after = self._pair()
        tweaked = [list(s) for s in after]
        tweaked[0][5] = (tweaked[0][5][0] + 0.001, tweaked[0][5][1])
        r = ai.gate_g7(tweaked, before, (100, 100, 900, 900), THRESHOLD,
                       allowlist=self._entries("regular"))
        self.assertFalse(r["pass"])
        self.assertFalse(r["per_stroke"][0].get("allowed"))
        self.assertTrue(r["per_stroke"][1].get("allowed"))

    def test_an_entry_is_bound_to_the_reference_it_was_written_against(self):
        before, after = self._pair()
        moved_ref = [list(s) for s in before]
        moved_ref[0][-1] = (moved_ref[0][-1][0] + 0.001, moved_ref[0][-1][1])
        r = ai.gate_g7(after, moved_ref, (100, 100, 900, 900), THRESHOLD,
                       allowlist=self._entries("regular"))
        self.assertFalse(r["pass"])
        self.assertFalse(r["per_stroke"][0].get("allowed"))

    def test_an_entry_is_bound_to_its_stroke_index(self):
        before, after = self._pair()
        entries = [dict(e, stroke=2) for e in self._entries("regular")]
        r = ai.gate_g7(after, before, (100, 100, 900, 900), THRESHOLD,
                       allowlist=entries)
        self.assertFalse(r["pass"])
        self.assertEqual(r["n_allowed"], 0)

    def test_entries_do_not_leak_across_letters_or_weights(self):
        import run_gates as rg
        entries = rg.load_g7_allowlist()
        self.assertEqual(rg.g7_allowlist_for(entries, "B", "regular"), [])
        self.assertEqual(rg.g7_allowlist_for(entries, "A", "regular")[0]
                         ["weight"], "regular")
        self.assertTrue(all(e["weight"] == "light" for e in
                            rg.g7_allowlist_for(entries, "A", "light")))

    def test_committed_entries_match_git_history(self):
        # Auditable: the recorded digests are those of the real blobs.
        import run_gates as rg
        for e in rg.load_g7_allowlist():
            weight_dir = e["weight"].capitalize()
            ref = _corpus_at(e["referenceCommit"], e["letter"], weight_dir)
            cand = _corpus_at(e["candidateCommit"], e["letter"], weight_dir)
            if ref is None or cand is None:
                self.skipTest("git history for the allow-list not available")
            self.assertEqual(ai.g7_stroke_digest(ref[e["stroke"]]),
                             e["referenceStrokeSha256"], e)
            self.assertEqual(ai.g7_stroke_digest(cand[e["stroke"]]),
                             e["candidateStrokeSha256"], e)


class TestG7AllowListFile(unittest.TestCase):

    GOOD = {"letter": "A", "weight": "regular", "stroke": 0,
            "referenceCommit": "a" * 40, "candidateCommit": "b" * 40,
            "referenceStrokeSha256": "c" * 64,
            "candidateStrokeSha256": "d" * 64,
            "reason": "deliberate", "date": "2026-10-01"}

    def _load(self, entries):
        import json
        import tempfile
        import run_gates as rg
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "al.json"
            path.write_text(json.dumps({"version": 1, "entries": entries}))
            return rg.load_g7_allowlist(path)

    def test_a_complete_entry_loads(self):
        self.assertEqual(self._load([self.GOOD]), [self.GOOD])

    def test_each_required_field_is_enforced(self):
        for key in self.GOOD:
            bad = {k: v for k, v in self.GOOD.items() if k != key}
            with self.assertRaises(ValueError, msg=key):
                self._load([bad])

    def test_malformed_values_are_rejected(self):
        for key, value in (("referenceStrokeSha256", "xyz"),
                           ("candidateStrokeSha256", "C" * 64),
                           ("reason", "   "), ("date", "1 Oct 2026"),
                           ("weight", "bold"), ("stroke", -1),
                           ("stroke", True), ("referenceCommit", "abc")):
            with self.assertRaises(ValueError, msg=key):
                self._load([dict(self.GOOD, **{key: value})])

    def test_the_committed_file_is_valid_and_starts_with_the_A_change(self):
        import run_gates as rg
        entries = rg.load_g7_allowlist()
        self.assertGreaterEqual(len(entries), 2)
        first = entries[0]
        self.assertEqual((first["letter"], first["weight"], first["stroke"]),
                         ("A", "regular", 0))
        self.assertTrue(first["candidateCommit"].startswith("caff3472"))
        self.assertIn("top-down", first["reason"])


if __name__ == "__main__":
    unittest.main()
