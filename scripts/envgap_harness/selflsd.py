"""ENVGAP: level-free LSD (150-5000 Hz) between two envdump envelopes: who1 in csv1 vs who2 in csv2."""
import csv, sys, math
def load(p, who): return {float(r["f"]): float(r["env_db"]) for r in csv.DictReader(open(p)) if r["who"] == who}
a, b = load(sys.argv[1], sys.argv[2]), load(sys.argv[3], sys.argv[4])
d = [a[f] - b[f] for f in a if f in b]
m = sum(d) / len(d)
print(f"{math.sqrt(sum((x - m) ** 2 for x in d) / len(d)):.4f}")
