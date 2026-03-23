#!/usr/bin/env python3
"""
Generate strokes.json for uppercase letters using standard German handwriting stroke order.
Coordinates are normalized 0.0-1.0 (x=right, y=down).
"""
import json
from pathlib import Path

OUTPUT_BASE = Path("BuchstabenNative/Resources/Letters")

# Standard stroke paths for each letter
# Format: list of strokes, each stroke is list of (x, y) checkpoints
STROKES = {
    "B": [
        # Single stroke: top down, then bump out right (top bump), bump out right (bottom bump)
        [[0.35, 0.15], [0.35, 0.40], [0.35, 0.65], [0.35, 0.85]],  # vertical line down
        [[0.35, 0.15], [0.55, 0.18], [0.62, 0.28], [0.55, 0.40], [0.35, 0.42]],  # top bump
        [[0.35, 0.42], [0.58, 0.46], [0.65, 0.60], [0.58, 0.74], [0.35, 0.85]],  # bottom bump
    ],
    "C": [
        [[0.72, 0.28], [0.60, 0.15], [0.45, 0.12], [0.30, 0.20],
         [0.22, 0.35], [0.20, 0.50], [0.22, 0.65], [0.30, 0.78],
         [0.45, 0.87], [0.60, 0.85], [0.72, 0.75]],
    ],
    "D": [
        [[0.35, 0.15], [0.35, 0.85]],  # vertical line
        [[0.35, 0.15], [0.55, 0.20], [0.68, 0.35], [0.70, 0.50],
         [0.68, 0.65], [0.55, 0.78], [0.35, 0.85]],  # right arc
    ],
    "E": [
        [[0.65, 0.15], [0.35, 0.15]],  # top horizontal
        [[0.35, 0.15], [0.35, 0.85]],  # vertical
        [[0.35, 0.50], [0.60, 0.50]],  # middle horizontal
        [[0.35, 0.85], [0.65, 0.85]],  # bottom horizontal
    ],
    "G": [
        [[0.72, 0.28], [0.60, 0.15], [0.45, 0.12], [0.30, 0.20],
         [0.22, 0.35], [0.20, 0.50], [0.22, 0.65], [0.30, 0.78],
         [0.45, 0.87], [0.60, 0.85], [0.72, 0.75], [0.72, 0.55], [0.52, 0.55]],
    ],
    "H": [
        [[0.30, 0.15], [0.30, 0.85]],  # left vertical
        [[0.30, 0.50], [0.70, 0.50]],  # crossbar
        [[0.70, 0.15], [0.70, 0.85]],  # right vertical
    ],
    "J": [
        [[0.60, 0.15], [0.60, 0.65], [0.55, 0.78], [0.45, 0.85],
         [0.35, 0.82], [0.28, 0.72]],
    ],
    "N": [
        [[0.28, 0.15], [0.28, 0.85]],  # left vertical
        [[0.28, 0.15], [0.70, 0.85]],  # diagonal
        [[0.70, 0.15], [0.70, 0.85]],  # right vertical
    ],
    "P": [
        [[0.33, 0.15], [0.33, 0.85]],  # vertical
        [[0.33, 0.15], [0.55, 0.18], [0.65, 0.28], [0.65, 0.40],
         [0.55, 0.50], [0.33, 0.50]],  # top bump
    ],
    "R": [
        [[0.33, 0.15], [0.33, 0.85]],  # vertical
        [[0.33, 0.15], [0.55, 0.18], [0.65, 0.28], [0.65, 0.40],
         [0.55, 0.50], [0.33, 0.50]],  # top bump
        [[0.33, 0.50], [0.65, 0.85]],  # diagonal leg
    ],
    "S": [
        [[0.68, 0.25], [0.57, 0.14], [0.43, 0.12], [0.30, 0.20],
         [0.25, 0.32], [0.30, 0.43], [0.50, 0.50], [0.68, 0.58],
         [0.72, 0.70], [0.65, 0.82], [0.50, 0.88], [0.35, 0.85], [0.25, 0.75]],
    ],
    "T": [
        [[0.25, 0.15], [0.75, 0.15]],  # top horizontal
        [[0.50, 0.15], [0.50, 0.85]],  # vertical
    ],
    "U": [
        [[0.28, 0.15], [0.28, 0.65], [0.33, 0.78], [0.45, 0.87],
         [0.55, 0.87], [0.67, 0.78], [0.72, 0.65], [0.72, 0.15]],
    ],
    "V": [
        [[0.28, 0.15], [0.50, 0.85]],  # left diagonal
        [[0.72, 0.15], [0.50, 0.85]],  # right diagonal
    ],
    "W": [
        [[0.18, 0.15], [0.30, 0.85]],
        [[0.30, 0.85], [0.50, 0.45]],
        [[0.50, 0.45], [0.70, 0.85]],
        [[0.70, 0.85], [0.82, 0.15]],
    ],
    "X": [
        [[0.25, 0.15], [0.75, 0.85]],  # diagonal top-left to bottom-right
        [[0.75, 0.15], [0.25, 0.85]],  # diagonal top-right to bottom-left
    ],
    "Y": [
        [[0.25, 0.15], [0.50, 0.50]],  # left diagonal to center
        [[0.75, 0.15], [0.50, 0.50]],  # right diagonal to center
        [[0.50, 0.50], [0.50, 0.85]],  # vertical down
    ],
    "Z": [
        [[0.25, 0.15], [0.75, 0.15]],  # top horizontal
        [[0.75, 0.15], [0.25, 0.85]],  # diagonal
        [[0.25, 0.85], [0.75, 0.85]],  # bottom horizontal
    ],
}

def make_strokes_json(letter, stroke_paths):
    strokes = []
    for i, path in enumerate(stroke_paths):
        checkpoints = [{"x": round(x, 3), "y": round(y, 3)} for x, y in path]
        strokes.append({
            "id": i + 1,
            "checkpoints": checkpoints
        })
    return {
        "letter": letter,
        "checkpointRadius": 0.06,
        "strokes": strokes
    }

for letter, paths in STROKES.items():
    out_dir = OUTPUT_BASE / letter
    out_file = out_dir / "strokes.json"
    if out_file.exists():
        print(f"  {letter}: already exists")
        continue
    out_dir.mkdir(parents=True, exist_ok=True)
    data = make_strokes_json(letter, paths)
    out_file.write_text(json.dumps(data, indent=2))
    print(f"  {letter}: generated ({len(data['strokes'])} strokes)")
