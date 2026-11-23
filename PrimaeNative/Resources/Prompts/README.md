# Prompts/

The RECORDED study prompts (protocol r9, D15): exactly seven mp3 takes (five from protocol r9, two added by r27 for the final test), voice
"Kiki" (ElevenLabs `eleven_multilingual_v2`, stability 0.55 / similarity 0.80
/ style 0.10), mono 44.1 kHz. They are the only spoken audio of a study
session; `PromptPlayer` plays them and a session refuses to start if one is
missing (`RecordedPromptSet`).

Filenames match `PromptPlayer.PromptKey.rawValue`:

- `phase_observe.mp3`    - "Schau genau hin."
- `phase_guided.mp3`     - "Jetzt du."
- `phase_freewrite.mp3`  - "Und jetzt ganz allein."
- `retry_cue.mp3`        - "Probier's nochmal."
- `celebration.mp3`      - "Super gemacht!"
- `final_intro.mp3`      - "Jetzt schreibst du sie alle noch einmal." (r27, after the pause)
- `final_glimpse.mp3`    - "Merk ihn dir gut." (r27, during each glimpse)

**r27: the last two files are recorded** (`python3 scripts/generate_prompts.py
--voice Kiki --prompt final_intro`, then `--prompt final_glimpse`) and pinned in
MANIFEST.json with their real digests; the seven-file set id is
`rec:kiki:b348d3f5d8c4`. A missing or changed take still makes a study session
refuse to start and `scripts/check_study_prompts.py` fail: no session runs on a
set that is not the reviewed one.

`MANIFEST.json` pins the bytes (sha256 per file) and the set id the app
stamps on every row as `voiceId`. `scripts/check_study_prompts.py` (CI job
"Resource presence") fails when this directory holds any other mp3 or any
byte differs. Replacing a take is a protocol change: new files, a
hand-edited MANIFEST.json, a new `StudyProtocol` revision.

Also here: the effect sounds `tap.wav`, `tap_wrong.wav`, `tick_stroke.wav`.

Generate candidate takes (not part of the build; needs an ElevenLabs key):

```bash
read -s -p "ELEVENLABS_API_KEY: " ELEVENLABS_API_KEY && export ELEVENLABS_API_KEY
python3 scripts/generate_prompts.py --voice Kiki
```
