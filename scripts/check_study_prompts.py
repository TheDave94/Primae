#!/usr/bin/env python3
"""check_study_prompts.py - the five recorded study prompts are exactly the
reviewed ones (protocol r9, R-023).

A study child hears five recorded phrases (voice Kiki). Their bytes ARE the
instrument: a re-recorded take, a swapped file or a sixth mp3 changes what
the child hears without any Swift diff. This check fails when
PrimaeNative/Resources/Prompts/*.mp3 is not exactly the set named in
MANIFEST.json, byte for byte (sha256), or when the manifest's own set id
(the string the app stamps on every row as voiceId) is not the one the
files produce. Stdlib only; run with `python3 -I`.

The set id is "rec:kiki:" + the first 12 hex of sha256 over the files'
bytes concatenated in manifest key order. PrimaeNative/Core/RecordedPromptSet
computes the same value at run time; a Swift test pins the two together.

Changing a take is a protocol change: new files, new MANIFEST.json (by hand,
reviewed), new protocol revision.

Usage: python3 -I scripts/check_study_prompts.py [--dir <Prompts dir>]
Exit 0 ok, 1 drift.
"""
import argparse
import hashlib
import json
import pathlib
import sys

DEFAULT_DIR = (pathlib.Path(__file__).resolve().parent.parent
               / "PrimaeNative" / "Resources" / "Prompts")


def check(prompts: pathlib.Path) -> list:
    problems = []
    manifest_path = prompts / "MANIFEST.json"
    if not manifest_path.is_file():
        return [f"{manifest_path}: MANIFEST.json is missing"]
    manifest = json.loads(manifest_path.read_text())
    entries = manifest["files"]
    expected = {f"{e['key']}.mp3": e["sha256"] for e in entries}
    present = {p.name for p in prompts.glob("*.mp3")}

    for name in sorted(present - set(expected)):
        problems.append(f"{name}: not in MANIFEST.json (a study build ships exactly "
                        f"{len(expected)} recorded prompts)")
    digest_all = hashlib.sha256()
    for e in entries:
        name = f"{e['key']}.mp3"
        path = prompts / name
        if not path.is_file():
            problems.append(f"{name}: missing")
            continue
        data = path.read_bytes()
        digest_all.update(data)
        actual = hashlib.sha256(data).hexdigest()
        if actual != e["sha256"]:
            problems.append(f"{name}: sha256 {actual} != manifest {e['sha256']}")
    set_id = f"rec:{manifest['voice'].lower()}:{digest_all.hexdigest()[:12]}"
    if set_id != manifest["setId"]:
        problems.append(f"MANIFEST.json setId {manifest['setId']} != {set_id} "
                        f"(computed from the files in key order)")
    return problems


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", type=pathlib.Path, default=DEFAULT_DIR)
    args = ap.parse_args()
    problems = check(args.dir)
    if problems:
        print("FAIL - recorded study prompts differ from MANIFEST.json:")
        for p in problems:
            print(f"  - {p}")
        return 1
    print("ok - the recorded study prompts match MANIFEST.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
