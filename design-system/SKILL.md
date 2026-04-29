---
name: primae-design
description: Use this skill to generate well-branded interfaces and assets for Primae (a German‑language iPad handwriting‑learning app for Austrian first‑graders), either for production or throwaway prototypes/mocks. Contains essential design guidelines, colors, type, fonts, assets, and UI kit components for prototyping.
user-invocable: true
---

Read the `README.md` file within this skill, and explore the other available files (`colors_and_type.css`, `assets/`, `fonts/`, `preview/`, `ui_kits/ipad-app/`).

If creating visual artifacts (slides, mocks, throwaway prototypes, etc.), copy assets out of this folder and create static HTML files for the user to view. Reference `colors_and_type.css` for all design tokens — every CSS var is documented in `README.md` § Visual foundations.

If working on production code, copy assets and read the rules here to become an expert in designing with this brand. Note the documented substitutions:

- **Primae** display family is substituted with **Nunito** (real font is not redistributable; flag this if pixel‑perfect type matters).
- **SF Symbols** is substituted with **Lucide** (CDN: `https://unpkg.com/lucide@latest`).

If the user invokes this skill without other guidance, ask them what they want to build, ask a few clarifying questions (audience: child vs. adult/parent area? which world: Schule / Werkstatt / Fortschritte? a single screen or a flow?), and then act as an expert designer who outputs HTML artifacts _or_ production code, depending on the need.

Critical rules to honour every time:

1. The child voice is German, second person, present‑tense action verbs first ("Schau mal genau hin.", "Tippe die Punkte der Reihe nach."). Praise is short and never numeric.
2. The adult/parent voice is more clinical and uses real terminology (Schreibmotorik, Studienteilnahme, Datenexport).
3. Canvas stroke colours are pinned by spec: ghost = blue, child ink = green, guide dot = orange. Do not invent new stroke colours.
4. Surface metaphor is **paper, not glass** — flat fills, ink‑line borders, no gradients, no blur except inside the KP comparison overlay.
5. Buttons use the sticker treatment: 2 px ink border + `0 4px 0` ink shadow that collapses to flush on press.
