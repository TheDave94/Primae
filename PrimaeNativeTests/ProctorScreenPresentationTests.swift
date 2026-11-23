// ProctorScreenPresentationTests.swift
// PrimaeNativeTests
//
// r27 Lane C (settings audit 2026-11-23): what the Settings and the Research
// Dashboard decide, held as values (`ProctorScreenPresentation.swift`) because
// a `View` body is unreachable from a unit test.
//
// Hermetic: no UserDefaults flip, no shared store. The enrolment tests build
// their own log and dashboard store and read `ParticipantStore.participantId`
// without writing it (the same read every other VM-building test performs).

import Testing
import Foundation
@testable import PrimaeNative

@MainActor
@Suite struct ProctorScreenPresentationTests {

    // MARK: Removed controls

    @Test("the four no-op controls are absent in a study build and present in the casual one")
    func removedControlsAreAbsentInTheStudyBuild() {
        for control in ProctorControl.allCases {
            #expect(!ProctorControls.isShown(control, studyBuild: true), "\(control) is still offered in a study build")
            #expect(ProctorControls.isShown(control, studyBuild: false), "\(control) vanished from the paused casual build")
        }
    }

    @Test("the views ask about THIS binary: the default follows StudyBuild.isActive")
    func theViewsDefaultToTheCompiledBuild() {
        for control in ProctorControl.allCases {
            #expect(ProctorControls.isShown(control) == !StudyBuild.isActive)
        }
        #expect(StudyBuild.isActive, "this package is a study build unconditionally (Package.swift)")
        #expect(ProctorControl.allCases.allSatisfy { !ProctorControls.isShown($0) })
    }

    // MARK: Sub-settings

    private func parents(distance: Bool = false, direction: Bool = false, pressure: Bool = false,
                         roughness: Bool = false, scope: PitchScope = .off) -> ComparisonParentSwitches {
        ComparisonParentSwitches(distanceTone: distance, directionMute: direction, pressureLoudness: pressure,
                                 dysfluencyRoughness: roughness, pitchScope: scope)
    }

    @Test("with every parent switch off, every sub-setting is disabled")
    func everySubSettingIsDisabledWhenItsParentIsOff() {
        for sub in ComparisonSubSetting.allCases {
            #expect(!sub.isEnabled(given: parents()), "\(sub) is live under an off parent")
        }
    }

    @Test("each parent switch enables exactly its own sub-settings")
    func eachParentEnablesOnlyItsChildren() {
        let table: [(ComparisonParentSwitches, Set<ComparisonSubSetting>)] = [
            (parents(distance: true), [.distanceLevel, .distanceCutoff]),
            (parents(direction: true), [.directionThreshold]),
            (parents(pressure: true), [.pressureRange]),
            (parents(roughness: true), [.roughnessDepth, .roughnessRate]),
            (parents(scope: .both), [.pitchRange]),
            (parents(scope: .spatialOnly), [.pitchRange]),
        ]
        for (switches, expected) in table {
            let enabled = Set(ComparisonSubSetting.allCases.filter { $0.isEnabled(given: switches) })
            #expect(enabled == expected, "\(switches): enabled \(enabled), expected \(expected)")
        }
    }

    // MARK: Probe column and sparkline

    private func record(phase: String = "freeWrite", form: CGFloat, probe: String? = nil,
                        completed: Bool = true) -> PhaseSessionRecord {
        PhaseSessionRecord(letter: "A", phase: phase, completed: completed, score: 0.5, schedulerPriority: 0,
                           assessment: WritingAssessment(formAccuracy: form, tempoConsistency: 0.5,
                                                         pressureControl: 0.5, rhythmScore: 0.5),
                           probe: probe)
    }

    @Test("the probe cell shows the export's probe tag, and nothing for a training row",
          arguments: StudyProbe.allCases)
    func probeCellShowsTheTag(probe: StudyProbe) {
        #expect(PhaseRowPresentation.probeCell(record(form: 0.5, probe: probe.rawValue)) == probe.rawValue)
        #expect(PhaseRowPresentation.probeCell(record(form: 0.5)) == "")
    }

