// The FIXED inputs of `ExporterGoldenFileTests` (ROADMAP §4 D11 item 4).
//
// Everything here is a literal: participant ids, instants, scores, stamps.
// Nothing reads the clock, the device, `UserDefaults`, a bundle or
// `StudyProtocol.revision` (the revision is pinned as the literal 26 on
// every row — the golden pins the export FORMAT, and a future protocol bump
// must not rewrite a fixture it did not touch). A fixture that read any of
// them would make the golden a measurement of the machine.
//
// Kept apart from the test so it carries no Swift Testing import and can be
// compiled by a plain `swiftc` driver together with `PrimaeNative/Core` to
// regenerate the expected text.
//
// ARM COVERAGE. Three participants, one per thesis arm AND one per audio
// arm, deliberately paired so every row family of the export is non-empty:
//   P1 threePhase / phoneme — the rich child: pre-enrolment row, observe
//      row (observe-sound columns), three scored free-writing rows of one
//      letter (so the scheduler proxy exists), a REJECTED attempt (r25,
//      `attemptRejected`, excluded from completion rates), and a cold
//      pretest probe row.
//   P2 guidedOnly / spatial, P3 control / silent — one scored row each.
//   E4 — enrolled and stopped: no participant block, only the enrolment row.

import Foundation
@testable import PrimaeNative

enum GoldenExportFixture {

    // MARK: - Fixed identity

    static let p1 = UUID(uuidString: "00000000-0000-0000-0000-00000000D111")!
    static let p2 = UUID(uuidString: "00000000-0000-0000-0000-00000000D112")!
    static let p3 = UUID(uuidString: "00000000-0000-0000-0000-00000000D113")!
    static let e4 = UUID(uuidString: "00000000-0000-0000-0000-00000000D114")!

    /// 2026-10-04T14:13:20Z, plus a quarter second so every exported
    /// timestamp carries a non-zero fractional part.
    static let t0 = Date(timeIntervalSince1970: 1_791_123_200.25)
    private static func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// The one timezone the golden is written in. Injected through the
    /// exporter's `timeZone:` seam (production default `.current`) — the
    /// `# timezone=` header line is the only machine-dependent byte in the
    /// export, and `TimeZone.current` cannot be set without mutating global
    /// state under parallel suites.
    static let timeZone = TimeZone(identifier: "Europe/Vienna")!

    // MARK: - Stamps (R-018 / R-020), every field populated

    static let environment = EnvironmentStamp(
        outputRoute: "BuiltInSpeaker", outputVolume: 0.5, outputLatency: 0.012,
        otherAudioPlaying: false, secondaryAudioHint: false,
        guidedAccess: true, idleTimerDisabled: true, lowPowerMode: false,
        thermalState: "nominal", batteryLevel: 0.875)

    static let build = BuildStamp(
        launchId: "LAUNCH-0001", previousRunAbnormal: false, appVersion: "1.0 (26)",
        buildConfiguration: "Release-Study", buildUUID: "BUILD-UUID-0001",
        osVersion: "27.2", deviceModel: "iPad13,18")

    // MARK: - Participants

    static func participants() -> [ParticipantExportSource] {
        [source1(), source2(), source3()]
    }

    static func enrolments() -> [EnrolmentRecord] {
        [
            EnrolmentRecord(participantId: p1, enrolledAt: at(0), audioCondition: .phoneme,
                            trainedSubset: "AFI", protocolRevision: 26,
                            comparisonConfiguration: nil, voiceId: "rec:kiki:0123456789ab",
                            environment: environment, build: build),
            EnrolmentRecord(participantId: p2, enrolledAt: nil, audioCondition: .spatial,
                            trainedSubset: "FIL", protocolRevision: 26),
            EnrolmentRecord(participantId: p3, enrolledAt: at(10), audioCondition: .silent,
                            trainedSubset: "ILM", protocolRevision: 26,
                            comparisonConfiguration: "allFiveLetters"),
            EnrolmentRecord(participantId: e4, enrolledAt: at(20), audioCondition: .phoneme,
                            trainedSubset: "AIM", protocolRevision: 26),
        ]
    }

    // MARK: P1 — threePhase / phoneme

