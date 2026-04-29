# Prompts/

Pre-recorded ElevenLabs MP3 takes for the 13 static phrases the
child hears during normal practice — phase entries, praise tiers,
paper-transfer cues, retrieval question.

Filenames match `PromptPlayer.PromptKey.rawValue`:

- `phase_observe.mp3`     · "Pass jetzt gut auf!"
- `phase_direct.mp3`      · "Tipp die Punkte der Reihe nach an."
- `phase_guided.mp3`      · "Fahr die Linie nach."
- `phase_freewrite.mp3`   · "Und jetzt du alleine."
- `praise_4.mp3`          · "Wow, das war perfekt! Super gemacht."
- `praise_3.mp3`          · "Toll gemacht!"
- `praise_2.mp3`          · "Gut gemacht!"
- `praise_1.mp3`          · "Schon gut! Probier's nochmal."
- `praise_0.mp3`          · "Probier's gleich nochmal."
- `paper_show.mp3`        · "Schau dir den Buchstaben gut an."
- `paper_write.mp3`       · "Jetzt schreibst du den Buchstaben auf Papier."
- `paper_assess.mp3`      · "Wie ist dein Buchstabe geworden?"
- `retrieval_question.mp3` · "Welchen Buchstaben hörst du?"
- `celebration.mp3`        · "Super gemacht!" (paired with a system success chime in `PromptPlayer.playSuccessChime`)

Generate with:

```bash
export ELEVENLABS_API_KEY=...
python3 scripts/generate_prompts.py
```

Until any of the MP3s land here, `PromptPlayer.play(_:fallbackText:)`
falls back to the AVSpeechSynthesizer voice — the app stays
functional even on a fresh checkout that hasn't been generated yet.
