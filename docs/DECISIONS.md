# Decisions — Primae pilot study

**Purpose.** The single decision ledger for the pilot study: locked decisions, open design decisions (D-series), their evidence bases, and the design constraints that govern them. Read this for *why* the pilot is shaped the way it is.

Companion docs: `docs/ROADMAP.md` holds the *work* (pilot freeze items H1–H6, known issues/residuals); `docs/PROJECT_STATUS.md` holds the *capability census*; `docs/SOUND_PRODUCTION_SPEC.md` holds the sound-asset *production procedure*. This file holds *decisions*. (Consolidated from the former `PILOT_READINESS.md`, 2026-06-20.)

**Study design (locked 2026-05-29; third arm redesigned 2026-07-06).** Three-arm between-subjects pilot: phoneme sonification / spatial sonification (pen position → pitch + pan on a neutral carrier; supersedes the engagement-matched arbitrary-sound arm, see D2) / silent control. N≈40 kindergarten/Vorschule. Single session 10–20 min. Sound-off post-test. Framed as a pilot throughout. *(Header brought current 2026-09-04; it had still named the arbitrary-sound arm.)*

**Governance (David, 2026-05-30).**
- No in-app consent / minor-assent UX required; KUG ethics does not require committee approval for this pilot. → consent UX is NOT a freeze item.
- All design decisions are David's; supervisors expected to follow sound reasoning (no external approval gate). Quality control is the soundness of the design itself — there is no committee backstop, so the reasoning must hold.

---

## The governing constraint (from the thesis prose, §2.6)

The thesis commits the app's audio to four things and **deliberately leaves the acoustic coupling parameter unspecified**: content = the **phoneme**; timing = **during tracing / real-time / continuous**; coupling = **to the movement of the trace** (parameter unnamed — "velocity-coupled" was deliberately edited out to "trace-coupled"); form = **Anlaut/no-schwa** (sustained continuants, clean-burst stops).

**The load-bearing constraint (§2.6, the matching discipline):** for the phoneme-vs-arbitrary contrast to isolate phonemic content, the phoneme arm and the arbitrary-sound arm must be **matched on every property of the audio — timing, and in particular any coupling of the sound to the movement of the trace — so the only difference is whether the sound is the letter's phoneme.**

Implications:
- Whatever the coupling is (current rate+pan, or rate+pan+pitch), it must run through the **same shared code path** for both the phoneme and arbitrary arms. The app's architecture already supports this: both arms call the same `setAdaptivePlayback`; only `activeAudioFiles(for:)` returns different files. The shared-path architecture and the matching discipline align perfectly.
- The silent arm has no audio regardless.

---

## Locked decisions

- **D1 — Arm structure: audio-only-varies.** Every participant gets the SAME pedagogical flow; the three arms differ ONLY in audio (phoneme / spatial / silent — the middle arm was arbitrary-sound until 2026-07-06). NOT a crossed pedagogical×audio design. Simplifies the arm build to swap-enum + branch-audio.
- **D5 — `direct` phase: CUT (move to three-phase `observe → guided → freeWrite`). SUPERSEDED 2026-09-16 — the four-phase flow is KEPT; the Direct phase stays.** Originally decided on a six-paper both-sides evidence read (see "Evidence base for D5"); status carried since 2026-09-04 as "decided, NOT executed," naming the fork between this entry and the shipped four-phase app. David's ruling closes the fork by keeping the app as built, not by executing the cut: the app has shipped the Direct phase since `559a1df` (2026-04, "Add directionality teaching phase between observe and guided"); two thesis chapters (Ch.3 §"The learning flow", Ch.6 §"Randomisation and apparatus preconditions") are already written around the four-phase flow; the pilot instrument is verified working on the device on this flow; and the traced process measures (stroke count, order, reversed-direction) are provably uncontaminated by Direct-phase tapping — `tapDirectDot` (`TracingViewModel.swift:1727`) never touches `activePath`, `freeWriteRecorder`, or `RawTraceStore`, which come exclusively from the FreeWrite phase that Direct-phase taps never reach. Executing the cut instead would mean ~12 Swift files, two docs, and tests, plus rewriting Ch.3 and Ch.6, then re-verifying the instrument — to make a working, already-verified pilot match a decision made once and never executed. If the Direct phase turns out to matter to the outcome, that is a finding for the main study, not a blocker for this pilot.

