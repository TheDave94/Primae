#!/usr/bin/env python3
"""render_stroke_order_grid.py — STROKE-ORDER contact sheet.

Distinct from `render_sweep_grid.py`, which re-bakes GEOMETRY from
LETTERS specs. The order question is not a geometry question: the
strokes are already baked and correct, and only the sequence in which
the child is asked to draw them differs. Re-baking would throw away the
frozen geometry this project treats as the stimulus.

So this reads the shipped `strokes.json`, reorders its `strokes` array
under named candidate permutations, and draws ONE CONTACT SHEET: a row
per candidate, columns = stroke number, each cell showing that stroke
in sequence with a start dot and an arrowhead, plus a full-letter
overlay at the right. Nobody has to guess a sequence from indices.

The shipped file is included as a candidate ("current (shipped)") so
the comparison has its baseline column, per CLAUDE.md's visual-sweep
workflow.

Usage:
    python3 scripts/render_stroke_order_grid.py <letter> \
        --candidate "name=1,2,3" [--candidate "name=1,3,2"] \
        [--weight Regular] [--out /tmp/sweep/<letter>-order.png]

Stroke numbering is 1-based and matches the `strokes` array order in
`strokes.json`. A candidate value is the stroke indices in draw order.
"""

from __future__ import annotations

import argparse
import json
import math
import pathlib
import sys

INK = (45, 55, 72)          # #2D3748, the project's ink
ORDER = (229, 62, 62)       # #E53E3E, the sweep red
MUTED = (160, 168, 180)
PAPER = (255, 255, 255)
CELL = 190
BAR = 96
CELL_PAD = 26


def load_strokes(root: pathlib.Path, letter: str, weight: str) -> list[dict]:
    path = root / "PrimaeNative/Resources/Letters" / weight / letter / "strokes.json"
    if not path.exists():
        sys.exit(f"no strokes.json for {letter} at {path}")
    data = json.loads(path.read_text())
    strokes = data["strokes"] if isinstance(data, dict) else data
    return strokes


def points_of(stroke: dict) -> list[tuple[float, float]]:
    """The `checkpoints` array is the polyline; some bakes carry
    `points`. Read either so this works on any frozen corpus file."""
    for key in ("checkpoints", "points"):
        if key in stroke:
            raw = stroke[key]
            if raw and isinstance(raw[0], dict):
                return [(p["x"], p["y"]) for p in raw]
            return [tuple(p) for p in raw]
    raise SystemExit("stroke has neither checkpoints nor points")


def png_size(w: int, h: int, rgb: tuple[int, int, int]) -> bytearray:
    raw = bytearray()
    row = bytes(rgb) * w
    for _ in range(h):
        raw.append(0)
        raw.extend(row)
    return raw


def set_px(buf: bytearray, w: int, x: int, y: int, rgb: tuple[int, int, int]) -> None:
    # disc()/polyline() hand us floats; bytearray slicing needs ints.
    xi, yi = int(x), int(y)
    if 0 <= xi < w and 0 <= yi < len(buf) // (w + 1):
        i = yi * (w + 1) + 1 + xi * 3
        buf[i:i + 3] = bytes(int(c) for c in rgb)


def disc(buf: bytearray, w: int, cx: float, cy: float, r: int, rgb: tuple[int, int, int]) -> None:
    for y in range(int(cy - r), int(cy + r) + 1):
        for x in range(int(cx - r), int(cx + r) + 1):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                set_px(buf, w, x, y, rgb)


def line(buf: bytearray, w: int, a, b, rgb, thick: int = 4) -> None:
    x0, y0 = a
    x1, y1 = b
    steps = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
    for s in range(steps + 1):
        t = s / steps
        disc(buf, w, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, thick, rgb)


def polyline(buf: bytearray, w: int, pts, ox: float, oy: float, size: int,
             rgb, thick: int = 4) -> None:
    sc = [(ox + x * size, oy + y * size) for x, y in pts]
    for i in range(len(sc) - 1):
        line(buf, w, sc[i], sc[i + 1], rgb, thick)


