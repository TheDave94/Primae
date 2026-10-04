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

  *Open for this entry.* Whether to pin the rate (hide the picker or stamp it) and whether to pin one named voice.

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
