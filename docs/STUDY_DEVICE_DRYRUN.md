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

`PrimaeUITests/StudyDryRunUITests.swift` — a real XCUITest target
(drives the actual app through the accessibility tree, same surface
VoiceOver uses; not a mock or a stub) — covers five of the things below
**when someone runs it**. **It does not run in CI** (corrected
2026-10-05; this said "CI-verified … every time CI runs"): both test
steps in `.github/workflows/ios-build.yml` pass
`-only-testing:PrimaeNativeTests`, so `PrimaeUITests` only COMPILES
there. It runs when it is run by hand — on the physical iPad, where all
7 passed on 2026-10-02 (see the device notes below). It covers: **enrolment**
("Neuer Teilnehmer" through to the "Neues Kind bereit" alert; no relaunch), **the
Vortest/Post-Test/Nachtest flow** (tapping a probe button and landing
correctly on the canvas, or getting a clear refusal alert instead of
silence), **a session completing** (a real canvas stroke through to
the phase indicator advancing), **a second enrolment preserving the
first participant** (the archive-and-replace flow, checked via the
participant count), and **the export containing both** (triggering a
real export and confirming the share sheet appears with the right
count behind it). These are exactly the things that have broken
silently on this project before — and since CI does not run them, they
are checked only when a human runs the suite.

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
- **All three audio arms, end to end** — CORRECTED 2026-10-01: this
  bullet used to claim the automated suite "does not switch arms".
  Measured 2026-09-21, `PrimaeUITests` runs ON THE PHYSICAL iPAD (bare
  `xcodebuild test -only-testing:PrimaeUITests -destination
  "platform=iOS,id=<UDID>"`), and both per-arm audio probes passed
  there — `testPhonemeArmRequestsAudioDuringObserve` and
  `testSpatialArmRequestsAudioDuringObserve` — each driving its arm via
  the audio override. What no XCUITest can do, on any destination, is
  LISTEN: the probes prove the arm requested the right asset, not that
  sound left the speaker. Section 6's per-arm listening pass is still
  David's. And a device UI-test run REPLACES the pilot artefact with a
  Debug-Study build (same bundle ID — `nm` cannot tell them apart), so
  reinstall Release-Study before any participant session.

Where a step below is now also covered by the automated suite, it says
so inline — that does not mean skip it on a real device dry-run, since
CI runs the suite on a simulator only (Layer 3 scopes to
PrimaeNativeTests; `PrimaeUITests` never runs there) and no automated
run anywhere proves the PHYSICAL experience; it means a failure there
is no longer a surprise waiting for the next manual pass to catch. The
UI suite can additionally be driven on the physical iPad from a
device-capable seat — see the audio-arms bullet above for what that
does and does not establish.

---

## 0 · Before you start (once, not per run)

- **Headphones connected.** Both the Phonem and the Raumklang arm need
  them, and since protocol r14 the session does not run without them:
  the canvas is replaced by "Studie kann nicht starten — Keine Kopfhörer
  verbunden …" until they are plugged in, and the red "Keine Kopfhörer
  verbunden" banner shows in the research tab. Ohne Ton doesn't need
  them, but leave them in for all three runs so the three are comparable.