    private static func source1() -> ParticipantExportSource {
        let delivery = PhaseDelivery(
            observeRestarts: 1, strokesCancelled: 2, routeChanges: 0, interruptions: 1,
            atStart: environment, outputRouteAtEnd: "BuiltInSpeaker",
            voiceId: "rec:kiki:0123456789ab", recognizerAvailable: true, build: build,
            observeLossesDuringSound: 1, observeLossesWithoutSound: 0,
            observeSoundSeconds: 2.0, observeSoundDeliveredSeconds: 1.875,
            soundEngine: "tdpsola",
            liftHoldSeconds: 0.35, stallSeconds: 1.5, strokeGaps: 3, strokeGapMedianSeconds: 0.425)

        let assessment = WritingAssessment(formAccuracy: 0.75, tempoConsistency: 0.5,
                                           pressureControl: 1.0, rhythmScore: 0.25)
        let recognition = RecognitionSample(predictedLetter: "A", confidence: 0.875,
                                            rawConfidence: 0.9, isCorrect: true)

        var records: [PhaseSessionRecord] = []

        // Written before the enrolment instant: dropped from the block and
        // counted in `# droppedPreEnrolmentRows=`.
        records.append(PhaseSessionRecord(
            letter: "A", phase: "guided", completed: true, score: 0.5, schedulerPriority: 0.5,
            condition: .threePhase, audioCondition: .phoneme, recordedAt: at(-100),
            protocolRevision: 26))

        // observe: carries the observe-sound columns.
        records.append(PhaseSessionRecord(
            letter: "A", phase: "observe", completed: true, score: 1.0, schedulerPriority: 0.9,
            condition: .threePhase, audioCondition: .phoneme, recordedAt: at(5),
            trainedSubset: "AFI", studyMode: true, comparisonConfiguration: nil,
            protocolRevision: 26, rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000A0001")!,
            context: PhaseRowContext(finalizedBy: .child, delivery: delivery)))

        // guided.
        records.append(PhaseSessionRecord(
            letter: "A", phase: "guided", completed: true, score: 0.625, schedulerPriority: 0.9,
            condition: .threePhase, audioCondition: .phoneme, recordedAt: at(15),
            inputDevice: "pencil", trainedSubset: "AFI", checkpointCoverage: 0.625,
            studyMode: true, protocolRevision: 26,
            rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000A0002")!,
            context: PhaseRowContext(finalizedBy: .child)))

        // free-writing pass 1: first attempt accepted.
        records.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.5, schedulerPriority: 0.9,
            condition: .threePhase, audioCondition: .phoneme, recordedAt: at(30),
            assessment: assessment, recognition: recognition, inputDevice: "pencil",
            trainedSubset: "AFI", phaseDurationSeconds: 4.5, checkpointCoverage: 0.8,
            spatialDeviation: 0.125, strokeCount: 3,
            strokeOrder: "0,2,1",     // comma-bearing: must be RFC 4180 quoted
            reversedStrokeCount: 1, studyMode: true, protocolRevision: 26,
            spatialDeviationRaw: 0.25,
            rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000A0003")!,
            context: PhaseRowContext(
                finalizedBy: .child, delivery: delivery, freeWriteAttempt: 1,
                attemptCheck: FreeWriteAttemptCheck.Result(
                    passed: true, shapeScore: 0.875, lengthRatio: 1.25, extraReversals: 0),
                spatialFitShearDegrees: 3.875)))

        // free-writing pass 2: attempt 1 REJECTED (r25), attempt 2 accepted.
        records.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: false, score: 0.0, schedulerPriority: 0.5,
            condition: .threePhase, audioCondition: .phoneme, recordedAt: at(60),
            trainedSubset: "AFI", studyMode: true, protocolRevision: 26,
            rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000A0004")!,
            context: PhaseRowContext(
                finalizedBy: .attemptRejected, freeWriteAttempt: 1,
                attemptCheck: FreeWriteAttemptCheck.Result(
                    passed: false, shapeScore: 0.5, lengthRatio: nil, extraReversals: 4))))
        records.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.7, schedulerPriority: 0.5,
            condition: .threePhase, audioCondition: .phoneme, recordedAt: at(70),
            assessment: assessment, recognition: recognition, inputDevice: "pencil",
            trainedSubset: "AFI", phaseDurationSeconds: 5.25, checkpointCoverage: 0.9,
            spatialDeviation: 0.0625, strokeCount: 2, strokeOrder: "0,1",
            reversedStrokeCount: 0, studyMode: true, protocolRevision: 26,
            spatialDeviationRaw: 0.1875,
            rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000A0005")!,
            context: PhaseRowContext(
                finalizedBy: .child, delivery: delivery, freeWriteAttempt: 2,
                attemptCheck: FreeWriteAttemptCheck.Result(
                    passed: true, shapeScore: 0.9375, lengthRatio: 1.5, extraReversals: 1),
                spatialFitShearDegrees: -7.5)))

        // free-writing pass 3: first attempt accepted.
        records.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.6, schedulerPriority: 0.3,
            condition: .threePhase, audioCondition: .phoneme, recordedAt: at(100),
            trainedSubset: "AFI", studyMode: true, protocolRevision: 26,
            rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000A0006")!,
            context: PhaseRowContext(
                finalizedBy: .child, freeWriteAttempt: 1,
                attemptCheck: FreeWriteAttemptCheck.Result(
                    passed: true, shapeScore: 0.8125, lengthRatio: 2.0, extraReversals: 2))))

        // The cold probe row: an UNTRAINED letter, pretest, first attempt.
        records.append(PhaseSessionRecord(
            letter: "M", phase: "freeWrite", completed: true, score: 0.25, schedulerPriority: 0.0,
            condition: .threePhase, audioCondition: .phoneme, recordedAt: at(2),
            inputDevice: "finger", trainedSubset: "AFI", phaseDurationSeconds: 3.0,
            checkpointCoverage: 0.5, spatialDeviation: 0.375, strokeCount: 4,
            strokeOrder: "0,1,2,3", reversedStrokeCount: 0, studyMode: true,
            probe: "pretest", protocolRevision: 26, spatialDeviationRaw: 0.4375,
            rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000A0007")!,
            context: PhaseRowContext(finalizedBy: .child, probeAttempt: 1, freeWriteAttempt: 1)))

        let snapshot = DashboardSnapshot(
            letterStats: [
                "A": LetterAccuracyStat(letter: "A", accuracySamples: [0.5, 0.75]),
                "M": LetterAccuracyStat(letter: "M", accuracySamples: [0.25]),
            ],
            sessionDurations: [
                // Before enrolment: filtered like the phase rows.
                SessionDurationRecord(dateString: "2026-10-04", durationSeconds: 11.5,
                                      recordedAt: at(-100), protocolRevision: 26),
                SessionDurationRecord(dateString: "2026-10-04", durationSeconds: 125.5,
                                      wallClockSeconds: 140.25, condition: .threePhase,
                                      recordedAt: at(110), inputDevice: "pencil", letter: "A",
                                      audioCondition: .phoneme, studyMode: true, probe: nil,
                                      trainedSubset: "AFI", comparisonConfiguration: nil,
                                      protocolRevision: 26,
                                      rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000B0001")!),
            ],
            phaseSessionRecords: records)

        var progressA = LetterProgress()
        progressA.recognitionAccuracy = [1.0, 0.5, 0.75]
        progressA.speedTrend = [0.5, 0.625]
        progressA.freeformCompletionCount = 2
        progressA.retrievalAttempts = [true, false, true, true]

        return ParticipantExportSource(snapshot: snapshot, participantId: p1,
                                       progress: ["A": progressA], rawTraces: [], enrolledAt: at(0))
    }

    // MARK: P2 — guidedOnly / spatial (never enrolled-stamped: no `# enrolledAt`)

    private static func source2() -> ParticipantExportSource {
        let snapshot = DashboardSnapshot(
            letterStats: [:],
            sessionDurations: [],
            phaseSessionRecords: [
                PhaseSessionRecord(
                    letter: "F", phase: "freeWrite", completed: true, score: 0.8125,
                    schedulerPriority: 0.4, condition: .guidedOnly, audioCondition: .spatial,
                    recordedAt: at(200), inputDevice: "finger", trainedSubset: "FIL",
                    spatialDeviation: 0.5, strokeCount: 2,
                    strokeOrder: "-,0",       // an unmatched stroke: leading "-" AND a comma
                    reversedStrokeCount: 0, studyMode: true, protocolRevision: 26,
                    spatialDeviationRaw: 0.625,
                    rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000A0101")!,
                    context: PhaseRowContext(finalizedBy: .child, freeWriteAttempt: 1,
                                             spatialFitShearDegrees: 15)),
            ])
        return ParticipantExportSource(snapshot: snapshot, participantId: p2,
                                       progress: [:], rawTraces: [], enrolledAt: nil)
    }

    // MARK: P3 — control / silent

    private static func source3() -> ParticipantExportSource {
        let snapshot = DashboardSnapshot(
            letterStats: [:],
            sessionDurations: [],
            phaseSessionRecords: [
                PhaseSessionRecord(
                    letter: "L", phase: "freeWrite", completed: true, score: 0.4375,
                    schedulerPriority: 0.2, condition: .control, audioCondition: .silent,
                    recordedAt: at(300), inputDevice: "finger", trainedSubset: "AFILM",
                    studyMode: true, comparisonConfiguration: "allFiveLetters",
                    protocolRevision: 26,
                    rowId: UUID(uuidString: "00000000-0000-0000-0000-0000000A0201")!,
                    context: PhaseRowContext(finalizedBy: .child, freeWriteAttempt: 1)),
            ])
        return ParticipantExportSource(snapshot: snapshot, participantId: p3,
                                       progress: [:], rawTraces: [], enrolledAt: at(10))
    }

    // MARK: - The export under test

    /// The research CSV as a proctor's combined export writes it: every
    /// archived child's block plus the trailing enrolment block.
    static func csv() -> String {
        let data = ParentDashboardExporter.combinedDelimitedData(
            participants: participants(), enrolments: enrolments(), setAside: [],
            separator: ",", timeZone: timeZone)
        return String(data: data, encoding: .utf8)!
    }
}
