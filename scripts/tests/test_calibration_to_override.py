"""Tests for `calibration_to_override.py`, the ACTUAL writer of the shipped
strokes.json corpus (audit 2026-10-13, G3-18).

Validation already ran before the first write for stroke usability and
schriftArt. Missing from it: `checkpointRadius` (a KeyError after earlier
letters had already been written), non-numeric / non-finite / out-of-range
coordinates, and the writes were neither atomic nor explicit-UTF-8.

Pure standard library; no numpy needed.

Run: python3 scripts/tests/test_calibration_to_override.py
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPT_DIR))
import calibration_to_override as c2o  # noqa: E402


def stroke(points):
    return {"id": 1, "checkpoints": [{"x": x, "y": y} for x, y in points]}


GOOD = [(0.1, 0.1), (0.5, 0.5), (0.9, 0.9)]


class ImportTests(unittest.TestCase):

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="primae-c2o-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.base = self.tmp / "Letters"
        saved = c2o.LETTERS_BASE
        c2o.LETTERS_BASE = self.base
        self.addCleanup(setattr, c2o, "LETTERS_BASE", saved)
        # Two shipped letters with skeleton fields that must survive.
        for name in ("A", "B"):
            d = self.base / "Regular" / name
            d.mkdir(parents=True)
            (d / "strokes.json").write_text(json.dumps(
                {"letter": name, "checkpointRadius": 0.1,
                 "strokes": [stroke([(0.0, 0.0), (1.0, 1.0)])],
                 "skeleton": [[1, 2]], "skeletonAdj": {}}) + "\n")

    def _export(self, letters, **extra):
        path = self.tmp / "export.json"
        path.write_text(json.dumps({"schriftArt": "druckschrift",
                                    "letters": letters, **extra}))
        return path

    def _entry(self, letter, points=GOOD, radius=0.1):
        e = {"letter": letter, "strokes": [stroke(points)]}
        if radius is not None:
            e["checkpointRadius"] = radius
        return e

    def _shipped(self, name):
        return (self.base / "Regular" / name / "strokes.json").read_text()

    def _assert_corpus_untouched(self):
        for name in ("A", "B"):
            self.assertIn('"checkpointRadius": 0.1', self._shipped(name))
            self.assertEqual(json.loads(self._shipped(name))["strokes"][0]
                             ["checkpoints"][0], {"x": 0.0, "y": 0.0})

    def test_happy_path_writes_and_preserves_skeleton(self):
        path = self._export([self._entry("A"), self._entry("B")])
        summary = c2o.import_aggregate_export(path)
        self.assertEqual(summary["written"], ["A", "B"])
        doc = json.loads(self._shipped("A"))
        self.assertEqual(doc["skeleton"], [[1, 2]])
        self.assertEqual(doc["strokes"][0]["checkpoints"][0],
                         {"x": 0.1, "y": 0.1})
        self.assertTrue(self._shipped("A").endswith("\n"))

    def test_missing_checkpoint_radius_is_rejected_before_any_write(self):
        # THE G3-18 REPRODUCTION: A is valid, B lacks the radius. Before the
        # fix A was written and THEN B raised KeyError: half-imported corpus.
        path = self._export([self._entry("A"), self._entry("B", radius=None)])
        with self.assertRaises(ValueError) as cm:
            c2o.import_aggregate_export(path)
        self.assertIn("checkpointRadius", str(cm.exception))
        self._assert_corpus_untouched()

    def test_non_numeric_radius_is_rejected(self):
        path = self._export([self._entry("A", radius="0.1")])
        with self.assertRaises(ValueError):
            c2o.import_aggregate_export(path)
        self._assert_corpus_untouched()

    def test_out_of_range_coordinate_is_rejected_before_any_write(self):
        path = self._export([self._entry("A"),
                             self._entry("B", [(0.1, 0.1), (0.5, -0.0061)])])
        with self.assertRaises(ValueError) as cm:
            c2o.import_aggregate_export(path)
        self.assertIn("B", str(cm.exception))
        self._assert_corpus_untouched()

    def test_coordinate_above_one_is_rejected(self):
        path = self._export([self._entry("A", [(0.1, 0.1), (1.0001, 0.5)])])
        with self.assertRaises(ValueError):
            c2o.import_aggregate_export(path)

    def test_boundary_values_zero_and_one_are_accepted(self):
        path = self._export([self._entry("A", [(0.0, 0.0), (1.0, 1.0)])])
        self.assertEqual(c2o.import_aggregate_export(path)["written"], ["A"])

    def test_nan_and_infinity_are_rejected(self):
        for bad in (float("nan"), float("inf")):
            path = self.tmp / "nan.json"
            # json.dumps emits the non-standard NaN/Infinity tokens, which
            # json.loads accepts - exactly the input to guard against.
            path.write_text(json.dumps({
                "schriftArt": "druckschrift",
                "letters": [self._entry("A", [(0.1, 0.1), (bad, 0.5)])]}))
            with self.assertRaises(ValueError):
                c2o.import_aggregate_export(path)
        self._assert_corpus_untouched()

    def test_non_numeric_and_boolean_coordinates_are_rejected(self):
        for bad in ("0.5", None, True):
            path = self._export([self._entry("A", [(0.1, 0.1), (bad, 0.5)])])
            with self.assertRaises(ValueError):
                c2o.import_aggregate_export(path)
        self._assert_corpus_untouched()

    def test_writes_are_utf8_and_leave_no_temp_files(self):
        d = self.base / "Regular" / "Ä"
        d.mkdir(parents=True)
        (d / "strokes.json").write_text("{}")
        path = self._export([self._entry("Ä")])      # NFD input
        c2o.import_aggregate_export(path)
        raw = (d / "strokes.json").read_bytes()
        self.assertIn('"letter": "Ä"'.encode("utf-8"), raw)
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["strokes.json"])

    def test_crash_during_replace_keeps_the_previous_file(self):
        from unittest import mock
        path = self._export([self._entry("A")])
        before = self._shipped("A")
        with mock.patch.object(c2o.os, "replace",
                               side_effect=OSError("simulated crash")):
            with self.assertRaises(OSError):
                c2o.import_aggregate_export(path)
        self.assertEqual(self._shipped("A"), before)
        d = self.base / "Regular" / "A"
        self.assertEqual(sorted(p.name for p in d.iterdir()), ["strokes.json"])


if __name__ == "__main__":
    unittest.main()