- **D8 — Primary accuracy outcome: order-invariant spatial deviation
  via STROKE CORRESPONDENCE, not shape normalisation and not discrete
  Fréchet on a concatenated path.** SUPERSEDES an earlier same-day
  design (symmetric Hausdorff over the whole trace, `da83821`–`b9f9d16`)
  that was itself a correction of the original primary outcome (raw
  discrete Fréchet over the whole concatenated trace, which penalised a
  spatially correct letter traced in an unusual stroke order).
  Two shape-normalisation approaches were explicitly REJECTED for this
  outcome: Procrustes analysis (rotation/scale fitting) and whole-trace
  Hausdorff. Reasoning: scale and rotation are already controlled by
  this task's design — a fixed reference and a defined canvas — so
  normalising them buys nothing, and rotation-invariance is actively
  WRONG here (a letter drawn upside down is an error, not a nuisance
  parameter to fit away). Whole-trace Hausdorff was order-invariant at
  the point-cloud level but still discarded stroke IDENTITY entirely —
  it could not distinguish "every point is near some reference point"
  from "each of MY strokes corresponds to one of THE REFERENCE's
  strokes," which is the invariance this study actually needs.
  The outcome measure is now `StrokeProcessMeasures.spatialDeviation`
  (`StrokeProcessScorer.analyze`): each traced stroke is matched to its
  best-fitting reference stroke — order-invariant by construction, since
  matching decides pairing, not arrival order — then discrete Fréchet
  distance (Eiter & Mannila 1994) is measured WITHIN each matched pair.
  The primary outcome is the mean of the matched pairs' distances.
  Fréchet is NOT retired by this redesign — its earlier "concatenated
  whole path" application is; the algorithm itself is now the
  within-pair engine.
  ONE computation now produces the primary AND the process secondaries:
  the recovered pairing IS `strokeOrder` (comma-joined matched-reference-
  stroke indices, e.g. "1,0" for a reversed-order two-stroke letter,
  with "-" for an unmatched extra stroke); a stroke-count mismatch
  (more or fewer traced strokes than the reference) IS `strokeCount`
  compared against the reference's own per-letter count; and per-pair
  orientation choice (each candidate pair tried both directions, cheaper
  wins) IS `reversedStrokeCount` — direction handled IN the pairing
  decision, not normalised away, because a reversed stroke is a process
  finding worth recording, not noise to erase from the distance.
  `PhaseSessionRecord.frechetDistance` (the RETIRED whole-path secondary
  from the previous design) stays declared and Codable for backward
  compat but is never populated going forward — the sequence signal it
  used to approximate is `strokeOrder`/`reversedStrokeCount` directly
  now, which is exact rather than an inflated-distance proxy.
  LITERATURE: "stroke correspondence search" is the established term in
  the handwriting-RECOGNITION literature (not morphometrics, which
  doesn't treat this problem) — Kaneko et al.'s stroke-order-free/
  stroke-number-free method (USPTO 5,796,867), surveyed in "Comparative
  performance analysis of stroke correspondence search methods for
  stroke-order free online multi-stroke character recognition" (Front.
  Comput. Sci., Springer), which names five representative methods
  (cube search, bipartite weighted matching, individual correspondence
  decision, stable marriage, deviation-expansion). Bipartite weighted
  matching is the Hungarian/Kuhn-Munkres assignment algorithm; unequal
  stroke counts are the linear sum assignment problem with error-
  correction (LSAPE).
  SIMPLIFIED deliberately for this domain: exhaustive search over the
  small assignment space (bundled Latin letters have at most a handful
  of strokes) replaces the Hungarian algorithm — same optimum, no new
  dependency, runs once per phase completion, not per frame. Matching is
  FORCED to maximum cardinality (exactly `min(traced, reference)` pairs)
  rather than using LSAPE's tunable null-match cost — this domain has no
  calibration evidence for such a threshold, and the count difference
  alone already reports extra/missing strokes.
  Implemented: `14e20ff` on `feat/order-invariant-primary-outcome`,
  full rationale in `StrokeProcessMeasures.swift`'s header.

