"""Topology-driven cross-font stroke generator.

Two layers, decoupled:

1. **Topology** — `LETTER_TOPOLOGY` below. Per letter, a font-independent
   description of *what kinds of strokes the letter has* (vertical /
   horizontal / loop / arc / continuous / bowl / arch / descender_hook),
   the *region* each stroke lives in (x_band: left/center/right;
   y_band: top/mid/bottom), and the *direction* it's drawn in (down /
   up / left / right / cw / ccw). Defined once for the whole alphabet,
   never changes when you add a new font.

2. **Geometry extractor** — the `GlyphAnalyzer` class. Takes any font
   path and any letter, rasterizes the glyph, computes its medial-axis
   skeleton via the Euclidean distance transform, and resolves each
   topology primitive to actual ink coordinates *in this font*. So for
   a new font you just run the generator over all letters — no per-
   letter spec changes.

The output JSON shape matches `generate_strokes_centerline.py` so the
iOS renderer keeps working unchanged.

Usage:
    pip install Pillow numpy scipy scikit-image
    python scripts/generate_strokes_topology.py            # all letters
    python scripts/generate_strokes_topology.py A E O      # subset
    python scripts/generate_strokes_topology.py --font /path/to/Other.otf
    python scripts/generate_strokes_topology.py --debug A  # save overlay PNG
"""
from __future__ import annotations

import argparse
import json
import math
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from scipy import ndimage
import skimage.morphology as morph
import skimage.measure as measure

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_FONT = REPO_ROOT / "design-system/fonts/Primae-Regular.otf"
OUTPUT_BASE = REPO_ROOT / "PrimaeNative/Resources/Letters"

# Rasterization knobs. SIZE high enough that the skeleton has a
# stable, sub-pixel-accurate centerline; PAD matches the iOS
# renderer's `pad = 0.10` so the JSON's 0..1 coordinates land in the
# same place on the canvas as the on-device ghost path.
SIZE = 1024
PAD = 0.10
DEFAULT_RADIUS = 0.04


# -----------------------------------------------------------------------------
# Rasterization (matches iOS PrimaeLetterRenderer.glyphPath)
# -----------------------------------------------------------------------------

def rasterize(letter: str, font_path: Path) -> np.ndarray:
    """Render `letter` to a SIZE × SIZE binary mask using uniform
    font-metric scaling: every glyph in the font shares the same
    em-square (ascent + descent) so lowercase 'a' renders smaller
    than 'A' (its natural typographic relationship).

    The baseline is anchored at `pad + scaled_ascent` from the top of
    the canvas — same rule as the iOS renderer — so the strokes
    generated here line up with the on-device ghost path.
    """
    avail = int(SIZE * (1 - 2 * PAD))
    probe_size = 1000
    probe = ImageFont.truetype(str(font_path), probe_size)
    probe_ascent, probe_descent = probe.getmetrics()
    em = probe_ascent + probe_descent
    if em <= 0:
        raise ValueError(f"Bad font metrics for {letter!r}")
    target_size = int(round(probe_size * avail / em))
    font = ImageFont.truetype(str(font_path), target_size)
    ascent, _ = font.getmetrics()
    bbox = font.getbbox(letter)
    w = bbox[2] - bbox[0]
    if w <= 0:
        raise ValueError(f"Empty glyph for {letter!r}")
    x = (SIZE - w) // 2 - bbox[0]
    baseline_y = int(SIZE * PAD + ascent)
    img = Image.new("L", (SIZE, SIZE), 255)
    ImageDraw.Draw(img).text((x, baseline_y), letter, font=font, fill=0, anchor="ls")
    return np.array(img) < 128


# -----------------------------------------------------------------------------
# GlyphAnalyzer — primitive extraction from a rasterized + skeletonised glyph
# -----------------------------------------------------------------------------

