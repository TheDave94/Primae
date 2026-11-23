import Foundation

// ProctorScreenPresentation.swift
//
// WHAT THE PROCTOR'S SCREENS DECIDE, as plain values (r27, Lane C, settings
// audit 2026-11-23).
//
// The Settings and Research-Dashboard views are unreachable from a unit test
// (SwiftUI vends nothing to `PrimaeNativeTests` in this configuration, the
// limit `NextParticipantControlTests` records). Every decision the audit found
// wrong lived inside a view body: which controls exist, which sub-settings are
// live, what a table cell shows, what a status line says. They are values here,
// the views read them, and `ProctorScreenPresentationTests` holds each one.
//
// All of it is PARENT-AREA copy (German, text is fine). Nothing here is
// child-facing and nothing here changes a stamped or exported value.

// MARK: - Controls that exist only outside the study build

/// A proctor control that does nothing in the study build.
enum ProctorControl: CaseIterable, Sendable {
    /// Settings, "Studienarm überschreiben". `StudyBuild` pins the
    /// pedagogical arm to `.threePhase`, so the override was a no-op that
    /// still blocked the session until a relaunch.
    case studyArmOverride
    /// Research dashboard, the "Studienarm" session counts. One row (always
    /// `threePhase`) in a study build.
    case studyArmCounts
    /// Research dashboard, "Spaced-Repetition-Effizienz". The scheduler proxy
    /// is never fed in a study session, so the card showed `r = +0.000` with a
    /// green check.
    case spacedRepetitionSection
    /// Research dashboard, "Kalibrierungs-Overrides löschen". The study build
    /// ignores stored calibrations (`studyMode`), and "Nächstes Kind" wipes
    /// them anyway.
    case calibrationWipe
}

enum ProctorControls {
    /// Whether the control is shown. Absent in a study build; the casual
    /// build (paused, not deleted) keeps all four. Decoding of old data is
    /// untouched: only what the screen offers changes.
    static func isShown(_ control: ProctorControl, studyBuild: Bool = StudyBuild.isActive) -> Bool {
        !studyBuild
    }
}

// MARK: - Sub-settings under a switch that is off

/// A setting whose value only matters while its parent switch is on.
enum ComparisonSubSetting: CaseIterable, Sendable {
    case distanceLevel, distanceCutoff     // under "Klang: Abstand vom Strich"
    case directionThreshold                // under "Klang: Richtung am Strich"
    case pressureRange                     // under "Stiftdruck steuert die Lautstärke"
    case roughnessDepth, roughnessRate     // under "Klang: Stocken → Rauheit"
    case pitchRange                        // under "Höhe steuert Tonhöhe" (not Aus)
}

/// The parent switches' current positions.
struct ComparisonParentSwitches: Equatable, Sendable {
    var distanceTone: Bool
    var directionMute: Bool
    var pressureLoudness: Bool
    var dysfluencyRoughness: Bool
    var pitchScope: PitchScope
}

extension ComparisonSubSetting {
    /// Whether the control is operable. A sub-setting under an Off parent is
    /// DISABLED in the UI only: the comparison stamp and the export still
    /// carry its stored value, so a stamp is byte-identical to what it was
    /// when the control stayed live (`ComparisonConfigurationStampTests`).
    func isEnabled(given parents: ComparisonParentSwitches) -> Bool {
        switch self {
        case .distanceLevel, .distanceCutoff: return parents.distanceTone
        case .directionThreshold:             return parents.directionMute
        case .pressureRange:                  return parents.pressureLoudness
        case .roughnessDepth, .roughnessRate: return parents.dysfluencyRoughness
        case .pitchRange:                     return parents.pitchScope != .off
        }
    }
}

// MARK: - Tables and trends on the research / parent dashboards

enum PhaseRowPresentation {
    /// The "Probe" cell of the research dashboard's phase table: the row's
    /// `probe` tag exactly as the export writes it (`finalTest`, `pretest`,
    /// …), empty for a training row.
    static func probeCell(_ record: PhaseSessionRecord) -> String {
        record.probe ?? ""
    }