- **D9 — Pre-task sound-arm demonstration: both arms taught, not
  matched in form.** Both sound arms (`.phoneme`, `.spatial`) get a
  brief, scripted demonstration immediately before the tracing task
  begins for each letter — not audio-coupled to the child's own trace.
  The `.phoneme` arm gets a sound-letter exposure: the letter's own
  phoneme, played once. The `.spatial` arm gets an axis demonstration:
  a scripted pitch/pan sweep across the FULL canvas range (independent
  of the specific letter's own stroke shape, so every participant hears
  the same full-range sweep regardless of which letter loads first).
  Both are capped by the same 2.0 s window
  (`PreTaskDemonstration.duration`) and run through the same code path
  (`TracingViewModel.armPreTaskDemonstration`).
  The `.silent` arm gets NO audio added — but NOT nothing: the
  ghost-letter animation (`LetterAnimationGuide` /
  `AnimationGuideController`) that already precedes tracing in every
  arm, unchanged, IS its matched non-auditory equivalent. Every arm
  already got the same visual demonstration, of the same duration,
  before this change; the sound arms now layer their own scripted sound
  onto that same window, and silent doesn't.
  THE REASON THE DEMONSTRATION EXISTS AT ALL (unchanged by the
  2026-09-14 correction below, and still doing real work): a
  demonstration can INSTALL a crossmodal mapping rather than reveal one
  that was already there. If only one arm's tracing-task audio had been
  preceded by a demonstration, that arm's later coupling wouldn't just
  be "the arm's sound" — it would be "the arm's sound, already taught."
  That would confound the arm contrast with having been taught, not
  with what the sound itself is.

  **Correction 2026-09-14 (supervisor ruling, Option C) — "matched in
  duration and form" was the wrong specification; the implementation
  was not wrong.** Found by cross-checking the implementation against
  the thesis's stated symmetry claim, not the reverse: the code was
  read first (`PreTaskDemonstration.swift`,
  `TracingViewModel.armPreTaskDemonstration`), the five delivered
  phoneme recordings were measured directly (1.965–2.000 s, varying by
  letter because each is a real spoken instance of that letter's own
  phone), and only then was the thesis checked against those two facts
  — where "matched in duration and form" turned out to describe
  neither the code's guarantee (duration only) nor the audio (which
  cannot be form-matched without ceasing to be phonemic).
  - **Why they differ.** The two demonstrations do different jobs. The
    spatial demonstration exists to teach a mapping the child has no
    other way to infer: pen position maps to pitch and pan only
    because the pilot invented that mapping, so the demonstration must
    show the mapping's full range — which is why it is scripted,
    synthetic, and identical in shape on every letter. The phoneme
    demonstration exists to present the letter-sound pairing the study
    trains: the letter's own phoneme, spoken once, the same stimulus
    (modulo natural recording variation) the child hears coupled to
    their own trace immediately after. Forcing the phoneme
    demonstration into the spatial demonstration's shape — synthetic,
    uniform, identical regardless of letter — would mean replacing or
    distorting a real spoken sound to hit a shape, which manufactures
    exactly the kind of unnatural stimulus the phoneme arm exists to
    avoid. Forcing the spatial demonstration into the phoneme
    demonstration's shape — one static instance rather than a swept
    range — would stop it from demonstrating the mapping at all.
    Matching them in form was never achievable without breaking the
    thing each one exists to do.
  - **What survives.** The finding behind D9 — a demonstration can
    install a mapping rather than reveal one — still holds, and it is
    still what the demonstration is for: it is why BOTH sound arms get
    one, not only the arm whose mapping needs teaching. What the
    finding requires is that neither arm is uniquely taught; it does
    not require the two demonstrations to be identical in shape. "Both
    arms receive a demonstration, so neither is singled out for having
    been taught" is the operative claim now. "Matched in duration and
    form" is retracted as its restatement — duration alone is still
    true by construction (see above); form is not, and was never the
    part doing the work.
  - **The residual, disclosed, not dismissed.** The two sound arms'
    demonstrations differ from each other in duration and structure:
    the spatial sweep is fixed and synthetic, identical regardless of
    letter; the phoneme exposure is a real spoken recording whose
    natural length varies letter to letter (1.965–2.000 s measured) and
    is capped to the same nominal window, so its precise temporal shape
    is not uniform the way the sweep's is. This sits beside the
    C2-1 asymmetry below (the silent arm gets no demonstration at all)
    as a second, distinct asymmetry — both intrinsic to what each arm's
    manipulation actually is (a taught synthetic mapping vs. a trained
    natural sound vs. no sound), and neither is claimed to be
    controlled. State both in thesis Ch.6 §Threats to validity beside
    the acoustic-matching asymmetry (thesis ledger T2), as one
    paragraph's two halves, not as a solved problem.

  NOT trace-coupled: driven by a fixed scripted timeline
  (`PreTaskDemonstration.axisSweep`, or a single phoneme play), never
  by `TouchDispatcher`'s live-touch coupling — a distinct mechanism
  from the §2.6-governed tracing-task coupling. Cancelled the instant a
  real touch begins (`TouchDispatcher.beginTouch` →
  `TracingViewModel.cancelPreTaskDemonstration()`), so a scripted demo
  point is never still writing to `setAdaptivePlayback`/
  `setSpatialPitch` once the child's own trace starts driving them.
  Pilot-only: gated on `studyMode`, the same gate H2.1 uses to force
  phoneme content — casual, non-study sessions are unaffected.
  No new persisted field: this is real-time playback only, nothing is
  recorded to `PhaseSessionRecord` / the CSV export for it.
  Implemented: `PreTaskDemonstration.swift`,
  `TracingViewModel.armPreTaskDemonstration`, wired at both of
  `load(letter:)`'s fresh-letter entry points (`.observe` and
  direct-to-`.guided`); deliberately NOT wired at the H6 post-test
  freeWrite entry (`startPostTest`) — reaching that letter at all is a
  cold, untrained probe, and a demonstration would train the very thing
  the probe depends on not having happened.

  - *Limitation recorded 2026-09-05 (supervisor ruling C2-1), extended
    2026-09-14.* The silent arm receives no demonstration because it
    has no mapping to demonstrate; a blank interstitial would be a
    confound, not a control. All three arms therefore differ from each
    other in what precedes the tracing task: two get an
    interaction/exposure period the third does not, and — per the
    2026-09-14 correction above — the two that do get one differ from
    each other in it. Stated together in thesis Ch.6 §Threats to
    validity beside the acoustic-matching asymmetry (thesis ledger T2).
    No time-on-task cost: the demonstration is layered inside the
    observe window (two guide-dot cycles, 5–11 s on A F I L M) that
    every arm runs identically.
