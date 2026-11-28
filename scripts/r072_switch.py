#!/usr/bin/env python3
"""R-072: does a letter switch click? Analyses one PopCapture directory.

Rebuilt by lane FOLLOWUP-r31 (2026-11-27); the integration seat's
tools/r072_switch.py was lost with its scratchpad. The capture comes from
`PrimaeUITests/LetterSwitchCaptureUITests` (one launch per arm, `-popCapture`),
pulled off the iPad with

    xcrun devicectl device copy from --device <UDID> \
      --domain-type appDataContainer --domain-identifier com.flamingistan.primae.study \
      --source Documents/popcap/<dir> --destination <local dir>

Usage:  /usr/bin/python3 scripts/r072_switch.py <capture dir> [--arm phoneme|spatial|silent]
                                              [--expect-fade-ms 400] [--json out.json]

A SWITCH is a change of the hook's letter (`hook.state letter=`); it is judged
at the `audio.load` that loaded the new letter's sound (the last load before
the state change; the load is where the voice is told), or at the state change
when the arm loads nothing (silent). For each switch, in kernel.wav (the
kernel's own output; written at the session rate, whatever its header says)
and mixer.wav (the main mixer, each channel measured on its own; a click on any channel counts, the louder
channel is the one printed):

  pre_db     RMS over the 100 ms before the switch, dBFS. SOUNDING when > -40.
  fade_ms    time from the switch until a 5 ms RMS falls 40 dB under pre_db
             (or under -80 dBFS); the standing stop fade gives about 400 ms,
             the kernel's duck about 20 ms.
  disc_db    the switch-local DISCONTINUITY: over the window from 20 ms before
             the switch to 600 ms after it, the largest |d2[n]| (d2 = second
             difference, x[n]-2x[n-1]+x[n-2]) against the RMS of d2 in the 5 ms
             either side of n, the 2 samples either side left out, in dB. The
             RMS is floored at 1e-5 (-100 dBFS), so digital silence does not
             divide by zero. disc_at_ms is where the largest one sits.
  CLICK      disc_db above +24.5 dB, on kernel.wav or on any mixer channel.
  step_db, d2_db   diagnostics only, no longer the criterion: the largest |d1|
             (|d2|) in the 600 ms after the switch against the largest in the
             200 ms before it, in dB.

Why disc_db and why +24.5 dB (lane R072CLICK, 2026-11-28). The old CLICK
(step_db or d2_db above +1 dB) flagged a clean phoneme switch (integ32b, A->M,
kernel step +1.08 dB) whose rerun passed (+0.26 dB). It compared a 600 ms
window that starts at full level with a 200 ms one: that switch's largest
|d1| sat 39 ms into the fade at -15.8 dBFS against -16.9 in the 200 ms before,
while the 600 ms before reach -15.0, so with equal windows the same switch
reads -0.8 dB. A longer window of the same sound, not a discontinuity; and the
+1 dB bound had no derivation. disc_db asks a different question: does one sample's d2 stand out
of the signal's OWN d2 around it? A step or an impulse puts its full amplitude
into d2 at one or two samples, while the 400 ms stop fade (a slow gain) scales
d2 and its neighbourhood together, so the fade cancels out and the level the
switch starts at does not matter.

Clean distribution (every capture with sound under .primae-lock-tools/
{integ32b-r072, r072fix-20261128/popcap}, 2026-11-28): 26 sounding switches in
6 captures, kernel plus both mixer channels = 78 values: phoneme +12.5 to
+16.6 dB, spatial carrier +16.5 to +18.3 dB (the old statistic on the same 78:
-3.9 to +1.36 dB, two above its +1 dB bound). And 1320 half-overlapping 620 ms
windows of sound away from any switch, in 11 captures: max +18.5 dB. Threshold
= that maximum + 6 dB (a residual twice the largest clean one) = +24.5 dB.

Detection floor, measured by injecting a one-sample impulse and a step into
the kernel at the 20 sounding switches of the five post-fix captures (the
smallest amplitude flagged, 10 dB grid; the old criterion's in brackets; "F"
and "A" are the phoneme being faded out):
  silence, 450 ms after the switch   impulse -80 dBFS, step -70 dBFS everywhere
                                     (old: -10 to -40 / -10 to -30; F 0 / never)
  fade tail, 385 ms (-43 to -52 dBFS)  I, L, carrier: impulse -50 to -70, step
                                     -40 to -60 (old -30 to -40 / -20 to -30);
                                     A -30 to -40 (old -10); F -10 to -20 (old 0)
  the switch sample, full level      impulse I, L -20, carrier -30 (old -30, -50
  (-14 to -18 dBFS RMS)              at three of ten), A -6 to -10, F not up to
                                     0 dBFS (old: not / 0 dBFS); a step I, L,
                                     carrier -10 to -30, A 0 dBFS, F not (old:
                                     never)
Under full-level sound the floor is where the injected sample first exceeds
the sound's own largest d2 excursions; a click below that is taken to be
masked by the sound's own transients (argued, not listened to; F is fricative
noise: before the integ32b F->A switch its own |d2| reaches +3.8 dBFS). A hard cut to zero at the
switch scores over the threshold at 12 of the 20 (the carrier 7 of 8, I 3 of
3, L 2 of 3; F and A +12 to +21 dB, not flagged); the old criterion flagged
none. --expect-fade-ms catches all 20 (fade 5 ms).

Exit status 1 when a sound arm has a switch that was not sounding (the switch
was not exercised), any switch clicks, or (with --expect-fade-ms) a sounding
switch's kernel fade is outside 75-125 % of the expected length. A capture
with dropped samples (meta.txt), or whose render records do not add up to kernel.wav (apart from one trailing
render buffer, the drain race at the app's termination), is refused.
"""
import argparse
import json
import os
import re
import sys

