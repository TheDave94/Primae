# Study device dry-run — proctor procedure

For David, holding the study iPad, no laptop/terminal needed. The app
is already installed (`Release-Study`, bundle ID
`com.flamingistan.primae.study`). Identify it on the home screen by
the amber icon with the navy "STUDIE" ribbon — the display name is
"Primae Studie" on a build made from the committed tree
(`project.pbxproj`'s `Debug-Study`/`Release-Study`
`INFOPLIST_KEY_CFBundleDisplayName`), but a build made from an
uncommitted working tree can show plain "Primae" instead if that
value was locally edited. Don't rely on the name alone — confirm you
have the study binary the way Section 0 says: the red "STUDY BUILD"
banner in the parent area.

Supersedes `docs/TESTING_CHECKLIST.md` for this purpose — that
checklist tests the paused casual app and predates the compile-out,
the bundle-ID split, the demonstrations (D9), and the phoneme
recordings (H5). Everything below is read directly off the current
implementation (`TracingViewModel.swift`, `ResearchDashboardView.swift`,
`ParentAreaView.swift`, `PreTaskDemonstration.swift`,
`ThesisCondition.swift`, `PilotAudioCondition.swift`), not recalled.

You will run the whole thing **three times**, once per audio arm:
**Phonem**, **Raumklang**, **Ohne Ton**. Section 6 covers switching
arms between runs.

## What's automated now, and what's still yours (2026-09-15)

`PrimaeUITests/StudyDryRunUITests.swift` — a real XCUITest target,
CI-verified (drives the actual app through the accessibility tree,
same surface VoiceOver uses; not a mock or a stub) — now covers five
of the things below every time CI runs, on the simulator: **enrolment**
("Neuer Teilnehmer" through to the relaunch alert), **the
Vortest/Post-Test/Nachtest flow** (tapping a probe button and landing
correctly on the canvas, or getting a clear refusal alert instead of
silence), **a session completing** (a real canvas stroke through to
the phase indicator advancing), **a second enrolment preserving the
first participant** (the archive-and-replace flow, checked via the
participant count), and **the export containing both** (triggering a
real export and confirming the share sheet appears with the right
count behind it). These are exactly the things that have broken
silently on this project before — worth running on every CI push
rather than only when a human remembers to re-check by hand.

**Still genuinely yours, on the physical device, every run** — this
suite deliberately does not and cannot cover these, not an oversight:
- **Apple Pencil-specific input** (pressure, azimuth/tilt) — the
  suite drives the canvas with plain synthetic touches, which the app
  accepts identically to a finger for completing a phase, but pencil
  pressure/azimuth values stay unset the whole way through. The
  spatial arm's pitch mapping and any pencil-specific calibration
  need a real Pencil.
- **Palm rejection** — untestable without a real hand resting on the
  glass.
- **Physical audio output** — whether sound actually plays through
  headphones is a hardware fact XCUITest cannot observe; Sections 4b/4c
  (below) and the audio arm checks stay manual.
- **The three-finger proctor gesture** — not simulated by this suite.
- **All three audio arms, end to end** — the automated suite exercises
  ONE cold-probe pass structurally; it does not switch arms or listen
  for sound in any of them. Section 6's per-arm re-runs are still
  entirely David's.

Where a step below is now also covered by the automated suite, it says
so inline — that does not mean skip it on a real device dry-run, since
the suite runs on a simulator and proves the LOGIC, not the physical
experience; it means a failure there is no longer a surprise waiting
for the next manual pass to catch.

---

## 0 · Before you start (once, not per run)

- **Headphones connected.** Both the Phonem and the Raumklang arm need
  them — the app now warns for either, not just Raumklang (a red
  banner reading "Keine Kopfhörer verbunden" appears in the research
  tab if not). Ohne Ton doesn't need them, but leave them in for all
  three runs so the three are comparable.