def arrow(buf: bytearray, w: int, a, b, rgb, thick: int = 5) -> None:
    """Solid triangular head at `b`, oriented along a->b."""
    ang = math.atan2(b[1] - a[1], b[0] - a[0])
    size = thick * 6
    for t in (i / 6 for i in range(6)):
        tip = (b[0] - math.cos(ang) * size * t, b[1] - math.sin(ang) * size * t)
        half = size * (1 - t) * 0.85
        if half < 0.4:
            break
        nx, ny = -math.sin(ang), math.cos(ang)
        p1 = (tip[0] + nx * half, tip[1] + ny * half)
        p2 = (tip[0] - nx * half, tip[1] - ny * half)
        # filled triangle by scanning rows
        y0, y1 = int(min(tip[1], p1[1], p2[1])), int(max(tip[1], p1[1], p2[1])) + 1
        for y in range(y0, y1 + 1):
            xs = []
            for (px, py) in (tip, p1, p2):
                if min(tip[1], p1[1], p2[1]) <= y <= max(tip[1], p1[1], p2[1]):
                    if abs(p1[1] - p2[1]) > 1e-9:
                        xs.append(px + (y - p1[1]) * (p2[0] - p1[0]) / (p2[1] - p1[1]))
                    else:
                        xs.append(px)
            if xs:
                disc(buf, w, sum(xs) / len(xs), y, thick // 2 + 1, rgb)


def bitmap(x0: int, y0: int, x1: int, y1: int) -> bytearray:
    """5x7 pixel font, enough for A-Z 0-9 and a few marks."""
    F = {
        "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
        "B": ["11110", "10001", "11110", "10001", "10001", "10001", "11110"],
        "C": ["01111", "10000", "10000", "10000", "10000", "10000", "01111"],
        "D": ["11110", "10001", "10001", "10001", "10001", "10001", "11110"],
        "E": ["11111", "10000", "11110", "10000", "10000", "10000", "11111"],
        "F": ["11111", "10000", "11110", "10000", "10000", "10000", "10000"],
        "G": ["01111", "10000", "10000", "10111", "10001", "10001", "01110"],
        "H": ["10001", "10001", "11111", "10001", "10001", "10001", "10001"],
        "I": ["11111", "00100", "00100", "00100", "00100", "00100", "11111"],
        "K": ["10001", "10010", "11100", "10100", "10010", "10010", "10001"],
        "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
        "M": ["10001", "11011", "10101", "10001", "10001", "10001", "10001"],
        "N": ["10001", "11001", "10101", "10011", "10001", "10001", "10001"],
        "O": ["01110", "10001", "10001", "10001", "10001", "10001", "01110"],
        "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
        "R": ["11110", "10001", "10001", "11110", "10100", "10010", "10001"],
        "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
        "T": ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
        "U": ["10001", "10001", "10001", "10001", "10001", "10001", "01110"],
        "V": ["10001", "10001", "10001", "10001", "10001", "01010", "00100"],
        "W": ["10001", "10001", "10001", "10101", "10101", "11011", "10001"],
        "X": ["10001", "01010", "00100", "00100", "00100", "01010", "10001"],
        "Y": ["10001", "01010", "00100", "00100", "00100", "00100", "00100"],
        "Z": ["11111", "00001", "00010", "00100", "01000", "10000", "11111"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "-": ["00000", "00000", "00000", "11111", "00000", "00000", "00000"],
        ".": ["00000", "00000", "00000", "00000", "00000", "01100", "01100"],
        ",": ["00000", "00000", "00000", "00000", "01100", "01100", "01000"],
        ":": ["00000", "01100", "01100", "00000", "01100", "01100", "00000"],
        "/": ["00001", "00010", "00010", "00100", "01000", "01000", "10000"],
        "(": ["00010", "00100", "01000", "01000", "01000", "00100", "00010"],
        ")": ["01000", "00100", "00010", "00010", "00010", "00100", "01000"],
        " ": ["00000"] * 7,
    }
    w, h = x1 - x0, y1 - y0
    buf = bytearray()
    for _ in range(h):
        buf.append(0)
    buf.extend(bytes(PAPER) * w)
    cx, cy = x0, y0
    for ch in text_upper:
        glyph = F.get(ch, F[" "])
        for ry, row in enumerate(glyph):
            for rx, bit in enumerate(row):
                if bit == "1":
                    for dy in range(3):
                        for dx in range(3):
                            px, py = cx + rx * 3 + dx, cy + ry * 3 + dy
                            if 0 <= px < w and 0 <= py < h:
                                set_px(buf, w, x0 + px, y0 + py, PAPER)
        cx += 6 * 3
    return buf


def draw_text(buf: bytearray, W: int, x: int, y: int, s: str, rgb, scale: int = 2) -> None:
    """Faint watermark text: draws with the muted colour so it reads as
    a label, never as part of the letterform."""
    global text_upper
    text_upper = "".join(ch if ch in F_CHARS else " " for ch in s.upper())
    sub = bitmap(0, 0, len(text_upper) * 18 + 4, 26)
    for i in range(len(sub)):
        y = 0
        xoff = i % (len(text_upper) * 18 + 4)
        yy = i // (len(text_upper) * 18 + 4)
        yy = yy
    # simple blit
    bw = len(text_upper) * 18 + 4
    for yy in range(26):
        for xx in range(bw):
            i = yy * (bw + 1) + 1 + xx * 3
            if sub[i:i + 3] == bytes(PAPER):
                for dy in range(scale):
                    for dx in range(scale):
                        set_px(buf, W, x + xx * scale + dx, y + yy * scale + dy, rgb)


F_CHARS = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-:.,/() ")
text_upper = " "


def save(path: pathlib.Path, buf: bytearray, w: int, h: int) -> None:
    import zlib
    import struct
    raw = bytes(buf)
    comp = zlib.compress(raw, 9)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", comp)
           + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("letter")
    ap.add_argument("--candidate", action="append", default=[],
                    help="name=1,2,3 (1-based stroke indices in draw order)")
    ap.add_argument("--weight", default="Regular")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    root = pathlib.Path(__file__).resolve().parent.parent
    strokes = load_strokes(root, args.letter, args.weight)
    n = len(strokes)

    candidates: list[tuple[str, list[int]]] = [
        ("current (shipped)", list(range(1, n + 1)))
    ]
    for spec in args.candidate:
        if "=" not in spec:
            sys.exit(f"--candidate needs name=1,2,3, got {spec!r}")
        name, _, order = spec.partition("=")
        idx = [int(x) for x in order.split(",") if x.strip()]
        if sorted(idx) != list(range(1, n + 1)):
            sys.exit(f"{name}: {idx} is not a permutation of 1..{n}")
        candidates.append((name, idx))

    cols = n
    overlay_w = CELL
    W = 8 + cols * (CELL + CELL_PAD) + overlay_w + 8
    H = 46 + len(candidates) * (BAR + 46)
    buf = png_size(W, H, PAPER)

    draw_text(buf, W, 8, 10, f"{args.letter} stroke order", INK, 2)

    for r, (name, order) in enumerate(candidates):
        y0 = 46 + r * (BAR + 46)
        draw_text(buf, W, 8, y0 + 4, name, INK, 2)
        for c, sidx in enumerate(order):
            cx = 8 + c * (CELL + CELL_PAD) + CELL // 2
            cy = y0 + BAR // 2 + 24
            pts = points_of(strokes[sidx - 1])
            # faint full letter for context
            for other in strokes:
                polyline(buf, W, points_of(other), cx - CELL * 0.42, cy - CELL * 0.46,
                         CELL, MUTED, 1)
            size = CELL * 0.84
            polyline(buf, W, pts, cx - size * 0.5, cy - size * 0.5, size, ORDER, 4)
            sx = cx - size * 0.5 + pts[0][0] * size
            sy = cy - size * 0.5 + pts[0][1] * size
            ex = cx - size * 0.5 + pts[-1][0] * size
            ey = cy - size * 0.5 + pts[-1][1] * size
            disc(buf, W, sx, sy, 6, INK)                 # start dot
            arrow(buf, W, (sx, sy), (ex, ey), ORDER, 5)  # direction
            draw_text(buf, W, cx - 6, y0 + BAR + 6, str(c + 1), INK, 2)

        # overlay: the whole letter in sequence, numbered at each start
        ox = 8 + cols * (CELL + CELL_PAD) + overlay_w // 2
        oy = y0 + BAR // 2 + 24
        size = CELL * 0.8
        for s in order:
            pts = points_of(strokes[s - 1])
            polyline(buf, W, pts, ox - size * 0.5, oy - size * 0.5, size, INK, 4)
        for c, s in enumerate(order):
            pts = points_of(strokes[s - 1])
            disc(buf, W, ox - size * 0.5 + pts[0][0] * size,
                 oy - size * 0.5 + pts[0][1] * size, 7, ORDER)
            draw_text(buf, W, ox - size * 0.5 + pts[0][0] * size + 9,
                      oy - size * 0.5 + pts[0][1] * size - 16, str(c + 1), ORDER, 2)

    out = pathlib.Path(args.out or f"/tmp/sweep/{args.letter}-order.png")
    save(out, buf, W, H)
    print(f"{out}  ({W}x{H})  candidates={len(candidates)}")
    for name, order in candidates:
        print(f"  {name}: {' -> '.join(str(i) for i in order)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
