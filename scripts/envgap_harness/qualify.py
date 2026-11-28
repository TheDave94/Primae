#!/usr/bin/env python3
"""ENVGAP-A qualification: candidate gates.csv against the r31 baseline gates.csv of the same rate.
Prints PASS/FAIL totals, every A env_lsd_vs_praat row (median, seeds), rows that newly FAIL (median), and rows whose
passing-seed count dropped. Usage: qualify.py <baseline gates.csv> <candidate gates.csv> <candidate name>"""
import csv, sys
base_f, cand_f, name = sys.argv[1:4]
key = lambda r: (r['source'], r['scenario'], r['gate'])
base = {key(r): r for r in csv.DictReader(open(base_f)) if r['candidate'] == 'r31'}
cand = [r for r in csv.DictReader(open(cand_f)) if r['candidate'] == name]
assert cand, f"no rows for {name}"
p = sum(r['pass'] == 'PASS' for r in cand)
print(f"## {name}: PASS {p} / FAIL {len(cand) - p}  (rows {len(cand)}, baseline rows {len(base)})")
sp = lambda r: (int(r['seed_pass'] or 0), int(r['seed_count'] or 1))
a_all = True
for r in cand:
    if r['source'].startswith('A_') and r['gate'] in ('env_lsd_vs_praat', 'env_lsd_letter_vs_praat'):
        s, n = sp(r); a_all &= (s == n and r['pass'] == 'PASS')
        print(f"  A {r['scenario']:20} {r['gate']:24} {float(r['value']):.4f} [{r['threshold']}] {r['pass']} seeds {s}/{n}")
print(f"  A env_lsd rows: every seed passes = {a_all}")
new_fail, seed_drop = [], []
for r in cand:
    b = base.get(key(r))
    if b is None: print("  (no baseline row)", key(r)); continue
    if r['pass'] != 'PASS' and b['pass'] == 'PASS': new_fail.append((r, b))
    elif sp(r)[0] < sp(b)[0]: seed_drop.append((r, b))
for title, lst in (("NEW median FAIL", new_fail), ("seed count dropped (median still as baseline)", seed_drop)):
    print(f"  {title}: {len(lst)}")
    for r, b in lst:
        print(f"    {r['source']:12} {r['scenario']:20} {r['gate']:22} {float(b['value']):.4f} -> {float(r['value']):.4f} "
              f"[{r['threshold']}] seeds {sp(b)[0]}/{sp(b)[1]} -> {sp(r)[0]}/{sp(r)[1]}")
