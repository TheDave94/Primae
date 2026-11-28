#!/usr/bin/env python3
"""BENCHWIN per-cell tables. Usage: benchwin_table.py <gates48.csv> <gates44.csv> <candidate>
Prints totals per rate, the env_lsd_vs_praat grid (letter x shift x rate: median [limit] seeds/N) and every row of
any gate whose median FAILs or whose seeds do not all pass."""
import csv, sys
f48, f44, cand = sys.argv[1:4]
R = {}
for tag, f in (("48k", f48), ("44.1k", f44)):
    R[tag] = [r for r in csv.DictReader(open(f)) if r['candidate'] == cand]
sp = lambda r: (int(r['seed_pass'] or 0), int(r['seed_count'] or 1))
for tag, rs in R.items():
    p = sum(r['pass'] == 'PASS' for r in rs)
    print(f"{cand} @{tag}: PASS {p} / FAIL {len(rs) - p} (rows {len(rs)}); rows with a failing seed: "
          f"{sum(sp(r)[0] < sp(r)[1] for r in rs)}")
print(f"\n| letter | cell | 48k median [limit] seeds | 44.1k median [limit] seeds |\n|---|---|---|---|")
for L in "AILM":
    for r_ in ("0.5", "1", "2"):
        for c in ("-600", "-300", "+300", "+600"):
            cells = []
            for tag in ("48k", "44.1k"):
                m = [r for r in R[tag] if r['source'] == f"{L}_phoneme1" and r['gate'] == 'env_lsd_vs_praat'
                     and r['scenario'] == f"pitch_{c}@{r_}"]
                if not m: cells.append("–"); continue
                r = m[0]; s, n = sp(r)
                cells.append(f"{float(r['value']):.3f} [{r['threshold']}] {s}/{n}{' **F**' if r['pass'] != 'PASS' else ''}")
            print(f"| {L} | {c}@{r_} | {cells[0]} | {cells[1]} |")
for tag, rs in R.items():
    print(f"\nnot-all-seeds-pass rows @{tag}:")
    for r in rs:
        s, n = sp(r)
        if r['pass'] != 'PASS' or s < n:
            print(f"  {r['pass']:4} {r['source']:12} {r['scenario']:18} {r['gate']:24} {float(r['value']):.4f} "
                  f"[{r['threshold']}] seeds {s}/{n}")
