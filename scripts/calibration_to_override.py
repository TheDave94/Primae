#!/usr/bin/env python3
"""Import an iPad-calibrator aggregate export into per-letter
strokes.json files.

The calibrator's `Alle` export bundles every letter for the current
schriftArt into one JSON. This script splits that bundle into the
per-letter directory layout under `PrimaeNative/Resources/Letters/`,
preserving any existing skeleton / skeletonAdj / bridgeEdges fields
on each letter (the calibrator export does not include them, but
they're required by the calibrator's BFS routing for ANKER mode).

The export's letter strings arrive in Unicode NFD form for diacritics
(`A` + combining diaeresis = Ä decomposed). Linux filesystems treat
NFD and NFC paths as distinct, so a literal write creates a
sibling directory next to the existing NFC `Ä`. `normalize_letter_name`
normalises to NFC before path construction.

Usage:
    python3 scripts/calibration_to_override.py \\
        --input /path/to/strokes.json \\
        [--weight regular]  # default: derived from JSON 'schriftArt'
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import tempfile
import unicodedata
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LETTERS_BASE = REPO_ROOT / "PrimaeNative/Resources/Letters"
LOWERCASE_SUFFIX = "_l"

SCHRIFTART_TO_WEIGHT_DIR = {
    "druckschrift": "Regular",
    "druckschrift_light": "Light",
}


def normalize_letter_name(name: str) -> str:
    """Normalize a letter string to Unicode NFC. The iPad calibrator
    export encodes diacritics in NFD (e.g. "Ä" as "A\\u0308"); shipped
    directories are NFC. Without this normalisation, a literal write
    creates an NFD-form sibling of the existing NFC directory."""
    return unicodedata.normalize("NFC", name)


def target_dir(letter: str, weight_dir: str) -> Path:
    """Resolve the per-letter resource directory for a given weight,
    honouring the lowercase-suffix convention (APFS / HFS+ case-
    insensitivity) and NFC normalisation for diacritics."""
    letter_nfc = normalize_letter_name(letter)
    if letter_nfc.isupper() or not letter_nfc.isalpha():
        return LETTERS_BASE / weight_dir / letter_nfc
    return LETTERS_BASE / weight_dir / f"{letter_nfc}{LOWERCASE_SUFFIX}"


def write_text_atomic(path: Path, text: str) -> None:
    """UTF-8 write via temp file + os.replace (a crash cannot leave a
    truncated strokes.json; the locale cannot mis-encode "Ä"/"ß")."""
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent),
                                    prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(text.encode("utf-8"))
        os.chmod(tmp_name, 0o644)
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
        raise


def _is_number(v) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def validate_entry(entry: dict) -> None:
    """Raise ValueError if `entry` must not be written. Runs for EVERY
    entry before the first write (audit 2026-10-13, G3-18): a bad
    checkpointRadius used to surface as a KeyError after earlier letters
    were already replaced, and nothing checked the coordinates."""
    letter = entry.get("letter")
    radius = entry.get("checkpointRadius")
    if not _is_number(radius) or not math.isfinite(radius) or radius <= 0:
        raise ValueError(f"{letter!r}: checkpointRadius missing or not a "
                         f"positive finite number ({radius!r}) — refusing to write")
    for si, s in enumerate(entry.get("strokes") or []):
        for ci, cp in enumerate(s.get("checkpoints", [])):
            x = cp.get("x") if isinstance(cp, dict) else None
            y = cp.get("y") if isinstance(cp, dict) else None
            for axis, v in (("x", x), ("y", y)):
                if not _is_number(v) or not math.isfinite(v) or not 0.0 <= v <= 1.0:
                    raise ValueError(
                        f"{letter!r}: stroke {si} checkpoint {ci} {axis}={v!r} "
                        f"is not a finite number in [0, 1] — refusing to write")


def import_aggregate_export(input_path: Path,
                             weight_dir: str | None = None
                             , allow_new: bool = False) -> dict:
    """Split the aggregate export into per-letter strokes.json files.

    Preserves skeleton / skeletonAdj / bridgeEdges fields from any
    existing per-letter file (the calibrator export omits them but
    the calibrator's runtime BFS routing requires them).

    Returns a summary dict: {written: [letter,...], skipped: [...]}.
    """
    data = json.loads(input_path.read_text(encoding="utf-8"))
    if weight_dir is None:
        schrift = data.get("schriftArt", "druckschrift")
        if schrift not in SCHRIFTART_TO_WEIGHT_DIR:
            # An unknown or misspelled value used to fall through to
            # Regular and overwrite the pilot corpus (audit 2026-09-04).
            raise ValueError(f"unknown schriftArt {schrift!r}; expected one of "
                             f"{sorted(SCHRIFTART_TO_WEIGHT_DIR)} — pass --weight-dir to override")
        weight_dir = SCHRIFTART_TO_WEIGHT_DIR[schrift]
    # Validate EVERY entry before the first write, so a rejected export
    # cannot leave the corpus half-overwritten (review 2026-09-05).
    for entry in data["letters"]:
        letter = entry["letter"]
        strokes = entry.get("strokes") or []
        if not strokes or any(len(s.get("checkpoints", [])) < 2 for s in strokes):
            # Never replace a shipped file with an empty or one-checkpoint
            # export from an unvisited letter (audit 2026-09-04).
            raise ValueError(f"{letter!r}: export has no usable strokes "
                             f"({[len(s.get('checkpoints', [])) for s in strokes]}) — refusing to write")
        validate_entry(entry)
        f = target_dir(normalize_letter_name(letter), weight_dir) / "strokes.json"
        if not f.exists() and not allow_new:
            # A letter with no shipped file would be written WITHOUT the
            # skeleton fields the calibrator and the schema audit need;
            # new letters are a bake-pipeline act (review 2026-09-05).
            raise ValueError(f"{letter!r}: no shipped strokes.json at {f}; new letters come "
                             f"from the bake, not the calibrator (pass --allow-new to override)")
    written: list[str] = []
    for entry in data["letters"]:
        letter = entry["letter"]
        letter_nfc = normalize_letter_name(letter)
        d = target_dir(letter_nfc, weight_dir)
        f = d / "strokes.json"
        old = (json.loads(f.read_text(encoding="utf-8"))
               if f.exists() else None)
        new_doc: dict = {
            "letter": letter_nfc,
            "checkpointRadius": entry["checkpointRadius"],
            "strokes": entry["strokes"],
        }
        if old:
            for k in ("skeleton", "skeletonAdj", "bridgeEdges"):
                if k in old:
                    new_doc[k] = old[k]
        d.mkdir(parents=True, exist_ok=True)
        write_text_atomic(f, json.dumps(new_doc, indent=2,
                                        ensure_ascii=False) + "\n")
        written.append(letter_nfc)
    return {"written": written, "weight_dir": weight_dir}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Import an iPad-calibrator aggregate strokes.json "
                    "into per-letter files.")
    parser.add_argument("--input", required=True, type=Path,
                         help="Path to the aggregate strokes.json export.")
    parser.add_argument("--allow-new", action="store_true",
                        help="permit writing a letter that has no shipped strokes.json "
                             "(it will lack the skeleton fields; normally a bake-pipeline act)")
    parser.add_argument("--weight", choices=["regular", "light"],
                         default=None,
                         help="Override weight directory. Default: derived "
                              "from the export's `schriftArt` field.")
    args = parser.parse_args(argv)
    weight_dir = (args.weight.capitalize()
                   if args.weight else None)
    if not args.input.exists():
        print(f"input not found: {args.input}", file=sys.stderr)
        return 1
    summary = import_aggregate_export(args.input, weight_dir=weight_dir,
                                      allow_new=args.allow_new)
    print(f"wrote {len(summary['written'])} letters to "
          f"Letters/{summary['weight_dir']}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
