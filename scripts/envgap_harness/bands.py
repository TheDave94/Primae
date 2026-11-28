"""ENVGAP: per-band decomposition of the bench's level-free envelope LSD (150-5000 Hz) from an envdump CSV.
LSD^2 = mean over bins of (d - mean d)^2; this prints each band's share of that sum, its mean signed deviation
(after the global mean removal), and the per-band RMS, for every `who` column against `source`."""
import csv, sys, math
from collections import defaultdict
rows = defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])):
    rows[r["who"]].append((float(r["f"]), float(r["env_db"])))
src = dict(rows.pop("source"))
bands = [(150, 400), (400, 700), (700, 1000), (1000, 1500), (1500, 2000), (2000, 2500), (2500, 3000), (3000, 3500), (3500, 4000), (4000, 5000)]
print("who      lsd   | " + " | ".join(f"{a}-{b}" for a, b in bands))
for who, pts in rows.items():
    d = [(f, e - src[f]) for f, e in pts]
    m = sum(x for _, x in d) / len(d)
    d = [(f, x - m) for f, x in d]
    tot = sum(x * x for _, x in d)
    lsd = math.sqrt(tot / len(d))
    cells = []
    for a, b in bands:
        sel = [x for f, x in d if a <= f < b or (b == 5000 and f == 5000)]
        if not sel: cells.append("-"); continue
        mean = sum(sel) / len(sel)
        share = sum(x * x for x in sel) / tot
        cells.append(f"{mean:+5.1f}/{100*share:3.0f}%")
    print(f"{who:8s} {lsd:5.3f} | " + " | ".join(cells))
