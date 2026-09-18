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
    static var observePasses: Int {
        get { intValue(observePassesKey, default: 1) }
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
    static var spokenFeedbackInStudy: Bool {
        get { boolValue(spokenFeedbackKey, default: false) }
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
    static var allFiveLetters: Bool {
        get { boolValue(allFiveLettersKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: allFiveLettersKey) }
    }

    /// How many times each letter's full four-phase flow runs before the
    /// proctor advances. The supervisor's "Buchstabe dreimal?".
    /// Default 1, which is what the app does today.
    static let letterRepeatCountKey = prefix + "letterRepeatCount"
    static var letterRepeatCount: Int {
        get { max(1, intValue(letterRepeatCountKey, default: 1)) }
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
    static var cycleAllConditions: Bool {
        get { boolValue(cycleAllConditionsKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: cycleAllConditionsKey) }
    }

    /// Seconds to pause between one letter's flow and the next letter's
    /// observe entry. The supervisor's "Abstand zwischen Darstellung?".
    /// Default 0 — no pause, as today.
    static let presentationSpacingKey = prefix + "presentationSpacingSeconds"
    static var presentationSpacingSeconds: Double {
        get { max(0, doubleValue(presentationSpacingKey, default: 0)) }
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
    static var panningEnabled: Bool {
        get { boolValue(panningEnabledKey, default: true) }
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
    static var guidedDotsVisible: Bool {
        get { boolValue(guidedDotsVisibleKey, default: true) }
        set { UserDefaults.standard.set(newValue, forKey: guidedDotsVisibleKey) }
    }

    /// Whether the spatial arm's pre-task demonstration runs the scripted
    /// axis sweep, or holds the carrier steady for the same two-second
    /// window. The supervisor's "Glissando weg" against the axis
    /// demonstration the thesis specifies.
    ///
    /// THE TENSION, STATED PLAINLY, BECAUSE IT DOES NOT RESOLVE HERE.
    /// `04-implementation.typ:17` specifies the scripted sweep as part of
    /// the spatial arm: a point travelling the full canvas while the
    /// carrier's pitch follows its vertical leg and its pan the horizontal
    /// one, for a fixed two seconds matched with the phoneme arm's
    /// demonstration. The rationale in `PreTaskDemonstration`'s header is
    /// that a demonstration can INSTALL a crossmodal mapping rather than
    /// reveal one already there — for this arm the sweep is not decoration,
    /// it is where the mapping is taught.
    ///
    /// The supervisor's device review of 2026-09-17 said "Glissando weg":
    /// on the device the sweep reads as the arm playing a high-low-high
    /// slide at the child before anything has been touched, and it is the
    /// most conspicuous thing about the arm.
    ///
    /// So OFF — this switch's default, and the behaviour the app has had
    /// since commit 6fb7233c — is a PROTOCOL DIVERGENCE from the written
    /// specification. A device left untouched runs the spatial arm without
    /// the demonstration the thesis says it has, and roughly 28 locations
    /// in the thesis (including `02-background.typ:107`) still describe the
    /// sweep. ON restores exactly what was removed, unchanged.
    ///
    /// Neither position is a code decision and this file does not make it.
    /// The ruling is David's; the thesis has to move with whichever way it
    /// goes. The switch exists so the two options can be compared on the
    /// device instead of argued about in the abstract — which is the whole
    /// reason this file exists.
    ///
    /// OFF is the default anyway, because the default of every switch here
    /// is the behaviour the device had before the switch existed: that is
    /// what makes adding one safe to an enrolled study device, and it keeps
    /// an untouched device identical to the one the 2026-09-17 review saw.
    static let spatialAxisDemonstrationKey = prefix + "spatialAxisDemonstration"
    static var spatialAxisDemonstration: Bool {
        get { boolValue(spatialAxisDemonstrationKey, default: false) }
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

    /// Restore every switch to the behaviour the app had before this file
    /// existed. Used by the researcher UI's reset row, and by tests.
    static func resetToDefaults() {
        for key in [observePassesKey, spokenFeedbackKey, allFiveLettersKey,
                    letterRepeatCountKey, cycleAllConditionsKey,
                    presentationSpacingKey, guidedDotsVisibleKey,
                    panningEnabledKey, spatialAxisDemonstrationKey,
                    soundGateRadiusFactorKey, soundGateVelocityFloorKey] {
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
