"""ENVGAP: harmonic peak levels (max LTAS bin within +-25% of F0 around k*F0) per `who`, re source's envelope.
usage: harm.py ltas.csv env.csv f0_out"""
import csv, sys
from collections import defaultdict
L = defaultdict(list)
for r in csv.DictReader(open(sys.argv[1])): L[r["who"]].append((float(r["f"]), float(r["ltas_db"])))
E = defaultdict(dict)
for r in csv.DictReader(open(sys.argv[2])): E[r["who"]][float(r["f"])] = float(r["env_db"])
f0 = float(sys.argv[3])
def peak(pts, fc, w):
    s = [v for f, v in pts if abs(f - fc) <= w]
    return max(s) if s else float("nan")
srcenv = E["source"]
fs = sorted(srcenv)
def envat(f):
    import bisect
    i = bisect.bisect_left(fs, f); i = min(max(i, 0), len(fs) - 1); return srcenv[fs[i]]
whos = [w for w in L if w != "source"]
print("k   f      srcEnv | " + " | ".join(f"{w:>14s}" for w in whos))
ref = {w: None for w in whos}
for k in range(1, int(5000 / f0) + 1):
    fc = k * f0
    if fc < 150: continue
    se = envat(fc)
    cells = []
    for w in whos:
        p = peak(L[w], fc, 0.25 * f0)
        cells.append(f"{p:7.1f} ({p - se:+5.1f})")
    print(f"{k:2d} {fc:6.0f} {se:7.1f} | " + " | ".join(cells))