import numpy as np


def read_wav_f32(path):
    """Float32 WAV as written by PopWav (format 3). Returns (samples[frames, ch], header rate)."""
    with open(path, "rb") as f:
        data = f.read()
    ch = int.from_bytes(data[22:24], "little")
    rate = int.from_bytes(data[24:28], "little")
    n = int.from_bytes(data[40:44], "little")
    x = np.frombuffer(data[44:44 + n], dtype="<f4")
    x = x[: (len(x) // ch) * ch].reshape(-1, ch)
    return x, rate


def read_meta(path):
    meta = {}
    with open(path) as f:
        for tok in f.read().split():
            if "=" in tok:
                k, v = tok.split("=", 1)
                meta[k] = v
    return meta


def read_events(path):
    ev = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 2 or not parts[0].isdigit():
                continue
            ev.append((int(parts[0]), parts[1], parts[2] if len(parts) > 2 else ""))
    ev.sort(key=lambda e: e[0])
    return ev


def read_rt(path):
    """R records (render callbacks) and T records (mixer-tap buffers), in file order."""
    renders, taps = [], []
    with open(path) as f:
        for line in f:
            p = line.split("\t")
            if len(p) < 6:
                continue
            if p[1] == "R":
                renders.append((int(p[0]), int(p[2])))
            elif p[1] == "T":
                taps.append((int(p[0]), int(p[2])))
    return renders, taps


def index_at(records, t_ns):
    """Sample index of the first buffer that starts at or after t_ns (buffers concatenated in order)."""
    pos = 0
    for start, frames in records:
        if start >= t_ns:
            return pos
        pos += frames
    return pos


def switches_from(events):
    out = []
    letter = None
    last_load = None
    prev_state_t = 0
    for t, kind, detail in events:
        if kind == "audio.load":
            last_load = (t, detail)
        elif kind == "hook.state":
            m = re.search(r"letter=(\S*)", detail)
            if not m:
                continue
            new = m.group(1)
            if letter not in (None, "") and new not in ("", letter):
                load = last_load if last_load and last_load[0] >= prev_state_t else None
                out.append({"from": letter, "to": new, "state_ns": t,
                            "load_ns": load[0] if load else None,
                            "load": load[1] if load else None})
            if new:
                letter = new
            prev_state_t = t
    return out


def db(x):
    return 20 * np.log10(max(float(x), 1e-12))


CLICK_DB = 24.5        # see the docstring: max clean +18.5 dB, +6 dB margin
DISC_FLOOR = 1e-5      # -100 dBFS, the d2 RMS floor (digital silence)


def discontinuity(x, rate, i, lead_s=0.02, post_s=0.6, half_s=0.005, gap=2):
    """(disc_db, disc_at_ms): the largest |d2[n]| over [i - lead_s, i + post_s) against the RMS of d2 within
    half_s either side of n (the gap samples either side of n left out), in dB."""
    W = max(1, int(half_s * rate))
    a, b = max(0, i - int(lead_s * rate)), min(len(x), i + int(post_s * rate))
    if b - a < 3:
        return -240.0, None
    lo, hi = max(0, a - W - 2), min(len(x), b + W)
    seg = np.asarray(x[lo:hi], dtype=np.float64)
    h = np.zeros(len(seg))
    h[2:] = np.diff(seg, n=2)
    c = np.concatenate([[0.0], np.cumsum(h * h)])
    n = np.arange(a - lo, b - lo)

    def win(p, q):
        p, q = np.clip(p, 0, len(h)), np.clip(q, 0, len(h))
        return c[q] - c[p], q - p
    so, co = win(n - W, n + W + 1)
    si, ci = win(n - gap, n + gap + 1)
    env = np.sqrt(np.maximum(so - si, 0.0) / np.maximum(co - ci, 1))
    score = np.abs(h[n]) / np.maximum(env, DISC_FLOOR)
    k = int(np.argmax(score))
    return round(db(score[k]), 2), round(1000.0 * (n[k] + lo - i) / rate, 1)


def measure(x, rate, i, pre_s=0.1, ref_s=0.2, post_s=0.6):
    i = int(min(max(i, 0), len(x)))
    pre = x[max(0, i - int(pre_s * rate)):i]
    ref = x[max(0, i - int(ref_s * rate)):i]
    post = x[i:i + int(post_s * rate)]
    pre_db = db(np.sqrt(np.mean(pre ** 2))) if len(pre) else -240.0
    # fade: first 5 ms window (hop 1 ms) under pre - 40 dB (or -80 dBFS)
    w, hop = max(1, int(0.005 * rate)), max(1, int(0.001 * rate))
    floor = max(pre_db - 40.0, -80.0)
    fade_ms = None
    for k in range(0, max(0, len(post) - w), hop):
        if db(np.sqrt(np.mean(post[k:k + w] ** 2))) < floor:
            fade_ms = 1000.0 * (k + w) / rate
            break

    def peak(seg, order):
        if len(seg) <= order:
            return 0.0
        return float(np.max(np.abs(np.diff(seg, n=order))))
    step_db = db(peak(post, 1)) - db(peak(ref, 1))
    d2_db = db(peak(post, 2)) - db(peak(ref, 2))
    disc_db, disc_at_ms = discontinuity(x, rate, i, post_s=post_s)
    return {"pre_db": round(pre_db, 2), "fade_ms": None if fade_ms is None else round(fade_ms, 1),
            "step_db": round(step_db, 2), "d2_db": round(d2_db, 2),
            "disc_db": disc_db, "disc_at_ms": disc_at_ms}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("capture")
    ap.add_argument("--arm", choices=["phoneme", "spatial", "silent"])
    ap.add_argument("--expect-fade-ms", type=float)
    ap.add_argument("--json")
    a = ap.parse_args()
    d = a.capture
    arm = a.arm or next((k for k in ("phoneme", "spatial", "silent") if k in os.path.basename(d.rstrip("/"))), None)
    meta = read_meta(os.path.join(d, "meta.txt"))
    drops = {k: int(meta.get(k, "0")) for k in ("rtDropped", "tapRecDropped", "rawDroppedSamples", "mixDroppedSamples")}
    if any(drops.values()):
        print(f"REFUSED: the capture dropped data {drops}")
        return 1
    rate = float(meta.get("sessionRate", "48000"))
    kernel, _ = read_wav_f32(os.path.join(d, "kernel.wav"))
    kernel = kernel[:, 0]
    mixer, mixer_rate = read_wav_f32(os.path.join(d, "mixer.wav"))
    # Both mixer channels: the spatial arm pans, so one channel alone under-reads a sound panned away from it.
    # Each channel is measured on its own (a click is judged on the signed signal, not a rectified one).
    mixer_ch = [mixer[:, c] for c in range(mixer.shape[1])]
    mixer = mixer_ch[0]
    renders, taps = read_rt(os.path.join(d, "rt.tsv"))
    held = sum(f for _, f in renders)
    # R072FIX: PopCapture.drain() reads the render records BEFORE the kernel samples, so a render between the two
    # reads lands its samples in this drain and its record in the next. A capture ended by the app's termination (the
    # next UI test launching) has no next drain: kernel.wav then ends with ONE render buffer more than the records
    # (silent arm, 2026-11-28: 256 frames). The rings are FIFO, so the surplus is the last buffer; it is cut off.
    # Anything else (a surplus over one buffer, or records holding more than the file) is still refused.
    largest = max((f for _, f in renders), default=0)
    if held < len(kernel) <= held + largest:
        print(f"note: kernel.wav ends {len(kernel) - held} frames past the last render record (the drain race); cut")
        kernel = kernel[:held]
    if held != len(kernel):
        print(f"REFUSED: render records hold {held} frames, kernel.wav {len(kernel)}")
        return 1
    events = read_events(os.path.join(d, "events.tsv"))
    sw = switches_from(events)
    print(f"capture {os.path.basename(d.rstrip('/'))}  arm={arm}  kernel {len(kernel) / rate:.1f} s at {rate:.0f} Hz  "
          f"mixer {len(mixer) / mixer_rate:.1f} s at {mixer_rate} Hz  switches {len(sw)}")
    bad = []
    for n, s in enumerate(sw, 1):
        t = s["load_ns"] or s["state_ns"]
        s["kernel"] = measure(kernel, rate, index_at(renders, t))
        chans = [measure(c, mixer_rate, index_at(taps, t)) for c in mixer_ch]
        s["mixer_channels"] = chans
        s["mixer"] = max(chans, key=lambda c: c["pre_db"])   # the louder channel is the one printed
        k, m = s["kernel"], s["mixer"]
        s["sounding"] = k["pre_db"] > -40.0
        s["click"] = bool(max([k["disc_db"]] + [c["disc_db"] for c in chans]) > CLICK_DB)
        verdict = "CLICK" if s["click"] else "no click"
        if arm in ("phoneme", "spatial") and not s["sounding"]:
            verdict += ", NOT SOUNDING (not exercised)"
            bad.append(n)
        if s["click"]:
            bad.append(n)
        if a.expect_fade_ms and s["sounding"]:
            f = k["fade_ms"]
            if f is None or not (0.75 * a.expect_fade_ms <= f <= 1.25 * a.expect_fade_ms):
                verdict += f", FADE {f} ms (expected {a.expect_fade_ms:.0f})"
                bad.append(n)
        print(f"  S{n} {s['from']}->{s['to']}  at={'load' if s['load_ns'] else 'state'}  "
              f"kernel pre {k['pre_db']} dB fade {k['fade_ms']} ms step {k['step_db']} d2 {k['d2_db']} "
              f"disc {k['disc_db']}  |  "
              f"mixer pre {m['pre_db']} dB fade {m['fade_ms']} ms step {m['step_db']} d2 {m['d2_db']} "
              f"disc {max(c['disc_db'] for c in chans)}  -> {verdict}")
    if arm == "silent":
        peak = max([float(np.max(np.abs(kernel))) if len(kernel) else 0]
                   + [float(np.max(np.abs(c))) if len(c) else 0 for c in mixer_ch])
        print(f"  silent arm: whole-capture peak {db(peak):.1f} dBFS")
        if peak > 1e-6:
            bad.append("silent-not-silent")
    if not sw:
        bad.append("no-switch")
    if a.json:
        with open(a.json, "w") as f:
            # numpy scalars (np.bool_ from the comparisons above) are not JSON types: convert them (R072FIX; the
            # first run crashed with "Object of type bool is not JSON serializable").
            json.dump({"capture": d, "arm": arm, "switches": sw, "bad": [str(b) for b in bad]}, f, indent=1,
                      default=lambda o: o.item() if isinstance(o, np.generic) else str(o))
    print("RESULT:", "PASS" if not bad else f"FAIL {sorted(set(map(str, bad)))}")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