- **D10 — Stroke-correspondence matching-policy parameters: DEFERRED
  pending pilot data.** D8's exhaustive-search assignment forces
  maximum cardinality (exactly `min(traced, reference)` pairs always
  matched) rather than LSAPE's tunable null-match cost, and aggregates
  matched-pair distances by MEAN rather than MAX. Both are genuine
  policy choices with real alternatives, not settled facts — and both
  were made under time pressure, before any child had traced anything
  on the redesigned instrument.
  DECISION: do not tune these further now. The right calibration
  evidence — real traced strokes, real extra/missing-stroke patterns,
  real per-stroke distance distributions — does not exist yet and
  guessing a null-cost threshold or an aggregation function ahead of it
  would be exactly the kind of pre-data guess the pilot exists to
  replace. What WOULD settle it: pilot (or even pre-pilot calibration-
  round) freeWrite traces, scored under both the current forced-max-
  cardinality/mean policy and at least one alternative (e.g. a null-cost
  LSAPE variant, or max-aggregation), compared for whether they produce
  materially different spatialDeviation rankings or flag different
  strokes as extra/missing. If they agree in practice, the choice
  doesn't matter and the simpler policy (current) stays. If they
  diverge, that divergence — not a guess — is what should decide.
  Not blocking: the current, simpler policy is a defensible default
  (documented in `StrokeProcessMeasures.swift`'s header) and ships as
  the pilot's primary outcome as-is.

- **D11 — Confidence-calibrator history boost was fed the wrong
  instrument; fixed.** `ConfidenceCalibrator`'s practised-letter boost
  requires historical geometric form accuracy but was silently fed CoreML
  recognition CONFIDENCE (`LetterProgress.recognitionAccuracy`) at both
  call sites — no channel carrying real form-accuracy history existed
  anywhere in the codebase before this fix. Same class of defect as the
  resource-bundle bug that kept the CoreML model from loading (#13): the
  study's own outcome computed by the wrong instrument, silently, because
  nothing failed loudly. Consequence: a letter with >= 5 recognition
  samples averaging >= 80% CONFIDENCE (regardless of actual handwriting
  quality) triggered a 10% confidence boost that flows directly into
  `PhaseSessionRecord.recognitionConfidence`/`recognitionConfidenceRaw` —
  exported study outcome columns. Not deferrable — fixed immediately,
  not held for sign-off, on the same footing as any other correctness
  bug: `LetterProgress.formAccuracyHistory` (new field, populated from
  the freeWrite phase's own `WritingAssessment.formAccuracy`) now feeds
  the boost instead. Existing-records impact: this sandboxed seat has no
  device/simulator data to inspect directly; the app is pre-pilot (no
  participant enrolled yet), and the bug has been present since the
  CoreML recognition feature's earliest tracked commit
  (`e9c08f1`, 2026-04-29). `scripts/audit_form_score_confound.py` lets
  anyone with a real `progress.json` (e.g. pulled from a dev/test
  device) compute the actual affected letters and confidence inflation,
  rather than relying on this analytical bound.
  Implemented: `dfae2de` on `feat/order-invariant-primary-outcome`.

- **D12 — The score composite has a mathematical floor of 0.5 under the
  four-phase flow; `averageAccuracy` dropped from the export as a result
  (ruling, David, 2026-09-16).** `PhaseSessionRecord.score` is not one
  instrument across phase rows, and never was: `observe` and `direct`
  are always exactly `1.0` (completion markers, not measurements),
  `guided` is checkpoint-proximity COVERAGE, and `freeWrite` is
  `WritingAssessment.overallScore`, a weighted 4-dimension composite
  (Form 40% + Tempo 25% + Druck 15% + Rhythmus 20%) — see
  `ParentDashboardStore.swift:10-37`. `LearningPhaseController
  .overallScore` (`:108-111`) is the UNWEIGHTED MEAN of every active
  phase's `score`, so under the four-phase flow two of its four terms
  are unconditionally `1.0` and the composite has a mathematical FLOOR
  of 0.5 — a child who traces nothing correctly in `guided` and
  `freeWrite` (both 0) still yields exactly 0.5. It is not merely an
  average of incomparable quantities: it is systematically inflated by
  a fixed, uninformative floor. The four-phase flow is the
  `ThesisCondition` case named `threePhase`, a Codable-rawValue
  stability artifact whose `displayName` is "Vier Phasen"
  (`ThesisCondition.swift:16-18`) — read the case name as historical,
  not as a phase count. `.guidedOnly`/`.control` (single active phase)
  have no floor, because nothing else is in the average to dilute it.

  **What the floor does NOT touch, traced hop by hop 2026-09-16 rather
  than assumed.** No outcome Ch.6 of the thesis defines is affected.
  Ch.6 §"Outcome measures" defines the primary outcome
  (`spatialDeviation`) and the secondaries (`strokeCount`,
  `strokeOrder`, `reversedStrokeCount`) as computed by stroke
  correspondence directly from the raw persisted trace (D8) — a
  separate computation path from `score`/`overallScore`, sharing no
  code with it. The exporter's own cross-arm FreeWrite aggregates
  (`averageFreeWriteScore_<arm>`, `letterByArm`, `letterByAudioArm`)
  already filter to `phase == .freeWrite` only, fixed in the 2026-09-04
  audit for exactly this reason. The floor reaches neither. Its other
  consumer, `LetterProgress.bestAccuracy`, is likewise not a confound:
  it drives `LetterScheduler`'s adaptive priority and
  `LetterPickerBar`'s partial-progress tint — operational and
  child-facing UI, never an exported outcome — and D1 holds the
  pedagogical flow constant across all three pilot audio arms.

  **The one place it did reach, and the ruling.** The per-letter
  `averageAccuracy` column was emitted unfiltered by phase AND by arm,
  fed by `PhaseTransitionCoordinator.swift:384`'s `Double(vm
  .phaseController.overallScore)` — the floored composite itself. It
  read like a real accuracy measure and was not one, a latent trap for
  anyone running exploratory analysis on the CSV beyond the three
  pre-specified contrasts. DROPPED from the CSV header and the matching
  per-letter row in `ParentDashboardExporter.swift` (`:213`), with
  `docs/APP_DOCUMENTATION.md`'s export-schema appendix updated to
  match. The underlying `LetterAccuracyStat.averageAccuracy` model
  property was deliberately LEFT INTACT — it still backs the
  parent-facing `ParentDashboardView` and `ResearchDashboardView`,
  neither of which reads the CSV, so nothing broke there. Guarded by
  `csvDoesNotContainRemovedAverageAccuracyColumn`
  (`PrimaeNativeTests/ParentDashboardExporterTests.swift:37`), which
  fails if the column returns. Implemented: `7305c55` on
  `feat/order-invariant-primary-outcome`; CI-verified (run
  `35109807497`, all 7 jobs).

  **Recorded late, deliberately noted.** This entry was cited from
  eight places in the repo before it existed — `ParentDashboardStore
  .swift:36`, `LearningPhaseController.swift:96-97`,
  `ParentDashboardExporter.swift:108`, and
  `PhaseTransitionCoordinator.swift:40`/`:533` in code;
  `APP_DOCUMENTATION.md:1425`/`:1498` in docs; and
  `ParentDashboardExporterTests.swift:33` — plus the handoff. So the
  ledger carried a hole exactly where its own series already skipped
  the number. Written 2026-09-16 to close it, not drafted then.

- **D13 — Sound delivery is matched across the two sound arms in
  LEVEL and in MOVEMENT-CONTINGENCY (rulings AE-1, AE-2, AE-2a, AE-2b,
  David, 2026-09-06).** Three points, each with the argument that
  decided it, because the next reader should see why:
  1. *Per-file loudness normalisation, RMS over the steady state.*
     Every file the engine loads is played at the gain that brings its
     RMS to one target — the bundled spatial carrier's own RMS (0.1463
     full-scale), so the verified carrier is unity and the phonemes are
     matched to it. RMS, not peak: peak equalises the loudest sample,
     and fricatives and vowels have very different crest factors, which
     is the vowel/continuant line the letter set spans — peak would
     leave most of that bias in place. Steady state, not the whole
     file: onset and release drag a phone's average down by an amount
     that also differs between fricatives and vowels. Measured once per
     file (20 ms windows within −6 dB of the loudest window), clamped
     ±18 dB and logged when the clamp bites (`AudioEngine+Loudness`).
     Side effect worth stating: this also removes the between-arm level
     difference the thesis records as a limitation.
  2. *Both sound arms go silent when the pen is not moving.* The
     argument for the other side is real: the carrier encodes position,
     not movement, so a held tone during a pause is still "true". It
     lost to this: if the phoneme arm fell silent on a pause and the
     spatial arm did not, the arms would differ in something other
     than what the sound carries — the same class as the silent-arm
     confound fixed the same day. The manipulation is what the audio
     encodes, not whether audio is present. The spatial mapping loses
     nothing: it resumes the moment the pen moves, at the pitch and pan
     of wherever the pen now is; a child who pauses and hears nothing,
     then moves and hears the position, gets a cleaner mapping than one
     who hears a held tone that means nothing during the pause.
     Mechanism: a pen that stops sends no samples, and only a sample
     could request idle, so every active sample arms a 0.12 s stall
     timeout (`PlaybackController.armStallIdle`); pinned by
     `bothSoundArms_stopOnPause_resumeOnMove` for both arms.
  3. *Rate does not move pitch — verified, not changed.* The ruling
     AE-1 premise ("playback-rate pitching contaminates the spatial
     arm's pitch with stroke velocity") does not hold: rate and pitch
     both go through the one `AVAudioUnitTimePitch` (pitch-preserving
     time-stretch; independent cents), no varispeed path exists, and
     Ch.4 states it. The rate coupling is the matched design across both
     sound arms and stays. Driven rather than read:
     `testTimePitchRate_doesNotMovePitch_varispeedDoes` (hardware suite)
     renders 440 Hz through the unit at rates 0.5/1/2 (→ 440), ±1200
     cents (→ 880/220) and through a varispeed unit at 2.0 (→ 880, the
     confound the ruling describes).
  Implemented: `605f8f0` (1, 3) and the follow-up commit (1 steady
  state, 2) on `feat/order-invariant-primary-outcome`.

---

## Open design decisions (David's, no external gate)

| # | Decision | Why it matters | Status |
|---|----------|----------------|--------|
| D2 | Arbitrary-sound arm design: what IS the engagement-matched, non-phonemic, coupling-matched control loop? | A wrong control confounds the central phoneme contrast — no committee backstop. Must be loopable + speed-couplable; must run the identical coupling path (matching discipline). Liking-match informed by the listening study. | **SUPERSEDED 2026-07-06** — the third arm is spatial sonification (pen Y → pitch over 220–880 Hz on a 440 Hz triangle carrier, X → pan, same rate/pan coupling; `PilotAudioCondition.spatial`, ROADMAP H4, thesis Ch.4). The per-letter abstract-sound design below (resolved 2026-06-20) is retained for the full-scale study's fourth arm (thesis Ch.7), not the pilot. *(Row brought current 2026-09-04.)* |
| D3 | Post-test outcome design: what each of the 3 modes measures; scoring; recognition distractor choice; production prompt (NB: a sound prompt in a sound-off test is a contradiction — resolve). Which is the PRIMARY outcome. | Defines what the study measures. | **CLOSED 2026-09-04 against D8** (thesis ledger T1): the pilot's outcome is letter production only — primary = order-invariant spatial deviation by stroke correspondence, secondary = stroke count/order/direction, writing time read jointly; recognition and letter–sound tests are not in the pilot (H6 re-scoped 2026-09-03). |
| D4 | Which outcomes to RUN in the pilot. Build-all-three decided (H6); *running* all three in a 10–20 min kindergarten session is a methods question (attention budget; multiple-comparison load on N≈40). Settings toggle moves this to pilot-run time; does not dissolve it. | Session feasibility + analysis validity | Build all three (decided); run-selection deferred |
| D6 | Stop-consonant under continuous looping. The loop+speed-couple principle works naturally for continuants (/m/, /f/, /l/ stretch and loop). Stops (/b/, /k/, /t/) have no steady state to loop/stretch. What does the phoneme arm play for stops? (Also applies to the arbitrary loop.) Intersects the no-schwa spec. | Phoneme-arm fidelity for ~⅓ of letters | OPEN — sound-domain, likely Groß-Vogt |
| D7 | Pitch coupling. The `pitchCents` knob is wired but undriven. The thesis prose leaves the acoustic parameter unspecified, so adding pitch is **fidelity-permissible** (neither described nor contradicted) — IF applied identically across phoneme+arbitrary arms (matching discipline). | Intervention enrichment with documented multi-parameter caveat | RESOLVED 2026-05-30 — **pitch IN the pilot.** Rationale: (a) fidelity-permissible per thesis prose; (b) closest same-age precedents — Ecalle 2021 (5yo, trajectory→pitch+brightness, sonification group beat controls) and Groß-Vogt 2024 (first-graders, pen-y→pitch) — both used pitch without reported harm; both FULL-read and already cited in §2.6; (c) no contraindication in the coupling sweep (see *Evidence base for D7* below); (d) already wired (`pitchCents` knob). **CONDITIONS (non-negotiable):** (1) **matching discipline** — identical pitch coupling in BOTH phoneme and arbitrary arms, only the audio file differs (the shared `setAdaptivePlayback` path makes this automatic); (2) **honest framing** — in Ch.5/methodology, pitch is a design choice consistent with precedents, NOT an evidence-backed component; (3) **documented limitation** — the pilot intervention is a three-parameter coupling (rate+pan+pitch), so an effect cannot be attributed to any single parameter; single-parameter isolation is an explicit future-study direction. |
| D7-sub | Pitch mapping target — `pitchCents` is wired but what movement parameter drives it is undecided (y-position? curvature? something else?). | Defines the pitch axis of the coupling | **DECIDED BY IMPLEMENTATION, not a fresh call — ledger corrected 2026-09-11.** Pen Y, linear-in-cents (`SpatialSonification.pitchCents(forNormalizedY:)`, called from `TouchDispatcher.swift` via `setSpatialPitch`). This entry said "OPEN — decide at build time" after build time had already decided it; nobody had come back to close it. The "matched across arms per D7 condition (1)" clause in the prior wording is stale for a separate reason (the third arm is now spatial sonification, not an arbitrary-sound arm matched on every property — see the supersession notice at the top of this file) and is deliberately not rewritten here, since D7 condition (1)'s wording is thesis-adjacent and this correction is scoped to the sub-question this row is actually about. |

> Freeze items (H1–H6) that these decisions gate now live in `docs/ROADMAP.md` → *Pilot study — freeze items*.

---

## D2 — RESOLVED (2026-06-20), then SUPERSEDED (2026-07-06): arbitrary arm = distinct abstract sound per letter

> **Superseded for the pilot.** The pilot's third arm is spatial sonification (see the header and the D2 row above); nothing in this section describes the pilot artefact. Kept as the design record for the full-scale study's fourth arm.

> **Production detail: see [`docs/SOUND_PRODUCTION_SPEC.md`](SOUND_PRODUCTION_SPEC.md)** — the procedure companion for producing both pilot sound-asset sets (phonemes + abstract sounds) to one standard. This ledger keeps the *decision/status*; the spec keeps the *how*.

The arbitrary-sound control arm is a DISTINCT, NON-REFERENTIAL abstract sound per letter — structurally parallel to the phoneme arm (unique sound per letter), differing from it in exactly ONE dimension: whether that per-letter sound is a phoneme or a meaningless designed sound.

Rationale: This isolates the variable of interest (phonemic vs. non-phonemic coupled sound) while controlling for letter-DISTINCTNESS. A single shared sound (rejected) would confound non-phonemic-ness with non-distinctness — the phoneme arm gives each letter a distinct anchor, so the control must too. A small assigned bank (rejected) introduces un-pre-registered sound-collision variance. Letter-associative (Affe/Auto, rejected) risks teaching the letter via Anlaut association (covert second intervention) AND can't cover the full alphabet coherently (no unambiguous associative sound exists for many letters).

Downstream commitments (NOT yet done):
- ~[N] abstract sounds to DESIGN (one per letter in the pilot set): non-referential, mutually distinct, distinct from the phonemes, and sustainable under continuous time-stretch/loop (same steady-state constraint as the phonemes — D6-adjacent).
- ENGAGEMENT-UNIFORMITY is the validity burden: the set must be perceptually matched (no sound accidentally more/less engaging than the phonemes or each other). This is where Groß-Vogt's sonification expertise applies — D2's DECISION is made; the EXECUTION (designing perceptually-matched sounds) is the Groß-Vogt ask.
- ACCIDENTAL-MEANING AUDIT before the pilot: naive-ear pass over the full set to flag any sound that evokes a word/animal/object (which would re-introduce Anlaut contamination). Pre-pilot QA step.
- H4 wiring (drop-in once sounds exist): the arbitraryAudioFiles slot is built and waiting (commits 279d553/b212e82); H4 sources the assets into it.

---

## Evidence base for D5 (`direct` cut)

Six papers read in full (both sides):
- **Merritt et al. 2020** (Frontiers): instructed stroke order ≤ self-directed for <4.5yo (recognition, novel symbols); effect gone by 4.5yo — below the pilot's ~6yo target. Off-population caution, not a rebuttal.
- **Bara & Bonneton-Botté 2018** (Percept Mot Skills): kindergarten (5y4mo) controlled trial. Visuomotor (motor practice of direction) > visual (arrows-only ≈ `direct`'s shown-not-practiced cue). The arrows-only group LOST. Benefit came from *practicing* direction, not being *shown* it → the work lives in `guided` (tracing), not `direct`.
- **Berninger et al. 1997** (J Educ Psychol): numbered-arrow stroke cues (≈ `direct`) effective only COMBINED with writing-from-memory, not alone; outcomes fluency/composition, not recognition; at-risk first-graders. Supports cues-fused-with-production, not a standalone cue phase.
- **Thibon et al. 2018** (Acta Psychologica; the app's own `direct` citation): purely DESCRIPTIVE (6–9yo kinematics, per-stroke motor programs); no efficacy claim. App §4.4 honestly says so.
- **Zemlock et al. 2018** (Reading and Writing): production > viewing for recognition; any symbol production helps (not stroke-order-specific). Supports having a production phase (`guided`/`freeWrite` already do).
- **Parkinson & Khurana 2007** (abstract only): stroke order primes recognition in ADULTS; may not transfer to children still varying their order.

**Conclusion:** No controlled evidence that a standalone, show-don't-practice, pre-tracing stroke-cue phase aids early letter recognition in the ~6yo regime. The well-supported finding is "motor production helps" — which `guided`/`freeWrite` already deliver. The two closest-analog conditions (Bara arrows-only, Berninger cue-alone) underperformed. By the best-practice standard, `direct` does not earn its place → cut to three-phase.

---

## Evidence base for D7 (pitch RESOLVED)

**Same-age precedents (FULL-read, already cited in thesis §2.6):**
- **Ecalle et al. 2021** (Hum Mov Sci): 5-year-olds, sonification group (trajectory → pitch + brightness) outperformed controls on letter learning. Pitch present in the intervention, no reported harm.
- **Groß-Vogt et al. 2024**: first-graders, pen y-position → pitch mapping. Pitch present, no reported harm.

**Adult-only coupling-sweep papers (abstract-only):** Maslovat, Effenberg & Schmitz 2018, Ghai 2019, Frid. Surveyed at abstract level for the evidence-AGAINST question; LOW/VERY-LOW Ch-2-relevance.

**Honesty note.** The verdict "keep speed-coupling; pitch defensible" rests on an **abstract-level literature survey** (adequate for the evidence-AGAINST question, since a contraindicating study would surface in its abstract), **NOT full reads**. The same-age justification (Ecalle 2021, Groß-Vogt 2024) IS full-read (already cited in the thesis). The adult pitch papers (Effenberg & Schmitz 2018, Ghai 2019) are abstract-only and would need full reads only if Ch.5 methodology cites them.

**Conclusion.** No contraindication for adding pitch to the coupling. Pitch joins rate + pan as the third coupling parameter, under the three D7 conditions (matching discipline, honest framing, documented multi-parameter limitation).

---

## Related separate workstreams (not the Primae freeze)

**Listening study — a SEPARATE app David will build.** Not a Primae mode. Tests non-phoneme sounds; out of scope for the Primae freeze.
- **Apparatus:** smiley scale (liking measure); possibly voiceover questions triggering speech-to-text OR audio recording to capture the child's spoken answer (for association/connection judgments). NB: STT on young children's speech is unreliable (phonology, noise, single-word utterances) — audio-record-for-later-human-coding is likely the safer primary method, STT a nice-to-have.
- **Design:** varies sound-to-letter **association strength** along a continuum (clearly-related → loosely-related) to find how loose a connection children still accept as "belonging" to the letter; **liking** measured orthogonally (not assumed to track association); small letter set; across sound categories (phoneme / nature-environment-animal / machine-city-instrument).
- **Origin:** David's original vision was multiple letter-associable sound categories per letter; deferred from the app because clearly-associable non-phoneme sounds couldn't be reliably sourced. The phoneme remains Primae's (and the pilot's) primary sound; other categories are an **evidence-gated future offering** contingent on this study.
- **Relationship to the pilot:** the liking data feeds the arbitrary-arm (D2) engagement-match selection. Note the control wants high liking-match; association-strength is a separate axis (a strongly letter-associable non-phoneme control would shrink the phoneme contrast — relevant to a future richer study, not this pilot's control).
- **Measurement-design caveat:** graded association judgments by young children are a real validity challenge (acquiescence bias, etc.) — a Seither-Preisler item when that app is built.
- **Status:** own document when built; this is the brief cross-reference.

**Thesis-relevant papers (deliberate §2.1/§2.2 recon + citation-candidate survey, 2026-05-30):**
- **Bara-2018, Zemlock-2018:** CONFIRMED REDUNDANT for Chapter 2 (existing cites cover their points). They remain load-bearing in this ledger only — Bara-2018 → D5 evidence base; Zemlock-2018 → production-helps frame.
- **Coupling-sweep papers (Maslovat, Effenberg & Schmitz 2018, Ghai 2019, Frid):** LOW/VERY-LOW Ch-2-relevance, NOT Ch-2-bound.
- **Seyll & Content 2022:** the survey's ONE find — integrated into §2.2 ¶4 as a single-sentence qualification of the variability prediction (committed separately in the thesis repo, `35a0419`).
- **No remaining Chapter-2 citation work pending.**

---

## Out of scope for the freeze
- Consent/assent UX (governance).
- Listening study (separate app, above).
- Post-thesis features (F1–F10, gated on thesis ship per ROADMAP).
- U5 Pencil-2 squeeze device validation (P3), U10 VoiceOver walkthrough (P3) — pre-existing P3, not pilot-blocking.

---

## Sequencing

No human-gated blockers remain (no ethics/committee dependency). Everything is build-David-controls or design-David-decides. The HIGH freeze items (arms H1–H3, arbitrary-sound H4+D2, P6 H5, post-test H6+D3 — all in `docs/ROADMAP.md` → *Pilot study*) are pilot-blocking. The `direct` cut (D5) is a separate scoped change. The design decisions D2 (arbitrary sound) and D3 (post-test outcomes) gate their respective builds and should be settled well — D2/D6 are the prime Groß-Vogt sanity-checks (sound domain); D3 is the prime Seither-Preisler item. The pitch question (D7) is RESOLVED (pitch IN the pilot, under three conditions); D7-sub (what movement parameter drives pitch) is CLOSED — pen Y, per the row above.
