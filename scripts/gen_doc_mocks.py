#!/usr/bin/env python3
"""
Generate mock screenshots for the Buchstaben-Lernen-App documentation.

These are illustrations of layout intent — not actual device screenshots
(no Xcode simulator on this Linux box). Designed to communicate the visual
language of the app for marketing material and thesis figures.
"""
from PIL import Image, ImageDraw, ImageFont
import os

OUT = "/opt/repos/Buchstaben-Lernen-App/docs/diagrams"
os.makedirs(OUT, exist_ok=True)

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


# =====================================================================
# Tracing canvas mock — what the child sees mid-trace
# =====================================================================
def render_tracing_canvas():
    W, H = 1366, 1024  # iPad landscape proportions, scaled for doc
    img = Image.new("RGB", (W, H), (250, 250, 252))  # near-white canvas
    d = ImageDraw.Draw(img)

    # Top status bar (small)
    d.rectangle([0, 0, W, 44], fill=(245, 245, 250))
    f_small = ImageFont.truetype(FONT, 16)
    d.text((24, 14), "9:41", font=f_small, fill=(80, 80, 80))
    d.text((W - 80, 14), "100%", font=f_small, fill=(80, 80, 80))

    # Phase indicator (top center)
    pf = ImageFont.truetype(FONT_BOLD, 18)
    d.rounded_rectangle([W // 2 - 220, 70, W // 2 + 220, 110], radius=18,
                         fill=(20, 184, 166))  # teal for guided
    d.text((W // 2 - 200, 80), "Phase 2 / 3 — Geführt schreiben",
           font=pf, fill="white")

    # Letter "A" with stroke segments — mimic the AnimatedStrokePath shape
    canvas_x, canvas_y = W // 2, H // 2 + 30
    glyph_size = 460
    # geometry relative to glyph_size, ported from OnboardingView's AnimatedStrokePath
    pts = [
        ((0.50, 0.05), (0.05, 0.95)),  # left leg
        ((0.50, 0.05), (0.95, 0.95)),  # right leg
        ((0.22, 0.62), (0.78, 0.62)),  # crossbar
    ]

    def to_canvas(p):
        return (int(canvas_x + (p[0] - 0.5) * glyph_size),
                int(canvas_y + (p[1] - 0.5) * glyph_size))

    # Draw ghost strokes (faint guides)
    for a, b in pts:
        d.line([to_canvas(a), to_canvas(b)],
               fill=(180, 180, 200), width=20)

    # Draw partial completed strokes (left leg done, right leg in-progress)
    a, b = pts[0]
    d.line([to_canvas(a), to_canvas(b)], fill=(52, 120, 246), width=22)
    a, b = pts[1]
    midp = ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2 - 0.05)
    d.line([to_canvas(a), to_canvas(midp)], fill=(52, 120, 246), width=22)

    # Round caps on completed segments
    r = 11
    for x, y in [to_canvas(pts[0][0]), to_canvas(pts[0][1]),
                  to_canvas(pts[1][0]), to_canvas(midp)]:
        d.ellipse([x - r, y - r, x + r, y + r], fill=(52, 120, 246))

    # Active "tracing dot" — orange — at the in-progress location
    dot_x, dot_y = to_canvas(midp)
    d.ellipse([dot_x - 18, dot_y - 18, dot_x + 18, dot_y + 18],
              fill=(255, 149, 10))

    # Checkpoint dots remaining (next stroke = crossbar)
    for fx in [0.22, 0.50, 0.78]:
        cx = int(canvas_x + (fx - 0.5) * glyph_size)
        cy = int(canvas_y + (0.62 - 0.5) * glyph_size)
        d.ellipse([cx - 12, cy - 12, cx + 12, cy + 12],
                   outline=(180, 180, 200), width=4, fill=(250, 250, 252))

    # Bottom dock — 7 buttons
    dock_y = H - 140
    btn_w = 110
    btn_gap = 18
    total_w = 7 * btn_w + 6 * btn_gap
    start_x = (W - total_w) // 2
    button_specs = [
        ("◀", (52, 211, 153),  "Zurück"),
        ("▶", (52, 211, 153),  "Weiter"),
        ("↻", (251, 146, 60),  "Reset"),
        ("⤨", (167, 139, 250), "Zufall"),
        ("♪", (96, 165, 250),  "Ton"),
        ("★", (250, 204, 21),  "Empf."),
        ("⚙", (148, 163, 184), "Setup"),
    ]
    fb = ImageFont.truetype(FONT_BOLD, 36)
    fs = ImageFont.truetype(FONT, 14)
    for i, (sym, col, label) in enumerate(button_specs):
        bx = start_x + i * (btn_w + btn_gap)
        d.rounded_rectangle([bx, dock_y, bx + btn_w, dock_y + 100],
                             radius=18, fill=col)
        bbox = d.textbbox((0, 0), sym, font=fb)
        sw = bbox[2] - bbox[0]
        d.text((bx + (btn_w - sw) // 2, dock_y + 12), sym, font=fb, fill="white")
        bbox = d.textbbox((0, 0), label, font=fs)
        sw = bbox[2] - bbox[0]
        d.text((bx + (btn_w - sw) // 2, dock_y + 70), label, font=fs, fill="white")

    # Caption
    fc = ImageFont.truetype(FONT, 18)
    d.text((40, H - 30),
           "Mock illustration · iPad landscape · phase 2 (geführt) mid-trace · letter \"A\"",
           font=fc, fill=(140, 140, 150))

    img.save(os.path.join(OUT, "tracing-canvas.png"), "PNG", optimize=True)
    print(f"  wrote {OUT}/tracing-canvas.png")


# =====================================================================
# Parent dashboard mock — what the parent sees
# =====================================================================
def render_dashboard():
    W, H = 1100, 1400
    img = Image.new("RGB", (W, H), (242, 242, 247))  # iOS systemGroupedBackground
    d = ImageDraw.Draw(img)

    # Status bar
    d.rectangle([0, 0, W, 44], fill=(238, 238, 244))
    f_small = ImageFont.truetype(FONT, 16)
    d.text((24, 14), "9:41", font=f_small, fill=(80, 80, 80))

    # Nav bar
    f_nav = ImageFont.truetype(FONT, 17)
    f_title = ImageFont.truetype(FONT_BOLD, 32)
    d.text((24, 56), "Einstellungen", font=f_nav, fill=(0, 122, 255))
    d.text((W - 130, 56), "Exportieren", font=f_nav, fill=(0, 122, 255))
    d.text((24, 100), "Lernfortschritt", font=f_title, fill=(20, 20, 30))

    f_section = ImageFont.truetype(FONT_BOLD, 13)
    f_label = ImageFont.truetype(FONT, 17)
    f_value = ImageFont.truetype(FONT_BOLD, 17)

    y = 170

    def section(title, height):
        nonlocal y
        d.text((40, y - 22), title.upper(), font=f_section, fill=(120, 120, 130))
        d.rounded_rectangle([24, y, W - 24, y + height],
                             radius=12, fill="white")
        return y

    # Übersicht
    section_y = section("Übersicht", 280)
    rows = [
        ("Buchstaben geübt", "7"),
        ("Tage in Folge", "12 Tage"),
        ("Beste Serie", "21 Tage"),
        ("Übungszeit (7 Tage)", "1 h 24 min"),
        ("Schreibqualität", "78 %"),
    ]
    for i, (label, value) in enumerate(rows):
        ry = section_y + 16 + i * 50
        d.text((44, ry), label, font=f_label, fill=(20, 20, 30))
        bbox = d.textbbox((0, 0), value, font=f_value)
        d.text((W - 44 - (bbox[2] - bbox[0]), ry), value,
               font=f_value, fill=(20, 20, 30))
        if i < len(rows) - 1:
            d.line([84, ry + 36, W - 24, ry + 36],
                   fill=(220, 220, 226), width=1)
    y = section_y + 280 + 40

    # Phasen-Erfolgsquote (NEW)
    section_y = section("Phasen-Erfolgsquote", 200)
    phase_rows = [
        ("Beobachten", 0.92, (52, 120, 246)),
        ("Geführt",    0.74, (20, 184, 166)),
        ("Frei",       0.58, (168, 85, 247)),
    ]
    for i, (label, val, col) in enumerate(phase_rows):
        ry = section_y + 25 + i * 56
        d.text((44, ry), label, font=f_label, fill=(20, 20, 30))
        # bar
        bx0, bx1 = 220, W - 130
        bw = bx1 - bx0
        d.rounded_rectangle([bx0, ry + 4, bx1, ry + 22],
                             radius=9, fill=col + (38,))  # alpha not supported in RGB; use lighter mix
        d.rounded_rectangle([bx0, ry + 4, bx0 + int(bw * val), ry + 22],
                             radius=9, fill=col)
        # %
        pct = f"{int(val*100)} %"
        d.text((W - 100, ry), pct, font=f_value, fill=(120, 120, 130))
    y = section_y + 200 + 40

    # Übungsverlauf (NEW)
    section_y = section("Übungsverlauf (30 Tage)", 220)
    # Generate 30 mock daily values
    import math
    values = [max(0, 6 + 4 * math.sin(i / 4) + (i % 7 == 6) * -3 + (i == 12) * 3)
              for i in range(30)]
    chart_x0, chart_x1 = 60, W - 60
    chart_y0, chart_y1 = section_y + 30, section_y + 200
    chart_w = chart_x1 - chart_x0
    chart_h = chart_y1 - chart_y0
    # axes
    d.line([chart_x0, chart_y1, chart_x1, chart_y1], fill=(200, 200, 210), width=1)
    # bars
    n = len(values)
    bar_w = chart_w / n - 4
    max_v = max(values)
    for i, v in enumerate(values):
        bx = chart_x0 + i * (chart_w / n) + 2
        bh = (v / max_v) * (chart_h - 30) if max_v > 0 else 0
        d.rounded_rectangle([bx, chart_y1 - bh, bx + bar_w, chart_y1],
                             radius=2, fill=(96, 165, 250))
    # legend tick labels
    f_axis = ImageFont.truetype(FONT, 11)
    d.text((chart_x0 - 35, chart_y0 - 5), "20m", font=f_axis, fill=(140, 140, 150))
    d.text((chart_x0 - 35, chart_y1 - 8), "0", font=f_axis, fill=(140, 140, 150))
    d.text((chart_x0, chart_y1 + 8), "vor 30 Tagen", font=f_axis, fill=(140, 140, 150))
    d.text((chart_x1 - 60, chart_y1 + 8), "heute", font=f_axis, fill=(140, 140, 150))
    y = section_y + 220 + 40

    # Stärkste Buchstaben (with per-phase line)
    section_y = section("Stärkste Buchstaben", 200)
    letters = [
        ("A", 92, (52, 211, 153), 95, 90, 88),
        ("F", 88, (52, 211, 153), 92, 88, 80),
        ("M", 81, (250, 204, 21), 88, 82, 70),
    ]
    f_letter = ImageFont.truetype(FONT_BOLD, 22)
    f_pct = ImageFont.truetype(FONT_BOLD, 18)
    f_chip = ImageFont.truetype(FONT, 13)
    for i, (L, pct, col, p_o, p_g, p_f) in enumerate(letters):
        ry = section_y + 16 + i * 60
        d.text((48, ry + 4), L, font=f_letter, fill=(20, 20, 30))
        d.text((100, ry + 6), f"{pct} %", font=f_pct, fill=col)
        # phase chips below
        chip_y = ry + 34
        d.ellipse([100, chip_y + 5, 108, chip_y + 13], fill=(52, 120, 246))
        d.text((113, chip_y), f"B {p_o}%", font=f_chip, fill=(120, 120, 130))
        d.ellipse([180, chip_y + 5, 188, chip_y + 13], fill=(20, 184, 166))
        d.text((193, chip_y), f"G {p_g}%", font=f_chip, fill=(120, 120, 130))
        d.ellipse([260, chip_y + 5, 268, chip_y + 13], fill=(168, 85, 247))
        d.text((273, chip_y), f"F {p_f}%", font=f_chip, fill=(120, 120, 130))
        # arrow
        d.text((W - 60, ry + 10), "↑", font=f_pct, fill=(52, 211, 153))
        if i < len(letters) - 1:
            d.line([84, ry + 56, W - 24, ry + 56],
                   fill=(220, 220, 226), width=1)

    # Caption
    fc = ImageFont.truetype(FONT, 14)
    d.text((24, H - 26),
           "Mock illustration · parent dashboard · per-phase metrics + 30-day practice trend (sections added in commit 80d40fd)",
           font=fc, fill=(140, 140, 150))

    img.save(os.path.join(OUT, "dashboard.png"), "PNG", optimize=True)
    print(f"  wrote {OUT}/dashboard.png")


if __name__ == "__main__":
    render_tracing_canvas()
    render_dashboard()
