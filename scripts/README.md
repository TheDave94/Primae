# Letter Asset Generation Scripts

## generate_pbm.py
Generates P4 PBM ghost files from Primae-Regular.otf.
```bash
pip install Pillow
# Generate specific letters:
python3 scripts/generate_pbm.py A B C
# Generate all letters:
python3 scripts/generate_pbm.py
```

Output: `BuchstabenNative/Resources/Letters/{LETTER}/{LETTER}.pbm`

## generate_strokes.py
Generates `strokes.json` tracing paths for letters that don't have them.
Paths are algorithmically generated — **review for pedagogical correctness**.
```bash
python3 scripts/generate_strokes.py
```

## After adding new letters
1. Run both scripts for the new letter
2. Add audio files to `BuchstabenNative/Resources/Letters/{LETTER}/`
3. Sync PBM to Xcode: `cp BuchstabenNative/Resources/Letters/{L}/{L}.pbm BuchstabenApp/BuchstabenApp/Letters/{L}/`
4. Review strokes.json for correct stroke order and direction
