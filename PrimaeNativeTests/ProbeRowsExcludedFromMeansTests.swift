// ProbeRowsExcludedFromMeansTests.swift
// PrimaeNativeTests
//
// Export audit 2026-11-23, finding 2 (protocol r27): `isScoredFreeWrite` had no
// probe filter, so a cold-probe row (pretest, post-test, delayed — and the r27
// final test) was averaged into `averageFreeWriteScore_<arm>`, `letterByArm`
// and the dashboard's mean and scheduler proxy, as if it were a training
// freeWrite. The old golden's 0.5125 included a pretest row. Every StudyProbe
// case is iterated, not named, so a case added later is covered the day it is
// added. The probe row stays in the per-row export; only the means skip it.

import Testing
import Foundation
@testable import PrimaeNative

@MainActor
@Suite struct ProbeRowsExcludedFromMeansTests {

    private let pid = UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!
    private let t0 = Date(timeIntervalSince1970: 1_793_100_000)

    private func row(_ letter: String, _ score: Double, _ dt: TimeInterval, probe: String? = nil,
                     priority: Double = 0.5) -> PhaseSessionRecord {
        PhaseSessionRecord(letter: letter, phase: "freeWrite", completed: true, score: score,
                           schedulerPriority: priority, condition: .threePhase, audioCondition: .phoneme,
                           recordedAt: t0.addingTimeInterval(dt), studyMode: true, probe: probe)
    }

    private func csv(_ snapshot: DashboardSnapshot) -> [String] {
        let source = ParticipantExportSource(snapshot: snapshot, participantId: pid,
                                             progress: [:], rawTraces: [], enrolledAt: nil)
        return String(decoding: ParentDashboardExporter.combinedDelimitedData(participants: [source], separator: ","),
                      as: UTF8.self).components(separatedBy: "\n")
    }

    @Test("a probe row does not move the per-arm means, the per-letter means or the snapshot's own mean",
          arguments: StudyProbe.allCases)
    func aProbeRowDoesNotMoveTheMeans(probe: StudyProbe) {
        var withProbe = DashboardSnapshot()
        withProbe.phaseSessionRecords = [row("A", 0.8, 10), row("A", 0.6, 20), row("M", 0.1, 5, probe: probe.rawValue)]
        var withoutProbe = DashboardSnapshot()
        withoutProbe.phaseSessionRecords = [row("A", 0.8, 10), row("A", 0.6, 20)]

        let lines = csv(withProbe)
        #expect(lines.contains("averageFreeWriteScore_threePhase,0.7000"), "arm mean moved: \(lines.filter { $0.hasPrefix("averageFreeWriteScore") })")
        #expect(lines.contains("averageFreeWriteScore_audio_phoneme,0.7000"))
        #expect(!lines.contains { $0.hasPrefix("letterByArm,M,") || $0.hasPrefix("letterByAudioArm,M,") },
                "a probe-only letter got a per-letter mean")
        // The same numbers as the file without the probe row at all.
        #expect(csv(withoutProbe).filter { $0.hasPrefix("averageFreeWriteScore") || $0.hasPrefix("letterBy") }
                == lines.filter { $0.hasPrefix("averageFreeWriteScore") || $0.hasPrefix("letterBy") })
        // The row itself is still exported, tagged.
        #expect(lines.contains { $0.hasPrefix("M,freeWrite,") && $0.contains(",\(probe.rawValue),") })
        // The dashboard's own mean (the parent area's Schreibmotorik mean).
        #expect(withProbe.averageFreeWriteScoreIfDefined == withoutProbe.averageFreeWriteScoreIfDefined)
        #expect(withProbe.averageFreeWriteScoreIfDefined.map { abs($0 - 0.7) < 1e-12 } == true)
    }

    @Test("a snapshot with only probe rows has no training mean at all", arguments: StudyProbe.allCases)
    func onlyProbeRowsMeansNoData(probe: StudyProbe) {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [row("A", 0.4, 10, probe: probe.rawValue), row("L", 0.9, 20, probe: probe.rawValue)]
        #expect(snap.averageFreeWriteScoreIfDefined == nil)
        let lines = csv(snap)
        #expect(!lines.contains { $0.hasPrefix("averageFreeWriteScore_") }, "\(lines.filter { $0.hasPrefix("averageFreeWriteScore") })")
    }

    @Test("the Schreibmotorik dimension means skip a probe row",
          arguments: StudyProbe.allCases)
    func dimensionMeansSkipProbeRows(probe: StudyProbe) {
        func dimRow(_ letter: String, _ v: CGFloat, _ dt: TimeInterval, probe: String? = nil) -> PhaseSessionRecord {
            PhaseSessionRecord(letter: letter, phase: "freeWrite", completed: true, score: 0.5, schedulerPriority: 0.5,
                               condition: .threePhase, audioCondition: .phoneme,
                               recordedAt: t0.addingTimeInterval(dt),
                               assessment: WritingAssessment(formAccuracy: v, tempoConsistency: v,
                                                             pressureControl: v, rhythmScore: v),
                               studyMode: true, probe: probe)
        }
        var withProbe = DashboardSnapshot()
        withProbe.phaseSessionRecords = [dimRow("A", 0.75, 10), dimRow("A", 0.25, 20), dimRow("M", 0.0, 5, probe: probe.rawValue)]
        let dims = withProbe.averageWritingDimensions
        #expect(dims.map { abs($0.form - 0.5) < 1e-6 && abs($0.tempo - 0.5) < 1e-6
                    && abs($0.pressure - 0.5) < 1e-6 && abs($0.rhythm - 0.5) < 1e-6 } == true,
                "a probe row moved a dimension mean: \(String(describing: dims))")
        let lines = csv(withProbe)
        #expect(lines.contains("averageFormAccuracy,0.5000"), "\(lines.filter { $0.hasPrefix("average") })")
        #expect(lines.contains("averageRhythmScore,0.5000"))

        var onlyProbe = DashboardSnapshot()
        onlyProbe.phaseSessionRecords = [dimRow("M", 0.9, 5, probe: probe.rawValue)]
        #expect(onlyProbe.averageWritingDimensions == nil)
        #expect(!csv(onlyProbe).contains { $0.hasPrefix("averageFormAccuracy") })
    }

    @Test("the scheduler proxy does not pair a probe row with a training row")
    func theSchedulerProxyIgnoresProbeRows() {
        // Training rows of A: priorities 0.9 and 0.1; a probe row of A (priority 0.5) in between.
        // Without the probe row the pairs are (0.9 -> +0.4) only: below 2 pairs, so undefined.
        // With it, (0.9 -> +0.7) and (0.5 -> -0.3) vary in both axes, so the proxy WOULD be
        // defined (the priorities must differ: equal priorities have zero variance and leave
        // the proxy nil whatever the rows, which made this test unable to fail).
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [row("A", 0.2, 10, priority: 0.9),
                                    row("A", 0.9, 20, probe: "pretest", priority: 0.5),
                                    row("A", 0.6, 30, priority: 0.1)]
        #expect(snap.schedulerEffectivenessProxyIfDefined == nil,
                "a probe row was paired with training rows: \(String(describing: snap.schedulerEffectivenessProxyIfDefined))")
    }
}
