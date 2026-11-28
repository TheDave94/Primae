#!/usr/bin/env python3
"""ENVGAP gate tables: per candidate, PASS/FAIL totals and every row whose median FAILs or whose seeds do not all pass.
Usage: gates_table.py <gates.csv>... [--cand NAME,...]   (several csvs are concatenated; base runs carry r31 + controls)"""
import csv, sys
args = sys.argv[1:]; cands = None
if '--cand' in args:
    i = args.index('--cand'); cands = args[i + 1].split(','); del args[i:i + 2]
rows = []
for f in args:
    rows += list(csv.DictReader(open(f)))
by = {}
for r in rows:
    if cands and r['candidate'] not in cands: continue
    by.setdefault(r['candidate'], []).append(r)
for c, rs in by.items():
    p = sum(r['pass'] == 'PASS' for r in rs); fl = len(rs) - p
    print(f"## {c}: PASS {p} / FAIL {fl}")
    for r in rs:
        sc, sp = int(r['seed_count'] or 1), int(r['seed_pass'] or 0)
        if r['pass'] != 'PASS' or sp < sc:
            print(f"  {r['pass']:4} {r['source']:12} {r['scenario']:16} {r['gate']:16} {float(r['value']):9.4f}  [{r['threshold']}]  seeds {sp}/{sc}  ({r['seed_min']}..{r['seed_max']})")
