"""Umbrella CLI driver for Phase 2b drift-from-reference gates.

Per `research_data/phase2b_gates/g1_design.md`. Each gate's logic lives
as a function in `scripts/audit_invariants.py` (`gate_g1`, future
`gate_g2`...); this script handles letter enumeration, candidate/
reference source resolution, mask rasterization, and output
formatting.

Usage:
  scripts/run_gates.py --gate g1|g3|g4|g6|g7 [LETTERS...]
                       [--candidate-ref REF | WORKTREE]
                       [--reference-ref REF]
                       [--weight regular|light]
                       [--threshold FLOAT]
                       [--json]

Gates: g1 g2 g3 g4 g6 g7 (g7 = stroke start/end position, i.e. direction
and start point; its threshold is provisional, see audit_invariants.py).

Defaults: candidate=WORKTREE, reference=HEAD, weight=regular, threshold =
the gate's default in GATE_METADATA. With no LETTERS given the letter set
is the UNION of the working tree and the candidate/reference git refs, so
a deleted letter folder fails as `missing_candidate` instead of vanishing.

Exit code: 0 if all letters pass; 1 if any letter fails.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import unicodedata
from pathlib import Path

# Reuse the bake's rasterize + bbox_from_mask so gate input mirrors
# what the bake itself would see for the same letter glyph.
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
import audit_invariants as ai  # noqa: E402
import generate_strokes_auto as g  # noqa: E402

REPO_ROOT = SCRIPT_DIR.parent
LETTERS_DIR_DEFAULT = REPO_ROOT / "PrimaeNative" / "Resources" / "Letters"
WORKTREE_SENTINEL = "WORKTREE"
G7_ALLOWLIST_PATH = SCRIPT_DIR / "g7_allowlist.json"


def folder_for(letter: str) -> str:
    """Map a letter character to its directory name on disk.

    Uppercase letters and uncased characters (ß) use bare-name folders;
    lowercase letters use `<letter>_l`. See
    `PrimaeNative/Resources/Letters/Regular/` for the convention.
    """
    return letter if letter.isupper() else f"{letter}_l"


def strokes_path(letter: str, weight: str,
                  letters_dir: Path = LETTERS_DIR_DEFAULT) -> Path:
    return (letters_dir / weight.capitalize() / folder_for(letter)
            / "strokes.json")


def load_strokes(letter: str, weight: str, ref: str,
                  letters_dir: Path = LETTERS_DIR_DEFAULT) -> dict | None:
    """Load a letter's strokes.json from a git ref or the working tree.

    Returns None if the source doesn't exist (missing letter, missing
    file at the ref, etc.).
    """
    path = strokes_path(letter, weight, letters_dir)
    if ref == WORKTREE_SENTINEL:
        if not path.exists():
            return None
        return json.loads(path.read_text())
    rel = path.relative_to(REPO_ROOT)
    result = subprocess.run(
        ["git", "show", f"{ref}:{rel.as_posix()}"],
        capture_output=True, text=True, cwd=REPO_ROOT)
    if result.returncode != 0:
        return None
    return json.loads(result.stdout)


_G7_REQUIRED = ("letter", "weight", "stroke", "referenceCommit",
                "candidateCommit", "referenceStrokeSha256",
                "candidateStrokeSha256", "reason", "date")


def load_g7_allowlist(path: Path | None = None) -> list[dict]:
    """Load and validate scripts/g7_allowlist.json (INTENDED stroke
    direction/endpoint changes G7 must not fail). Raises ValueError on a
    malformed entry: an allow-list that silently accepts garbage would be
    a way to switch the gate off."""
    import re
    path = path or G7_ALLOWLIST_PATH
    doc = json.loads(path.read_text(encoding="utf-8"))
    entries = doc.get("entries", [])
    sha = re.compile(r"[0-9a-f]{64}\Z")
    commit = re.compile(r"[0-9a-f]{40}\Z")
    day = re.compile(r"\d{4}-\d{2}-\d{2}\Z")
    for n, e in enumerate(entries):
        where = f"{path.name} entry {n}"
        for key in _G7_REQUIRED:
            if key not in e:
                raise ValueError(f"{where}: missing {key!r}")
        if not (isinstance(e["stroke"], int) and not isinstance(e["stroke"], bool)
                and e["stroke"] >= 0):
            raise ValueError(f"{where}: stroke must be a non-negative integer")
        if e["weight"] not in ("regular", "light"):
            raise ValueError(f"{where}: weight must be regular|light")
        if not isinstance(e["letter"], str) or not e["letter"]:
            raise ValueError(f"{where}: letter must be a non-empty string")
        for key in ("referenceCommit", "candidateCommit"):
            if not isinstance(e[key], str) or not commit.match(e[key]):
                raise ValueError(f"{where}: {key} must be a full 40-hex sha")
        for key in ("referenceStrokeSha256", "candidateStrokeSha256"):
            if not isinstance(e[key], str) or not sha.match(e[key]):
                raise ValueError(f"{where}: {key} must be 64 lowercase hex")
        if not isinstance(e["reason"], str) or not e["reason"].strip():
            raise ValueError(f"{where}: reason must be non-empty")
        if not isinstance(e["date"], str) or not day.match(e["date"]):
            raise ValueError(f"{where}: date must be YYYY-MM-DD")
    return entries


def g7_allowlist_for(entries: list[dict], letter: str, weight: str
                     ) -> list[dict]:
    """The entries that apply to one letter (NFC) and weight."""
    key = unicodedata.normalize("NFC", letter)
    return [e for e in entries
            if unicodedata.normalize("NFC", e["letter"]) == key
            and e["weight"] == weight]


def strokes_to_polylines(data: dict) -> list[list[tuple[float, float]]]:
    """Extract (x, y) tuples per stroke from a strokes.json dict."""
    return [[(c["x"], c["y"]) for c in s["checkpoints"]]
            for s in data["strokes"]]


def _letter_from_folder(name: str) -> str:
    """Inverse of `folder_for`."""
    if name.endswith("_l") and len(name) == 3:
        return name[0]
    return name


def _folders_at_ref(weight: str, ref: str,
                    letters_dir: Path = LETTERS_DIR_DEFAULT) -> list[str]:
    """Letter folder names under `<Weight>/` in the tree at git `ref`.

    Empty if the ref, or the directory at that ref, does not exist (the
    per-letter load then reports `missing_reference` / `missing_candidate`
    for it, so an unknown ref still fails loudly rather than passing).
    `-z` keeps non-ASCII folder names (Ä, ß_l, ...) unquoted.
    """
    try:
        rel = (letters_dir / weight.capitalize()).relative_to(REPO_ROOT)
    except ValueError:
        return []
    result = subprocess.run(
        ["git", "ls-tree", "-d", "--name-only", "-z", ref,
         rel.as_posix() + "/"],
        capture_output=True, cwd=REPO_ROOT)
    if result.returncode != 0:
        return []
    names = result.stdout.decode("utf-8").split("\0")
    return [n.rsplit("/", 1)[-1] for n in names if n]


def enumerate_letters(weight: str,
                       letters_dir: Path = LETTERS_DIR_DEFAULT,
                       refs: tuple[str, ...] = ()
                       ) -> list[str]:
    """Every letter under `letters_dir/<Weight>/` in the working tree
    UNION every letter in the tree of each git ref in `refs`.

    The union is the point (audit 2026-10-13, G3-06): enumerating only
    the working tree meant a PR that deleted a letter folder -- or its
    `strokes.json` -- was never visited by any gate and passed. A letter
    that exists at the reference but not in the candidate is now
    enumerated, and `run_gate_for_letter` fails it as
    `missing_candidate`.

    `WORKTREE_SENTINEL` in `refs` adds the working tree; refs that are
    not the sentinel are read with `git ls-tree`. With `refs` empty only
    the working tree is read (the previous behaviour).
    """
    folders: dict[str, str] = {}   # NFC key -> folder spelling first seen

    def add(name: str) -> None:
        folders.setdefault(unicodedata.normalize("NFC", name), name)

    weight_dir = letters_dir / weight.capitalize()
    if (not refs or WORKTREE_SENTINEL in refs) and weight_dir.is_dir():
        for entry in sorted(weight_dir.iterdir()):
            if entry.is_dir():
                add(entry.name)
    for ref in refs:
        if ref == WORKTREE_SENTINEL:
            continue
        for name in _folders_at_ref(weight, ref, letters_dir):
            add(name)
    return [_letter_from_folder(n) for n in sorted(folders.values())]


# Per-gate metadata. Adding G3/G4/G5 is a single-row table entry.
# `needs_mask`: G1 (asymmetry) and the future G3 (stem-width / perpendicular
# deviation) need the ink-mask raster; G2 (turn-angle) and the future G4
# (junction-tangent) are pure polyline computations.
GATE_METADATA: dict[str, dict] = {
    "g1": {
        "function_with_mask": ai.gate_g1,
        "function_without_mask": None,
        "needs_mask": True,
        "title": "asymmetry-profile drift from reference",
        # Drift gate: pass iff metric ≥ threshold.
        "comparison": "≥",
        "default_threshold": ai.G1_DEFAULT_THRESHOLD,
    },
    "g2": {
        "function_with_mask": None,
        "function_without_mask": ai.gate_g2,
        "needs_mask": False,
        "title": "turn-angle-profile drift from reference",
        "comparison": "≥",
        # G2 is investigated-not-viable; not enforced. No default
        # threshold; --threshold must be passed explicitly to run.
        "default_threshold": None,
    },
    "g3": {
        "function_with_mask": None,
        "function_without_mask": ai.gate_g3,
        "needs_mask": False,
        "title": "perpendicular deviation on straight strokes",
        # Conformance gate: pass iff metric ≤ threshold.
        "comparison": "≤",
        "default_threshold": ai.G3_DEFAULT_THRESHOLD,
    },
    "g4": {
        "function_with_mask": None,
        "function_without_mask": ai.gate_g4,
        "needs_mask": False,
        "title": "junction-tangent-kink drift from reference",
        # Drift gate on per-junction property: pass iff drift ≤ threshold.
        "comparison": "≤",
        "default_threshold": ai.G4_DEFAULT_THRESHOLD_DEG,
    },
    "g6": {
        "function_with_mask": None,
        "function_without_mask": ai.gate_g6,
        "needs_mask": False,
        "title": "T-junction attachment-tangent drift from reference",
        # Drift gate on per-junction property: pass iff drift ≤ threshold.
        "comparison": "≤",
        "default_threshold": ai.G6_DEFAULT_THRESHOLD_DEG,
    },
    "g7": {
        "function_with_mask": None,
        "function_without_mask": ai.gate_g7,
        "needs_mask": False,
        "title": "stroke start/end position drift from reference "
                 "(direction + start point)",
        # Drift gate on per-stroke endpoints (px): pass iff shift <= threshold.
        "comparison": "≤",
        "default_threshold": ai.G7_DEFAULT_THRESHOLD_PX,
    },
}


def run_gate_for_letter(letter: str, gate: str, weight: str,
                         candidate_ref: str, reference_ref: str,
                         threshold: float,
                         letters_dir: Path = LETTERS_DIR_DEFAULT
                         ) -> dict:
    """Dispatch to the gate function for `gate` against a single letter.

    The gate function comes from GATE_METADATA; mask is built only when
    the gate needs it.
    """
    meta = GATE_METADATA[gate]
    candidate = load_strokes(letter, weight, candidate_ref, letters_dir)
    reference = load_strokes(letter, weight, reference_ref, letters_dir)
    if candidate is None or reference is None:
        return {
            "letter": letter,
            "pass": False,
            "error": ("missing_candidate" if candidate is None
                      else "missing_reference"),
        }
    font_path = g.FONTS[weight]
    if not font_path.exists():
        return {"letter": letter, "pass": False,
                "error": f"missing_font:{font_path}"}
    mask = g.rasterize(letter, font_path)
    bbox = g.bbox_from_mask(mask)
    cand_polys = strokes_to_polylines(candidate)
    ref_polys = strokes_to_polylines(reference)
    extra: dict = {}
    if gate == "g7":
        extra["allowlist"] = g7_allowlist_for(load_g7_allowlist(), letter,
                                              weight)
    if meta["needs_mask"]:
        result = meta["function_with_mask"](cand_polys, ref_polys,
                                              mask, bbox, threshold)
    else:
        result = meta["function_without_mask"](cand_polys, ref_polys,
                                                 bbox, threshold, **extra)
    result["letter"] = letter
    # Every gate compares min(n_cand, n_ref) pairs, so a deleted or added
    # stroke passed all of them silently — the most consequential corpus
    # regression was the one thing no gate checked (audit 2026-09-04).
    n_cand, n_ref = len(cand_polys), len(ref_polys)
    # Do not shadow a gate that reports its own counts (G4/G6 do): if
    # they ever disagree with the runner's, say so instead of hiding it.
    for key, val in (("n_strokes_candidate", n_cand), ("n_strokes_reference", n_ref)):
        if key in result and result[key] != val:
            result["pass"] = False
            result["stroke_count_mismatch"] = f"gate reports {key}={result[key]}, runner counts {val}"
        result.setdefault(key, val)
    if n_cand != n_ref:
        result["pass"] = False
        result["stroke_count_mismatch"] = f"candidate {n_cand} vs reference {n_ref} strokes"
    return result


def format_letter_human(result: dict) -> str:
    letter = result["letter"]
    if "error" in result:
        return f"{letter:6s} ERROR: {result['error']}"
    parts = [f"{'✓' if result['pass'] else '✗'} {letter:4s}"]
    if result.get("stroke_count_mismatch"):
        parts.append(f"STROKE COUNT CHANGED: {result['stroke_count_mismatch']}")
    # Drift-per-stroke (G1/G2) and conformance-per-stroke (G3) gates
    # produce a `per_stroke` key. Drift-per-junction (G4) gates produce
    # `per_junction` instead.
    if "per_junction" in result:
        if result.get("letter_reason"):
            parts.append(f"({result['letter_reason']})")
        for j in result["per_junction"]:
            idx = f"s{j['stroke_i']}-s{j['stroke_j']}"
            if j.get("reason"):
                parts.append(f"{idx}: vacuous ({j['reason']})")
            else:
                mark = "✓" if j["pass"] else "✗"
                parts.append(f"{idx}: {mark} drift={j['kink_drift_deg']:.2f}°"
                             f" (ref={j['kink_ref_deg']:.1f}°"
                             f" cand={j['kink_cand_deg']:.1f}°)")
        return "  " + "  ".join(parts)
    for s in result["per_stroke"]:
        idx = s["stroke"]
        if s.get("reason"):
            parts.append(f"s{idx}: vacuous ({s['reason']})")
        else:
            mark = "✓" if s["pass"] else "✗"
            # Drift gates report 'pearson'; conformance gates report
            # 'deviation_px'. Format whichever the gate produced.
            if "pearson" in s:
                parts.append(f"s{idx}: {mark} pearson={s['pearson']:.4f}"
                             f" n={s['n_measured']}")
            elif "deviation_px" in s:
                parts.append(f"s{idx}: {mark} dev={s['deviation_px']:.2f}px"
                             f" n={s['n_measured']}")
            elif "start_shift_px" in s:
                tail = " REVERSED" if s.get("reversed") else ""
                if s.get("allowed"):
                    tail += f" ALLOWED ({s.get('allowed_date')})"
                path = ("" if s.get("path_shift_px") is None
                        else f" path={s['path_shift_px']:.1f}px")
                parts.append(f"s{idx}: {mark} start={s['start_shift_px']:.1f}px"
                             f" end={s['end_shift_px']:.1f}px{path}{tail}")
            else:
                parts.append(f"s{idx}: {mark} (unknown metric shape)")
    return "  " + "  ".join(parts)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("letters", nargs="*",
                        help="Letters to audit (default: all on disk)")
    parser.add_argument("--gate", required=True,
                        choices=list(GATE_METADATA.keys()),
                        help="Gate to run (more gates land in later Phase 2b commits)")
    parser.add_argument("--candidate-ref", default=WORKTREE_SENTINEL,
                        help="Git ref for candidate strokes.json "
                             "(default: WORKTREE = working tree)")
    parser.add_argument("--reference-ref", default="HEAD",
                        help="Git ref for reference strokes.json (default: HEAD)")
    parser.add_argument("--weight", default="regular",
                        choices=list(g.FONTS.keys()))
    parser.add_argument("--threshold", type=float, default=None,
                        help="Pass threshold (overrides the gate's "
                             "calibrated default). Each gate has a "
                             "post-calibration default in "
                             "GATE_METADATA; omit this flag to use it.")
    parser.add_argument("--letters-dir", type=Path,
                        default=LETTERS_DIR_DEFAULT)
    parser.add_argument("--json", action="store_true",
                        help="Emit machine-readable JSON instead of stdout report")
    args = parser.parse_args(argv)

    # Resolve --threshold default from GATE_METADATA. If the gate
    # has no calibrated default (G2: investigated-not-viable) and
    # --threshold wasn't passed, fail loudly rather than running
    # against a meaningless placeholder.
    if args.threshold is None:
        gate_default = GATE_METADATA[args.gate].get("default_threshold")
        if gate_default is None:
            print(f"Gate {args.gate} has no calibrated default threshold "
                  f"(investigated-not-viable). Pass --threshold "
                  f"explicitly to run it.", file=sys.stderr)
            return 1
        args.threshold = gate_default

    # Union of both sides, not just the working tree: a deleted letter
    # folder must be visited (and fail) rather than silently vanish.
    letters = args.letters or enumerate_letters(
        args.weight, args.letters_dir,
        refs=(args.candidate_ref, args.reference_ref))
    if not letters:
        print(f"No letters found under "
              f"{args.letters_dir}/{args.weight.capitalize()}",
              file=sys.stderr)
        return 1

    results: list[dict] = []
    for letter in letters:
        results.append(run_gate_for_letter(
            letter, args.gate, args.weight,
            args.candidate_ref, args.reference_ref,
            args.threshold, args.letters_dir))

    n_pass = sum(1 for r in results if r.get("pass"))
    n_fail = len(results) - n_pass

    if args.json:
        out = {
            "gate": args.gate,
            "threshold": args.threshold,
            "candidate_ref": args.candidate_ref,
            "reference_ref": args.reference_ref,
            "weight": args.weight,
            "letters": {r["letter"]: r for r in results},
            "summary": {"pass": n_pass, "fail": n_fail,
                        "total": len(results)},
        }
        print(json.dumps(out, indent=2, ensure_ascii=False))
    else:
        meta = GATE_METADATA[args.gate]
        title = meta["title"]
        comparison = meta.get("comparison", "≥")
        header = (f"{args.gate.upper()} — {title} "
                  f"(threshold {comparison} {args.threshold})")
        print(header)
        print()
        for r in results:
            print(format_letter_human(r))
        print()
        print(f"Summary: {n_pass}/{len(results)} pass, {n_fail} fail")

    return 0 if n_fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