    @Test("the sparkline's last five values skip probe and final-test rows",
          arguments: StudyProbe.allCases)
    func theTrendSkipsProbeRows(probe: StudyProbe) {
        // Six training rows (0.1 ... 0.6), then a cold row that would be the newest point.
        var rows = (1...6).map { record(form: CGFloat($0) / 10) }
        rows.append(record(form: 0.99, probe: probe.rawValue))
        let trend = PhaseRowPresentation.trendValues(rows, \.formAccuracy)
        #expect(trend.count == 5)
        #expect(zip(trend, [0.2, 0.3, 0.4, 0.5, 0.6]).allSatisfy { abs($0 - $1) < 1e-6 },
                "the trend ended on the probe row or lost a training row: \(trend)")
        // Only probe rows: nothing to draw.
        #expect(PhaseRowPresentation.trendValues([record(form: 0.9, probe: probe.rawValue)], \.formAccuracy).isEmpty)
    }

    @Test("the trend keeps its other rules: only completed freeWrite rows")
    func theTrendKeepsItsOtherRules() {
        let rows = [record(phase: "guided", form: 0.1), record(form: 0.2, completed: false), record(form: 0.3)]
        let trend = PhaseRowPresentation.trendValues(rows, \.formAccuracy)
        #expect(trend.count == 1 && abs(trend[0] - 0.3) < 1e-6)
    }

    // MARK: Status lines

    @Test("the status lines carry the revision, the enrolment state and a pending relaunch")
    func statusLines() {
        #expect(ResearchStatus.protocolLine(revision: 27) == "Protokoll-Revision r27")
        #expect(ResearchStatus.protocolLine() == "Protokoll-Revision r\(StudyProtocol.revision)")
        let id = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
        #expect(ResearchStatus.enrolmentLine(enrolled: true, participantId: id).contains("ABCDEF12"))
        #expect(!ResearchStatus.enrolmentLine(enrolled: true, participantId: id).contains("3456"))
        #expect(ResearchStatus.enrolmentLine(enrolled: false, participantId: id) == "Kein Kind eingeschrieben")
        #expect(ResearchStatus.relaunchLine(pending: false) == nil)
        #expect(ResearchStatus.relaunchLine(pending: true)?.contains("Neustart nötig") == true)
        #expect(ResearchStatus.finalTestLine(pauseSeconds: 45, glimpseSeconds: 3) == "Pause 45 s · Zeigedauer 3,0 s")
    }

    @Test("settings: 'festgelegt' is not claimed for a fresh install with no child enrolled")
    func settingsEnrolmentLineIsTrueOnAFreshInstall() {
        #expect(!ResearchStatus.settingsEnrolmentLine(enrolled: false).contains("festgelegt"))
        #expect(ResearchStatus.settingsEnrolmentLine(enrolled: false).contains("noch kein Kind"))
        #expect(ResearchStatus.settingsEnrolmentLine(enrolled: true).contains("eingeschrieben"))
        #expect(!ResearchStatus.overrideLockedNote(includesStudyArm: false).contains("Studienarm"))
        #expect(ResearchStatus.overrideLockedNote(includesStudyArm: true).contains("Studienarm"))
    }

    // MARK: Texts that r27 made false

    @Test("no proctor text names the removed four-phase flow, the five probes or the old tests")
    func noStaleProtocolText() {
        let texts = [ComparisonSwitchHints.guidedDots, ComparisonSwitchHints.presentationSpacing,
                     ComparisonSwitchHints.enrolment, ComparisonSwitchHints.trainedSubsetOverride,
                     ComparisonSwitchHints.oncePerCondition, ComparisonSwitchHints.comparisonFooter,
                     ResearchStatus.finalTestDescription,
                     ResearchStatus.settingsEnrolmentLine(enrolled: true),
                     ResearchStatus.settingsEnrolmentLine(enrolled: false),
                     RelaunchBlockCopy.comparison]
        let stale = ["Vier-Phasen", "Richtung-lernen", "Richtung lernen", "Vortest", "Post-Test", "Nachtest",
                     "Ungeübt", "3 der 5", "fünf Buchstaben drei Vorführungen", "festgelegt", "Arm bzw."]
        for text in texts {
            for word in stale {
                #expect(!text.contains(word), "'\(word)' survives in: \(text.prefix(80))…")
            }
        }
    }

    @Test("the final-test description names the three trained letters, the pause and the tag")
    func finalTestDescription() {
        let d = ResearchStatus.finalTestDescription
        #expect(d.contains("drei geübten Buchstaben"))
        #expect(d.contains("Pause"))
        #expect(d.contains("finalTest"))
    }

    @Test("the spacing hint says the delay precedes EVERY observe, first one and repeats included")
    func spacingHintIsTrue() {
        let h = ComparisonSwitchHints.presentationSpacing
        #expect(h.contains("JEDER Vorführung"))
        #expect(h.contains("vor dem ersten Buchstaben"))
        #expect(h.contains("Wiederholung"))
    }

    @Test("the footer names the setting message, and that message exists")
    func footerMatchesTheBlockMessage() {
        #expect(ComparisonSwitchHints.comparisonFooter.contains("Einstellung geändert"))
        #expect(RelaunchBlockCopy.comparison.hasPrefix("Einstellung geändert"))
        #expect(!RelaunchBlockCopy.comparison.contains("Arm"))
        #expect(RelaunchBlockCopy.message(assignmentChanged: false, comparisonChanged: false) == nil)
        #expect(RelaunchBlockCopy.message(assignmentChanged: true, comparisonChanged: true) == RelaunchBlockCopy.assignment)
        #expect(RelaunchBlockCopy.message(assignmentChanged: false, comparisonChanged: true) == RelaunchBlockCopy.comparison)
    }

    // MARK: The view model's side of it (RED against the pre-Lane-C view model)

    @Test("a moved comparison switch blocks the session with the SETTING message, not the arm message")
    func comparisonChangeBlockMessage() {
        let vm = TracingViewModel(.stub.with(studyMode: true))
        vm.markComparisonSettingChanged()
        #expect(vm.sessionBlockReason == RelaunchBlockCopy.comparison, "\(String(describing: vm.sessionBlockReason))")
    }

    @Test("an assignment override keeps the arm message, also when a switch moved too")
    func assignmentChangeBlockMessage() {
        let vm = TracingViewModel(.stub.with(studyMode: true))
        vm.markAssignmentOverrideChanged()
        #expect(vm.sessionBlockReason == RelaunchBlockCopy.assignment)
        vm.markComparisonSettingChanged()
        #expect(vm.sessionBlockReason == RelaunchBlockCopy.assignment)
    }

    @Test("relaunchPending is what the header's 'Neustart nötig' line reads: any pending block, study sessions only")
    func relaunchPendingFollowsTheBlockFlags() {
        let comparison = TracingViewModel(.stub.with(studyMode: true))
        #expect(!comparison.relaunchPending)
        comparison.markComparisonSettingChanged()
        #expect(comparison.relaunchPending)
        #expect(comparison.sessionBlockReason != nil, "the line and the child-facing block must agree")

        let assignment = TracingViewModel(.stub.with(studyMode: true))
        assignment.markAssignmentOverrideChanged()
        #expect(assignment.relaunchPending)

        let casual = TracingViewModel(.stub.with(studyMode: false))
        casual.markComparisonSettingChanged()
        #expect(!casual.relaunchPending, "outside a study session nothing is blocked, so nothing is pending")
        #expect(casual.sessionBlockReason == nil || casual.sessionBlockReason != RelaunchBlockCopy.comparison)
    }

    @Test("'sofort startklar' is said only when no relaunch is pending")
    func readyToastTellsTheTruth() {
        let calm = TracingViewModel(.stub.with(studyMode: true))
        calm.announceNewChildReady()
        #expect(calm.toastMessage == NextParticipantCopy.readyMessage)
        #expect(NextParticipantCopy.readyMessageFor(restartPending: false).contains("sofort startklar"))

        let pending = TracingViewModel(.stub.with(studyMode: true))
        pending.markComparisonSettingChanged()
        pending.announceNewChildReady()
        #expect(pending.toastMessage == NextParticipantCopy.readyMessageFor(restartPending: true))
        #expect(!NextParticipantCopy.readyMessageFor(restartPending: true).contains("startklar"))
        #expect(NextParticipantCopy.readyMessageFor(restartPending: true).contains("Neustart"))
        // The ready toast keeps its identifier either way (UI tests wait on it).
        #expect(NextParticipantCopy.toastIdentifier(for: NextParticipantCopy.readyMessageRestartPending)
                == NextParticipantCopy.readyToastIdentifier)
    }
}

