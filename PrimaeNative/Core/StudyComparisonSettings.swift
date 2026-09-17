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

    /// Restore every switch to the behaviour the app had before this file
    /// existed. Used by the researcher UI's reset row, and by tests.
    static func resetToDefaults() {
        for key in [observePassesKey, spokenFeedbackKey, allFiveLettersKey,
                    letterRepeatCountKey, cycleAllConditionsKey,
                    presentationSpacingKey, guidedDotsVisibleKey,
                    panningEnabledKey] {
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