- **Do Not Disturb on, no other audio app playing.** Turning the
  iPad's Do Not Disturb on and making sure nothing else is playing
  audio isn't just tidiness — opening Control Center or a notification
  banner during a trial can end that trial early. Either one briefly
  puts the app's scene into `.inactive`, and the app treats that the
  same as full backgrounding: `appDidEnterBackground()` runs and
  finalises any finished-but-not-yet-scored free-write in progress,
  cutting the trial short.
- **Reach the parent area**: on the Schule canvas, long-press the gear
  icon at the bottom of the left rail for about 2 seconds (a blue ring
  fills around it). This opens "Eltern-Bereich" full-screen. A red
  "STUDY BUILD" banner should be visible somewhere in it — if it's
  missing, this isn't the study binary; stop and check with me before
  running anything.
- The parent area has exactly three tabs on this build: **Forschungs-
  Daten**, **Einstellungen**, **Datenexport**. There is no "Übersicht"
  tab — that's the casual app's dashboard, compiled out here. That's
  correct, not a defect.

---

## 1 · Enrol a participant (start of each run)

1. In the parent area, open **Forschungs-Daten**. Scroll to
   **"Studien-Gerät vorbereiten"** at the bottom.
2. You should see **"Studienmodus: An (Studien-Build)"** with a lock
   icon — no toggle. That's correct: this build can't run outside
   study mode.
3. Tap **"Neuer Teilnehmer."** A share sheet opens first — this is an
   automatic export of whatever data is currently on the device
   (empty, on the very first run). **Save it somewhere** (Files, or
   "Save to Files") rather than just dismissing — this is your first
   "did data land" checkpoint, and it's also how a delayed-retest
   participant would later be restored. Dismiss the share sheet.
4. A confirmation appears: **"Teilnehmer-Daten löschen?"** Tap
   **"Löschen & neu starten."**
5. An alert reads **"Neuer Teilnehmer angelegt... App jetzt vollständig
   schließen und neu starten."** Don't relaunch yet — do step 2 below
   first, so one relaunch covers both changes.

---

## 2 · Force the arm for this run

The new participant just got a **random** arm assignment (Phonem /
Raumklang / Ohne Ton, picked from the fresh ID). Don't leave it to
chance — force it explicitly so you know which run is which.

1. Still without relaunching, switch to the **Einstellungen** tab.
2. Scroll to the **"Forschung"** section. You should now see three
   pickers: "Studienarm überschreiben," **"Audio-Arm überschreiben,"**
   and "Trainierte Buchstaben überschreiben" — they only appear once a
   participant is enrolled, which you just did.
3. **Leave "Studienarm überschreiben" on "Automatisch."** This is a
   *different* axis (a pedagogical-flow leftover from an earlier study
   design) — it has no effect under study mode regardless of what it's
   set to, so touching it does nothing either way. Only "Audio-Arm
   überschreiben" matters for this test.
4. Set **"Audio-Arm überschreiben"** to the arm for this run: **Phonem**
   (run 1), **Raumklang** (run 2), or **Ohne Ton** (run 3).
5. Leave "Trainierte Buchstaben überschreiben" on "Automatisch" unless
   you specifically want fixed letters — either way, the app will tell
   you which three it picked (next step).
6. **Now force-quit the app and relaunch it** (swipe up, swipe the app
   away, tap the "Primae Studie" icon again). One relaunch covers both
   the new participant and the arm override.
7. **Verify before doing anything else.** Long-press the gear again →
   Forschungs-Daten → look at the top card, **"Aktiver Teilnehmer."**
   It shows a short participant ID, then a line like **"Phonem ·
   [Automatisch]"** and **"Trainiert: A / F / L"** (whichever three).
   Confirm the first word matches the arm you set in step 4. If it
   doesn't, repeat steps 2–6 — don't proceed on the wrong arm.

---

## 3 · Pretest (all five letters, before any training)

Still in **Forschungs-Daten**, scroll to **"Vortest (alle fünf
Buchstaben, vor dem Training)."** There are five buttons, one per
study letter (A, F, I, L, M — regardless of which three this
participant trains).

