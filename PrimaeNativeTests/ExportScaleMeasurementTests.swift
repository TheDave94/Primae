// ExportScaleMeasurementTests.swift
//
// MEASUREMENT INSTRUMENT for audit R-086 ("export on main, archives decoded
// at launch"). The register's first step is to measure, with a 40-archive
// fixture, before anything moves off the main actor. This suite does that
// and nothing else: it changes no production behaviour, asserts only
// correctness invariants, and PRINTS the timings and sizes in one line:
//
//     R-086 MEASURE archives=40 ... decodeMs=... exportCsvMs=... ...
//
// Grep the test log for `R-086 MEASURE`. Timing is NOT a gate here: no
// assertion reads a duration. Run it on the physical iPad — a simulator
// number says nothing about the device the pilot runs on.
//
// WHAT IS MEASURED, and through which production path:
//   seal    40 x `JSONParticipantArchiveStore.archive(_:)` (encode, staged
//           write, read-back verify, rename) — the "Nächstes Kind" cost.
//   decode  `JSONParticipantArchiveStore.init(directoryURL:)` on a
//           directory holding the 40 seals — exactly what launch runs
//           (`loadAll`, every archive decoded eagerly).
//   export  per format, the body of `makeResearchExport(format:)`
//           (`ResearchExportPreparation.swift`, called synchronously from
//           `ExportCenterView.export(format:)` in ParentAreaView): the
//           `allParticipantExportSources` mapping over the archive, then
//           `ParentDashboardExporter.combinedExportForSharing(...)`, which
//           writes the tmp/ file AND the retained `Exports/` copy.
//           The mapping is mirrored here (it is a one-line `map` on the
//           view model; building a TracingViewModel would move the
//           process-wide ParticipantStore identity). The live child is
//           not appended: all 40 are archived, the end-of-day state.
//
// ISOLATION (CLAUDE.md, Test Infrastructure point 5): every file goes under
// one fresh temporary directory — the archive store and the export
// `Locations` are both injected — and a private `PersistenceFailureCenter`.
// Nothing touches Application Support, `UserDefaults.standard` (the letter
// repository is given its weight, so it does not read the preference) or
// `ParticipantStore`. The directory is removed at the end.
//
// THE FIXTURE, per child (see `PerChild`): a single pilot session of one
// child under the three-phase protocol (D5: observe -> guided -> freeWrite):
//   pretest   5 cold probes, one per study letter (StudyProbe.pretest:
//             "every child writes all five study letters once")
//   training  3 trained letters x 3 passes x (observe, guided, freeWrite)
//             = 27 rows, plus 1 REJECTED free-writing attempt per trained
//             letter (r25 allows up to three attempts) = 3 rows. Three
//             passes per letter is the golden fixture's rich child (three
//             scored free-writing rows of one letter) applied to every
//             trained letter, which fits the 10-20 min session in D-header.
//   posttest  5 cold probes (StudyProbe.posttest: all five, cold)
//   => 40 phase rows, 19 session-duration rows (one per letter session),
//      22 raw traces (one per free-writing production with ink: 5 + 9 + 3
//      + 5), each 1200 samples = 5 s at the Apple Pencil's 240 Hz
//      coalesced rate (TracingCanvasView reads `coalescedTouches`), every
//      coordinate/timestamp/force a full-precision Double, and each trace
//      carrying the REAL bundle reference strokes for its letter (strokes
//      only, as `strokeTracker.definition` holds them — no skeleton).
//   This is deliberately the pencil upper end: a finger at 60-120 Hz
//   produces a quarter to a half of the samples. The counts are constants
//   so the supervisor can re-run at another size by editing one line.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite("R-086 export and archive-load scale measurement")
struct ExportScaleMeasurementTests {

    /// The fixture's shape. Edit here to re-measure at another scale.
    enum PerChild {
        static let children = 40
        static let trainedLetterCount = 3
        static let trainingPasses = 3
        static let rejectedAttemptsPerTrainedLetter = 1
        static let samplesPerTrace = 1200          // 5 s x 240 Hz
        static let strokesPerTrace = 3
    }

