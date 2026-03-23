#!/usr/bin/env python3
"""Generate P4 PBM ghost files from Primae-Regular.otf."""
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

FONT_PATH = Path("BuchstabenNative/Resources/Fonts/Primae-Regular.otf")
OUTPUT_BASE = Path("BuchstabenNative/Resources/Letters")
SIZE = 512
PAD = 0.10

def generate_pbm(letter):
    avail = int(SIZE * (1 - 2 * PAD))
    font = ImageFont.truetype(str(FONT_PATH), avail)
    bbox = font.getbbox(letter)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    if w <= 0 or h <= 0:
        return None
    scale = min(avail / w, avail / h)
    font = ImageFont.truetype(str(FONT_PATH), int(avail * scale))
    bbox = font.getbbox(letter)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (SIZE - w) // 2 - bbox[0]
    y = (SIZE - h) // 2 - bbox[1]

    img = Image.new("L", (SIZE, SIZE), 255)
    ImageDraw.Draw(img).text((x, y), letter, font=font, fill=0)
    img = img.convert("1")

    row_bytes = (SIZE + 7) // 8
    header = f"P4\n{SIZE} {SIZE}\n".encode()
    pixels = list(img.getdata())
    data = []
    for row in range(SIZE):
        for bi in range(row_bytes):
            byte = 0
            for bit in range(8):
                col = bi * 8 + bit
                if col < SIZE and pixels[row * SIZE + col] == 0:
                    byte |= (1 << (7 - bit))
            data.append(byte)
    return header + bytes(data)

letters = sys.argv[1:] if len(sys.argv) > 1 else list("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
for letter in letters:
    out_dir = OUTPUT_BASE / letter
    out_file = out_dir / f"{letter}.pbm"
    if out_file.exists():
        print(f"  {letter}: exists")
        continue
    pbm = generate_pbm(letter)
    if not pbm:
        print(f"  {letter}: FAILED")
        continue
    out_dir.mkdir(parents=True, exist_ok=True)
    out_file.write_bytes(pbm)
    print(f"  {letter}: OK ({len(pbm)} bytes)")
