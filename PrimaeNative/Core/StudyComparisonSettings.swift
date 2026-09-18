// StudyComparisonSettings.swift
// PrimaeNative
//
// Researcher switches for the questions a supervisor raised on 2026-09-17
// WITHOUT resolving. Each entry below is one of those open questions, and
// each is a two-valued switch rather than a decision, on David's
// instruction: "for everything that has a ? implement it so it can be
// turned on and off in settings to be able to compare both options".
//
// So this file exists to make the comparison possible, not to pick a side.
// Every default is the CURRENT behaviour, so an untouched device behaves
// exactly as it did before this file existed — that is the property that
// makes the switches safe to add to a study device.
//
// WHERE THESE LIVE. Device config, not participant identity: like
// `studyMode`/`schriftArt`/the weights, they are deliberately untouched by
// `startNewParticipant`/`restoreParticipant`, which reset only the
// participant-scoped keys (`ThesisCondition.swift:180`). A comparison run
// is a property of the session being set up, not of the child.
//
// WHAT THEY ARE NOT. None of these is a study arm. The arms are assigned
// from the identifier and overridden through `ParticipantStore`; these
// switches change what the SESSION does, and any row produced under a
// non-default switch is a comparison run rather than pilot data. The
// researcher UI says so at the point of use.
//
// Persistence is `UserDefaults.standard` keyed on the
// `de.flamingistan.primae.` prefix, matching every other device setting.

import Foundation

/// The researcher comparison switches, read once per session at
/// `TracingDependencies` construction like the other device config.
enum StudyComparisonSettings {

    private static let prefix = "de.flamingistan.primae.comparison."

    /// How many times the observe demonstration plays before the phase
    /// advances. The supervisor's "einmal vorzeigen (vielleicht etwas
    /// langsamer)" — 1 is the new behaviour, 2 is what it was. The pass
    /// runs at `AnimationSpeed.slow` either way.
    static let observePassesKey = prefix + "observePasses"
    /// The value an untouched device runs, named so the default the
    /// STAMP compares against cannot drift from the default the getter
    /// falls back to. Same reason `soundGateRadiusFactorDefault` is
    /// named further down.
    static let observePassesDefault: Int = 1
    static var observePasses: Int {
        get { intValue(observePassesKey, default: observePassesDefault) }
        set { UserDefaults.standard.set(newValue, forKey: observePassesKey) }
    }

    /// Whether the study session speaks. The thesis removes spoken output
    /// in study mode outright ("no spoken prompts", 03-architecture.typ:73)
    /// and the code nulls the synthesiser to match
    /// (`TracingViewModel.swift:866-867`). The supervisor's "Voiceover??"
    /// asks whether that is right for this population; ON restores the
    /// casual app's spoken feedback so the two can be compared.
    ///
    /// Default OFF, i.e. the thesis behaviour.
    static let spokenFeedbackKey = prefix + "spokenFeedbackInStudy"
    static let spokenFeedbackInStudyDefault: Bool = false
    static var spokenFeedbackInStudy: Bool {
        get { boolValue(spokenFeedbackKey, default: spokenFeedbackInStudyDefault) }
        set { UserDefaults.standard.set(newValue, forKey: spokenFeedbackKey) }
    }

    /// Whether every child practises all five study letters rather than a
    /// counterbalanced subset of three. The supervisor's "jedes Kind alle
    /// 5 Buchstaben? Aber jeder Buchstabe nur einmal?" — ON is all five,
    /// once each; OFF is the counterbalanced three that
    /// 06-evaluation.typ:15 specifies, with the two untrained letters
    /// reserved for the post-test contrast.
    ///
    /// ON removes the within-child trained/untrained contrast, because
    /// there are then no untrained letters. The researcher UI states this,
    /// and so does the DATA (2026-09-17, was not true before): every row
    /// written under this switch is stamped `trainedSubset == "AFILM"`
    /// (`TracingViewModel.effectiveTrainedSubset`), the all-five case of
    /// `TrainedLetterSubset`, whose `untrainedLetters` is empty. Before
    /// that fix the rows still carried the assigned 3-subset, so an
    /// export of an all-five run asserted the child was untrained on two
    /// letters it had practised — a fabricated contrast, and the post-test
    /// offered those same two letters as the "untrained" probe.
    static let allFiveLettersKey = prefix + "allFiveLetters"
    static let allFiveLettersDefault: Bool = false
    static var allFiveLetters: Bool {
        get { boolValue(allFiveLettersKey, default: allFiveLettersDefault) }
        set { UserDefaults.standard.set(newValue, forKey: allFiveLettersKey) }
    }