- **Do Not Disturb on, no other audio app playing.** Turning the
  iPad's Do Not Disturb on and making sure nothing else is playing
  audio is still worth doing: another app's audio plays through every
  arm, and the research tab shows a banner when it detects some. Opening
  Control Center, a notification banner or the app switcher briefly
  puts the app's scene into `.inactive`. Since protocol revision 8
  (#47) that SUSPENDS the session instead of ending it: the stroke
  under the pen is cancelled, a pending free-write quiet window is held,
  the sound and the voice stop, an interrupted observe restarts from the
  instruction on return, and nothing is scored or recorded for the
  interruption. Only `.background` (leaving the app) still finalises a
  finished-but-not-yet-scored free-write
  (`TracingViewModel.scenePhaseDidChange`). Do Not Disturb does not
  block Control Center or the edge swipes, so a suspended trial is still
  possible; the interruption count is recorded on the row
  (`interruptions`).
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
3. Tap **"Neuer Teilnehmer."** (The same action is the rail's
   double-tap, then **"Nächstes Kind"**.) There is no share sheet: the
   outgoing child, if they did anything, is sealed to the on-device
   archive first and is part of the ONE combined export taken at the end
   (Section 6). It is also where a delayed-retest participant's id is
   later read from.
4. A confirmation appears: **"Neuen Teilnehmer beginnen?"** Tap
   **"Neues Kind starten."** If the outgoing child cannot be sealed, an
   alert **"Kein neues Kind begonnen"** says so and nothing is wiped or
   enrolled.
5. An alert reads **"Neues Kind bereit"** (arm re-derived, app ready).
   No relaunch is asked for or needed by enrolment itself. Enrolment
   loads the first trained letter **parked**, exactly as a fresh launch
   does: nothing plays and nothing animates until you start it, so the
   Vortests in Section 3 stay cold for every letter, the first trained
   letter included. (Fixed 2026-10-22, audit R-007: enrolment used to
   start that letter's observe at once, playing its demonstration and
   arm sound before its own Vortest.)

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
   away, tap the "Primae Studie" icon again). The relaunch is needed
   only because of the override ("Zuweisung geändert — die App muss neu
   gestartet werden" blocks the canvas until then); enrolling itself
   needs none. If you set no override, skip it.
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
2. The canvas shows a blank glyph — no ghost line, no demonstration.
   While you write, **no arm plays any sound** — every cold probe is
   sound-off in every arm since protocol r12 (2026-10-21; under r2-r11
   Phonem and Raumklang sounded here). If you hear the letter's sound or
   the carrier under the pen during a probe, that is a defect. No spoken instruction
   here: a probe phase has no phase-entry cue, so **you** tell the child
   which letter to write, by its letter name ("Schreib ein A"), in the
   same words for every child and every arm, and never by its sound.
   Write the letter once from memory.
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

- **Right after a fresh launch or an enrolment** (before any pretest
  was run), the app shows the **first trained letter, "parked"**: nothing is
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
- **What you hear, per arm (protocol revision 10, 2026-10-18; the timing
  is r5, the recorded voice r9, the phoneme files' mono 44.1 kHz format
  r10 — same recordings, same loudness):** the instruction is a bundled recording
  (voice Kiki, `phase_observe.mp3`, 1.25 s), identical in every arm.
  - **Phonem:** the recorded prompt **"Schau genau hin."**, then —
    **1.0 s after the prompt ENDS** (3.0 s after it started if no end is
    reported) — the guide-dot animation starts and, together with it, the
    letter's own recorded sound, **looping for the whole pass** and
    stopping when the phase moves on. The sound follows the dot as it
    follows the pen: rate from the dot's speed (a still dot plays on at
    the slowest rate), pan from its horizontal position.
  - **Raumklang:** the same prompt and the same start, with the
    synthetic carrier tone following the dot: rate from its speed, pan
    from x, **pitch from its height (y)**. It is no longer a steady
    held tone: r5 (#42) reversed the 2026-09-17 "Glissando weg" steady
    carrier for observe.
  - **Ohne Ton:** the recorded prompt **only** — the same words as the
    other two arms — then the guide-dot animation in silence, same
    timing as the other two arms.
- An observe phase that is interrupted (Control Center, banner, app
  switcher, opening the parent area) restarts from the instruction in
  every arm (r8), so the sound and the animation are never heard from the
  middle.
- **Check, every run: the prompt must FINISH before the animation and
  the arm's sound start** (the start is tied to the end of the
  recording, not to a fixed delay or to the iPad's speech-rate setting,
  which no longer applies to the five study phrases). **If the voice and
  the sound overlap, that is a defect — flag it.**
- The screen does not react to touch during this phase — that's
  correct, not a glitch.

### 4b · (removed 2026-09-18) — the tapping-points phase
- **This phase no longer runs.** It was "Direct (Richtung lernen)":
  numbered dots over each stroke's start point, tapped in order. David's
  ruling — "the whole tapping the points part should go" — took it out of
  the session, so a letter's flow is now **observe → guided → freeWrite**.
- **You should never see numbered dots during a session.** If you do, that
  is a regression worth reporting, not a step to work through.
- The section is kept, rather than deleted, so a proctor working from an
  older printout can find out what happened to the step they expected.
- Implementation note: the `LearningPhase.direct` case still exists (it is
  `Codable` and stored rows reference it); it is simply not in
  `LearningPhaseController.activePhases`, so no session runs it.

### 4c · Guided (Nachspuren)
- A faint ghost letter appears. Trace it with your finger or the
  Pencil.