// MARK: - The enrolment record's comparison stamp across a relaunch

@MainActor
@Suite struct EnrolmentRestampTests {

    private let staleStamp = "panningEnabled=true;old=1"

    /// A launch: a view model over `log` and `dash`, panning OFF so the
    /// session's own stamp is non-nil and different from `staleStamp`.
    private func launch(log: StubEnrolmentLog, dash: ParentDashboardStoring? = nil,
                        panning: Bool = false) -> TracingViewModel {
        var deps = TracingDependencies.stub
            .with(studyMode: true)
            .with(participantEnrolled: true)
            .with(audioCondition: .phoneme)
            .with(trainedSubset: TrainedLetterSubset.defaultForInstall)
        if let dash { deps = deps.with(dashboardStore: dash) }
        deps.panningEnabled = panning
        deps.enrolmentLog = log
        return TracingViewModel(deps)
    }

    private func seed(_ log: StubEnrolmentLog, stamp: String?) -> UUID {
        let id = ParticipantStore.participantId
        log.append(EnrolmentRecord(participantId: id, enrolledAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   audioCondition: .phoneme,
                                   trainedSubset: TrainedLetterSubset.defaultForInstall.rawValue,
                                   protocolRevision: 26, comparisonConfiguration: stamp,
                                   voiceId: "rec:kiki:abcdef123456"))
        return id
    }

