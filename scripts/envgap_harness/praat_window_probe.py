"""ENVGAP black-box probe of Praat's PSOLA synthesis window (observes output only): source = 200 Hz impulse train
(amplitude 1) + DC 0.05 at 48 kHz, 1 s, 32-bit float WAV. After Praat's overlap-add, the DC term is c * sum of
windows; impulses are masked out (+-3 samples) and the result printed around a few output pulses."""
import struct, sys, math
sr, f0, dc, n = 48000, 200.0, 0.05, 48000
def wwav(path, x):
    data = b"".join(struct.pack("<f", v) for v in x)
    hdr = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE" + b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, sr, sr * 4, 4, 32) + b"data" + struct.pack("<I", len(data))
    open(path, "wb").write(hdr + data)
def rwav(path):
    b = open(path, "rb").read()
    i = 12; fmt = None
    while i < len(b):
        cid, sz = b[i:i+4], struct.unpack("<I", b[i+4:i+8])[0]
        if cid == b"fmt ": fmt = struct.unpack("<HHIIHH", b[i+8:i+24])
        if cid == b"data":
            d = b[i+8:i+8+sz]
            if fmt[0] == 3: return list(struct.unpack("<%df" % (sz // 4), d))
            return [v / 32768 for v in struct.unpack("<%dh" % (sz // 2), d)]
        i += 8 + sz + (sz & 1)
if sys.argv[1] == "make":
    T = sr / f0
    x = [dc] * n
    k = 0
    while k * T < n:
        x[int(round(k * T))] += 1.0; k += 1
    wwav(sys.argv[2], x)
else:
    y = rwav(sys.argv[2]); T = sr / f0
    spikes = [i for i in range(1, len(y) - 1) if y[i] > 0.5 * max(y) and y[i] >= y[i-1] and y[i] >= y[i+1]]
    mask = set(j for s in spikes for j in range(s - 3, s + 4))
    w = [None if i in mask else y[i] / dc for i in range(len(y))]
    mid = [s for s in spikes if 0.4 * len(y) < s < 0.6 * len(y)][:3]
    print("spikes spacing (samples):", [b - a for a, b in zip(mid, mid[1:])], "T_src=", T)
    a, b = mid[0], mid[2]
    for i in range(a - 10, b + 10, 6):
        v = w[i]
        print(f"{i - a:5d} {'' if v is None else f'{v:6.3f}'}")
