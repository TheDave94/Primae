#!/usr/bin/env python3
"""Generate letter-name + example-word + tracing-word audio for German
using ten popular ElevenLabs voices. Builds the whole audio inventory
the app needs so word-tracing can ship as a full feature, not just a demo.

Output layout (one folder per voice):
    audio_variants/<Voice>/<Letter>/
        <Letter>1.mp3  – first variant of the letter name
        <Letter>2.mp3  – second variant
        <Letter>3.mp3  – third variant (three variants match the
                         existing A1/A2/A3 pattern in the bundle so
                         the two-finger-swipe sound cycler keeps working)
        <ExampleWord>.mp3 × 1–2 (Affe.mp3, Alarm.mp3, ...)
    audio_variants/<Voice>/words/
        <TracingWord>.mp3 × ~30 (OMA.mp3, MAMA.mp3, AUTO.mp3, ...)

Variant strategy: each variant hits the API with the same text but
different voice_settings so ElevenLabs returns audibly distinct takes
instead of near-duplicate outputs from same-seed generation.

Budget (free tier = 10 000 characters/month):
    per voice:
      - letter names × 3 variants: 30 letters × ~3 chars × 3 ≈ 270
      - example words (~2 per letter, ~6 chars): ≈ 360
      - tracing words (~32 words × ~5 chars):    ≈ 160
      = ~790 chars per voice
    × 10 voices = ~7 900 chars, well under the 10k limit.

Prereq:
    export ELEVENLABS_API_KEY=your-key
    pip install requests

Run:
    python3 scripts/generate_letter_audio.py

Re-runs skip files that already exist, so tweaking one voice/letter
doesn't re-pay for the rest.

After listening, pick a favourite voice and copy its folder into place:
    cp -r audio_variants/Rachel/A/* BuchstabenNative/Resources/Letters/A/
The file names already match what the app expects (A1.mp3 etc.).
"""
from __future__ import annotations

import os
import sys
import time
from pathlib import Path

try:
    import requests
except ImportError:
    sys.stderr.write("pip install requests\n")
    sys.exit(1)

API_KEY = os.environ.get("ELEVENLABS_API_KEY")
if not API_KEY:
    sys.stderr.write("Set ELEVENLABS_API_KEY env var\n")
    sys.exit(1)

BASE_URL = "https://api.elevenlabs.io/v1"
MODEL_ID = "eleven_multilingual_v2"

# Ten popular ElevenLabs library voices that handle German via the
# multilingual_v2 model. Swap any of these by visiting the ElevenLabs
# voice library, copying a voice ID, and replacing the value here.
# Retired voices cause a 404 and the script moves on to the next letter.
VOICE_IDS: dict[str, str] = {
    "Rachel":    "21m00Tcm4TlvDq8ikWAM",
    "Adam":      "pNInz6obpgDQGcFmaJgB",
    "Antoni":    "ErXwobaYiN019PkySvjV",
    "Arnold":    "VR6AewLTigWG4xSOukaG",
    "Bella":     "EXAVITQu4vr4xnSDxMaL",
    "Charlotte": "XB0fDUnXU5powFXDhCwa",
    "Domi":      "AZnzlk1XvdvUeBnXmlld",
    "Elli":      "MF3mGyEYCl7XYWbV9V6O",
    "Josh":      "TxGEqnHWrfWFTfGW9XjX",
    "Sam":       "yoZ06aMxZJJ28mfd3POQ",
}

# Three voice-settings presets drive audibly different takes from the
# same text, matching the app's A1/A2/A3 variant slots.
VARIANT_SETTINGS: list[dict] = [
    {"stability": 0.35, "similarity_boost": 0.80, "style": 0.30, "use_speaker_boost": True},
    {"stability": 0.55, "similarity_boost": 0.75, "style": 0.15, "use_speaker_boost": True},
    {"stability": 0.75, "similarity_boost": 0.90, "style": 0.00, "use_speaker_boost": True},
]

# German letter names spelled phonetically so TTS pronounces them as
# letter names ("Ah") rather than raw phonemes. Austrian convention.
LETTER_NAMES: dict[str, str] = {
    "A": "Ah",    "B": "Beh",   "C": "Tseh",    "D": "Deh",
    "E": "Eh",    "F": "Ef",    "G": "Geh",     "H": "Hah",
    "I": "Ih",    "J": "Yot",   "K": "Kah",     "L": "El",
    "M": "Em",    "N": "En",    "O": "Oh",      "P": "Peh",
    "Q": "Kuh",   "R": "Er",    "S": "Es",      "T": "Teh",
    "U": "Uh",    "V": "Fau",   "W": "Veh",     "X": "Iks",
    "Y": "Üpsilon", "Z": "Tsett",
    "Ä": "Äh",    "Ö": "Öh",    "Ü": "Üh",      "ß": "Eszett",
}