- **This is where the arm's sound actually plays while you write:**
  - **Phonem / Raumklang:** sound is active only while the pen is on
    the path (near the expected checkpoint); since r3 there is no speed
    threshold. It speeds up / slows down and (Raumklang only) changes
    pitch with your vertical position and pans with your horizontal
    position. If you pause for 0.3 s it stops, and after a lift it is
    held for 0.8 s (a pen put back down inside that hold keeps the sound,
    r7), fading out over 0.4 s once it ends.
  - **Ohne Ton:** silent throughout, by design.
- **No haptics anywhere in this phase, in any arm.** Under study mode
  the haptic engine is a silent no-op (same substitution as 4b), so
  neither the per-checkpoint ticks nor the stroke-completion buzz that
  the casual app has actually fires — don't expect to feel anything.
- If your finger or the Pencil leaves the canvas bounds mid-stroke,
  the app shows a text toast reading "Probier's nochmal" and resets
  the current stroke so you retrace it from its start point, and the
  app SAYS "Probier's nochmal" (the recorded `retry_cue`, at most once
  per 3.0 s of touch time; it waits for an instruction still playing) —
  in all three arms alike, Ohne Ton included (spoken content is
  identical in every arm).
  That's the expected recovery path, not a defect. If one arm says it
  and another doesn't, that is a defect.

### 4d · FreeWrite (Selbst schreiben)
- Blank canvas, no ghost. Write the letter from memory.
- **The canvas is EMPTY of the Guided trace.** Since #27 (2026-10-03)
  no ink carries into FreeWrite: entering it clears the Guided stroke
  and any snapshot still fading from an earlier transition at once
  (`TracingViewModel.resetForPhaseTransition`:
  `let carriesIntoUnassistedTrial = phaseController.currentPhase == .freeWrite`
  and, on that branch, `lingeringInk = []`). The 5 s "lingering ink"
  still happens between Observe and Guided, where the outline is on
  screen anyway. **If you can see the Guided stroke on the FreeWrite
  canvas, that is a defect — flag it:** it is a trace the child could
  copy in the one unassisted trial.
- **The arms are NOT identical here, and that is the design (P2).**
  Phonem and Raumklang couple to the pen as in Guided, except that since
  r6 the sound follows the pen anywhere on the canvas, not only on the
  letter — if
  you hear NOTHING under either sound arm while writing, that is now
  the defect, flag it. **Ohne Ton stays silent** — if you hear the
  arm's sound there, that is a defect, flag it. (This bullet used to
  read "silent in all three arms": the freeWrite sound-off gate was
  lifted 2026-10-02.)
- **After you lift: nothing, under study mode** — except after the
  LAST trained letter of the set; see "End of the set" below. In the casual app a
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

After the third trained letter's FreeWrite, training is done. That
FreeWrite was **practice**, not the post-test (protocol r12,
2026-10-21; under r1-r11 it was taken as the trained letters'
post-test). **All five letters, the three trained ones included, get
their own cold post-test in Section 5.**

**End of the set — what you hear and see (protocol revision 9; since r7 only
a TRAINING pass ends the set, never a cold probe).** When
the LAST trained letter's FreeWrite is recorded in training
(`PhaseTransitionCoordinator`, `} else if vm.currentProbe == nil, vm.isLastLetterOfSet {`):
- **All three arms play the recorded "Super gemacht!"** — content is identical
  in every arm (`vm.prompts.play(.celebration, …)`; `.celebration` is in
  `StudyVoiceoverPromptPlayer.studySpokenKeys`).
- **No chime in any arm** (protocol r13, 2026-10-21; under r4-r12 Phonem
  and Raumklang played a short one). `StudyVoiceoverPromptPlayer` drops
  every sound effect, the stroke tick included.
- **Nothing appears on screen, in any arm.** The celebration overlay is
  queued, but a study build draws nothing for it: `SchuleWorldView`
  renders `case .celebration` as `EmptyView()` under `STUDY_BUILD`
  (`CompletionCelebrationOverlay` is compiled out).
- **The chevron stops advancing** — the set is over
  (`nextLetter()`: `guard !awaitingNextParticipant else { return }`).
  That is the hand-over signal: enrol the next child with the rail
  double-tap ("Nächstes Kind"). If the chevron still moves to another
  letter after the last one, that is a defect.

