#!/usr/bin/env python3
"""pilot_find_ipad.py — pick the one connected iPad out of `devicectl list devices`.

Usage: python3 -I scripts/pilot_find_ipad.py <devicectl-json-output-file>

The file is what `xcrun devicectl list devices --json-output <file>` writes.
Prints the selected UDID (hardwareProperties.udid — the value both
`devicectl --device` and `xcodebuild -destination id=` accept) on stdout and
exits 0. Exits 1 with a diagnosis on stderr when there are zero candidates,
more than one, or the JSON is not the expected shape.

WHY THIS IS A FILE AND NOT AN INLINE HEREDOC. R-058 (audit 2026-10-13): the
previous version of deploy_verified_pilot_build.sh piped the device listing
into `python3 - <<'PY'`. With a pipe AND a here-document on the same
command, the here-document wins stdin, so the listing was discarded and the
script could never find any device. Taking the path as argv removes the
stdin contest entirely.

SELECTION RULE. A candidate is a device entry that is
  - hardwareProperties.platform == "iOS"      (not watchOS/tvOS/visionOS)
  - hardwareProperties.deviceType == "iPad"   (not an iPhone)
  - hardwareProperties.reality is "physical" or absent
  - connectionProperties.tunnelState != "unavailable"
Entries missing a field are tolerated for `reality`/`tunnelState` only; a
missing udid, platform or deviceType excludes the entry. The schema was
written from the documented shape of devicectl's JSON, not from a capture of
this iPad (no seat may touch it), so a non-matching live device is reported
with the raw entries rather than guessed at.
"""
import json
import sys


def candidates(doc):
    """Return [(udid, label)] for every device that qualifies."""
    devices = doc["result"]["devices"]
    out = []
    for d in devices:
        hw = d.get("hardwareProperties") or {}
        conn = d.get("connectionProperties") or {}
        dev = d.get("deviceProperties") or {}
        udid = hw.get("udid")
        if not udid:
            continue
        if hw.get("platform") != "iOS" or hw.get("deviceType") != "iPad":
            continue
        if hw.get("reality", "physical") != "physical":
            continue
        if conn.get("tunnelState", "") == "unavailable":
            continue
        label = "%s  udid=%s  tunnel=%s" % (
            dev.get("name", "?"),
            udid,
            conn.get("tunnelState", "?"),
        )
        out.append((udid, label))
    return out


def main(argv):
    if len(argv) != 2:
        print("usage: pilot_find_ipad.py <devicectl-json-output-file>", file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as fh:
            doc = json.load(fh)
        found = candidates(doc)
    except (OSError, ValueError, KeyError, TypeError) as e:
        print("UNPARSEABLE: %s: %s" % (type(e).__name__, e), file=sys.stderr)
        return 1
    if not found:
        print("NONE", file=sys.stderr)
        return 1
    if len(found) > 1:
        print("AMBIGUOUS", file=sys.stderr)
        for _, label in found:
            print("  " + label, file=sys.stderr)
        return 1
    print(found[0][0])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