    /// How many times each letter's full four-phase flow runs before the
    /// proctor advances. The supervisor's "Buchstabe dreimal?".
    /// Default 1, which is what the app does today.
    static let letterRepeatCountKey = prefix + "letterRepeatCount"
    static let letterRepeatCountDefault: Int = 1
    static var letterRepeatCount: Int {
        get { max(1, intValue(letterRepeatCountKey, default: letterRepeatCountDefault)) }
        set { UserDefaults.standard.set(max(1, newValue), forKey: letterRepeatCountKey) }
    }

    /// Whether the session cycles through all three audio conditions
    /// instead of running the one assigned from the identifier. The
    /// supervisor's "alle Konditionen oder nur eine Kondition".
    ///
    /// OFF is the between-subjects design of 06-evaluation.typ:7 — one
    /// arm per child. ON makes the design within-subject for comparison
    /// runs only; it is not a pilot configuration.
    static let cycleAllConditionsKey = prefix + "cycleAllConditions"
    static let cycleAllConditionsDefault: Bool = false
    static var cycleAllConditions: Bool {
        get { boolValue(cycleAllConditionsKey, default: cycleAllConditionsDefault) }
        set { UserDefaults.standard.set(newValue, forKey: cycleAllConditionsKey) }
    }

    /// Seconds to pause between one letter's flow and the next letter's
    /// observe entry. The supervisor's "Abstand zwischen Darstellung?".
    /// Default 0 — no pause, as today.
    static let presentationSpacingKey = prefix + "presentationSpacingSeconds"
    static let presentationSpacingSecondsDefault: Double = 0
    static var presentationSpacingSeconds: Double {
        get { max(0, doubleValue(presentationSpacingKey, default: presentationSpacingSecondsDefault)) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: presentationSpacingKey) }
    }

    /// Whether the trace coupling drives stereo pan. The supervisor's
    /// "auch ohne Panning".
    ///
    /// ON is the current behaviour and the default. OFF holds the bias at
    /// zero for the whole session, which makes the sound arms usable over
    /// a LOUDSPEAKER — the axis the thesis says is meaningless without
    /// headphones ("the pan axis is meaningless over a loudspeaker, the
    /// spatial arm requires headphones", 04-implementation.typ:44), and
    /// which `06-evaluation.typ:56` lists as a per-device precondition
    /// ("headphones are connected, since the pan axis of both sound arms
    /// and the pitch axis of the spatial arm are otherwise degraded or
    /// void"). Turning it off therefore removes a precondition rather than
    /// satisfying one: it is a comparison configuration, and the arms stop
    /// being matched on the axis 04-implementation.typ:66 declares them
    /// matched on.
    ///
    /// The pitch axis is untouched — the spatial arm is still the spatial
    /// arm. Only pan goes.
    static let panningEnabledKey = prefix + "panningEnabled"
    static let panningEnabledDefault: Bool = true
    static var panningEnabled: Bool {
        get { boolValue(panningEnabledKey, default: panningEnabledDefault) }
        set { UserDefaults.standard.set(newValue, forKey: panningEnabledKey) }
    }

    /// Whether the tracing phases draw the stroke start dots at all. The
    /// supervisor's "Punkte rausschmeißen" (throw the dots out) against
    /// "Punkte nur sehen?" (only see them) — the pair is drawn-vs-not,
    /// which is what the two notes actually describe.
    ///
    /// ON is the current behaviour and the default. OFF suppresses the
    /// dots in Observe and Guided; the Direct phase's NUMBERED dots are a
    /// different element with its own behaviour and are not affected —
    /// that phase is "tap the dots in order" and would have nothing left
    /// to tap.
    ///
    /// Note this is a presentation switch, not an interaction one: the
    /// guided dots are inert either way. Touch in Observe is disabled by
    /// the phase controller regardless.
    static let guidedDotsVisibleKey = prefix + "guidedDotsVisible"
    static let guidedDotsVisibleDefault: Bool = true
    static var guidedDotsVisible: Bool {
        get { boolValue(guidedDotsVisibleKey, default: guidedDotsVisibleDefault) }
        set { UserDefaults.standard.set(newValue, forKey: guidedDotsVisibleKey) }
    }

    /// Whether the spatial arm's pre-task demonstration runs the scripted
    /// axis sweep, or holds the carrier steady for the same two-second
    /// window. The supervisor's "Glissando weg" against the axis
    /// demonstration the thesis specifies.
    ///
    /// **RULED 2026-09-18: the sweep is OUT, and OFF is now the RULED
    /// behaviour rather than a divergence.** David: the glissando "was just
    /// distracting not helping", and the study contrasts **silence vs
    /// letter-unrelated sound vs phoneme**.
    ///
    /// UNDER THAT CONTRAST THE SWEEP WAS BREAKING THE SYMMETRY IT WAS
    /// WRITTEN TO SERVE. Its rationale was that a demonstration can INSTALL
    /// a crossmodal mapping rather than reveal one already there. But the
    /// phoneme arm's demonstration is a pure EXPOSURE — here is the sound —
    /// and the sweep made this arm's demonstration a MAPPING LESSON, a
    /// different KIND of event rather than the same event with different
    /// audio. A steady carrier for the same window is the matched
    /// demonstration: each arm presents its own sound, for the same length,
    /// teaching nothing beyond it.
    ///
    /// So `6fb7233`'s removal STANDS, and the machinery below survives only
    /// as a researcher affordance — a way to hear the old behaviour on the
    /// device — not as an open protocol question.
    ///
    /// **THE THESIS HAS NOT MOVED YET, and that is now the outstanding
    /// work.** Roughly 28 locations still describe the sweep as present,
    /// including `02-background.typ:107`; CLAUDE.md's "DON'T FIX THE
    /// SPATIAL GLISSANDO" block instructed the opposite of this ruling and
    /// is corrected; and **the thesis repo's currency check will block the
    /// reword.** MEASURED in `/Users/musicbox/repos/master-thesis`:
    /// `docs/design-facts.json` requires the literal string
    /// `"axis demonstration"` for `content/04-implementation.typ` and for
    /// the background chapter, and `scripts/check_design_currency.py`
    /// enforces it. Removing the phrase from the prose therefore fails that
    /// check until the fact is updated too — **update both together**, or
    /// the check will look broken for a reason that is actually correct.
    /// The same files live in the THESIS repo, not this one.
    ///
    /// OFF is the default anyway, because the default of every switch here
    /// is the behaviour the device had before the switch existed: that is
    /// what makes adding one safe to an enrolled study device, and it keeps
    /// an untouched device identical to the one the 2026-09-17 review saw.
    static let spatialAxisDemonstrationKey = prefix + "spatialAxisDemonstration"
    static let spatialAxisDemonstrationDefault: Bool = false
    static var spatialAxisDemonstration: Bool {
        get { boolValue(spatialAxisDemonstrationKey, default: spatialAxisDemonstrationDefault) }
        set { UserDefaults.standard.set(newValue, forKey: spatialAxisDemonstrationKey) }
    }

    /// How far from the next expected checkpoint the child's finger may be
    /// and still have the arm's sound allowed to play, as a MULTIPLE of the
    /// checkpoint radius — the supervisor's "Trigger boundaries".
    ///
    /// WHY THIS SWITCH EXISTS AND WHY IT IS THE ONE THAT MOVES. The
    /// supervisor's note is a noun phrase: it names the class of boundary
    /// that decides when the app responds to the child, and proposes no
    /// value. Five such boundaries exist and four of them are buried bare
    /// literals in four different files (the checkpoint hit radius,
    /// `StrokeTracker.swift:99`; this sound gate, `:100`; the 1.5 pt
    /// minimum move and the 0.22 EWMA, `TouchDispatcher.swift:31,36`; the
    /// 0.1/0.03/0.12 s playback debounces and the 22 pt/s floor,
    /// `TouchDispatcher.swift:33` + `PlaybackController.swift:75-77`).
    /// None was named, none was visible, none was switchable.
    ///
    /// This one and the velocity floor below are the two that are ANDed to
    /// produce the single boundary a child actually experiences — WHEN THE
    /// LETTER'S SOUND STARTS — so they are the pair that makes "are these
    /// boundaries right?" answerable by moving them. They are two switches
    /// and not one because they are ANDed: a run that moved both at once
    /// could not attribute what changed.
    ///
    /// THE MEASUREMENT THAT SET THE DEFAULT'S RANGE, taken 2026-09-17
    /// against the five study letters (`TrainedLetterSubset.studyLetters`
    /// = A F I L M), read from `Resources/Letters/Regular/*/strokes.json`
    /// — the weight `LetterRepository` defaults to. In study mode
    /// difficulty is pinned at `.standard` (`TracingViewModel.swift:1123-1127`,
    /// and the errorless ramp above it is `if !studyMode`), so
    /// `radiusMultiplier` is 1.0, and every study letter's authored
    /// `checkpointRadius` is 0.1. The hit boundary is therefore 0.1 and
    /// this gate is 3 × 0.1 = 0.3 — while the LARGEST gap between two
    /// consecutive checkpoints in any study letter is 0.0278 (A; I 0.0266,
    /// L 0.0242, F 0.0242, M 0.0197). So along the stroke the default gate
    /// is satisfied with a 10.8× margin, and even at the TIGHTEST setting
    /// offered (1×, where the gate IS the hit boundary) it clears the
    /// largest on-stroke gap by 3.6×. No setting in this range can
    /// therefore close the gate on a child who is tracing the stroke —
    /// this factor is live only when the finger is OFF it, which is exactly
    /// when a child would notice the sound stopping. Recorded rather than
    /// glossed, because it is the reason the velocity floor below is the
    /// switch that binds and this one is the switch that bounds.
    ///
    /// SPACE CAVEAT, recorded because the numbers above are not in the same
    /// coordinates the running app compares in: they are the stroke JSON's
    /// glyph-bbox values. The shipped app remaps each checkpoint through the
    /// glyph rect — anisotropically, `x` by the rect's width and `y` by its
    /// height — and scales `checkpointRadius` by `sqrt(width × height)`
    /// instead (`TracingViewModel.swift:3007-3012`), so the effective ratio
    /// is glyph-dependent rather than the flat 3.6×..15.2× above. Not
    /// reproduced here because `PrimaeLetterRenderer.normalizedGlyphRect`
    /// refuses to run under test (`guard !isRunningTests`). The conclusion
    /// is unaffected: the correction is an aspect ratio, not an order of
    /// magnitude, and the tightest margin above is 3.6×.
    ///
    /// 1.0 is the floor of the range: at 1× the gate IS the hit boundary,
    /// which is the tightest setting the tracker's own logic has an
    /// interpretation for (below it, a checkpoint could advance while the
    /// sound gate reported "not near"). 6× is a deliberately generous
    /// ceiling. Default 3.0, the hardcoded value this has had since the
    /// tracker was written, so an untouched device is unchanged.
    static let soundGateRadiusFactorKey = prefix + "soundGateRadiusFactor"
    /// The value above that an untouched device runs, named so the
    /// researcher control and the production default cannot drift apart.
    static let soundGateRadiusFactorDefault: Double = 3.0
    static var soundGateRadiusFactor: Double {
        get { max(1.0, doubleValue(soundGateRadiusFactorKey,
                                   default: soundGateRadiusFactorDefault)) }
        set { UserDefaults.standard.set(max(1.0, newValue), forKey: soundGateRadiusFactorKey) }
    }

    /// The smoothed touch velocity (pt/s) below which the letter's sound
    /// is held at `.idle` even with the finger on the letter — the second
    /// half of the same ANDed boundary, and the half that BINDS. Because
    /// the radius gate above is saturated along the stroke, this is the
    /// gate that decides whether a child tracing correctly hears the
    /// letter at all (`TouchDispatcher.swift:381-384`).
    ///
    /// Default 22.0, the hardcoded value since the dispatcher was written.
    /// 0.0 is a legitimate comparison — sound follows proximity alone,
    /// with no motion requirement — and is included as a setting because
    /// it is the "both options" the note implies when read as "should the
    /// trigger require movement at all?".
    static let soundGateVelocityFloorKey = prefix + "soundGateVelocityFloor"
    /// The default above, named for the same reason as its sibling.
    static let soundGateVelocityFloorDefault: Double = 22.0
    static var soundGateVelocityFloor: Double {
        get { max(0, doubleValue(soundGateVelocityFloorKey,
                                 default: soundGateVelocityFloorDefault)) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: soundGateVelocityFloorKey) }
    }

    /// Whether the pre-task sound demonstration is delivered ONCE PER
    /// AUDIO CONDITION per session rather than once per letter. The
    /// supervisor's "Einmal pro Kondition".
    ///
    /// OFF is the default and the behaviour the app has today: the
    /// demonstration is armed on EVERY fresh letter load
    /// (`TracingViewModel.armPreTaskDemonstration`, called from
    /// `load(letter:)`'s observe and direct-to-guided entries), so every
    /// letter's trace is preceded by the same exposure. That per-letter
    /// firing is recorded as intended in `docs/STUDY_DEVICE_DRYRUN.md`
    /// ("The demonstration in 4a plays again on every letter entry —
    /// that's intended (every trace is preceded by the same exposure),
    /// not a repeat-content bug"), and this switch is the note that
    /// questions it.
    ///
    /// WHY THIS READING. The demonstration is the only behaviour in the
    /// app whose content IS the audio condition and which runs once per
    /// letter: the ghost-letter animation repeats per letter too, but it
    /// is identical in all three arms, and the per-touch coupling is the
    /// arm's manipulation rather than a demonstration of it. So "einmal
    /// pro Kondition" has exactly one referent in the code, and this is
    /// it.
    ///
    /// ON — what this switch selects, and it is a COMPARISON
    /// CONFIGURATION rather than a neutral one. The demonstration is
    /// delivered at the FIRST letter loaded in each audio condition and
    /// NOT on any later letter in that condition. With the arm fixed for
    /// the session (the pilot's between-subjects design) that means the
    /// child hears it exactly once, before the first letter, and every
    /// later letter runs its observe phase with no demonstration at all.
    /// With `cycleAllConditions` ON each arm's demonstration lands on its
    /// own first letter, so a five-letter cycle delivers three
    /// demonstrations and the fourth and fifth letters get none.
    ///
    /// THE CONSEQUENCE, STATED PLAINLY BECAUSE IT IS A PROTOCOL ONE.
    /// `04-implementation.typ:17` and `06-evaluation.typ:62` both rest on
    /// the arms' demonstrations being of the SAME LENGTH, structurally
    /// matched across arms. Suppressing the demonstration for later
    /// letters does not break the arms' match with EACH OTHER — every arm
    /// loses its later-letter demonstration under this switch, so the
    /// arms stay matched to one another — but it does change what the
    /// session IS. For the spatial arm the demonstration is where the
    /// pitch/pan mapping is INSTALLED rather than merely revealed (see
    /// `PreTaskDemonstration`'s header), so a child who hears it once has
    /// had that mapping taught once instead of re-taught per letter; and
    /// the observe window of every letter after the first no longer
    /// carries the exposure the dry-run document describes. Any data
    /// produced under this switch is comparison-run data, like every
    /// other switch in this file.
    ///
    /// The count is per SESSION, and a new participant starts a new
    /// session: `reapplyParticipantIdentity` clears it when the proctor
    /// enrols the next child, so the incoming child is not silently
    /// denied the demonstration the outgoing one already used up.
    ///
    /// OFF is the default anyway, by the rule every switch here follows:
    /// the default is the behaviour the device had before the switch
    /// existed, so an untouched device is byte-identical to today's.
    static let oncePerConditionKey = prefix + "oncePerCondition"
    static let oncePerConditionDefault: Bool = false
    static var oncePerCondition: Bool {
        get { boolValue(oncePerConditionKey, default: oncePerConditionDefault) }
        set { UserDefaults.standard.set(newValue, forKey: oncePerConditionKey) }
    }

    /// Restore every switch to the behaviour the app had before this file
    /// existed. Used by the researcher UI's reset row, and by tests.
    static func resetToDefaults() {
        for key in [observePassesKey, spokenFeedbackKey, allFiveLettersKey,
                    letterRepeatCountKey, cycleAllConditionsKey,
                    presentationSpacingKey, guidedDotsVisibleKey,
                    panningEnabledKey, spatialAxisDemonstrationKey,
                    soundGateRadiusFactorKey, soundGateVelocityFloorKey,
                    oncePerConditionKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Typed reads

    private static func boolValue(_ key: String, default fallback: Bool) -> Bool {
        // Same default-when-unset shape as `enableFreeformMode`: a stored
        // value is authoritative once written, and an untouched key takes
        // the current behaviour.
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func intValue(_ key: String, default fallback: Int) -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.integer(forKey: key)
    }

    private static func doubleValue(_ key: String, default fallback: Double) -> Double {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return UserDefaults.standard.double(forKey: key)
    }
}

// MARK: - The configuration a session ran under, ON THE ROW

/// The twelve comparison switches RESOLVED — the values one session
/// actually runs under, as opposed to the device's settings, which may
/// have moved since that session finished.
///
/// WHY THIS TYPE EXISTS (2026-09-18). Every switch in
/// `StudyComparisonSettings` changes what a session IS, and ELEVEN of the
/// twelve left no trace in the exported data: a comparison run's rows
/// carried the same 27 columns, in the same order, with the same names as
/// a pilot run's. The only exception was `allFiveLetters`, which
/// disclosed itself indirectly through `trainedSubset == "AFILM"`. So the
/// claim in the header above — "any row produced under a non-default
/// switch is a comparison run rather than pilot data" — was true of what
/// the session WAS and false of what the row SAID, and an export merged
/// across sessions could not be partitioned into pilot and comparison
/// rows at all.
///
/// THE VALUE IS CARRIED ON THE ROW, AND IT IS FIXED WHEN THE ROW IS
/// WRITTEN. It is deliberately NOT recomputed at export time: an export
/// can happen days after the session, on a device whose switches have
/// since been changed, so a read at export time would stamp yesterday's
/// session with today's configuration. `PhaseSessionRecord
/// .comparisonConfiguration` is the carrier, and
/// `PhaseTransitionCoordinator` is where it is filled in.
///
/// WHAT IT IS NOT. Not a study arm (`audioCondition` and `condition` are
/// the arms, and both already ride on every row), not a participant
/// property, and not a hash — a hash would be compact and useless, since
/// an analyst could neither read it nor check it. A default
/// configuration, i.e. the PILOT, stamps NOTHING AT ALL: `nonDefaultStamp`
/// is nil and the exported column is empty, so every pilot row remains
/// byte-identical in meaning to what it was before this file changed.
struct StudyComparisonConfiguration: Equatable {

    // Declaration order IS the stamp's field order, and is stable: an
    // analyst parsing a stamp can rely on it, and a test pins it. Adding
    // a switch means adding a field here, its default check below, and
    // the name in `nonDefaultStamp` — the compiler cannot yet enforce
    // that, so the list in `nonDefaultStamp` is the one place to keep
    // complete.

    var observePasses: Int = StudyComparisonSettings.observePassesDefault
    var spokenFeedbackInStudy: Bool = StudyComparisonSettings.spokenFeedbackInStudyDefault
    var allFiveLetters: Bool = StudyComparisonSettings.allFiveLettersDefault
    var letterRepeatCount: Int = StudyComparisonSettings.letterRepeatCountDefault
    var cycleAllConditions: Bool = StudyComparisonSettings.cycleAllConditionsDefault
    var presentationSpacingSeconds: Double = StudyComparisonSettings.presentationSpacingSecondsDefault
    var panningEnabled: Bool = StudyComparisonSettings.panningEnabledDefault
    var guidedDotsVisible: Bool = StudyComparisonSettings.guidedDotsVisibleDefault
    var spatialAxisDemonstration: Bool = StudyComparisonSettings.spatialAxisDemonstrationDefault
    var soundGateRadiusFactor: Double = StudyComparisonSettings.soundGateRadiusFactorDefault
    var soundGateVelocityFloor: Double = StudyComparisonSettings.soundGateVelocityFloorDefault
    var oncePerCondition: Bool = StudyComparisonSettings.oncePerConditionDefault

    /// All twelve at their production defaults — the PILOT configuration,
    /// and the value a `PhaseSessionRecord` written before this type
    /// existed decodes as.
    static let defaults = StudyComparisonConfiguration()

    /// The compact stamp written onto every row this session produces:
    /// the NON-DEFAULT switches only, `name=value` pairs in declaration
    /// order joined by `;` — e.g. `observePasses=2;panningEnabled=false`.
    ///
    /// NIL when every switch is at its default, which is the pilot case
    /// and must stay the pilot case: a nil here means the row's column is
    /// empty, so existing pilot analysis is unaffected by this field
    /// existing.
    ///
    /// Readable by a human AND parseable by a machine — the properties'
    /// own names, not the `UserDefaults` key strings, so the stamp can be
    /// read against this file without a key-name lookup. No value can
    /// contain `;` or `=`, so the split is unambiguous; the separator is
    /// not a comma, so the field needs no CSV quoting.
    var nonDefaultStamp: String? {
        var entries: [String] = []
        if observePasses != Self.defaults.observePasses {
            entries.append("observePasses=\(observePasses)")
        }
        if spokenFeedbackInStudy != Self.defaults.spokenFeedbackInStudy {
            entries.append("spokenFeedbackInStudy=\(spokenFeedbackInStudy)")
        }
        if allFiveLetters != Self.defaults.allFiveLetters {
            entries.append("allFiveLetters=\(allFiveLetters)")
        }
        if letterRepeatCount != Self.defaults.letterRepeatCount {
            entries.append("letterRepeatCount=\(letterRepeatCount)")
        }
        if cycleAllConditions != Self.defaults.cycleAllConditions {
            entries.append("cycleAllConditions=\(cycleAllConditions)")
        }
        if presentationSpacingSeconds != Self.defaults.presentationSpacingSeconds {
            entries.append("presentationSpacingSeconds=\(presentationSpacingSeconds)")
        }
        if panningEnabled != Self.defaults.panningEnabled {
            entries.append("panningEnabled=\(panningEnabled)")
        }
        if guidedDotsVisible != Self.defaults.guidedDotsVisible {
            entries.append("guidedDotsVisible=\(guidedDotsVisible)")
        }
        if spatialAxisDemonstration != Self.defaults.spatialAxisDemonstration {
            entries.append("spatialAxisDemonstration=\(spatialAxisDemonstration)")
        }
        if soundGateRadiusFactor != Self.defaults.soundGateRadiusFactor {
            entries.append("soundGateRadiusFactor=\(soundGateRadiusFactor)")
        }
        if soundGateVelocityFloor != Self.defaults.soundGateVelocityFloor {
            entries.append("soundGateVelocityFloor=\(soundGateVelocityFloor)")
        }
        if oncePerCondition != Self.defaults.oncePerCondition {
            entries.append("oncePerCondition=\(oncePerCondition)")
        }
        return entries.isEmpty ? nil : entries.joined(separator: ";")
    }
}