For **each of the five letters**, one at a time:
1. Tap **"Vortest starten: `<letter>`."** The parent area closes
   immediately and drops you straight onto the canvas.
2. The canvas shows a blank glyph — no ghost line, no demonstration,
   no sound in any arm (pretest is sound-off and unscaffolded by
   design, the same for all three arms). Write the letter once from
   memory.
3. After you lift and pause briefly, the trial scores and the canvas
   goes idle (no celebration, no badge — a cold probe gets no
   reward-class feedback).
4. Long-press the gear again, back to Forschungs-Daten, tap the next
   letter's pretest button. Repeat until all five are done.

This is 5 round trips through the gear long-press — expected, not a
bug.

---

## 4 · Training — the three trained letters

Close the parent area (or it should already be closed from the last
pretest). You're on the canvas — what you see depends on how you got
here:

- **Right after a fresh launch** (before any pretest was run), the
  app opens on the **first trained letter, "parked"**: nothing is
  playing, nothing is animating yet. You'll see the brand-blue pill at
  the bottom with only 👁️ 👆 (no text — the app never shows unreadable
  text to a child). **Tap it once** to start the letter for real.
- **Right after the five pretests (the normal case, Section 3 just
  finished)**, the canvas is still showing the **last pretest
  letter**, in its finished free-writing state — nothing is parked.
  Press the **right-arrow (chevron) nav button** in the bottom bar
  once to reach the first trained letter. That arrow calls
  `nextLetter()`, which cycles the trained pool; since the pretest
  letter you're leaving may not be one of the three trained letters,
  it isn't found in that pool and the arrow lands on the first trained
  letter rather than "the next one after it."

For **each of the three trained letters** (the ones named on the
"Aktiver Teilnehmer" card), in order:

### 4a · Observe (Anschauen)
- The guide-dot animation runs for **one pass** (roughly 6–14 seconds
  depending on the letter — I, being short, is at the fast end; M is
  slower). It plays at 0.4x, which is why a single pass is longer than
  half of the two it replaced: the window grew about 25%, from ~5–11 s
  to ~6–14 s. **Do not expect a tap to skip this** — under study mode a
  tap does nothing here except start the parked launch letter the very
  first time. It auto-advances on its own after the pass. If it seems
  stuck past ~20 seconds, that's a defect, not patience being tested.
  (The tripwire was ~15 s and had four seconds of headroom; the window
  change left it about one, so it moved.)
- **What plays, per arm, in the first ~2 seconds of this window:**
  - **Phonem:** the letter's own recorded sound, once (may loop
    briefly to fill the 2 s window on four of the five letters —
    that's expected, not a bug).
  - **Raumklang:** a synthetic tone, STEADY. It holds the neutral rate at
    centre pan and zero pitch for the 2 s window — no sweep. It used to
    sweep the pitch and pan across the canvas; that was removed on
    2026-09-17 ("Glissando weg"), because on the device it read as the
    arm playing a high-low-high slide at the child before anything had
    been touched. **Expect a plain held tone and nothing else.** What the
    arm does with pitch and pan happens during the child's own tracing,
    not here — the demonstration no longer teaches the mapping, only
    occupies the same window as the phoneme arm's.
  - **Ohne Ton:** nothing added — just the guide-dot animation,
    silent, same length as the other two arms.
- The demonstration is cancelled instantly if you touch the canvas
  early — that's correct, not a glitch.

### 4b · Direct (Richtung lernen)
- Numbered dots appear over each stroke's start point. Tap them **in
  order**. The next expected one pulses. A correct tap advances a
  brief directional arrow along the stroke — that part is real. **The
  tap-sound and the haptics are not**: under study mode the app
  substitutes silent no-op objects for both the prompt player and the
  haptic engine (`TracingViewModel.init`), so a correct tap is silent
  and a wrong dot gives no haptic either — only the visual pulse on
  the wrong dot and the arrow on a correct one are present, in every
  arm. Don't expect to hear or feel anything here; that's correct, not
  a defect.