    @Test("a relaunch re-stamps the live child's enrolment record with the configuration now running")
    func relaunchRestampsTheRecord() {
        let log = StubEnrolmentLog()
        let id = seed(log, stamp: staleStamp)
        let vm = launch(log: log)
        let running = vm.comparisonConfigurationStamp
        #expect(running != nil && running != staleStamp, "fixture: the session must run a different configuration")
        let record = vm.enrolmentRecords.last { $0.participantId == id }
        #expect(record?.comparisonConfiguration == running,
                "record says \(String(describing: record?.comparisonConfiguration)), the session runs \(String(describing: running))")
        // What describes the enrolment itself is kept.
        #expect(record?.protocolRevision == 26)
        #expect(record?.enrolledAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(record?.voiceId == "rec:kiki:abcdef123456")
    }

    @Test("a record stamped with a switch that is back at its default is re-stamped to the pilot configuration (nil)")
    func restampToThePilotConfiguration() {
        let log = StubEnrolmentLog()
        let id = seed(log, stamp: staleStamp)
        let vm = launch(log: log, panning: StudyComparisonSettings.panningEnabledDefault)
        #expect(vm.comparisonConfigurationStamp == nil, "fixture: the defaults must stamp nothing")
        #expect(vm.enrolmentRecords.last { $0.participantId == id }?.comparisonConfiguration == nil)
    }

    @Test("a record that already matches is left alone")
    func matchingRecordIsUntouched() {
        let log = StubEnrolmentLog()
        let id = seed(log, stamp: nil)
        let vm = launch(log: log, panning: StudyComparisonSettings.panningEnabledDefault)
        let record = vm.enrolmentRecords.last { $0.participantId == id }
        #expect(record?.comparisonConfiguration == nil)
        #expect(record?.protocolRevision == 26)
    }

    @Test("once the child has a row the record keeps the enrolment-time stamp (the rows carry their own)")
    func recordIsKeptAfterTheFirstRow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RESTAMP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dash = JSONParentDashboardStore(fileURL: dir.appendingPathComponent("dash.json"),
                                            failureCenter: PersistenceFailureCenter())
        dash.recordPhaseSession(letter: "F", phase: "observe", completed: true, score: 0.7, schedulerPriority: 0,
                                condition: .threePhase, audioCondition: .phoneme, assessment: nil,
                                recognition: nil, trainedSubset: nil, probe: nil)
        let log = StubEnrolmentLog()
        let id = seed(log, stamp: staleStamp)
        let vm = launch(log: log, dash: dash)
        #expect(!vm.assignmentOverrideAllowed, "fixture: the child must have a row")
        #expect(vm.enrolmentRecords.last { $0.participantId == id }?.comparisonConfiguration == staleStamp)
    }

    // The Vergleichsmodus and Abschlusstest switches lock after the child's
    // first row, as the overrides do (docs/DECISIONS.md, r27). The
    // `.disabled` wiring in SettingsView is not reachable from a unit test;
    // what is pinned here is the predicate it reads and the note it shows.
    @Test("the comparison switches are changeable before the child's first row and locked after it")
    func comparisonSettingsLockAfterTheFirstRow() throws {
        let before = launch(log: StubEnrolmentLog())
        #expect(before.comparisonSettingsAllowed, "no row yet: the switches may still change")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("COMPLOCK-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dash = JSONParentDashboardStore(fileURL: dir.appendingPathComponent("dash.json"),
                                            failureCenter: PersistenceFailureCenter())
        dash.recordPhaseSession(letter: "F", phase: "observe", completed: true, score: 0.7, schedulerPriority: 0,
                                condition: .threePhase, audioCondition: .phoneme, assessment: nil,
                                recognition: nil, trainedSubset: nil, probe: nil)
        let after = launch(log: StubEnrolmentLog(), dash: dash)
        #expect(!after.comparisonSettingsAllowed, "the child has a row: the switches are locked")
    }

    @Test("the locked note names both sections and when they could change")
    func comparisonLockedNoteSaysWhat() {
        #expect(ResearchStatus.comparisonLockedNote.contains("Vergleichsmodus"))
        #expect(ResearchStatus.comparisonLockedNote.contains("Abschlusstest"))
        #expect(ResearchStatus.comparisonLockedNote.contains("nur vor dem ersten Buchstaben änderbar"))
    }
}