# Classic Austrian Fibel Anlaut-Tabelle example words — words that start
# with the letter, used for "A wie Affe" hint audio in the single-letter
# flow. Adjust freely; strings here are literally what the TTS reads.
EXAMPLE_WORDS: dict[str, list[str]] = {
    "A": ["Affe", "Alarm"],
    "B": ["Ball", "Baum"],
    "C": ["Clown"],
    "D": ["Dose", "Dach"],
    "E": ["Elefant", "Esel"],
    "F": ["Fisch", "Frosch"],
    "G": ["Giraffe", "Gabel"],
    "H": ["Haus", "Hund"],
    "I": ["Igel", "Insel"],
    "J": ["Jäger"],
    "K": ["Katze", "Kuh"],
    "L": ["Lama", "Löwe"],
    "M": ["Maus", "Mond"],
    "N": ["Nase", "Nuss"],
    "O": ["Oma", "Opa"],
    "P": ["Papa", "Puppe"],
    "Q": ["Quelle"],
    "R": ["Rabe", "Roller"],
    "S": ["Sonne", "Seife"],
    "T": ["Tasse", "Tiger"],
    "U": ["Uhr", "Uhu"],
    "V": ["Vogel", "Vase"],
    "W": ["Wolke", "Wasser"],
    "X": ["Xylophon"],
    "Y": ["Yoga"],
    "Z": ["Zebra", "Zug"],
    "Ä": ["Ärztin"],
    "Ö": ["Öl"],
    "Ü": ["Übung"],
    "ß": [],  # eszett never starts a word
}

# Austrian Volksschule 1. Klasse tracing-word progression — the words a
# first-grader actually composes during the letter-building weeks. Sourced
# from BMBWF Lehrplan Deutsch-oriented primers (Funkelsteine, Mimi die
# Lesemaus AT, Auer Fibel). Ordered roughly shortest → longest so a
# teacher can pick an age-appropriate slice.
TRACING_WORDS: list[str] = [
    # Family (Woche 1)
    "OMA", "OMI", "OPA", "MAMA", "PAPA",
    # Short 3-letter concretes (Woche 2–3)
    "OHR", "UHR", "UHU", "KUH",
    # 4-letter everyday nouns (Woche 3–4)
    "AFFE", "AUTO", "BALL", "HAUS", "MOND", "ROSE",
    "NASE", "OBST", "IGEL", "ESEL", "MAUS",
    "LAMA", "KILO", "FILM",
    # Doubled-letter reinforcement (Woche 4–5)
    "SONNE", "TASSE", "PUPPE", "KATZE", "WOLLE",
    # Longer 5–6 letter (Woche 6+)
    "APFEL", "FISCH", "VOGEL", "SCHULE",
    "FAMILIE", "ELEFANT",
]

OUTPUT_ROOT = Path("audio_variants")


def synthesise(text: str, voice_id: str, settings: dict, out_path: Path) -> int:
    """POST to ElevenLabs TTS. Writes the MP3 to ``out_path`` unless the
    file already exists. Returns the number of characters billed (0 when
    skipped or on failure)."""
    if out_path.exists():
        return 0
    resp = requests.post(
        f"{BASE_URL}/text-to-speech/{voice_id}",
        headers={"xi-api-key": API_KEY, "Content-Type": "application/json"},
        json={
            "text": text,
            "model_id": MODEL_ID,
            "voice_settings": settings,
        },
        timeout=60,
    )
    if resp.status_code != 200:
        sys.stderr.write(
            f"  ✗ {resp.status_code} for '{text}' ({voice_id}): "
            f"{resp.text[:200]}\n"
        )
        return 0
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(resp.content)
    return len(text)


def main() -> int:
    total_chars = 0
    for voice_name, voice_id in VOICE_IDS.items():
        print(f"=== {voice_name} ({voice_id}) ===")

        # Letters: 3 variants of the letter name + all example words.
        for letter, spoken in LETTER_NAMES.items():
            folder = OUTPUT_ROOT / voice_name / letter
            for i, settings in enumerate(VARIANT_SETTINGS, start=1):
                path = folder / f"{letter}{i}.mp3"
                print(f"  {letter}{i}: '{spoken}' (stab={settings['stability']})")
                total_chars += synthesise(spoken, voice_id, settings, path)
                time.sleep(0.2)
            # One take of each example word — middle stability preset.
            for word in EXAMPLE_WORDS.get(letter, []):
                path = folder / f"{word}.mp3"
                print(f"      example: '{word}'")
                total_chars += synthesise(word, voice_id, VARIANT_SETTINGS[1], path)
                time.sleep(0.2)

        # Tracing words: standalone audio for whole-word completion and
        # picker-level word pronunciation. Single take, middle settings.
        print(f"  -- tracing words --")
        words_folder = OUTPUT_ROOT / voice_name / "words"
        for word in TRACING_WORDS:
            path = words_folder / f"{word}.mp3"
            print(f"    '{word}'")
            total_chars += synthesise(word, voice_id, VARIANT_SETTINGS[1], path)
            time.sleep(0.2)

    print()
    print(f"Total characters billed: {total_chars}")
    print(f"Output: {OUTPUT_ROOT.absolute()}")
    print()
    print("Next steps:")
    print("  1. cd audio_variants and listen through each voice folder.")
    print("  2. Pick a favourite voice (say 'Rachel').")
    print("  3. Copy each letter folder into the bundle, preserving names:")
    print("       for L in A B C D E ... ; do")
    print("         cp audio_variants/Rachel/$L/*.mp3 \\")
    print("            BuchstabenNative/Resources/Letters/$L/")
    print("       done")
    print("  4. Decide where tracing-word audio should live (new")
    print("     Resources/Words/ folder + a repo.loadWords() loader).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
