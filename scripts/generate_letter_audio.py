#!/usr/bin/env python3
"""Generate letter-name + example-word audio for every German letter using
ten popular ElevenLabs voices, so you can listen to each voice reading the
whole alphabet and pick the one you like best for the app.

Output layout:
    audio_variants/<VoiceName>/<Letter>/
        letter.mp3          – the letter pronounced as a letter name
                              ("Ah" for A, "Peh" for P, ...)
        <Example>.mp3       – example words that start with the letter
                              ("Affe.mp3", "Oma.mp3", ...)

Budget (free tier is 10 000 characters/month):
    ~85 chars for 30 letter names + ~220 chars for example words
    = ~305 chars per voice × 10 voices ≈ 3 050 characters total.

After listening, pick a favourite voice and either:
    A) copy that voice's folder contents into
       BuchstabenNative/Resources/Letters/, renaming letter.mp3 to the
       scheme the app expects (e.g. A1.mp3), or
    B) just bundle the whole voice folder and point the bundle at it.

Prereq:
    export ELEVENLABS_API_KEY=your-key
    pip install requests

Run:
    python3 scripts/generate_letter_audio.py

Edit VOICE_IDS, LETTER_NAMES, or EXAMPLE_WORDS below if you want a
different mix; the script is idempotent (existing files are skipped).
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
# If ElevenLabs has retired a voice, the script skips it and continues.
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

# German letter names spelled phonetically so TTS pronounces them as
# letter names ("Ah") and not as the raw phoneme. Austrian convention.
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

# Classic Anlaut-Tabelle example words — Austrian Fibel-standard picks
# that start with the letter and are age-appropriate. Adjust freely;
# strings here are literally what gets sent to TTS.
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

OUTPUT_ROOT = Path("audio_variants")


def synthesise(text: str, voice_id: str, out_path: Path) -> int:
    """POST to ElevenLabs TTS, write the MP3 to ``out_path`` if the call
    succeeds. Returns the number of characters billed (0 on failure or if
    the file already existed)."""
    if out_path.exists():
        return 0
    resp = requests.post(
        f"{BASE_URL}/text-to-speech/{voice_id}",
        headers={"xi-api-key": API_KEY, "Content-Type": "application/json"},
        json={
            "text": text,
            "model_id": MODEL_ID,
            "voice_settings": {"stability": 0.5, "similarity_boost": 0.75},
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
        for letter, spoken in LETTER_NAMES.items():
            folder = OUTPUT_ROOT / voice_name / letter
            print(f"  {letter}: '{spoken}'")
            total_chars += synthesise(spoken, voice_id, folder / "letter.mp3")
            time.sleep(0.2)  # gentle on rate limits
            for word in EXAMPLE_WORDS.get(letter, []):
                print(f"      '{word}'")
                total_chars += synthesise(word, voice_id, folder / f"{word}.mp3")
                time.sleep(0.2)
    print()
    print(f"Total characters billed: {total_chars}")
    print(f"Output: {OUTPUT_ROOT.absolute()}")
    print()
    print("Next: listen to each voice's folder, pick a favourite, and copy")
    print("its <Letter>/letter.mp3 files into BuchstabenNative/Resources/")
    print("Letters/<Letter>/ as A1.mp3 etc. (matches the existing naming).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