class GlyphAnalyzer:
    """Holds a rasterized glyph + its medial-axis skeleton + connected
    components, and exposes primitive-finder methods that the topology
    layer composes into full strokes.
    """

    def __init__(self, mask: np.ndarray):
        self.mask = mask
        self.skel = morph.skeletonize(mask)
        # Distance transform: pixel-distance to nearest non-ink edge.
        # The skeleton sits on the local maxima of this; we keep the
        # full transform around so primitives like `loop` can use the
        # ridge value to disambiguate path choices.
        self.dist = ndimage.distance_transform_edt(mask)
        # 8-connected components. Letters like K skeletonise into
        # disjoint pieces; primitives that need to stay on one
        # stroke (e.g. spine vs arm) constrain to the right component.
        self.skel_labels = measure.label(self.skel, connectivity=2)
        ys, xs = np.where(mask)
        if len(xs) == 0:
            raise ValueError("Empty glyph")
        self.x_min, self.x_max = int(xs.min()), int(xs.max())
        self.y_min, self.y_max = int(ys.min()), int(ys.max())
        self.skel_pts = np.column_stack(np.where(self.skel))  # (row, col) array

    # ------------------------------------------------------------------ bands

    def x_band(self, name: str) -> tuple[int, int]:
        w = self.x_max - self.x_min
        third = max(1, w // 3)
        if name == "left":   return self.x_min, self.x_min + third
        if name == "right":  return self.x_max - third, self.x_max
        if name == "center": return self.x_min + third, self.x_max - third
        if name == "full":   return self.x_min, self.x_max
        raise ValueError(f"Unknown x_band: {name!r}")

    def y_band(self, name: str) -> tuple[int, int]:
        h = self.y_max - self.y_min
        third = max(1, h // 3)
        if name == "top":    return self.y_min, self.y_min + third
        if name == "mid":    return self.y_min + third, self.y_max - third
        if name == "bottom": return self.y_max - third, self.y_max
        if name == "full":   return self.y_min, self.y_max
        if name == "upper-half":  return self.y_min, (self.y_min + self.y_max) // 2
        if name == "lower-half":  return (self.y_min + self.y_max) // 2, self.y_max
        raise ValueError(f"Unknown y_band: {name!r}")

    # -------------------------------------------------------------- primitives

    def _local_orientation(self, c: int, r: int, span: int = 3) -> str:
        """Classify a skeleton pixel as 'h' (horizontal run) or 'v'
        (vertical run) by counting skeleton neighbours on the same
        row vs the same column within `span` pixels. Pixels at
        T-junctions (where a horizontal and vertical meet) get
        classified by whichever axis dominates locally."""
        h, w = self.skel.shape
        n_h = 0
        n_v = 0
        for d in range(1, span + 1):
            if c - d >= 0 and self.skel[r, c - d]:
                n_h += 1
            if c + d < w and self.skel[r, c + d]:
                n_h += 1
            if r - d >= 0 and self.skel[r - d, c]:
                n_v += 1
            if r + d < h and self.skel[r + d, c]:
                n_v += 1
        return "h" if n_h > n_v else "v"

    def find_vertical(self, x_band: str = "full", y_band: str = "full",
                      direction: str = "down") -> list[tuple[int, int]]:
        """Skeleton pixels of a vertical stroke within the band, ordered
        top→bottom (or bottom→top for direction='up'). Filters by
        local orientation so a pixel that's part of a horizontal
        crossbar within the same band doesn't get pulled in. Multiple
        skeleton pixels at the same row collapse to their median
        column so a slightly-jagged centerline reads as a clean
        vertical."""
        x_lo, x_hi = self.x_band(x_band)
        y_lo, y_hi = self.y_band(y_band)
        rows, cols = np.where(self.skel)
        m = (cols >= x_lo) & (cols <= x_hi) & (rows >= y_lo) & (rows <= y_hi)
        if not m.any():
            return []
        by_row: dict[int, list[int]] = {}
        for r, c in zip(rows[m], cols[m]):
            if self._local_orientation(int(c), int(r)) != "v":
                continue
            by_row.setdefault(int(r), []).append(int(c))
        if not by_row:
            return []
        ordered = [(int(np.median(by_row[r])), r) for r in sorted(by_row)]
        return list(reversed(ordered)) if direction == "up" else ordered

    def find_horizontal(self, x_band: str = "full", y_band: str = "full",
                        direction: str = "right") -> list[tuple[int, int]]:
        """Skeleton pixels of a horizontal stroke within the band, ordered
        left→right (or right→left for direction='left'). Filters by
        local orientation so a pixel that's part of a vertical spine
        running through the same band doesn't bend the stroke."""
        x_lo, x_hi = self.x_band(x_band)
        y_lo, y_hi = self.y_band(y_band)
        rows, cols = np.where(self.skel)
        m = (cols >= x_lo) & (cols <= x_hi) & (rows >= y_lo) & (rows <= y_hi)
        if not m.any():
            return []
        by_col: dict[int, list[int]] = {}
        for r, c in zip(rows[m], cols[m]):
            if self._local_orientation(int(c), int(r)) != "h":
                continue
            by_col.setdefault(int(c), []).append(int(r))
        if not by_col:
            return []
        ordered = [(c, int(np.median(by_col[c]))) for c in sorted(by_col)]
        return list(reversed(ordered)) if direction == "left" else ordered

    # ---------------------------------------------------- corner / anchor resolve

    def anchor(self, name: str) -> tuple[int, int]:
        """Resolve an anchor name to an actual pixel on the skeleton.

        Uppercase keys map to glyph-bbox corners — TL = top-left, BR =
        bottom-right, etc.; T/B/L/R = mid of that edge. The resolved
        pixel is the skeleton (or ink) pixel nearest the requested
        bbox corner, so all anchor-driven primitives stay on the
        actual centerline.
        """
        cx = (self.x_min + self.x_max) // 2
        cy = (self.y_min + self.y_max) // 2
        targets = {
            "TL": (self.x_min, self.y_min),
            "TR": (self.x_max, self.y_min),
            "BL": (self.x_min, self.y_max),
            "BR": (self.x_max, self.y_max),
            "TC": (cx, self.y_min),
            "BC": (cx, self.y_max),
            "T":  (cx, self.y_min),
            "B":  (cx, self.y_max),
            "L":  (self.x_min, cy),
            "R":  (self.x_max, cy),
            "C":  (cx, cy),
        }
        if name not in targets:
            raise ValueError(f"Unknown anchor: {name!r}")
        return self.nearest_skeleton(targets[name])

    def nearest_skeleton(self, target_xy: tuple[int, int],
                         comp: int | None = None) -> tuple[int, int]:
        """Return (col, row) of the nearest skeleton pixel to `target_xy`.
        If `comp` is given, restrict to that connected component."""
        if not self.skel.any():
            return target_xy
        rows, cols = np.where(self.skel)
        if comp is not None:
            mask = self.skel_labels[rows, cols] == comp
            rows, cols = rows[mask], cols[mask]
            if len(rows) == 0:
                return target_xy
        tx, ty = target_xy
        d2 = (cols - tx) ** 2 + (rows - ty) ** 2
        i = int(np.argmin(d2))
        return int(cols[i]), int(rows[i])

    # ----------------------------------------------------------- BFS along skeleton

    def bfs(self, start: tuple[int, int], end: tuple[int, int],
            blocked: set[tuple[int, int]] | None = None,
            mask: np.ndarray | None = None) -> list[tuple[int, int]]:
        """Shortest-path BFS along the skeleton from `start` to `end`.
        Returns the pixel path in (col, row) order. `blocked` excludes
        specific pixels (used to force the BFS the long way round a
        closed loop). `mask` restricts the walk to a sub-array of the
        skeleton (used to keep K's arms on their component)."""
        skel = self.skel if mask is None else (self.skel & mask)
        if not skel[start[1], start[0]]:
            start = self.nearest_skeleton(start)
        if not skel[end[1], end[0]]:
            end = self.nearest_skeleton(end)
        h, w = skel.shape
        prev: dict[tuple[int, int], tuple[int, int] | None] = {start: None}
        q = deque([start])
        block = blocked or set()
        while q:
            cur = q.popleft()
            if cur == end:
                break
            x, y = cur
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = x + dx, y + dy
                    if not (0 <= nx < w and 0 <= ny < h):
                        continue
                    if not skel[ny, nx]:
                        continue
                    nb = (nx, ny)
                    if nb in prev or nb in block:
                        continue
                    prev[nb] = cur
                    q.append(nb)
        if end not in prev:
            return [start, end]
        # reconstruct
        path = [end]
        cur: tuple[int, int] | None = end
        while cur is not None and cur != start:
            cur = prev[cur]
            if cur is not None:
                path.append(cur)
        path.reverse()
        return path

    # ------------------------------------------------------- continuous & loop

    def find_continuous(self, anchors: list[str | tuple[float, float]]
                        ) -> list[tuple[int, int]]:
        """Trace a single continuous stroke through `anchors` in order.

        Each anchor is either a named bbox corner ('TL', 'BR', 'BC',
        etc.) or a normalised (x, y) tuple in [0, 1] for arbitrary
        positions (e.g. M's mid-valley at roughly (0.5, 0.7)).
        """
        # Resolve all anchors to skeleton pixels, voting on the dominant
        # connected component so the BFS doesn't try to span disjoint
        # skeleton pieces (K's spine vs arm, etc.).
        targets = []
        for a in anchors:
            if isinstance(a, str):
                targets.append(self.anchor(a))
            else:
                px = (int(round(a[0] * (SIZE - 1))), int(round(a[1] * (SIZE - 1))))
                targets.append(self.nearest_skeleton(px))
        comp_votes: dict[int, int] = {}
        for x, y in targets:
            cid = int(self.skel_labels[y, x])
            comp_votes[cid] = comp_votes.get(cid, 0) + 1
        chosen = max(comp_votes.items(), key=lambda kv: kv[1])[0]
        comp_mask = (self.skel_labels == chosen)
        snapped = [self.nearest_skeleton((x, y), comp=chosen) for x, y in targets]
        # Chain BFS through the anchors, dropping the duplicate join
        # pixel at each segment boundary so the returned path has no
        # repeated points.
        full: list[tuple[int, int]] = []
        for i in range(len(snapped) - 1):
            seg = self.bfs(snapped[i], snapped[i + 1], mask=comp_mask)
            full.extend(seg if i == 0 else seg[1:])
        return full

    def find_loop(self, start: str = "T", direction: str = "ccw"
                  ) -> list[tuple[int, int]]:
        """Walk a closed-loop skeleton component starting at `start`
        and going CCW or CW. The algorithm:

        1. Resolve `start` to an actual skeleton pixel.
        2. Pick two skeleton-neighbour candidates for the first step
           and decide which is the CCW lead-in by signed angle from
           the glyph centre.
        3. From the first step, walk the cycle one neighbour at a
           time (always picking an unvisited skeleton pixel) until
           we arrive back at the anchor.

        BFS isn't suitable here because the shortest path from the
        first-step to the anchor is *one pixel* (they're neighbours);
        the cycle walk forces the long way around.
        """
        anchor_xy = self.anchor(start)
        cid = int(self.skel_labels[anchor_xy[1], anchor_xy[0]])
        comp_mask = (self.skel_labels == cid)
        x, y = anchor_xy
        nbrs = []
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if dx == 0 and dy == 0:
                    continue
                nx, ny = x + dx, y + dy
                if 0 <= nx < self.skel.shape[1] and 0 <= ny < self.skel.shape[0] \
                        and self.skel[ny, nx]:
                    nbrs.append((nx, ny))
        if len(nbrs) < 2:
            return [anchor_xy]
        cx = (self.x_min + self.x_max) / 2
        cy = (self.y_min + self.y_max) / 2
        nbrs.sort(key=lambda p: math.atan2(p[1] - cy, p[0] - cx))
        # With image y growing downward, atan2 of an upper-left
        # neighbour is more negative than upper-right, so sorted[0]
        # = leftmost lead-in (CCW from a top anchor), sorted[-1] =
        # rightmost lead-in (CW from a top anchor).
        ccw_lead, cw_lead = nbrs[0], nbrs[-1]
        first_step = ccw_lead if direction == "ccw" else cw_lead
        return self._walk_cycle(anchor_xy, first_step, comp_mask)

    def _walk_cycle(self, anchor: tuple[int, int],
                    first_step: tuple[int, int],
                    comp_mask: np.ndarray,
                    max_steps: int = 100_000
                    ) -> list[tuple[int, int]]:
        """Walk a closed cycle from `anchor` through `first_step` and
        return when we arrive back at `anchor`.

        On each step, prefer an unvisited skeleton neighbour. Only
        close the loop (return to `anchor`) when no unvisited
        neighbour is available — otherwise the walk would short-cut
        on the very first step (since `anchor` is always a neighbour
        of `first_step` for closed loops).
        """
        h, w = self.skel.shape
        path = [anchor, first_step]
        visited = {anchor, first_step}
        current = first_step
        for _ in range(max_steps):
            cx, cy = current
            next_pt: tuple[int, int] | None = None
            anchor_reachable = False
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx, ny = cx + dx, cy + dy
                    if not (0 <= nx < w and 0 <= ny < h):
                        continue
                    if not self.skel[ny, nx] or not comp_mask[ny, nx]:
                        continue
                    if (nx, ny) == anchor:
                        anchor_reachable = True
                        continue
                    if (nx, ny) in visited:
                        continue
                    if next_pt is None:
                        next_pt = (nx, ny)
            if next_pt is not None:
                path.append(next_pt)
                visited.add(next_pt)
                current = next_pt
                continue
            if anchor_reachable:
                # No more unvisited skeleton — close the loop.
                path.append(anchor)
            return path
        return path

    def find_arc(self, start: str | tuple[float, float],
                 end:   str | tuple[float, float],
                 via:   list[str | tuple[float, float]] | None = None
                 ) -> list[tuple[int, int]]:
        """Open arc from `start` to `end`, optionally routing through
        named or normalised waypoints. Same anchor resolution rules as
        `find_continuous` but doesn't expect a closed loop."""
        anchors: list[str | tuple[float, float]] = [start, *(via or []), end]
        return self.find_continuous(anchors)


# -----------------------------------------------------------------------------
# Sampling
# -----------------------------------------------------------------------------

def auto_count(path_length: int) -> int:
    return max(3, min(12, path_length // 60))


def sample_evenly(path: list[tuple[int, int]], count: int
                  ) -> list[tuple[int, int]]:
    if count < 2 or len(path) <= count:
        return list(path)
    idx = np.linspace(0, len(path) - 1, count).round().astype(int)
    return [path[i] for i in idx]


def to_normalised(pt: tuple[int, int]) -> dict[str, float]:
    x, y = pt
    return {"x": round(x / (SIZE - 1), 3), "y": round(y / (SIZE - 1), 3)}


# -----------------------------------------------------------------------------
# Topology — font-independent stroke description per letter
# -----------------------------------------------------------------------------
# Each entry is a list of stroke specs. Spec keys:
#   kind:    "vertical" | "horizontal" | "loop" | "continuous" | "arc"
#   x_band:  "left" | "center" | "right" | "full"   (for vertical / horizontal)
#   y_band:  "top" | "mid" | "bottom" | "upper-half" | "lower-half" | "full"
#   direction: "down" | "up" | "left" | "right" | "ccw" | "cw"
#   anchors: list of named corners or normalised (x, y) tuples
#            (continuous / arc primitives only)
#   start:   corner anchor (loop primitive only)
LETTER_TOPOLOGY: dict[str, list[dict]] = {
    # ------------------------------ uppercase --------------------------------
    "A": [
        # Worksheet: ↑ at bottom-left → continuous left-leg up + right
        # leg down + crossbar.
        {"kind": "arc", "start": "BL", "end": "TC"},
        {"kind": "arc", "start": "TC", "end": "BR"},
        {"kind": "horizontal", "y_band": "mid", "direction": "right"},
    ],
    "B": [
        {"kind": "vertical",   "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": "TL", "end": "C", "via": [(0.65, 0.30)]},
        {"kind": "arc", "start": "C",  "end": "BL", "via": [(0.65, 0.65)]},
    ],
    "C": [
        {"kind": "arc", "start": "TR", "end": "BR", "via": [(0.18, 0.50)]},
    ],
    "D": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": "TL", "end": "BL", "via": [(0.78, 0.50)]},
    ],
    "E": [
        {"kind": "vertical",   "x_band": "left",   "direction": "down"},
        {"kind": "horizontal", "y_band": "top",    "direction": "right"},
        {"kind": "horizontal", "y_band": "mid",    "direction": "right"},
        {"kind": "horizontal", "y_band": "bottom", "direction": "right"},
    ],
    "F": [
        {"kind": "vertical",   "x_band": "left", "direction": "down"},
        {"kind": "horizontal", "y_band": "top",  "direction": "right"},
        {"kind": "horizontal", "y_band": "mid",  "direction": "right"},
    ],
    "G": [
        {"kind": "arc", "start": "TR", "end": (0.55, 0.55),
         "via": [(0.18, 0.50), (0.55, 0.95), (0.95, 0.55)]},
    ],
    "H": [
        {"kind": "vertical",   "x_band": "left",  "direction": "down"},
        {"kind": "horizontal", "y_band": "mid",   "direction": "right"},
        {"kind": "vertical",   "x_band": "right", "direction": "down"},
    ],
    "I": [
        {"kind": "vertical", "x_band": "full", "direction": "down"},
    ],
    "J": [
        {"kind": "arc", "start": "TR", "end": "BL",
         "via": [(0.55, 0.85)]},
    ],
    "K": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": "TR", "end": (0.30, 0.50)},
        {"kind": "arc", "start": (0.30, 0.50), "end": "BR"},
    ],
    "L": [
        {"kind": "vertical",   "x_band": "left",   "direction": "down"},
        {"kind": "horizontal", "y_band": "bottom", "direction": "right"},
    ],
    "M": [
        # ONE continuous stroke, BL ↑ TL → mid-valley → TR ↓ BR.
        {"kind": "continuous",
         "anchors": ["BL", "TL", (0.50, 0.85), "TR", "BR"]},
    ],
    "N": [
        # ONE continuous stroke, BL ↑ TL → BR ↑ TR.
        {"kind": "continuous",
         "anchors": ["BL", "TL", "BR", "TR"]},
    ],
    "O": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
    ],
    "P": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": "TL", "end": (0.40, 0.50),
         "via": [(0.70, 0.30)]},
    ],
    "Q": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "arc", "start": (0.55, 0.65), "end": "BR"},
    ],
    "R": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": "TL", "end": (0.40, 0.50),
         "via": [(0.70, 0.30)]},
        {"kind": "arc", "start": (0.40, 0.50), "end": "BR"},
    ],
    "S": [
        {"kind": "arc", "start": "TR", "end": "BL",
         "via": [(0.50, 0.50)]},
    ],
    "T": [
        {"kind": "horizontal", "y_band": "top", "direction": "right"},
        {"kind": "vertical",   "x_band": "center", "direction": "down"},
    ],
    "U": [
        {"kind": "arc", "start": "TL", "end": "TR",
         "via": [(0.50, 0.90)]},
    ],
    "V": [
        # ONE continuous stroke, TL → apex → TR.
        {"kind": "continuous",
         "anchors": ["TL", "BC", "TR"]},
    ],
    "W": [
        # ONE continuous stroke, TL → V₁ → mid → V₂ → TR.
        {"kind": "continuous",
         "anchors": ["TL", (0.32, 0.85), (0.50, 0.45),
                     (0.68, 0.85), "TR"]},
    ],
    "X": [
        {"kind": "arc", "start": "TL", "end": "BR"},
        {"kind": "arc", "start": "TR", "end": "BL"},
    ],
    "Y": [
        {"kind": "arc", "start": "TL", "end": (0.50, 0.50)},
        {"kind": "arc", "start": "TR", "end": (0.50, 0.50)},
        {"kind": "arc", "start": (0.50, 0.50), "end": "BC"},
    ],
    "Z": [
        {"kind": "horizontal", "y_band": "top",    "direction": "right"},
        {"kind": "arc", "start": "TR", "end": "BL"},
        {"kind": "horizontal", "y_band": "bottom", "direction": "right"},
    ],
    "Ä": [
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "arc", "start": "BL", "end": "TC"},
        {"kind": "arc", "start": "TC", "end": "BR"},
        {"kind": "horizontal", "y_band": "mid", "direction": "right"},
    ],
    "Ö": [
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "loop", "start": "T", "direction": "ccw"},
    ],
    "Ü": [
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "arc", "start": "TL", "end": "TR", "via": [(0.50, 0.90)]},
    ],
    "ß": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": "TL", "end": (0.40, 0.50),
         "via": [(0.70, 0.30)]},
        {"kind": "arc", "start": (0.40, 0.50), "end": "BR",
         "via": [(0.70, 0.70)]},
    ],
    # ------------------------------ lowercase --------------------------------
    "a": [
        {"kind": "continuous",
         "anchors": [(0.65, 0.45), (0.50, 0.40), (0.30, 0.50),
                     (0.30, 0.65), (0.50, 0.70), (0.65, 0.65), "BR"]},
    ],
    "b": [
        {"kind": "vertical", "x_band": "left", "y_band": "full",
         "direction": "down"},
        {"kind": "loop", "start": "L", "direction": "ccw"},
    ],
    "c": [
        {"kind": "arc", "start": "TR", "end": "BR",
         "via": [(0.20, 0.55)]},
    ],
    "d": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "vertical", "x_band": "right", "direction": "down"},
    ],
    "e": [
        {"kind": "horizontal", "y_band": "mid", "direction": "right"},
        {"kind": "arc", "start": "R", "end": "BR",
         "via": [(0.30, 0.45), (0.30, 0.70), (0.65, 0.85)]},
    ],
    "f": [
        {"kind": "arc", "start": "TR", "end": "B",
         "via": [(0.40, 0.30)]},
        {"kind": "horizontal", "y_band": "mid", "direction": "right"},
    ],
    "g": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "arc", "start": "TR", "end": "BL",
         "via": [(0.55, 0.85)]},
    ],
    "h": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": "L", "end": "BR",
         "via": [(0.55, 0.40)]},
    ],
    "i": [
        {"kind": "vertical", "x_band": "center", "y_band": "lower-half",
         "direction": "down"},
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
    ],
    "j": [
        {"kind": "arc", "start": "TC", "end": "BL",
         "via": [(0.55, 0.85)]},
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
    ],
    "k": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": "TR", "end": (0.40, 0.65)},
        {"kind": "arc", "start": (0.40, 0.65), "end": "BR"},
    ],
    "l": [
        {"kind": "vertical", "x_band": "center", "direction": "down"},
    ],
    "m": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": (0.20, 0.45), "end": (0.50, 1.00),
         "via": [(0.35, 0.40)]},
        {"kind": "arc", "start": (0.50, 0.45), "end": "BR",
         "via": [(0.65, 0.40)]},
    ],
    "n": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": (0.30, 0.45), "end": "BR",
         "via": [(0.50, 0.40)]},
    ],
    "o": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
    ],
    "p": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "loop", "start": "L", "direction": "ccw"},
    ],
    "q": [
        {"kind": "loop", "start": "T", "direction": "ccw"},
        {"kind": "vertical", "x_band": "right", "direction": "down"},
    ],
    "r": [
        {"kind": "vertical", "x_band": "left", "direction": "down"},
        {"kind": "arc", "start": "L", "end": "TR",
         "via": [(0.55, 0.40)]},
    ],
    "s": [
        {"kind": "arc", "start": "TR", "end": "BL",
         "via": [(0.50, 0.65)]},
    ],
    "t": [
        {"kind": "vertical", "x_band": "center", "direction": "down"},
        {"kind": "horizontal", "y_band": "mid", "direction": "right"},
    ],
    "u": [
        {"kind": "arc", "start": "TL", "end": "TR",
         "via": [(0.50, 0.95)]},
        {"kind": "vertical", "x_band": "right", "direction": "down"},
    ],
    "v": [
        {"kind": "continuous",
         "anchors": ["TL", "BC", "TR"]},
    ],
    "w": [
        {"kind": "continuous",
         "anchors": ["TL", (0.32, 1.00), (0.50, 0.55),
                     (0.68, 1.00), "TR"]},
    ],
    "x": [
        {"kind": "arc", "start": "TL", "end": "BR"},
        {"kind": "arc", "start": "TR", "end": "BL"},
    ],
    "y": [
        {"kind": "arc", "start": "TL", "end": "BC"},
        {"kind": "arc", "start": "TR", "end": "BL",
         "via": [(0.45, 0.95)]},
    ],
    "z": [
        {"kind": "horizontal", "y_band": "top",    "direction": "right"},
        {"kind": "arc", "start": "TR", "end": "BL"},
        {"kind": "horizontal", "y_band": "bottom", "direction": "right"},
    ],
    "ä": [
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "continuous",
         "anchors": [(0.65, 0.50), (0.50, 0.45), (0.32, 0.55),
                     (0.32, 0.70), (0.50, 0.78), (0.65, 0.70), "BR"]},
    ],
    "ö": [
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "loop", "start": "T", "direction": "ccw"},
    ],
    "ü": [
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "vertical", "x_band": "center", "y_band": "top"},
        {"kind": "arc", "start": "TL", "end": "TR",
         "via": [(0.50, 0.95)]},
        {"kind": "vertical", "x_band": "right", "direction": "down"},
    ],
}