    /// The last five non-nil values of one Schreibmotorik dimension across
    /// completed TRAINING freeWrite rows, for the parent dashboard's
    /// sparkline. A probe or final-test row is a different instrument (the
    /// same rule as `PhaseSessionRecord.isScoredFreeWrite`, which the mean
    /// above the sparkline already follows) and is skipped, so the trend does
    /// not end on a cold-write point the mean left out.
    static func trendValues(_ records: [PhaseSessionRecord],
                            _ keyPath: KeyPath<PhaseSessionRecord, Double?>) -> [Double] {
        records
            .filter { $0.probe == nil && $0.phase == LearningPhase.freeWrite.rawName && $0.completed }
            .compactMap { $0[keyPath: keyPath] }
            .suffix(5)
            .map { $0 }
    }
}

// MARK: - Status lines (read-only)

enum ResearchStatus {
    /// "Protokoll r27".
    static func protocolLine(revision: Int = StudyProtocol.revision) -> String {
        "Protokoll-Revision r\(revision)"
    }

    /// The enrolment state in the short form the proctor compares at a
    /// hand-over (first eight characters of the id), or the absence of one.
    static func enrolmentLine(enrolled: Bool, participantId: UUID) -> String {
        enrolled
            ? "Eingeschrieben: Teilnehmer \(participantId.uuidString.prefix(8))"
            : "Kein Kind eingeschrieben"
    }

    /// Shown only while a relaunch is pending (a comparison switch, an
    /// assignment override or a restored identity was changed).
    static func relaunchLine(pending: Bool) -> String? {
        pending
            ? "Neustart nötig: Die App muss vollständig geschlossen und neu gestartet werden, bevor ein Kind schreibt."
            : nil
    }

    /// The final test's two settings as this session runs them.
    static func finalTestLine(pauseSeconds: Double, glimpseSeconds: Double) -> String {
        String(format: "Pause %.0f s · Zeigedauer %.1f s", pauseSeconds, glimpseSeconds)
            .replacingOccurrences(of: ".", with: ",")
    }

    /// The one description of the closing part of a session (r27), in place
    /// of the five probe buttons and their Vortest / Post-Test / Nachtest
    /// texts.
    static let finalTestDescription =
        "Nach dem dritten Übungsbuchstaben folgt eine stille Pause. Danach schreibt das Kind die drei geübten Buchstaben aus dem Gedächtnis noch einmal, in der Reihenfolge des Trainings, ohne Ton und ohne Rückmeldung. Die Zeilen tragen in der Spalte „probe“ den Wert „finalTest“. Es gibt keine Knöpfe dafür: der Abschlusstest läuft von selbst."

    /// Settings, under the enrolment line. The study version cannot be
    /// switched out of the study, so what it reports is whether a child is
    /// enrolled, not that the participation is "festgelegt".
    static func settingsEnrolmentLine(enrolled: Bool) -> String {
        enrolled
            ? "Studienteilnahme: ein Kind ist eingeschrieben"
            : "Studienteilnahme: noch kein Kind eingeschrieben. Im Forschungs-Bereich „Neuer Teilnehmer“ wählen."
    }

    /// The note under the override pickers once the child has a row.
    static func overrideLockedNote(includesStudyArm: Bool) -> String {
        includesStudyArm
            ? "Studienarm, Audio-Arm und trainierte Buchstaben: nur vor dem ersten Buchstaben änderbar."
            : "Audio-Arm und trainierte Buchstaben: nur vor dem ersten Buchstaben änderbar."
    }

    /// The note in the Vergleichsmodus and Abschlusstest sections once the
    /// child has a row (the switches lock then, as the overrides do).
    static let comparisonLockedNote =
        "Vergleichsmodus und Abschlusstest: nur vor dem ersten Buchstaben änderbar."
}

// MARK: - "Nächstes Kind" readiness copy

extension NextParticipantCopy {
    /// Said INSTEAD of `readyMessage` while a relaunch is still pending
    /// (a comparison switch was moved and the app has not been restarted):
    /// the new child is enrolled, but the session is blocked until then, so
    /// "sofort startklar" would be false.
    static let readyMessageRestartPending =
        "Neues Kind eingeschrieben. Eine geänderte Einstellung gilt erst nach einem Neustart: die App vollständig schließen und neu starten, bevor das Kind schreibt."

