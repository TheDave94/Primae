import Foundation

// ComparisonControlDomains.swift
//
// WHAT A PROCTOR CAN SELECT in the "Vergleichsmodus" panel, as values.
//
// Before this file the option lists, ranges, steps and their German labels sat
// inline in `SettingsView.body`, where nothing could hold them to the store
// they write to. Three things could go wrong there and nothing would notice:
//
//  - a picker offers a value the store then clamps to something else, so the
//    control shows one setting and the session runs another;
//  - a picker (or stepper) no longer offers the store's default, so an
//    untouched device renders a control with nothing selected;
//  - a label says "(Vorgabe)" on a value that has stopped being the default
//    (the r26 pitch-range default moved 2400 -> 1200; the label text is the
//    only thing that records which option is "the" default).
//
// The view reads these values and nothing else decides them. Labels, order and
// numbers are exactly what the inline literals were, so the rendered panel is
// unchanged. `ComparisonControlDomainsTests` holds each domain to the store.

/// One row of a picker: the German label the proctor reads and the value it
/// writes.
struct ComparisonOption<Value: Hashable>: Hashable {
    let label: String
    let value: Value
}

/// A stepper's reachable values: `range` with moves of `step`.
struct ComparisonStepperDomain: Equatable {
    let range: ClosedRange<Double>
    let step: Double
}

enum ComparisonControlDomains {

    // MARK: Pickers

    /// "Vorzeigen".
    static let observePasses: [ComparisonOption<Int>] = [
        ComparisonOption(label: "Einmal", value: 1),
        ComparisonOption(label: "Zweimal", value: 2),
    ]

    /// "Wiederholungen je Buchstabe".
    static let letterRepeatCount: [ComparisonOption<Int>] = [
        ComparisonOption(label: "1", value: 1),
        ComparisonOption(label: "2", value: 2),
        ComparisonOption(label: "3", value: 3),
    ]

    /// "Höhe steuert Tonhöhe".
    static let pitchScope: [ComparisonOption<PitchScope>] = [
        ComparisonOption(label: "Beide Klang-Arme", value: .both),
        ComparisonOption(label: "Nur Raumklang", value: .spatialOnly),
        ComparisonOption(label: "Aus", value: .off),
    ]

    /// "Tonumfang der Höhe", in cents. Order is the panel's order, not
    /// ascending.
    static let pitchRangeCents: [ComparisonOption<Int>] = [
        ComparisonOption(label: "1 Oktave", value: 1200),
        ComparisonOption(label: "2 Oktaven", value: 2400),
        ComparisonOption(label: "1,5 Oktaven", value: 1800),
        ComparisonOption(label: "½ Oktave", value: 600),
    ]

    /// "Ton-Trigger: Nähe zum Buchstaben", as a multiple of the hit radius.
    static let soundGateRadiusFactor: [ComparisonOption<Double>] = [
        ComparisonOption(label: "1× (nur auf dem Strich)", value: 1.0),
        ComparisonOption(label: "2×", value: 2.0),
        ComparisonOption(label: "3× (Vorgabe)", value: 3.0),
        ComparisonOption(label: "4×", value: 4.0),
        ComparisonOption(label: "6× (ganze Zelle)", value: 6.0),
    ]

    /// "Ton-Trigger: Bewegung", in pt/s.
    static let soundGateVelocityFloor: [ComparisonOption<Double>] = [
        ComparisonOption(label: "Ohne Bewegungsschwelle (Vorgabe)", value: 0.0),
        ComparisonOption(label: "22 pt/s", value: 22.0),
        ComparisonOption(label: "44 pt/s", value: 44.0),
        ComparisonOption(label: "66 pt/s", value: 66.0),
    ]

    /// The word a picker label uses to mark the default option.
    static let defaultMarker = "Vorgabe"

    // MARK: Steppers

    /// "Abstand: Dämpfung am Rand", dB.
    static let distanceToneFarLevelDB = ComparisonStepperDomain(range: -60...0, step: 3)
    /// "Abstand: Grenzfrequenz am Rand", Hz.
    static let distanceToneFarCutoffHz = ComparisonStepperDomain(range: 100...20000, step: 100)
    /// "Richtung: Rückwärts-Schwelle", a cosine.
    static let directionMuteBackwardCosine = ComparisonStepperDomain(range: -1...1, step: 0.25)
    /// "Stiftdruck: Lautstärkeumfang", dB.
    static let pressureLoudnessRangeDB = ComparisonStepperDomain(range: 0...60, step: 3)
    /// "Rauheit: Tiefe", 0...1 (shown as a percentage).
    static let dysfluencyRoughnessDepth = ComparisonStepperDomain(range: 0...1, step: 0.1)
    /// "Rauheit: Rate", Hz.
    static let dysfluencyRoughnessRateHz = ComparisonStepperDomain(range: 5...100, step: 5)
    /// "Abstand zwischen Buchstaben", seconds.
    static let presentationSpacingSeconds = ComparisonStepperDomain(range: 0...10, step: 0.5)
    /// "Pause" before the final test, seconds (r27).
    static let pauseSeconds = ComparisonStepperDomain(range: StudyComparisonSettings.pauseSecondsRange, step: 5)
    /// "Zeigedauer" of the glyph in the final test, seconds (r27; a slider with a step).
    static let glimpseSeconds = ComparisonStepperDomain(range: StudyComparisonSettings.glimpseSecondsRange, step: 0.5)

    // MARK: Labels

    /// The roughness depth as the whole percentage the stepper's label shows.
    /// Rounded, not truncated: a stepper that adds 0.1 repeatedly reaches
    /// 0.7999999999999999, and truncating that would read "79 %" for the
    /// 80 % default.
    static func roughnessDepthPercent(_ depth: Double) -> Int {
        Int((depth * 100).rounded())
    }
}
