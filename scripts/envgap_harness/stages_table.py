#!/usr/bin/env python3
"""ENVGAP-A: summarise stages.csv (LoopStages.swift) per letter/rate/variant/stage: median over seeds, min, max,
and, for shifted cells with a Praat reference, the gate limit (1.2 x Praat) and seeds passing.
Usage: stages_table.py <stages.csv> [<stages.csv> ...] [--letters A,I] [--stages +300@0.5,-600@1]"""
import csv, statistics, sys
PRAAT = {48000: {"A": {-600: 1.009, -300: 1.525, 300: 1.096, 600: 1.336},
                 "I": {-600: 1.977, -300: 3.258, 300: 3.624, 600: 4.327},
                 "L": {-600: 1.269, -300: 1.978, 300: 2.553, 600: 3.335},
                 "M": {-600: 1.698, -300: 1.717, 300: 2.165, 600: 2.166}},
         44100: {"A": {-600: 0.958, -300: 1.516, 300: 1.164, 600: 1.376},
                 "I": {-600: 2.140, -300: 3.325, 300: 3.565, 600: 4.352},
                 "L": {-600: 1.460, -300: 2.146, 300: 2.713, 600: 3.557},
                 "M": {-600: 1.745, -300: 1.588, 300: 2.133, 600: 2.137}}}
def limit(letter, rate, stage):
    if "@" not in stage or stage.startswith(("tile", "slice")): return None
    c = int(stage.split("@")[0])
    if c == 0: return None
    v = PRAAT.get(rate, {}).get(letter, {}).get(c)
    return None if v is None else 1.2 * v
args = sys.argv[1:]
files = [a for a in args if a.endswith(".csv")]
opt = dict(zip(args[len(files)::2], args[len(files) + 1::2]))
letters = set(opt["--letters"].split(",")) if "--letters" in opt else None
stages = set(opt["--stages"].split(",")) if "--stages" in opt else None
groups = {}
for f in files:
    for r in csv.DictReader(open(f)):
        if letters and r["letter"] not in letters: continue
        if stages and r["stage"] not in stages: continue
        k = (r["letter"], int(r["rate_hz"]), r["variant"], r["stage"])
        groups.setdefault(k, []).append(float(r["lsd"]))
print("letter,rate,variant,stage,n,median,min,max,limit,seeds_pass,verdict")
for k in sorted(groups):
    v = groups[k]; lim = limit(k[0], k[1], k[3])
    med = statistics.median(v)
    if lim is None:
        print(f"{k[0]},{k[1]},{k[2]},{k[3]},{len(v)},{med:.4f},{min(v):.4f},{max(v):.4f},,,")
    else:
        sp = sum(1 for x in v if x <= lim)
        print(f"{k[0]},{k[1]},{k[2]},{k[3]},{len(v)},{med:.4f},{min(v):.4f},{max(v):.4f},{lim:.3f},{sp}/{len(v)},{'PASS' if med <= lim else 'FAIL'}")