    static func readyMessageFor(restartPending: Bool) -> String {
        restartPending ? readyMessageRestartPending : readyMessage
    }
}

// MARK: - Proctor hints

extension ComparisonSwitchHints {
    static let guidedDots = "Ein ist die Vorgabe: Anschauen und Nachspuren zeichnen an jedem Strichanfang einen Punkt. Aus zeichnet sie gar nicht mehr. Antippen war dort noch nie möglich. Der Endpunkt-Ring am Buchstabenende bleibt in beiden Stellungen sichtbar."

    static let presentationSpacing = "Pause vor JEDER Vorführung (Anschauen): vor dem ersten Buchstaben, vor jedem weiteren und vor jeder Wiederholung desselben Buchstabens — nicht nur zwischen zwei Buchstaben. 0 ist die Vorgabe."

    static let enrolment = "Nur für Forschung. Die Studien-Version ist fest eingestellt; ein Kind wird im Forschungs-Bereich über „Neuer Teilnehmer“ eingeschrieben und erhält dabei seine Studienbedingung. Jedes Kind durchläuft drei Phasen: Anschauen, Nachspuren, Selbst schreiben."

    static let trainedSubsetOverride = "Nur für Studienleitung. Legt fest, welche drei der fünf Studienbuchstaben dieses Kind übt und im Abschlusstest noch einmal schreibt, anstatt die automatische Zuweisung zu verwenden — für ausgewogenes Counterbalancing. Änderung wird beim nächsten App-Start wirksam."

    static let oncePerCondition = "Aus ist die Vorgabe: vor jedem Buchstaben läuft die Vorführung des Arms erneut — jede Spur beginnt mit derselben Darbietung. Ein lässt sie nur beim ersten Buchstaben einer Audio-Bedingung laufen; alle weiteren Buchstaben derselben Bedingung beginnen ohne Vorführung. Bei fester Kondition hört das Kind sie also genau einmal, vor dem ersten Buchstaben. Bei „Alle Konditionen durchlaufen“ bekommt jede Bedingung ihre eigene Vorführung, sodass bei drei geübten Buchstaben jeder genau eine Vorführung bekommt (eine je Bedingung). Die Arme bleiben dabei untereinander gleich lang, aber die Sitzung ist nicht mehr die, die der Trockenlauf beschreibt, und für den Raumklang-Arm wird die Tonhöhen-/Ortungszuordnung dadurch nur einmal gelegt statt vor jedem Buchstaben. Ein Vergleichslauf, keine Pilotbedingung. Der Zähler gilt je Kind: bei „Neuer Teilnehmer“ beginnt er von vorn."

    /// Footer under the Vergleichsmodus switches. The block text names the
    /// setting, not the arm (it used to say "Arm bzw. Buchstaben").
    static let comparisonFooter = "Diese Schalter ändern die Sitzung, nicht den Studienarm. Eine Sitzung mit einem abweichenden Schalter ist ein Vergleichslauf und keine Pilotdaten. Alle Schalter werden beim Start der App gelesen und gelten für die ganze Sitzung. Wird ein Schalter während einer laufenden Sitzung umgestellt, sperrt die App die Sitzung bis zum Neustart; die Meldung lautet dann „Einstellung geändert — die App muss neu gestartet werden“."
}

/// The session-block messages for a pending relaunch, as values so a test can
/// hold the footer above to the text the child's screen actually shows.
enum RelaunchBlockCopy {
    /// An assignment override (arm, letters) changed.
    static let assignment = "Zuweisung geändert — die App muss neu gestartet werden, damit der gewählte Arm bzw. die gewählten Buchstaben gelten."
    /// A comparison switch changed, and nothing about the assignment did.
    static let comparison = "Einstellung geändert — die App muss neu gestartet werden, damit die gewählte Einstellung gilt."

    static func message(assignmentChanged: Bool, comparisonChanged: Bool) -> String? {
        if assignmentChanged { return assignment }
        if comparisonChanged { return comparison }
        return nil
    }
}