- No arm-specific sound here in any arm — this phase is unaffected by
  the audio condition.
- All dots tapped in order → auto-advances.

### 4c · Guided (Nachspuren)
- A faint ghost letter appears. Trace it with your finger or the
  Pencil.
- **This is where the arm's sound actually plays while you write:**
  - **Phonem / Raumklang:** sound is active only while you're near the
    expected checkpoint and moving above a small speed threshold; it
    speeds up / slows down and (Raumklang only) changes pitch with
    your vertical position and pans with your horizontal position. If
    you stop moving, it holds briefly then goes idle within about a
    tenth of a second; moving again brings it back.
  - **Ohne Ton:** silent throughout, by design.
- **No haptics anywhere in this phase, in any arm.** Under study mode
  the haptic engine is a silent no-op (same substitution as 4b), so
  neither the per-checkpoint ticks nor the stroke-completion buzz that
  the casual app has actually fires — don't expect to feel anything.
- If your finger or the Pencil leaves the canvas bounds mid-stroke,
  the app shows a text toast reading "Probier's nochmal" and resets
  the current stroke so you retrace it from its start point — no
  sound accompanies the toast (speech is also silenced under study
  mode). That's the expected recovery path, not a defect.

### 4d · FreeWrite (Selbst schreiben)
- Blank canvas, no ghost. Write the letter from memory.
- **You may still see the last stroke of the Guided phase for a
  moment.** The canvas keeps that finished trace visible for up to
  5 seconds after the phase changes ("lingering ink" — so the child
  sees their own ink survive the transition instead of it blinking
  away), and it clears immediately as soon as you touch the canvas
  again. That's expected — don't flag it as leftover ghost content.
- **Silent in all three arms, including Phonem and Raumklang** — the
  audio coupling is deliberately gated off here (sound-off production
  is part of the design, not a missing feature). If you hear the
  arm's sound during this phase, that IS a defect — flag it.
- **After you lift: nothing, under study mode.** In the casual app a
  dark KP overlay would compare your trace to the reference, followed
  by a star-count celebration screen ("Geschafft!" + stars) — but
  under study mode BOTH are gated off (`celebrateFreeWrite` and
  `recordSessionCompletion` in `PhaseTransitionCoordinator` each gate
  on `!vm.studyMode`), and the views themselves
  (`CompletionCelebrationOverlay`, the freeWrite KP overlay) are
  compiled out of the study binary entirely. After the ~2 s quiet
  window following your last touch, the canvas simply goes idle — no
  overlay, no stars, no chime, in any arm. What you will **not** see
  in any arm, casual or study: the coloured recognition badge or the
  guided-score feedback card — both are reward-class feedback
  suppressed under study mode regardless of what else changes.
- **There is no "Weiter" button under study mode** — it belongs to the
  celebration screen, which doesn't exist here. To move to the next
  trained letter, press the **right-arrow (chevron) nav button** in
  the bottom bar (`nextLetter()`); the left-arrow (`previousLetter()`)
  goes back. Then repeat 4a–4d. The demonstration in 4a plays again on
  every letter entry — that's intended (every trace is preceded by the
  same exposure), not a repeat-content bug.

After the third trained letter's FreeWrite, training is done. **There
is no separate "post-test" step for the three trained letters** — that
FreeWrite pass you just did already is their post-test measure.

---

## 5 · Post-test (the two untrained letters)

Long-press the gear → Forschungs-Daten → **"Post-Test (ungeübte
Buchstaben)."** Exactly two buttons here, for the two letters this
participant did NOT train.

For each of the two:
1. Tap **"Post-Test starten: `<letter>`."** Drops straight to canvas.
2. Same as pretest: blank canvas, no ghost, no demonstration, no
   sound, single cold FreeWrite attempt.
3. Long-press the gear, back to Forschungs-Daten, do the second
   letter.

That's the end of the session for this run.

---

## 6 · Confirming the data landed

Long-press the gear → **Datenexport** (third tab). Tap **"JSON
exportieren"** (or CSV). A share sheet opens with a file named
`primae_progress_<date>.json`. Save it to Files.

