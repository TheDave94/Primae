# Phoneme Audio Authoring Guide (P6)

_Companion document for ROADMAP_V5 P6 — phoneme audio integration. Tells the researcher / voice talent / ElevenLabs operator exactly what files to drop into the bundle and where, so the parent's "Lautwert wiedergeben" toggle picks them up._

---

## Why phonemes

The app's existing audio plays the **letter name** (German: /aː/, /beː/, /tseː/, …). Phonemic awareness — recognising that the letter `A` makes the **sound** /a/ as in *Affe* — is the load-bearing pre-reading skill that German Volksschule curricula teach in parallel with handwriting. Adding a phoneme audio set lets the parent toggle between *names* and *sounds* depending on what the child is currently working on.

Citation: Adams, M. J. (1990). *Beginning to Read: Thinking and Learning about Print*. MIT Press. — phonemic awareness predicts later reading acquisition.

---

## Filename convention

Drop phoneme recordings into the existing per-letter directory:

```
BuchstabenNative/Resources/Letters/<base>/
    <base>_phoneme1.mp3
    <base>_phoneme2.mp3        # optional second voice / take
    <base>_phoneme3.mp3        # optional third voice / take
```

Where `<base>` is the **uppercase** letter directory name (`A`, `B`, …, `Ä`, `Ö`, `Ü`, `ß`). The filename's leaf must contain the literal substring `_phoneme` (case-insensitive) — that's the partition rule in `LetterRepository.partitionPhonemeAudio`.

The repository scanner picks up any audio file in the per-letter directory. Files **with** `_phoneme` land in `LetterAsset.phonemeAudioFiles`; everything else lands in `LetterAsset.audioFiles` (the canonical name set). This means existing letter-name recordings (`A1.mp3`, `A2.mp3`, …) keep working unchanged.

### Supported audio formats
`.mp3`, `.wav`, `.m4a`, `.aac`, `.flac`, `.ogg` — same as the existing audio inventory.

### Recommended specs
- **Sample rate**: 44.1 kHz or 48 kHz
- **Bit depth / bitrate**: 16-bit / 192 kbps mp3 or above
- **Length**: 0.6–1.2 seconds — short enough that a child can tap rapidly without the previous playback still running
- **Pre-roll silence**: ≤ 50 ms — long pre-roll feels sluggish on tap
- **Loudness**: target `-16 LUFS` so phoneme tracks don't pop louder than the existing letter-name tracks (which were recorded at roughly that level)

---

## Voice variants (3 takes per letter)

The existing letter-name layout ships 1–3 takes per letter (`A1.mp3`, `A2.mp3`, `A3.mp3`). The child cycles through them via the **two-finger swipe** gesture on the canvas. Phoneme recordings inherit this behaviour: when phoneme mode is on, the same gesture cycles through `<base>_phoneme1`, `<base>_phoneme2`, `<base>_phoneme3` in order.

Recommended voice mix for the 3 takes:
1. A neutral adult German voice (clear articulation; matches the existing letter-name set)
2. A second adult voice in a different timbre (deeper / lighter — child can pick a favourite)
3. A child-pitched voice (modelled, not real child) — Mayer & Sims (1994) "personalisation principle" suggests a peer-aged voice can boost engagement

ElevenLabs prompt template (single-shot generation):

> Speak only the German phoneme, not the letter name. The letter is `<base>`. Produce the **sound** the letter makes, e.g. for `A` produce `/a/` as in *Affe*, not `/aː/` as in the alphabet song. Brief and clean — under 1 second total. No words, no syllables, just the bare phoneme.

---

## German phoneme reference (target IPA per letter)

| Letter | Phoneme | German example |
|---|---|---|
| A | /a/ | *Affe* |
| B | /b/ | *Ball* |
| C | /ts/ or /k/ | *Cent* / *Computer* (use /k/ as primary) |
| D | /d/ | *Dach* |
| E | /ɛ/ or /eː/ | *Bett* / *Esel* (use /ɛ/ as primary) |
| F | /f/ | *Fisch* |
| G | /ɡ/ | *Gabel* |
| H | /h/ | *Haus* |
| I | /ɪ/ or /iː/ | *Igel* (use /ɪ/ as primary) |
| J | /j/ | *Jahr* |
| K | /k/ | *Kuh* |
| L | /l/ | *Löwe* |
| M | /m/ | *Maus* |
| N | /n/ | *Nase* |
| O | /ɔ/ or /oː/ | *Ofen* (use /ɔ/ as primary) |
| P | /p/ | *Papa* |
| Q | /kv/ | *Quelle* (a digraph; record as a unit) |
| R | /ʁ/ or /ɐ/ | *Rad* (German R; not the rolled Spanish R) |
| S | /s/ or /z/ | *Sonne* (use /z/ at word start) |
| T | /t/ | *Tisch* |
| U | /ʊ/ or /uː/ | *Uhu* (use /ʊ/ as primary) |
| V | /f/ | *Vater* (German V is usually /f/) |
| W | /v/ | *Wasser* |
| X | /ks/ | *Hexe* (digraph) |
| Y | /y/ or /ʏ/ | *Yacht* (rare in German; use /y/) |
| Z | /ts/ | *Zoo* (always /ts/, not English /z/) |
| Ä | /ɛ/ | *Äpfel* |
| Ö | /ø/ or /œ/ | *Öl* |
| Ü | /y/ or /ʏ/ | *Über* |
| ß | /s/ | *Straße* (the unvoiced S — important: NOT /z/) |

**Citations for the IPA choices**: Krech, E.-M. et al. (2009). *Deutsches Aussprachewörterbuch*. de Gruyter — the standard reference for German phoneme realisations.

---

## Verification checklist

After dropping new files into the bundle:

1. **Run the app**, open Settings → Lautwert, toggle "Lautwert wiedergeben" on.
2. Tap any letter that has phoneme recordings. The audio that plays should be the *sound*, not the name.
3. Two-finger vertical swipe should cycle through all phoneme takes for that letter (toast shows "Ton 1 von 3", etc.).
4. Tap a letter that does **not** yet have phoneme recordings. The fallback contract says the letter-name audio plays — verify no silence.
5. Toggle Lautwert off; verify name audio resumes immediately, no app restart needed.

---

## Coverage tracking

Add a row to this table when a letter's phoneme set is recorded:

| Letter | Status | Voices | Notes |
|---|---|---|---|
| A | ⏳ pending | 0/3 | |
| B | ⏳ pending | 0/3 | |
| (repeat for each letter) | | | |

Status values: ⏳ pending, 🟡 partial (1–2 voices), ✅ complete (3 voices).

---

_Last updated 2026-04-29. Update when the convention changes or when ElevenLabs voice choices shift._