# -----------------------------------------------------------------------------
# Generation
# -----------------------------------------------------------------------------

def extract_stroke(analyzer: GlyphAnalyzer, spec: dict) -> list[tuple[int, int]]:
    kind = spec["kind"]
    if kind == "vertical":
        return analyzer.find_vertical(
            x_band=spec.get("x_band", "full"),
            y_band=spec.get("y_band", "full"),
            direction=spec.get("direction", "down"),
        )
    if kind == "horizontal":
        return analyzer.find_horizontal(
            x_band=spec.get("x_band", "full"),
            y_band=spec.get("y_band", "full"),
            direction=spec.get("direction", "right"),
        )
    if kind == "continuous":
        return analyzer.find_continuous(spec["anchors"])
    if kind == "arc":
        return analyzer.find_arc(
            spec["start"], spec["end"], spec.get("via"),
        )
    if kind == "loop":
        return analyzer.find_loop(
            start=spec.get("start", "T"),
            direction=spec.get("direction", "ccw"),
        )
    raise ValueError(f"Unknown stroke kind: {kind!r}")


def generate_for_letter(letter: str, font_path: Path,
                        radius: float = DEFAULT_RADIUS) -> dict:
    if letter not in LETTER_TOPOLOGY:
        raise ValueError(f"No topology entry for {letter!r}")
    mask = rasterize(letter, font_path)
    analyzer = GlyphAnalyzer(mask)
    out_strokes: list[dict] = []
    for i, spec in enumerate(LETTER_TOPOLOGY[letter], start=1):
        path = extract_stroke(analyzer, spec)
        if len(path) < 2:
            # Empty / degenerate primitive — fall back to anchor pair so
            # the iOS renderer at least sees something it can draw.
            path = path + path
        count = spec.get("count") or auto_count(len(path))
        sampled = sample_evenly(path, count)
        cps = [to_normalised(p) for p in sampled]
        stroke: dict = {"id": i, "checkpoints": cps}
        if "comment" in spec:
            stroke["comment"] = spec["comment"]
        elif "kind" in spec:
            stroke["comment"] = spec["kind"]
        out_strokes.append(stroke)
    return {"letter": letter, "checkpointRadius": radius,
            "strokes": out_strokes}


