#!/usr/bin/env python3
"""ENVGAP target-cell matrix: env_lsd_vs_praat median (seeds passing) per candidate for the supervisor's cells.
Usage: cells.py <gates.csv>..."""
import csv, sys
CELLS = [('A_phoneme1', 'pitch_+300@0.5'), ('A_phoneme1', 'pitch_-600@0.5'), ('A_phoneme1', 'pitch_-600@1'),
         ('I_phoneme1', 'pitch_+600@0.5'), ('I_phoneme1', 'pitch_+600@1'), ('I_phoneme1', 'pitch_+600@2')]
rows = [r for f in sys.argv[1:] for r in csv.DictReader(open(f))]
cands = []
for r in rows:
    if r['candidate'] not in cands: cands.append(r['candidate'])
idx = {(r['candidate'], r['source'], r['scenario'], r['gate']): r for r in rows}
print('| candidate | ' + ' | '.join(f"{s[0]} {c.replace('pitch_', '')}" for s, c in CELLS) + ' |')
print('|---' * (len(CELLS) + 1) + '|')
for k in cands:
    out = []
    for s, c in CELLS:
        r = idx.get((k, s, c, 'env_lsd_vs_praat'))
        out.append('–' if r is None else f"{float(r['value']):.3f} ({r['seed_pass']}/{r['seed_count']})" + ('' if r['pass'] == 'PASS' else ' F'))
    print(f"| {k} | " + ' | '.join(out) + ' |')
