"""ENVGAP: median offset (fraction of the local period) from each of our marks (loop region) to the absolute
waveform extremum within +-W*T of the mark, in the bench's 48 kHz source. usage: extremum_offset.py src.wav marks.csv W"""
import sys, struct, statistics as st
def rwav(path):
    b = open(path, "rb").read(); i = 12
    while i < len(b):
        cid, sz = b[i:i+4], struct.unpack("<I", b[i+4:i+8])[0]
        if cid == b"data": return list(struct.unpack("<%df" % (sz // 4), b[i+8:i+8+sz]))
        i += 8 + sz + (sz & 1)
x = rwav(sys.argv[1]); W = float(sys.argv[3])
rows = [l.split(",") for l in open(sys.argv[2]).read().splitlines()[1:]]
hdr = open(sys.argv[2]).readline()
ai = int(hdr.split("attackIndex=")[1].split(",")[0])
m = [float(a) for a, b in rows]; P = [float(b) for a, b in rows]
pos, neg, absv = [], [], []
for k in range(ai, len(m) - 1):
    c, T = m[k], P[k]
    lo, hi = int(c - W * T), int(c + W * T)
    seg = range(max(0, lo), min(len(x), hi))
    ip = max(seg, key=lambda i: x[i]); ineg = min(seg, key=lambda i: x[i]); ia = max(seg, key=lambda i: abs(x[i]))
    pos.append((ip - c) / T); neg.append((ineg - c) / T); absv.append((ia - c) / T)
def iqr(v):
    q = st.quantiles(v, n=4); return q[2] - q[0]
print(f"  spread(IQR) max {iqr(pos):.3f} min {iqr(neg):.3f}")
print(f"{sys.argv[1].split('/')[-1][:1]} W={W}: max {st.median(pos):+.3f}  min {st.median(neg):+.3f}  |max| {st.median(absv):+.3f}")