    // MARK: - The measurement

    @Test("40 archived children: seal, launch decode, combined export (prints R-086 MEASURE)")
    func measureFortyChildren() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("R086-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let archiveDir = root.appendingPathComponent("ParticipantArchive", isDirectory: true)
        let locations = ExportFileRetention.Locations.standard(
            applicationSupport: root.appendingPathComponent("Support", isDirectory: true),
            temporary: root.appendingPathComponent("tmp", isDirectory: true))
        try fm.createDirectory(at: locations.temporaryDirectory, withIntermediateDirectories: true)

        let references = try Self.referenceStrokes()
        let children = (0..<PerChild.children).map { Self.child(index: $0, references: references) }
        let enrolments = children.enumerated().map { i, c in
            EnrolmentRecord(participantId: c.participantId, enrolledAt: c.enrolledAt,
                            audioCondition: Self.audioArms[i % 3],
                            trainedSubset: Self.subsets[i % Self.subsets.count],
                            protocolRevision: 26,
                            voiceId: "rec:kiki:0123456789ab",
                            environment: GoldenExportFixture.environment,
                            build: GoldenExportFixture.build)
        }

        let clock = ContinuousClock()

        // Seal: through the REAL store, one `archive(_:)` per child.
        let sealingStore = JSONParticipantArchiveStore(directoryURL: archiveDir,
                                                       failureCenter: PersistenceFailureCenter())
        #expect(sealingStore.archivedParticipants.isEmpty, "the temp archive must start empty")
        var sealDurations: [Duration] = []
        for c in children {
            sealDurations.append(try clock.measure { try sealingStore.archive(c) })
        }
        let archiveBytes = try Self.directoryBytes(archiveDir)

        // Decode: a fresh store on the same directory is what launch runs.
        var loaded: JSONParticipantArchiveStore!
        let decode = clock.measure {
            loaded = JSONParticipantArchiveStore(directoryURL: archiveDir,
                                                 failureCenter: PersistenceFailureCenter())
        }

        // Correctness of the load: every child back, nothing set aside, no row lost.
        #expect(loaded.archivedParticipants.count == PerChild.children)
        #expect(loaded.setAsideArchiveFiles.isEmpty)
        #expect(Set(loaded.archivedParticipants.map(\.participantId))
                == Set(children.map(\.participantId)))
        let loadedRows: Int = Self.total(loaded.archivedParticipants) { $0.snapshot.phaseSessionRecords.count }
        let sealedRows: Int = Self.total(children) { $0.snapshot.phaseSessionRecords.count }
        let loadedTraces: Int = Self.total(loaded.archivedParticipants) { $0.rawTraces.count }
        let sealedTraces: Int = Self.total(children) { $0.rawTraces.count }
        #expect(loadedRows == sealedRows)
        #expect(loadedTraces == sealedTraces)