You don't need a terminal to sanity-check it: open it in the Files app
preview, or in a text/spreadsheet app if you have one on the iPad. You
should be able to see:
- the participant ID matching the "Aktiver Teilnehmer" card,
- a header line naming `enrolledAt`,
- one row per **phase** completed, not per letter — each row carries
  its own `phase` (observe/direct/guided/freeWrite) and, for the cold
  probes, a `probe` column (pretest/posttest). Each cold probe (a
  pretest or post-test letter) opens straight into freeWrite, so it
  writes exactly **1 row**: **5 pretest rows** (one per letter) and
  **2 post-test rows** (one per letter). Each of the **3 trained
  letters** writes **up to 4 rows** — one per phase it completed
  (observe, direct, guided, freeWrite; `LearningPhase` has exactly
  these four cases) — all written together at that letter's freeWrite
  completion. That caps a clean run at **5 + (3 × 4) + 2 = 19 rows**,
  fewer if a trained letter's session ended before every phase scored
  (e.g. you had to abandon a letter mid-phase). Nothing should be
  entirely missing for a letter you actually wrote.

If the export is empty or missing rows, that's a defect — stop and
flag it rather than starting the next run.

---

## 7 · Between runs — what resets, what doesn't

Starting the **next** run means repeating from **Section 1** ("Neuer
Teilnehmer"). This is the only supported way to run a clean second
arm — don't just flip "Audio-Arm überschreiben" without a fresh
participant first, because **"Neuer Teilnehmer" clears every override
you set**, including the audio-arm one (it re-randomises all three
axes for the new ID). Setting the override again, per Section 2, is
what pins the arm for the new run.

What **"Neuer Teilnehmer" wipes**: all progress, stars, phase-session
records, raw traces, and on-device stroke calibrations for the
outgoing participant (it exports them first, per Section 1 step 3, so
nothing is lost — just cleared off the device).

What it **does not touch**: device-level settings — appearance,
speech rate, and so on. You don't need to redo anything there between
runs.

You do **not** need "Teilnehmer wiederherstellen" for this — that's
for the delayed retention re-test weeks later, on a participant ID
recovered from an earlier export. Don't use it for switching arms
today.

---

## Failure catalogue — which refusals are correct, which are defects

The app is designed to refuse loudly rather than run an invalid
session. If you see one of these exact screens, that's the app
working as intended:

| What you see | Message (paraphrased) | Correct when | Defect if |
|---|---|---|---|
| Full-screen stop, "Studie kann nicht starten" | "Kein Teilnehmer eingeschrieben..." | You skipped Section 1 (never enrolled, or forgot after a fresh install) | You DID enrol and this still shows |
| Same screen | "Zuweisung geändert — die App muss neu gestartet werden..." | You changed an override (Section 2) and haven't relaunched yet | It still shows AFTER a full relaunch |
| Same screen | "Teilnehmer gewechselt — die App muss neu gestartet werden..." | You just did "Neuer Teilnehmer" and haven't relaunched yet | It still shows after relaunch |
| Same screen | "Spatial-Arm ohne Trägerton..." | Should never happen — the carrier file is bundled | Shows at all, on any run |
| Same screen | "Phonem-Arm ohne Phonem-Aufnahmen für: ..." | Should never happen — all five recordings are bundled (H5 closed 2026-09-14) | Shows at all, on any run |
| "Buchstaben nicht geladen — Bitte die App neu starten." | — | Should never happen on a correctly built artefact | Shows at all |
| Red "Keine Kopfhörer verbunden" banner in Forschungs-Daten | — | Phonem or Raumklang run, headphones not plugged in | Shows with headphones plugged in, or in the Ohne Ton run |

Anything that blocks the canvas with **any other** message, or that
lets a session start silently in a state that looks wrong (e.g. the
"Aktiver Teilnehmer" card showing an arm you didn't set), is a defect
— note the exact wording and which step you were on, and send it back
rather than working around it.
