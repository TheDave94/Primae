#!/usr/bin/env python3
"""Read a PopCapture directory from SessionInterruptionUITests.testClockTimerInterruptsVoice
(pulled with `xcrun devicectl device copy from`) and judge the real interruption.

GREEN (exit 0) needs all of:
  1. a SYSTEM interruption: `session.inactive source=2` (iOS 27 pair) or
     `session.interruption type=1` (the pre-SDK27 notification);
  2. it landed while the voice was sounding (an `audio.play` before it, no
     `audio.stop` in between);
  3. the voice handled it: `voice.interruption began intent=true` within 1 s;
  4. if the system ended it (`session.resumption` / `session.interruption type=0`),
     the voice logged `voice.interruption ended …`;
  5. the voice rendered again afterwards: a kernel voice begin (rt.tsv `K2`)
     later than 3 s after the interruption (the guided trace).
Anything else is RED (exit 1), with the reason.

Usage: check_interruption_capture.py <dir containing events.tsv and rt.tsv>
"""
import pathlib
import sys


def main(d: pathlib.Path) -> int:
    ev = []
    for line in (d / "events.tsv").read_text().splitlines():
        f = line.split("\t")
        if len(f) >= 2:
            ev.append((int(f[0]), f[1], f[2] if len(f) > 2 else ""))
    t0 = ev[0][0]
    rel = lambda t: (t - t0) / 1e9
    k2 = []
    for line in (d / "rt.tsv").read_text().splitlines():
        f = line.split("\t")
        if len(f) >= 2 and f[1] == "K2":
            k2.append(int(f[0]))

    sys_int = [e for e in ev if (e[1] == "session.inactive" and "source=2" in e[2])
               or (e[1] == "session.interruption" and "type=1" in e[2])]
    if not sys_int:
        print("RED: no system interruption reached the app"); return 1
    t_int = sys_int[0][0]
    print(f"system interruption at {rel(t_int):.3f}s: {sys_int[0][1]} {sys_int[0][2]}")

    plays = [e for e in ev if e[1] == "audio.play" and e[0] <= t_int]
    if not plays:
        print("RED: the voice was not sounding (no audio.play before the interruption)"); return 1
    stops = [e for e in ev if e[1] == "audio.stop" and plays[-1][0] < e[0] <= t_int]
    if stops:
        print(f"RED: the voice stopped at {rel(stops[0][0]):.3f}s, before the interruption"); return 1
    print(f"voice sounding since {rel(plays[-1][0]):.3f}s")

    began = [e for e in ev if e[1] == "voice.interruption" and e[2].startswith("began")
             and 0 <= e[0] - t_int <= 1_000_000_000]
    if not began or "intent=true" not in began[0][2]:
        print(f"RED: the voice did not handle the interruption with its resume intent: {began}"); return 1
    print(f"voice: {began[0][2]} at {rel(began[0][0]):.3f}s")

    ends = [e for e in ev if e[0] > t_int and ((e[1] == "session.resumption")
            or (e[1] == "session.interruption" and "type=0" in e[2]))]
    vend = [e for e in ev if e[1] == "voice.interruption" and e[2].startswith("ended")]
    if ends:
        print(f"system end at {rel(ends[0][0]):.3f}s: {ends[0][1]} {ends[0][2]}")
        if not vend:
            print("RED: the system ended the interruption but the voice never handled it"); return 1
        print(f"voice: {vend[0][2]} at {rel(vend[0][0]):.3f}s")
    else:
        print("system end: none posted (no session.resumption / interruption type=0)")

    after = [t for t in k2 if t > t_int + 3_000_000_000]
    if not after:
        print("RED: the voice never rendered again after the interruption (no K2 in rt.tsv)"); return 1
    print(f"voice rendered again: {len(after)} kernel voice begins, first at {rel(after[0]):.3f}s")
    print("GREEN"); return 0


if __name__ == "__main__":
    sys.exit(main(pathlib.Path(sys.argv[1])))