        // Export: the body of `makeResearchExport(format:)`, per format.
        var exportMs: [DashboardExportFormat: Double] = [:]
        var exportBytes: [DashboardExportFormat: Int] = [:]
        for format in [DashboardExportFormat.csv, .tsv, .json] {
            var url: URL!
            let d = try clock.measure {
                let sources = loaded.archivedParticipants.map {
                    ParticipantExportSource(snapshot: $0.snapshot, participantId: $0.participantId,
                                            progress: $0.progress, rawTraces: $0.rawTraces,
                                            enrolledAt: $0.enrolledAt)
                }
                url = try ParentDashboardExporter.combinedExportForSharing(
                    participants: sources, enrolments: enrolments,
                    setAside: loaded.setAsideArchiveFiles,
                    format: format, locations: locations)
            }
            let data = try Data(contentsOf: url)
            exportMs[format] = Self.ms(d)
            exportBytes[format] = data.count

            // Correctness of the export: every one of the 40 ids is in it.
            #expect(String(data: data, encoding: .utf8) != nil, "\(format): the export is not valid UTF-8")
            // Byte search, not `String.contains`: forty Unicode-aware scans
            // of the 173 MB JSON export took ~100 s of this test at -Onone,
            // all of it on the main actor. A UUID string is ASCII, so a
            // byte match is the same predicate.
            let missing = children.map(\.participantId.uuidString).filter { !Self.bytes(data, contain: $0) }
            #expect(missing.isEmpty, "\(format): \(missing.count) participant id(s) missing from the export")
            #expect(url.lastPathComponent.contains("_all\(PerChild.children)."),
                    "\(format): file name should count \(PerChild.children) children, got \(url.lastPathComponent)")
        }

        let rowsPerChild = children[0].snapshot.phaseSessionRecords.count
        let tracesPerChild = children[0].rawTraces.count
        let sealMs = sealDurations.map { Self.ms($0) }
        let line = [
            "R-086 MEASURE",
            "archives=\(PerChild.children)",
            "rowsPerChild=\(rowsPerChild)",
            "durationsPerChild=\(children[0].snapshot.sessionDurations.count)",
            "tracesPerChild=\(tracesPerChild)",
            "samplesPerTrace=\(PerChild.samplesPerTrace)",
            "archiveBytes=\(archiveBytes)",
            "sealMsTotal=\(Self.f(sealMs.reduce(0, +)))",
            "sealMsMax=\(Self.f(sealMs.max() ?? 0))",
            "decodeMs=\(Self.f(Self.ms(decode)))",
            "exportCsvMs=\(Self.f(exportMs[.csv] ?? -1))",
            "csvBytes=\(exportBytes[.csv] ?? -1)",
            "exportTsvMs=\(Self.f(exportMs[.tsv] ?? -1))",
            "tsvBytes=\(exportBytes[.tsv] ?? -1)",
            "exportJsonMs=\(Self.f(exportMs[.json] ?? -1))",
            "jsonBytes=\(exportBytes[.json] ?? -1)",
        ].joined(separator: " ")
        print(line)
    }

    /// Whether `haystack` holds the UTF-8 bytes of `needle` (`memmem`).
    static func bytes(_ haystack: Data, contain needle: String) -> Bool {
        let n = Array(needle.utf8)
        return haystack.withUnsafeBytes { hay in
            n.withUnsafeBytes { nd in
                memmem(hay.baseAddress, hay.count, nd.baseAddress, nd.count) != nil
            }
        }
    }

    // MARK: - Fixture

    static let thesisArms: [ThesisCondition] = [.threePhase, .guidedOnly, .control]
    static let audioArms: [PilotAudioCondition] = [.phoneme, .spatial, .silent]
    static let subsets = ["AFI", "FIL", "ILM", "AIM", "AFM", "FLM"]
    static let day0 = Date(timeIntervalSince1970: 1_791_123_200.25)

    /// The real bundle reference strokes of the five study letters, as the
    /// tracker holds them (strokes only; no skeleton).
    static func referenceStrokes() throws -> [String: LetterStrokes] {
        let repo = LetterRepository(resources: BundleLetterResourceProvider(),
                                    cache: NullLetterCache(), weight: .regular)
        let assets = repo.loadLetters()
        var out: [String: LetterStrokes] = [:]
        for letter in TrainedLetterSubset.studyLetters {
            let asset = try #require(assets.first { $0.name == letter },
                                     "bundle letter \(letter) not found (\(assets.count) assets loaded)")
            out[letter] = LetterStrokes(letter: letter,
                                        checkpointRadius: asset.strokes.checkpointRadius,
                                        strokes: asset.strokes.strokes)
        }
        return out
    }

    /// One archived child: the session described in the file header.
    static func child(index i: Int, references: [String: LetterStrokes]) -> ArchivedParticipant {
        let id = UUID()
        let condition = thesisArms[i % 3]
        let audio = audioArms[i % 3]
        let subset = subsets[i % subsets.count]
        let trained = Array(subset.map { String($0) }.prefix(PerChild.trainedLetterCount))
        // One child every 20 minutes on one pilot morning.
        let enrolledAt = day0.addingTimeInterval(Double(i) * 1200)
        var t: TimeInterval = 5
        func next(_ dt: TimeInterval) -> Date { t += dt; return enrolledAt.addingTimeInterval(t) }

        let delivery = PhaseDelivery(
            observeRestarts: 0, strokesCancelled: 1, routeChanges: 0, interruptions: 0,
            atStart: GoldenExportFixture.environment, outputRouteAtEnd: "BuiltInSpeaker",
            voiceId: "rec:kiki:0123456789ab", recognizerAvailable: true,
            build: GoldenExportFixture.build,
            observeLossesDuringSound: 0, observeLossesWithoutSound: 0,
            observeSoundSeconds: 2.0, observeSoundDeliveredSeconds: 1.9375,
            soundEngine: "tdpsola",
            liftHoldSeconds: 0.35, stallSeconds: 1.25, strokeGaps: 2, strokeGapMedianSeconds: 0.4)
        let assessment = WritingAssessment(formAccuracy: 0.71, tempoConsistency: 0.53,
                                           pressureControl: 0.88, rhythmScore: 0.42)

        var rows: [PhaseSessionRecord] = []
        var durations: [SessionDurationRecord] = []
        var traces: [RawTrace] = []

        func freeWrite(_ letter: String, probe: StudyProbe?, accepted: Bool, attempt: Int) {
            let at = next(6)
            let trace = synthesizedTrace(letter: letter, recordedAt: at, seed: traces.count + i * 100,
                                         reference: references[letter])
            traces.append(trace)
            var r = PhaseSessionRecord(
                letter: letter, phase: "freeWrite", completed: accepted,
                score: accepted ? 0.61 + Double(traces.count) * 0.003 : 0.0,
                schedulerPriority: 0.5, condition: condition, audioCondition: audio,
                recordedAt: at, assessment: accepted ? assessment : nil,
                recognition: RecognitionSample(predictedLetter: letter, confidence: 0.83,
                                               rawConfidence: 0.86, isCorrect: true),
                inputDevice: "pencil", rawTraceID: trace.id, trainedSubset: subset,
                phaseDurationSeconds: 5.0, checkpointCoverage: 0.8, spatialDeviation: 0.137,
                strokeCount: PerChild.strokesPerTrace, strokeOrder: "0,1,2",
                reversedStrokeCount: 0, studyMode: true, probe: probe?.rawValue,
                protocolRevision: 26, spatialDeviationRaw: 0.211, rowId: UUID(),
                context: PhaseRowContext(
                    finalizedBy: accepted ? .child : .attemptRejected,
                    probeAttempt: probe == nil ? nil : 1,
                    delivery: probe == nil ? delivery : nil,
                    freeWriteAttempt: attempt,
                    attemptCheck: FreeWriteAttemptCheck.Result(
                        passed: accepted, shapeScore: accepted ? 0.86 : 0.41,
                        lengthRatio: 1.21, extraReversals: accepted ? 0 : 3)))
            r.enrolmentId = id
            rows.append(r)
        }
        func plainPhase(_ letter: String, _ phase: String) {
            var r = PhaseSessionRecord(
                letter: letter, phase: phase, completed: true, score: 0.72,
                schedulerPriority: 0.5, condition: condition, audioCondition: audio,
                recordedAt: next(8), inputDevice: "pencil", trainedSubset: subset,
                phaseDurationSeconds: 7.5, checkpointCoverage: phase == "guided" ? 0.9 : nil,
                studyMode: true, protocolRevision: 26, rowId: UUID(),
                context: PhaseRowContext(finalizedBy: .child, delivery: delivery))
            r.enrolmentId = id
            rows.append(r)
        }
        func sessionDuration(_ letter: String, probe: StudyProbe?) {
            var d = SessionDurationRecord(
                dateString: "2026-10-04", durationSeconds: probe == nil ? 31.5 : 8.25,
                wallClockSeconds: probe == nil ? 36.0 : 9.5, condition: condition,
                recordedAt: next(1), inputDevice: "pencil", letter: letter,
                audioCondition: audio, studyMode: true, probe: probe?.rawValue,
                trainedSubset: subset, protocolRevision: 26, rowId: UUID())
            d.enrolmentId = id
            durations.append(d)
        }

        for letter in TrainedLetterSubset.studyLetters {
            freeWrite(letter, probe: .pretest, accepted: true, attempt: 1)
            sessionDuration(letter, probe: .pretest)
        }
        for pass in 0..<PerChild.trainingPasses {
            for letter in trained {
                plainPhase(letter, "observe")
                plainPhase(letter, "guided")
                if pass == 0 {
                    for a in 0..<PerChild.rejectedAttemptsPerTrainedLetter {
                        freeWrite(letter, probe: nil, accepted: false, attempt: a + 1)
                    }
                }
                freeWrite(letter, probe: nil, accepted: true,
                          attempt: pass == 0 ? PerChild.rejectedAttemptsPerTrainedLetter + 1 : 1)
                sessionDuration(letter, probe: nil)
            }
        }
        for letter in TrainedLetterSubset.studyLetters {
            freeWrite(letter, probe: .posttest, accepted: true, attempt: 1)
            sessionDuration(letter, probe: .posttest)
        }

        var stats: [String: LetterAccuracyStat] = [:]
        var progress: [String: LetterProgress] = [:]
        for letter in TrainedLetterSubset.studyLetters {
            stats[letter] = LetterAccuracyStat(letter: letter, accuracySamples: [0.5, 0.625, 0.71])
            var p = LetterProgress()
            p.completionCount = trained.contains(letter) ? PerChild.trainingPasses : 0
            p.bestAccuracy = 0.71
            p.lastCompletedAt = enrolledAt.addingTimeInterval(t)
            p.speedTrend = [0.5, 0.55, 0.61]
            p.recognitionAccuracy = [0.83, 0.79, 0.88]
            progress[letter] = p
        }

        return ArchivedParticipant(
            participantId: id, enrolledAt: enrolledAt,
            archivedAt: enrolledAt.addingTimeInterval(1080),
            snapshot: DashboardSnapshot(letterStats: stats, sessionDurations: durations,
                                        phaseSessionRecords: rows),
            progress: progress, rawTraces: traces)
    }

    /// A deterministic pencil trace: `samplesPerTrace` samples at 240 Hz in
    /// `strokesPerTrace` strokes, on a 1024 x 768 canvas, every value a
    /// full-precision Double (as real touch data is).
    static func synthesizedTrace(letter: String, recordedAt: Date, seed: Int,
                                 reference: LetterStrokes?) -> RawTrace {
        let n = PerChild.samplesPerTrace
        let phase = Double(seed) * 0.137
        var points: [CGPoint] = []
        var timestamps: [CFTimeInterval] = []
        var forces: [CGFloat] = []
        points.reserveCapacity(n); timestamps.reserveCapacity(n); forces.reserveCapacity(n)
        let t0 = 48_213.416_670_833 + Double(seed) * 37.1
        for k in 0..<n {
            let u = Double(k) / Double(n)
            points.append(CGPoint(x: 512 + 180 * sin(6.283_185 * u + phase) + 3.1 * sin(97 * u),
                                  y: 384 + 220 * cos(4.712_389 * u + phase) + 2.7 * cos(83 * u)))
            timestamps.append(t0 + Double(k) / 240.0)
            forces.append(0.55 + 0.25 * sin(13.7 * u + phase))
        }
        let per = n / PerChild.strokesPerTrace
        return RawTrace(id: UUID(), letter: letter, recordedAt: recordedAt,
                        points: points, timestamps: timestamps, forces: forces,
                        strokeStartIndices: (0..<PerChild.strokesPerTrace).map { $0 * per },
                        canvasSize: CGSize(width: 1024, height: 768),
                        referenceStrokes: reference)
    }

    // MARK: - Helpers

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    static func total(_ records: [ArchivedParticipant], _ count: (ArchivedParticipant) -> Int) -> Int {
        var sum = 0
        for r in records { sum += count(r) }
        return sum
    }

    static func f(_ v: Double) -> String { String(format: "%.1f", v) }

    static func directoryBytes(_ dir: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            .reduce(0) { $0 + ((try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
