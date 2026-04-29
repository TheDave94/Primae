# Primae — iPad UI Kit

A click-thru recreation of the iPad app, focused on the **four-phase letter-tracing flow** (Schule world). Includes lightweight Werkstatt and Fortschritte worlds for navigation context.

## Files
- `index.html` — entry; renders the full app at iPad-landscape proportions.
- `components.jsx` — design primitives: `WorldRail`, `PhaseIndicator`, `StickerButton`, `StarRow`, `TracingCanvas`, `LetterPicker`, `PraiseBand`, `KPOverlay`.
- `app.jsx` — the four-phase Schule flow + Werkstatt + Fortschritte + parental gate.
- `styles.css` — kit-specific CSS, layered on top of `colors_and_type.css`.

## What's interactive
1. **Schule** (default): pick any letter from the bottom rail. Walk through the four phases via the **Weiter / Punkt n / Nachspuren fertig / Fertig** sticker buttons. The phase indicator pip and the prompt update each step. After the free-write phase, a KP comparison overlay fades in, then a celebration card with stars.
2. **World rail** switches between Schule, Werkstatt, Fortschritte. Long-press the gear (~2 s) to surface the parental gate placeholder.
3. **Werkstatt** shows a free-write canvas with a placeholder word.
4. **Fortschritte** shows total stars + streak + per-letter star gallery.

## What's intentionally stubbed
- No real ink rendering (Apple Pencil PencilKit). The "child path" shown in the KP overlay re-uses the ghost reference for demo purposes.
- No real haptics, audio cue, or "Tafelwischer" wipe transition.
- Letter strokes are a hand-authored sample (A, F, I, K, L, M, O). A production app would load these from a stroke-order data file.

## Verifying against source
This kit was built from the materials provided to the project. **No codebase or Figma was attached**, so visual fidelity is based on the brand description (German alphabet teaching app, paper-and-ink aesthetic, sticker-style buttons, four-phase pedagogy). Treat as a *direction*, not a 1:1 recreation. See the root `README.md` § Caveats.
