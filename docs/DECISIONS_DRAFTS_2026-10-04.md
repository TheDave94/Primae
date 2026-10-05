# DRAFTS for docs/DECISIONS.md — NOT APPLIED (2026-10-04)

> Shipped as a separate file in the `fix/protocol-stamp-speech` PR so it travels with the code it describes.
> Nothing here has been merged into `docs/DECISIONS.md`; that is a load-bearing doc and the text is David's to apply.

Drafted from David's corrected protocol of 2026-10-04 for his review. DECISIONS.md is a load-bearing doc, so these
are proposals only. The wording of the rationales is David's; the facts
under "What the code does" were measured at HEAD c7eb93ee (file:line).

---

## (a) New entry — D14

- **D14 — The sound arms sound while writing in EVERY writing part, including free-writing and the outcome
  passes; no sound-free pass exists, by design (David, 2026-10-04; implemented in #27, 2026-10-03).**
  David: *"children would not understand if not all letter-writing parts produce the sound."* Under this design the
  sound is part of the writing act itself in the sound arms, so a pass that suddenly went quiet would make that pass
  a different activity, not a second attempt at the same letter.

  *What it replaces.* The header's "Sound-off post-test" and the 2026-09-04 gate that idled playback in study-mode
  free-writing (removed in `90874e13`, formerly `TouchDispatcher.swift:356-359`). D8's outcome passes (pretest,
  untrained post-test and delayed cold probes; the trained letters' final training free-writing) are now produced
  WITH the arm's sound in the phoneme and spatial arms.

  *What the code does (HEAD).* Sound requires the pen to be on the letter path and moving:
  `shouldBeActive = isNearStroke && smoothedVelocity >= playbackActivationVelocityThreshold`
  (`TouchDispatcher.swift:422-424` at revision 4), floor 0 pt/s (`StudyComparisonSettings.swift:332`). There is no phase or probe check
  after the silent-arm return (`TouchDispatcher.swift:357-360`). Cold probes load the arm file like any letter
  (`TracingViewModel.swift:3288-3290`). The silent arm has no sound path at all (`TracingViewModel.swift:1117`).

  *Consequence to state in the thesis.* In the sound arms the outcome is measured with the arm's sound present.
  Because sound depends on the pen being on the letter path, it is also on-path feedback during the outcome trial,
  and only the sound arms get it. Ch.6 (`06-evaluation.typ:19`, `:29`, `:57`) and Ch.2 §2.5 must say this instead of
  "audio off".

  *Data.* Rows recorded before #27 reached the device were produced sound-off. The export carries no build or
  protocol field (`ParentDashboardExporter.swift:88-95`, `:228`), so the cut-over must be recovered from `recordedAt`
  against the install log.

---

## (b) New entry — D15

- **D15 — The spoken content is IDENTICAL in all three arms (David, 2026-10-04; implemented on branch
  `fix/protocol-stamp-speech`, protocol revision 4).** ("Instructions only" was a supervisor paraphrase of this rule,
  withdrawn the same day.)
  David: *"children cannot read; the voiceover is the same for every child so it cannot bias the results."*

  *What the speech actually is (measured, not assumed).*
  - **Live text-to-speech, not a recording.** `AVSpeechSynthesizer` (`SpeechSynthesizer.swift:40-82`). No recorded
    prompt files are bundled: `Resources/Prompts/` holds only `tap.wav`, `tap_wrong.wav` and `tick_stroke.wav`, so
    `PromptPlayer.play` always falls back to `speech.speak(fallbackText)` (`PromptPlayer.swift`, `play(_:fallbackText:)`).
  - **Voice.** The first installed German voice of `.enhanced` quality, else the first German voice, else the
    `de-DE` system default (`SpeechSynthesizer.swift:57-63`). It is chosen from whatever the device has installed,
    so it is a property of the iPad, the same for every child on that iPad. Which voice the study iPad resolves to
    is UNMEASURED.
  - **Rate 0.42** (`:48`), **pitch multiplier 1.05** (`:55`), **volume 0.9** (`:78`).
  - **The rate can be changed by the proctor in the study build.** The "Sprechgeschwindigkeit" picker offers
    Langsam 0.36 / Normal 0.42 / Schnell 0.50 (`SettingsView.swift:139-148`) and persists it. The stored value is
    applied only when the Settings screen appears (`SettingsView.swift:466-468`), so after a relaunch the rate is 0.42
    until Settings is opened. The rate is not exported.

  *What the study voiceover consists of (revision 4).*
  - **Spoken, identically in all three arms:** "Schau genau hin." (observe, once per observe phase, before the sound
    arms' observe sound starts), "Jetzt du." (guided), "Und jetzt ganz allein." (free-writing), "Probier's nochmal"
    (when the pen leaves the canvas in guided), and the end-of-set "Super gemacht!". The prompt phrases are filtered by
    construction in `StudyVoiceoverPromptPlayer.studySpokenKeys`; "Probier's nochmal" reaches every arm through the
    same real synthesiser.
  - **Not spoken, in any arm:** the score-dependent praise tiers (unreachable in study mode, as before), retrieval and
    paper-transfer phrases.
  - **Non-speech sounds (stroke tick, end-of-set chime) follow the arm:** the phoneme and spatial arms hear them, the
    silent arm does not. The tick existed at baseline but was inaudible in study mode until #27 turned speech on; the
    end-of-set chime was added in #27.
  - **No cue on a cold-probe landing** (it lands in free-writing, not observe), in any arm.

  *Open for this entry — RULED (supervisor ruling, 2026-10-05):* a study build fixes the rate at
  `SpeechRate.standard` (0.42) and hides the "Sprache" picker (`SettingsView.swift`, `#if !STUDY_BUILD`) — not
  merely the default, the only value a study session can speak at, regardless of anything stored on the device
  from earlier testing. The voice is NOT pinned by identifier: it is displayed, read-only, in the research
  dashboard (`ResearchDashboardView`, behind the parental gate — `SpeechVoiceInfo.dashboardText`), for the proctor
  to record at session start, and it is not exported. Unchanged from the open question: the voice still depends
  on what is installed on the one study iPad (`AVSpeechSpeechSynthesizer.init`'s enhanced-then-first-German-then-
  de-DE fallback, `SpeechSynthesizer.swift:57-63`) — a hard identifier pin was considered and rejected because it
  fails or falls back on a device without that voice, which the display approach does not risk. **[DAVID]** *Whether
  this ruling is the final word for the thesis write-up, or whether a named-voice pin is still wanted once the
  study iPad's resolved voice is known.*

---

## (c) Replacement for `docs/DECISIONS.md:7`

**Study design (locked 2026-05-29; third arm redesigned 2026-07-06; sound and voiceover revised 2026-10-04).**
Three-arm between-subjects pilot: phoneme sonification / spatial sonification (pen position → pitch + pan on a
neutral carrier; supersedes the engagement-matched arbitrary-sound arm, see D2) / silent control. N≈40
kindergarten/Vorschule. Single session 10–20 min. In the sound arms, writing produces the arm's sound in every
writing part, including free-writing and the outcome passes (D14), and the sound plays for the whole observe
animation; the silent arm writes in silence throughout. All arms hear the same voiceover (D15). Framed as a pilot
throughout. *(Header brought current 2026-09-04; it had still named the arbitrary-sound arm. Revised 2026-10-04: it
had said "Sound-off post-test".)*

---

## Also affected, NOT drafted here

- **D9 (pre-task demonstration).** In a study session the sound arms now hear their sound for the WHOLE observe
  animation (P4, revision 4), which replaces the 2 s demonstration window in observe
  (`TracingViewModel.claimWholeObserveSound`). The steady-carrier ruling of 2026-09-18 still holds: neutral rate, centre
  pan and zero pitch, with nothing coupled to the animated dot. D9's "2.0 s window" text needs David's revision.
- **D8.** The outcome passes are produced with the arm's sound present in the sound arms (D14).

---

## (d) D9 revision — the whole-observe sound replaces the 2.0 s demonstration window (drafted 2026-10-05)

> Facts measured at `bf4a5cbe` (main, protocol revision 4), file:line. **[DAVID]** marks every sentence whose
> wording or rationale must be David's; nothing marked so is a proposal of substance, only a placeholder.
> Not applied to `docs/DECISIONS.md`.

**Proposed addition at the end of D9, after "Correction 2026-09-18":**

**Revision 2026-10-04 (protocol revision 4, PR #34) — in a study session the sound arms hear their sound for the
WHOLE observe animation; that replaces the 2.0 s demonstration window. The steady-carrier ruling of 2026-09-18
stands.**

- **[DAVID]** *Why the window was replaced — David's own words, one or two sentences.*
- **What replaced it.** On a study load that lands in observe, `claimWholeObserveSound(for:)`
  (`TracingViewModel.swift:2396`) decides whether the arm gets the whole-observe sound; when it does,
  `armPreTaskDemonstration` is NOT called for that load (`TracingViewModel.swift:3386-3389`). The sound starts once,
  after the observe instruction: `armWholeObserveSoundAfterCue` (`TracingViewModel.swift:2452`) waits
  `observeCueToSoundGapSeconds`, 2.0 s in production (`TracingDependencies.swift:244`), then calls
  `startObservePhaseAudio` (`TracingViewModel.swift:2371`). It does not start if observe has already been left or the
  arm changed in the meantime (`TracingViewModel.swift:2458-2461`).
- **Steady, as ruled 2026-09-18.** `startObservePhaseAudio` sets neutral rate and centre pan
  (`TracingViewModel.swift:2374`) and, for the spatial carrier, zero pitch (`:2376`) before playing; nothing couples
  pitch or pan to the animated dot, and touch is disabled in observe (comment at `TracingViewModel.swift:2363-2370`).
  The 2026-09-18 ruling — a steady carrier, no sweep — is therefore unchanged; only the length moved, from a fixed
  2.0 s window to the observe animation.
- **Length is no longer matched by construction.** The old window was capped for both arms by
  `PreTaskDemonstration.duration` = 2.0 s (`PreTaskDemonstration.swift:68`). The whole-observe sound lasts as long as
  the observe animation does after the 2.0 s gap, in both sound arms alike. **[DAVID]** *Whether "same length" in the
  2026-09-18 correction now reads "same window — the observe animation" — David's formulation.*
- **Where the 2.0 s window still runs.** `claimWholeObserveSound` returns false — and the load falls back to
  `armPreTaskDemonstration` — for: the spatial arm with the researcher-only axis-sweep switch on
  (`TracingViewModel.swift:2398`, `StudyComparisonSettings.spatialAxisDemonstration`, `StudyComparisonSettings.swift:233`,
  off by default); and a condition already demonstrated under the "Einmal pro Kondition" switch
  (`TracingViewModel.swift:2399-2402`, key `de.flamingistan.primae.comparison.oncePerCondition`,
  `StudyComparisonSettings.swift:404`, off by default). The silent arm gets no sound in either path
  (`TracingViewModel.swift:2397`).
- **Order of what the child hears.** "Schau genau hin." first (`TracingViewModel.swift:3469-3476`, every arm), then the
  arm's sound after the 2.0 s gap. **[DAVID]** *Whether the D9 rationale ("both arms taught, neither singled out")
  needs a sentence about the cue preceding the sound.*
- **[DAVID]** *Which sentences of D9's original body ("Both are capped by the same 2.0 s window", lines 119-121 of
  DECISIONS.md) are marked superseded, and how.*

## (e) D8 — one-line note (drafted 2026-10-05)

> **Note 2026-10-04 (D14):** D8's measure is unchanged, but in the phoneme and spatial arms the outcome passes it
> scores are now produced with the arm's sound present — the silent-arm return is the only arm check before the
> coupling (`TouchDispatcher.swift:355`), and a probe whose arm recording is missing is refused
> (`TracingViewModel.probeArmAudioMissingReason`). **[DAVID]** *Whether this note belongs in D8 or only in D14.*