---

## 5 · Post-test (all five letters)

Long-press the gear → Forschungs-Daten → **"Post-Test (alle fünf
Buchstaben, nach dem Training)."** Five buttons, one per study letter,
trained and untrained alike (protocol r12, 2026-10-21; under r1-r11
only the two untrained letters were offered).

For each of the five:
1. Tap **"Post-Test starten: `<letter>`."** Drops straight to canvas.
2. Same as pretest: blank canvas, no ghost, no demonstration, single
   cold FreeWrite attempt, sound-off in every arm (as in Section 3). Repeating a probe, or starting a
   post-test before the child's set is complete, asks you to confirm
   (warned, never blocked; r8).
3. Long-press the gear, back to Forschungs-Daten, do the next
   letter.

That's the end of the session for this run.

---

## 6 · Confirming the data landed

Long-press the gear → **Datenexport** (third tab). Tap **"JSON
exportieren"** (or CSV). A share sheet opens with the combined file for every child on
this iPad, named `primae_progress_ALL_<date>_<time>_all<N>.json`
(`<N>` = children with data; the same for CSV/TSV). Save it to Files.
(Take this export ONCE, after the last child; the app keeps the newest
five copies in `Application Support/PrimaeNative/Exports/` for `devicectl`
retrieval, and deletes the temporary file once a share activity completes
(a leftover is swept at the next launch).)

You don't need a terminal to sanity-check it: open it in the Files app
preview, or in a text/spreadsheet app if you have one on the iPad. You
should be able to see:
- the participant ID matching the "Aktiver Teilnehmer" card (in the
  combined file, in that child's block),
- a header line naming `enrolledAt`,
- one row per **phase** completed, not per letter — each row carries
  its own `phase` (observe/direct/guided/freeWrite) and, for the cold
  probes, a `probe` column (pretest/posttest). Each cold probe (a
  pretest or post-test letter) opens straight into freeWrite, so it
  writes exactly **1 row**: **5 pretest rows** (one per letter) and
  **5 post-test rows** (one per letter, r12; 2 under r1-r11). Each of the **3 trained
  letters** writes **up to 3 rows** — one per phase it completed
  (observe, guided, freeWrite; `direct` no longer runs, see 4b) — all
  written together at that letter's freeWrite
  completion. That caps a clean run at **5 + (3 × 3) + 5 = 19 rows**,
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
outgoing participant (if the child did anything, it seals them to the on-device archive first, so
they stay in the combined export — cleared from the live stores only; a child who did nothing
is kept only in the export's enrolment block).

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
| Same screen | "Teilnehmer gewechselt — die App muss neu gestartet werden..." | You just did "Teilnehmer wiederherstellen" (the delayed-retest restore) and haven't relaunched yet; "Neuer Teilnehmer" no longer needs a relaunch | It shows after "Neuer Teilnehmer", or still shows after relaunch |
| Same screen | "Aufgenommene Anweisungen fehlen: …" / "…sind nicht die geprüften…" | Should never happen — the five recorded study phrases are bundled and pinned by `Resources/Prompts/MANIFEST.json` (r9) | Shows at all, on any run |
| Same screen | "Spatial-Arm ohne Trägerton..." | Should never happen — the carrier file is bundled | Shows at all, on any run |
| Same screen | "Phonem-Arm ohne Phonem-Aufnahmen für: ..." | Should never happen — all five recordings are bundled (H5 closed 2026-09-14) | Shows at all, on any run |
| "Buchstaben nicht geladen — Bitte die App neu starten." | — | Should never happen on a correctly built artefact | Shows at all |
| Red "Keine Kopfhörer verbunden" banner in Forschungs-Daten | — | Phonem or Raumklang run, headphones not plugged in | Shows with headphones plugged in, or in the Ohne Ton run |
| Full-screen stop, "Studie kann nicht starten" | "Keine Kopfhörer verbunden. In diesem Arm läuft die Sitzung nur mit Kopfhörern …" | Phonem or Raumklang run, headphones not plugged in (r14); goes away the moment they are | Shows with headphones plugged in, or in the Ohne Ton run |

Anything that blocks the canvas with **any other** message, or that
lets a session start silently in a state that looks wrong (e.g. the
"Aktiver Teilnehmer" card showing an arm you didn't set), is a defect
— note the exact wording and which step you were on, and send it back
rather than working around it.