# -----------------------------------------------------------------------------
# Visual debugging
# -----------------------------------------------------------------------------

def debug_overlay(letter: str, font_path: Path, out_path: Path) -> None:
    """Render the glyph with the generated strokes overlaid; saves a
    PNG so you can spot-check primitive output without a build."""
    data = generate_for_letter(letter, font_path)
    mask = rasterize(letter, font_path)
    img = Image.fromarray(((1 - mask) * 220).astype("uint8")).convert("RGB")
    d = ImageDraw.Draw(img)
    cols = [(220, 50, 50), (50, 100, 220), (50, 180, 80),
            (220, 150, 50), (180, 50, 220)]
    for i, s in enumerate(data["strokes"]):
        color = cols[i % len(cols)]
        pts = [(c["x"] * SIZE, c["y"] * SIZE) for c in s["checkpoints"]]
        for j in range(len(pts) - 1):
            d.line([pts[j], pts[j + 1]], fill=color, width=4)
        if pts:
            d.ellipse([pts[0][0] - 8, pts[0][1] - 8,
                       pts[0][0] + 8, pts[0][1] + 8], fill=color)
    img.save(out_path)


# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------

def folder_for(letter: str) -> str:
    """Lowercase folders carry a `_l` suffix to dodge case collisions
    on case-insensitive filesystems (APFS / HFS+)."""
    is_lower = letter == letter.lower() and letter != letter.upper()
    return f"{letter}_l" if is_lower else letter


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Topology-driven cross-font stroke generator.")
    ap.add_argument("letters", nargs="*",
                    help="Letters to (re)generate. Default: all in topology.")
    ap.add_argument("--font", default=str(DEFAULT_FONT),
                    help="OTF / TTF font path. Default: Primae-Regular.")
    ap.add_argument("--out", default=str(OUTPUT_BASE),
                    help="Output base directory.")
    ap.add_argument("--no-overwrite", action="store_true",
                    help="Skip letters whose strokes.json already exists.")
    ap.add_argument("--debug", action="store_true",
                    help="Also write a side-by-side PNG to /tmp/topology_<letter>.png.")
    args = ap.parse_args()

    font_path = Path(args.font)
    targets = args.letters or sorted(LETTER_TOPOLOGY.keys())
    out_base = Path(args.out)
    failures = 0
    for letter in targets:
        if letter not in LETTER_TOPOLOGY:
            print(f"  {letter}: no topology — skipping")
            continue
        out_file = out_base / folder_for(letter) / "strokes.json"
        if args.no_overwrite and out_file.exists():
            print(f"  {letter}: exists (skipped)")
            continue
        try:
            data = generate_for_letter(letter, font_path)
        except Exception as e:
            print(f"  {letter}: FAILED — {e}")
            failures += 1
            continue
        out_file.parent.mkdir(parents=True, exist_ok=True)
        out_file.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
        cp = sum(len(s["checkpoints"]) for s in data["strokes"])
        print(f"  {letter}: ✓ {len(data['strokes'])} strokes, {cp} checkpoints")
        if args.debug:
            debug_overlay(letter, font_path, Path(f"/tmp/topology_{letter}.png"))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
