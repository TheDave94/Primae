// PersistenceRobustnessTests.swift
// PrimaeNativeTests
//
// Audit 2026-10-13, lane B2 (persistence robustness). Every test here
// works on its OWN temporary directory. Every store whose actions in a
// test REPORT something — a failure or a notice — is built with the
// test's own `PersistenceFailureCenter`. The remaining stores (the
// "first" store that writes the healthy file a test then damages, and the
// stores that reopen a healthy file to read it back) use the default
// `.shared` center and report nothing to it. That matters: a failure left
// on `.shared` is replayed into every later view model, which would block
// unrelated study-mode suites. (Corrected in review: the original header
// said no test used `.shared` at all, which was not true.)
//
//   R-053  a non-finite value must not stop persistence, and a NaN score
//          must never be recorded as a valid one (it used to clamp to 1.0)
//   R-054  an unreadable or future-schema store file must not be treated
//          as empty and overwritten by the next save
//   R-055  one malformed element of an archived child must not cost the
//          whole child; an undecodable enrolment file is moved aside
//   R-056  a failure reported before anyone subscribed reaches the
//          subscriber
//
// Mutation checks are listed per suite; run them with a SUITE-level
// `-only-testing:` filter and read "Test run with N tests" every time.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - Helpers

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("B2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func removeTempDirectory(_ dir: URL) {
    // Restore permissions first so a chmod-000 file cannot survive cleanup.
    if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
        for item in items {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: item.path)
        }
    }
    try? FileManager.default.removeItem(at: dir)
}

/// Rewrites the store file's `"schemaVersion":1` to a future version.
private func bumpSchemaVersion(at url: URL, to version: Int = 99) throws {
    let text = try String(contentsOf: url, encoding: .utf8)
    let bumped = text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":\(version)")
    try #require(bumped != text, "the store file carries no schemaVersion to bump: \(text.prefix(200))")
    try Data(bumped.utf8).write(to: url)
}

private func makeTrace(letter: String = "A", force: CGFloat = 0.5) -> RawTrace {
    RawTrace(id: UUID(), letter: letter, recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
             points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
             timestamps: [0.0, 0.1],
             forces: [force, 0.5],
             strokeStartIndices: [0],
             canvasSize: CGSize(width: 100, height: 100))
}

// MARK: - R-053 non-finite values

@Suite @MainActor struct NonFinitePersistenceTests {

    @Test("a NaN score is not recorded as a perfect 1.0")
    func nanScoreIsNeverAPerfectScore() {
        let record = PhaseSessionRecord(letter: "A", phase: "freeWrite", completed: true,
                                        score: .nan, schedulerPriority: 0)
        #expect(record.score != 1.0, "max(0, min(1, NaN)) is 1.0 — a NaN must not become a perfect score")
        #expect(record.score.isNaN, "no valid score exists for a NaN measurement; keep it NaN")
    }

    @Test("a NaN spatialDeviation does not stop the rows after it from reaching disk")
    func nanMeasureDoesNotStopLaterRows() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("dashboard.json")
        let center = PersistenceFailureCenter()
        let store = JSONParentDashboardStore(fileURL: url, failureCenter: center)
        store.recordPhaseSession(letter: "A", phase: "freeWrite", completed: true, score: 0.4,
                                 schedulerPriority: 0, condition: .threePhase, audioCondition: .phoneme,
                                 assessment: nil, recognition: nil, inputDevice: nil, rawTraceID: nil,
                                 trainedSubset: nil, phaseDurationSeconds: nil, frechetDistance: nil,
                                 checkpointCoverage: nil, spatialDeviation: .nan)
        store.recordPhaseSession(letter: "F", phase: "freeWrite", completed: true, score: 0.6,
                                 schedulerPriority: 0, condition: .threePhase, audioCondition: .phoneme,
                                 assessment: nil, recognition: nil, inputDevice: nil, rawTraceID: nil,
                                 trainedSubset: nil, phaseDurationSeconds: nil, frechetDistance: nil,
                                 checkpointCoverage: nil, spatialDeviation: 0.12)
        await store.flush()

        let reopened = JSONParentDashboardStore(fileURL: url).snapshot.phaseSessionRecords
        #expect(reopened.count == 2, "both rows must survive a relaunch: \(reopened.map(\.letter))")
        #expect(reopened.first?.spatialDeviation == nil, "the non-finite measure is recorded as absent")
        #expect(reopened.last?.spatialDeviation == 0.12)
        #expect(!center.hasFailed, "a broken measurement is not a lost save")
        #expect(center.notices.count == 1 && center.notices[0].contains("spatialDeviation"),
                "the sanitised measure must be listed for the proctor: \(center.notices)")
    }

    @Test("a NaN score survives a relaunch as NaN — not lost, not 1.0")
    func nanScoreRoundTripsAsNaN() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("dashboard.json")
        let store = JSONParentDashboardStore(fileURL: url, failureCenter: PersistenceFailureCenter())
        store.recordPhaseSession(letter: "A", phase: "freeWrite", completed: true, score: .nan,
                                 schedulerPriority: 0, condition: .threePhase)
        store.recordPhaseSession(letter: "F", phase: "freeWrite", completed: true, score: 0.6,
                                 schedulerPriority: 0, condition: .threePhase)
        await store.flush()

        let reopened = JSONParentDashboardStore(fileURL: url).snapshot.phaseSessionRecords
        #expect(reopened.count == 2, "both rows must survive: \(reopened.map(\.letter))")
        #expect(reopened.first?.score.isNaN == true, "the NaN score must come back NaN: \(String(describing: reopened.first?.score))")
        #expect(reopened.last?.score == 0.6)
    }

    @Test("a non-finite raw-trace sample does not stop later traces from reaching disk")
    func nanTraceDoesNotStopLaterTraces() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("rawtraces.json")
        let center = PersistenceFailureCenter()
        let store = JSONRawTraceStore(fileURL: url, failureCenter: center)
        store.append(makeTrace(letter: "A", force: .nan))
        store.append(makeTrace(letter: "F"))
        await store.flush()

        let reopened = JSONRawTraceStore(fileURL: url).traces
        #expect(reopened.map(\.letter) == ["A", "F"], "both traces must survive a relaunch")
        #expect(reopened.first?.forces.first?.isNaN == true, "raw data stays raw — the NaN is kept, not rewritten")
        #expect(center.notices.count == 1, "the non-finite trace must be listed for the proctor: \(center.notices)")
    }

    @Test("a NaN phase score is kept as NaN by the phase controller and earns no star")
    func nanPhaseScoreEarnsNoStar() {
        var controller = LearningPhaseController(condition: .guidedOnly)
        controller.advance(score: .nan)
        #expect(controller.isLetterSessionComplete, "the phase still completes — the child did it")
        #expect(controller.phaseScores[.guided]?.isNaN == true,
                "max(0, min(1, NaN)) is 1.0 — the completed row must not carry a valid 1.0")
        #expect(controller.starsEarned == 0, "a broken measurement must not earn a star")
    }

    @Test("a NaN session accuracy is not added to the per-letter accuracy samples")
    func nanSessionAccuracyIsNotASample() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("B2-dashboard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = PersistenceFailureCenter()
        let store = JSONParentDashboardStore(fileURL: dir, failureCenter: center)
        store.recordSession(letter: "A", accuracy: .nan, durationSeconds: 10, wallClockSeconds: nil,
                            date: Date(timeIntervalSince1970: 1_770_000_000), condition: .threePhase,
                            inputDevice: nil)
        let samples = store.snapshot.letterStats["A"]?.accuracySamples ?? []
        #expect(!samples.contains { !$0.isFinite }, "a NaN must not enter the accuracy samples: \(samples)")
        #expect(store.snapshot.sessionDurations.count == 1, "the duration row is still recorded")
        #expect(center.notices.count == 1, "the skipped sample must be listed: \(center.notices)")
    }

    @Test("a NaN score does not make the COMBINED JSON export fail")
    func nanScoreDoesNotFailTheCombinedJSONExport() throws {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: .nan,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_100)))
        let source = ParticipantExportSource(snapshot: snap, participantId: UUID(), progress: [:],
                                             rawTraces: [], enrolledAt: nil)
        let data = try ParentDashboardExporter.combinedJSONData(participants: [source])
        #expect(String(data: data, encoding: .utf8)?.contains("\"NaN\"") == true,
                "the one-export path must carry the NaN as an explicit token")
    }

    @Test("a NaN score does not make the JSON export fail")
    func nanScoreDoesNotFailTheJSONExport() throws {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: .nan,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_100)))
        let data = try ParentDashboardExporter.jsonData(from: snap, participantId: UUID(), enrolledAt: nil)
        #expect(String(data: data, encoding: .utf8)?.contains("\"NaN\"") == true,
                "the NaN must be exported as an explicit token, not dropped and not 1.0")
    }

    @Test("a NaN phase score in the progress store does not stop later completions from persisting")
    func nanProgressDoesNotStopLaterCompletions() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("progress.json")
        let store = JSONProgressStore(fileURL: url, failureCenter: PersistenceFailureCenter())
        store.recordCompletion(for: "A", accuracy: 0.5, phaseScores: ["freeWrite": .nan],
                               speed: nil, recognitionResult: nil, formAccuracy: nil)
        store.recordCompletion(for: "F", accuracy: 0.5, phaseScores: ["freeWrite": 0.5],
                               speed: nil, recognitionResult: nil, formAccuracy: nil)
        await store.flush()

        let reopened = JSONProgressStore(fileURL: url)
        #expect(reopened.progress(for: "A").completionCount == 1)
        #expect(reopened.progress(for: "F").completionCount == 1,
                "the completion after the NaN one must reach disk")
    }

    @Test("a NaN form accuracy is not recorded as 0.0 in the history")
    func nanFormAccuracyIsNotZero() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("B2-progress-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONProgressStore(fileURL: dir, failureCenter: PersistenceFailureCenter())
        store.recordCompletion(for: "A", accuracy: 0.5, phaseScores: nil,
                               speed: nil, recognitionResult: nil, formAccuracy: .nan)
        let history = store.progress(for: "A").formAccuracyHistory ?? []
        #expect(!history.contains(0.0), "max(0, NaN) is 0.0 — a NaN must not become a valid reading: \(history)")
    }
}

// MARK: - R-054 unreadable / future-schema files are never overwritten

@Suite @MainActor struct StoreReadRefusalTests {

    @Test("ProgressStore: a future-schema file keeps every byte after a record")
    func progressFutureSchemaIsNotOverwritten() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("progress.json")
        let first = JSONProgressStore(fileURL: url)
        first.recordCompletion(for: "A", accuracy: 0.5)
        await first.flush()
        try bumpSchemaVersion(at: url)
        let before = try Data(contentsOf: url)

        let center = PersistenceFailureCenter()
        let store = JSONProgressStore(fileURL: url, failureCenter: center)
        store.recordCompletion(for: "F", accuracy: 0.5)
        await store.flush()
        #expect(try Data(contentsOf: url) == before, "a future-schema file must not be clobbered by the next save")
        #expect(store.writeRefusal != nil)
        #expect(center.failures.count == 1, "the refusal must reach the failure center (it blocks a study session)")
    }

    @Test("ParentDashboardStore: a future-schema file keeps every byte after a record")
    func dashboardFutureSchemaIsNotOverwritten() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("dashboard.json")
        let first = JSONParentDashboardStore(fileURL: url)
        first.recordPhaseSession(letter: "A", phase: "freeWrite", completed: true, score: 0.5,
                                 schedulerPriority: 0, condition: .threePhase)
        await first.flush()
        try bumpSchemaVersion(at: url)
        let before = try Data(contentsOf: url)

        let center = PersistenceFailureCenter()
        let store = JSONParentDashboardStore(fileURL: url, failureCenter: center)
        store.recordPhaseSession(letter: "F", phase: "freeWrite", completed: true, score: 0.5,
                                 schedulerPriority: 0, condition: .threePhase)
        await store.flush()
        #expect(try Data(contentsOf: url) == before, "a future-schema file must not be clobbered by the next save")
        #expect(store.writeRefusal != nil)
        #expect(center.failures.count == 1, "the refusal must reach the failure center (it blocks a study session)")
    }

    @Test("StreakStore: a future-schema file keeps every byte after a record")
    func streakFutureSchemaIsNotOverwritten() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("streak.json")
        let first = JSONStreakStore(fileURL: url)
        first.recordSession(date: Date(timeIntervalSince1970: 1_770_000_000), lettersCompleted: ["A"], accuracy: 0.5)
        await first.flush()
        try bumpSchemaVersion(at: url)
        let before = try Data(contentsOf: url)

        let center = PersistenceFailureCenter()
        let store = JSONStreakStore(fileURL: url, failureCenter: center)
        store.recordSession(date: Date(timeIntervalSince1970: 1_770_100_000), lettersCompleted: ["F"], accuracy: 0.5)
        await store.flush()
        #expect(try Data(contentsOf: url) == before, "a future-schema file must not be clobbered by the next save")
        #expect(store.writeRefusal != nil)
        #expect(center.failures.count == 1, "the refusal must reach the failure center (it blocks a study session)")
    }

    @Test("ProgressStore: an UNREADABLE file (chmod 000) keeps every byte after a record")
    func progressUnreadableIsNotOverwritten() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("progress.json")
        let first = JSONProgressStore(fileURL: url)
        first.recordCompletion(for: "A", accuracy: 0.5)
        await first.flush()
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        let center = PersistenceFailureCenter()
        let store = JSONProgressStore(fileURL: url, failureCenter: center)
        store.recordCompletion(for: "F", accuracy: 0.5)
        await store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before, "a read error is not a first launch — the file must survive")
        #expect(center.failures.count == 1, "the refusal must reach the failure center (it blocks a study session)")
    }

    @Test("RawTraceStore: an UNREADABLE file (chmod 000) keeps every byte after an append")
    func rawTraceUnreadableIsNotOverwritten() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("rawtraces.json")
        let first = JSONRawTraceStore(fileURL: url)
        first.append(makeTrace(letter: "A"))
        await first.flush()
        let before = try Data(contentsOf: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)

        let center = PersistenceFailureCenter()
        let store = JSONRawTraceStore(fileURL: url, failureCenter: center)
        store.append(makeTrace(letter: "F"))
        await store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Data(contentsOf: url) == before, "a read error is not a first launch — the file must survive")
        #expect(center.failures.count == 1, "the refusal must reach the failure center (it blocks a study session)")
    }
}

@Suite @MainActor struct StoreFailureWiringTests {

    /// A path whose parent is a regular FILE: every write fails, and the
    /// load sees no file (a first launch), so the first save is the probe.
    private func unwritableURL(in dir: URL, _ name: String) throws -> URL {
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        return blocker.appendingPathComponent(name)
    }

    @Test("ProgressStore reports a failed write to its center")
    func progressWriteFailureIsReported() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let center = PersistenceFailureCenter()
        let store = JSONProgressStore(fileURL: try unwritableURL(in: dir, "progress.json"), failureCenter: center)
        store.recordCompletion(for: "A", accuracy: 0.5)
        await store.flush()
        #expect(center.failures.contains { $0.hasPrefix("ProgressStore:") }, "\(center.failures)")
    }

    @Test("ParentDashboardStore reports a failed write to its center")
    func dashboardWriteFailureIsReported() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let center = PersistenceFailureCenter()
        let store = JSONParentDashboardStore(fileURL: try unwritableURL(in: dir, "dashboard.json"), failureCenter: center)
        store.recordPhaseSession(letter: "A", phase: "freeWrite", completed: true, score: 0.5,
                                 schedulerPriority: 0, condition: .threePhase)
        await store.flush()
        #expect(center.failures.contains { $0.hasPrefix("ParentDashboardStore:") }, "\(center.failures)")
    }

    @Test("RawTraceStore reports a failed write to its center")
    func rawTraceWriteFailureIsReported() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let center = PersistenceFailureCenter()
        let store = JSONRawTraceStore(fileURL: try unwritableURL(in: dir, "rawtraces.json"), failureCenter: center)
        store.append(makeTrace())
        await store.flush()
        #expect(center.failures.contains { $0.hasPrefix("RawTraceStore:") }, "\(center.failures)")
    }

    @Test("StreakStore reports a failed write to its center")
    func streakWriteFailureIsReported() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let center = PersistenceFailureCenter()
        let store = JSONStreakStore(fileURL: try unwritableURL(in: dir, "streak.json"), failureCenter: center)
        store.recordSession(date: Date(timeIntervalSince1970: 1_770_000_000), lettersCompleted: ["A"], accuracy: 0.5)
        await store.flush()
        #expect(center.failures.contains { $0.hasPrefix("StreakStore:") }, "\(center.failures)")
    }

    @Test("ParticipantArchiveStore reports a failed seal to its center")
    func archiveWriteFailureIsReported() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let center = PersistenceFailureCenter()
        let store = JSONParticipantArchiveStore(directoryURL: try unwritableURL(in: dir, "ParticipantArchive"),
                                                failureCenter: center)
        // The seal is synchronous and throwing (R-050): the caller keeps the
        // live child, so the failure is a NOTICE for the proctor, never a
        // session-stopping failure.
        #expect(throws: (any Error).self) {
            try store.archive(ArchivedParticipant(participantId: UUID(), enrolledAt: nil, archivedAt: Date(),
                                                  snapshot: DashboardSnapshot(), progress: [:], rawTraces: []))
        }
        #expect(center.notices.contains { $0.hasPrefix("ParticipantArchiveStore:") }, "\(center.notices)")
        #expect(!center.hasFailed, "a failed seal loses nothing, so it must not hard-stop the live child")
    }

    @Test("EnrolmentLog reports a failed write to its center")
    func enrolmentWriteFailureIsReported() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let center = PersistenceFailureCenter()
        let log = JSONEnrolmentLog(directoryURL: try unwritableURL(in: dir, "Enrolments"), failureCenter: center)
        log.append(EnrolmentRecord(participantId: UUID(), enrolledAt: Date(), audioCondition: .silent,
                                   trainedSubset: "AFI", protocolRevision: StudyProtocol.revision))
        await log.flush()
        #expect(center.failures.contains { $0.hasPrefix("EnrolmentLog:") }, "\(center.failures)")
    }

    @Test("a raw-trace cap eviction is listed, not silent")
    func rawTraceCapEvictionIsANotice() async throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let center = PersistenceFailureCenter()
        let store = JSONRawTraceStore(fileURL: dir.appendingPathComponent("rawtraces.json"), failureCenter: center)
        for _ in 0..<500 { store.append(makeTrace()) }
        #expect(center.notices.isEmpty, "at the cap nothing is evicted yet")
        store.append(makeTrace(letter: "Z"))
        await store.flush()
        #expect(store.traces.count == 500)
        #expect(center.notices.count == 1 && center.notices[0].contains("evicted"), "\(center.notices)")
        #expect(!center.hasFailed)
    }

    @Test("an undecodable store file is moved aside AND listed as a notice, without blocking")
    func undecodableFileIsANotice() throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let url = dir.appendingPathComponent("progress.json")
        try Data("{not json".utf8).write(to: url)
        let center = PersistenceFailureCenter()
        let store = JSONProgressStore(fileURL: url, failureCenter: center)
        #expect(store.writeRefusal == nil, "moved aside, so the next save destroys nothing")
        #expect(!center.hasFailed)
        #expect(center.notices.count == 1 && center.notices[0].hasPrefix("ProgressStore:"), "\(center.notices)")
    }
}

// MARK: - R-055 archive / enrolment load is element-wise and visible

@Suite @MainActor struct ArchiveLoadRobustnessTests {

    private func archived(traces: [RawTrace], progress: [String: LetterProgress]) -> ArchivedParticipant {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_100)))
        return ArchivedParticipant(participantId: UUID(),
                                   enrolledAt: Date(timeIntervalSince1970: 1_770_000_000),
                                   archivedAt: Date(timeIntervalSince1970: 1_770_000_500),
                                   snapshot: snap, progress: progress, rawTraces: traces)
    }

    /// Encodes `record`, lets `mutate` damage the JSON object, writes it
    /// where the archive store looks for it.
    private func writeDamaged(_ record: ArchivedParticipant, in dir: URL,
                              _ mutate: (inout [String: Any]) -> Void) throws {
        let data = try JSONEncoder().encode(record)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutate(&object)
        let damaged = try JSONSerialization.data(withJSONObject: object)
        try damaged.write(to: dir.appendingPathComponent("\(record.participantId.uuidString).json"))
    }

    @Test("one malformed raw trace costs only itself — the child and the other traces load")
    func malformedTraceCostsOnlyItself() throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let record = archived(traces: [makeTrace(letter: "A"), makeTrace(letter: "F")], progress: [:])
        try writeDamaged(record, in: dir) { object in
            var traces = object["rawTraces"] as! [[String: Any]]
            traces[1]["letter"] = 5          // wrong type: the element no longer decodes
            object["rawTraces"] = traces
        }

        let center = PersistenceFailureCenter()
        let store = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: center)
        let loaded = try #require(store.archivedParticipants.first,
                                  "one bad trace must not quarantine the whole child")
        #expect(center.notices.count == 1 && center.notices[0].contains("rawTraces"),
                "the dropped trace must be listed for the proctor: \(center.notices)")
        #expect(loaded.participantId == record.participantId)
        #expect(loaded.rawTraces.map(\.letter) == ["A"])
        #expect(loaded.snapshot.phaseSessionRecords.count == 1)
    }

    @Test("one malformed letter-progress entry costs only itself")
    func malformedProgressCostsOnlyItself() throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        var good = LetterProgress(); good.completionCount = 2
        let record = archived(traces: [], progress: ["A": good, "F": good])
        try writeDamaged(record, in: dir) { object in
            var progress = object["progress"] as! [String: Any]
            progress["F"] = ["completionCount": "two"]   // wrong type
            object["progress"] = progress
        }

        let center = PersistenceFailureCenter()
        let store = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: center)
        let loaded = try #require(store.archivedParticipants.first,
                                  "one bad progress entry must not quarantine the whole child")
        #expect(center.notices.count == 1 && center.notices[0].contains("progress"), "\(center.notices)")
        #expect(loaded.progress.keys.sorted() == ["A"])
        #expect(loaded.progress["A"]?.completionCount == 2)
    }

    @Test("an undecodable archive file does not hide the others")
    func badArchiveDoesNotHideTheOthers() throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let good = archived(traces: [], progress: [:])
        try JSONEncoder().encode(good).write(to: dir.appendingPathComponent("\(good.participantId.uuidString).json"))
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))

        let center = PersistenceFailureCenter()
        let store = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: center)
        #expect(store.archivedParticipants.map(\.participantId) == [good.participantId])
        #expect(center.notices.count == 1 && center.notices[0].contains("NOT in the export"),
                "a child missing from the export must be listed for the proctor: \(center.notices)")
        #expect(!center.hasFailed, "an old child's file does not stop the current session")
    }

    /// Files in `dir` whose name carries the set-aside marker.
    private func setAside(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".undecodable-") }
    }

    @Test("a set-aside archive file is not re-read, re-moved and renamed on the next launch")
    func setAsideArchiveIsNotReprocessed() throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))

        let first = PersistenceFailureCenter()
        _ = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: first)
        let second = PersistenceFailureCenter()
        let store = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: second)

        let names = try setAside(in: dir)
        #expect(names.count == 1, "exactly one set-aside file: \(names)")
        #expect(names.allSatisfy { $0.components(separatedBy: ".undecodable-").count == 2 },
                "the name must not grow on every launch: \(names)")
        #expect(store.archivedParticipants.isEmpty)
        #expect(first.notices.filter { $0.contains("moved aside") }.count == 1, "\(first.notices)")
        #expect(second.notices.filter { $0.contains("moved aside") }.isEmpty,
                "nothing is moved again: \(second.notices)")
        #expect(second.notices.count == 1 && second.notices[0].contains("set aside earlier"),
                "a later launch must still show the proctor the child missing from the export: \(second.notices)")
    }

    @Test("a set-aside enrolment file is not re-read, re-moved and renamed on the next launch")
    func setAsideEnrolmentIsNotReprocessed() throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))

        let first = PersistenceFailureCenter()
        _ = JSONEnrolmentLog(directoryURL: dir, failureCenter: first)
        let second = PersistenceFailureCenter()
        _ = JSONEnrolmentLog(directoryURL: dir, failureCenter: second)

        let names = try setAside(in: dir)
        #expect(names.count == 1, "exactly one set-aside file: \(names)")
        #expect(names.allSatisfy { $0.components(separatedBy: ".undecodable-").count == 2 }, "\(names)")
        #expect(first.notices.filter { $0.contains("moved aside") }.count == 1, "\(first.notices)")
        #expect(second.notices.filter { $0.contains("moved aside") }.isEmpty, "\(second.notices)")
        #expect(second.notices.count == 1 && second.notices[0].contains("set aside earlier"), "\(second.notices)")
    }

    @Test("an undecodable enrolment file is moved aside, not silently skipped")
    func undecodableEnrolmentIsQuarantined() throws {
        let dir = try makeTempDirectory(); defer { removeTempDirectory(dir) }
        let bad = dir.appendingPathComponent("\(UUID().uuidString).json")
        try Data("{not json".utf8).write(to: bad)

        let center = PersistenceFailureCenter()
        let log = JSONEnrolmentLog(directoryURL: dir, failureCenter: center)
        #expect(log.enrolments.isEmpty)
        #expect(center.notices.count == 1, "\(center.notices)")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.contains { $0.contains(".undecodable-") },
                "the undecodable enrolment must be kept aside for inspection: \(names)")
    }
}

// MARK: - R-056 replay on subscribe

@Suite @MainActor struct PersistenceFailureReplayTests {

    @Test("a failure reported BEFORE anyone subscribed reaches the subscriber")
    func failureBeforeSubscribeIsReplayed() async {
        let center = PersistenceFailureCenter()
        center.reportFailure(store: "ProgressStore",
                             error: NSError(domain: "t", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "read-only volume"]))
        var received: [String] = []
        center.subscribe { received.append($0) }
        for _ in 0..<50 where received.isEmpty { await Task.yield() }
        #expect(received.count == 1, "the early failure must be replayed to the new subscriber")
        #expect(received.first?.contains("ProgressStore") == true)
    }

    @Test("a notice is listed for the parent area but is not a failure")
    func noticeIsVisibleButNotBlocking() {
        let center = PersistenceFailureCenter()
        #expect(center.integritySummary == nil, "nothing to show while nothing went wrong")
        center.reportNotice(store: "ParticipantArchiveStore", message: "x.json was undecodable")
        #expect(!center.hasFailed, "a notice must not hard-stop the session")
        #expect(center.notices == ["ParticipantArchiveStore: x.json was undecodable"])
        #expect(center.integritySummary?.headline == "1 Datenhinweis")
        center.reportFailure(store: "ProgressStore", error: NSError(domain: "t", code: 1))
        #expect(center.integritySummary?.headline == "1 Speicherfehler · 1 Datenhinweis")
    }
}

// MARK: - R-053 review: a NaN score row must not blank an aggregate
//
// A completed freeWrite row may carry score NaN (`LearningPhaseController.
// advance`, `PhaseSessionRecord.init`): the per-row CSV/JSON keep that
// honest NaN, but every SCORE aggregate must read as though the row were
// absent — the mean of the finite scores, and with no finite score the
// same value "no data" gives today. Each test reads ONE aggregate family
// so a mutation of one site turns exactly its own test red.

@Suite @MainActor struct NonFiniteAggregateTests {

    private let pid = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    private func row(_ letter: String, _ score: Double, priority: Double,
                     _ condition: ThesisCondition, _ audio: PilotAudioCondition,
                     at t: Double) -> PhaseSessionRecord {
        PhaseSessionRecord(letter: letter, phase: "freeWrite", completed: true,
                           score: score, schedulerPriority: priority,
                           condition: condition, audioCondition: audio,
                           recordedAt: Date(timeIntervalSince1970: 1_770_000_000 + t))
    }

    /// threePhase A: 0.2 → 0.6 → 0.7 (two delta pairs, so both proxies are
    /// defined); guidedOnly B: 1.0. Audio: phoneme A 0.2, 0.6; spatial A
    /// 0.7; silent B 1.0.
    private var finiteRows: [PhaseSessionRecord] {
        [row("A", 0.2, priority: 0.1, .threePhase, .phoneme, at: 100),
         row("A", 0.6, priority: 0.5, .threePhase, .phoneme, at: 200),
         row("A", 0.7, priority: 0.9, .threePhase, .spatial, at: 300),
         row("B", 1.0, priority: 0.2, .guidedOnly, .silent, at: 400)]
    }

    /// NaN rows inside every populated arm, one BETWEEN two finite rows of
    /// the same letter (it would split a delta pair), and a letter C that
    /// has only NaN rows (it must not appear at all).
    private var nanRows: [PhaseSessionRecord] {
        [row("A", .nan, priority: 0.3, .threePhase, .phoneme, at: 150),
         row("A", .nan, priority: 0.8, .threePhase, .spatial, at: 350),
         row("B", .nan, priority: 0.4, .guidedOnly, .silent, at: 450),
         row("C", .nan, priority: 0.6, .threePhase, .phoneme, at: 500)]
    }

    private func snapshot(_ records: [PhaseSessionRecord]) -> DashboardSnapshot {
        var s = DashboardSnapshot()
        s.phaseSessionRecords = records
        return s
    }

    /// Metric-section rows starting with `prefix`. The completion-rate
    /// rows are never compared: a NaN row DID complete.
    private func metricRows(_ records: [PhaseSessionRecord], prefix: String) -> [String] {
        let data = ParentDashboardExporter.csvData(from: snapshot(records), participantId: pid,
                                                   progress: [:], enrolledAt: nil)
        let lines = String(data: data, encoding: .utf8)!
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(of: "metric,value") else { return [] }
        return lines[(start + 1)...].filter { $0.hasPrefix(prefix) }
    }

    /// The family's rows with NaN rows mixed in equal the rows without
    /// them, and an all-NaN record set equals an empty one.
    private func expectNaNRowsIgnored(prefix: String,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
        let baseline = metricRows(finiteRows, prefix: prefix)
        #expect(!baseline.isEmpty, "fixture must populate \(prefix)", sourceLocation: sourceLocation)
        #expect(metricRows(finiteRows + nanRows, prefix: prefix) == baseline,
                "a NaN row must not change \(prefix)", sourceLocation: sourceLocation)
        #expect(metricRows(nanRows, prefix: prefix) == metricRows([], prefix: prefix),
                "all-NaN must read as no data for \(prefix)", sourceLocation: sourceLocation)
    }

    @Test("the dashboard's freeWrite mean ignores a NaN row; all-NaN reads as no data")
    func storeAverageIgnoresNaN() {
        let withNaN = snapshot(finiteRows + nanRows).averageFreeWriteScore
        #expect(withNaN == snapshot(finiteRows).averageFreeWriteScore)
        #expect(abs(withNaN - 0.625) < 1e-12, "(0.2+0.6+0.7+1.0)/4, got \(withNaN)")
        #expect(snapshot(nanRows).averageFreeWriteScore == snapshot([]).averageFreeWriteScore)
    }

    @Test("the dashboard's scheduler proxy ignores a NaN row; all-NaN reads as no data")
    func storeProxyIgnoresNaN() throws {
        let baseline = try #require(snapshot(finiteRows).schedulerEffectivenessProxyIfDefined)
        #expect(snapshot(finiteRows + nanRows).schedulerEffectivenessProxyIfDefined == baseline)
        #expect(snapshot(nanRows).schedulerEffectivenessProxyIfDefined == nil)
    }

    @Test("averageFreeWriteScore_<arm> ignores a NaN row")
    func armAverageIgnoresNaN() {
        for arm in [ThesisCondition.threePhase, .guidedOnly] {
            expectNaNRowsIgnored(prefix: "averageFreeWriteScore_\(arm.rawValue),")
        }
    }

    @Test("averageFreeWriteScore_audio_<arm> ignores a NaN row")
    func audioArmAverageIgnoresNaN() {
        expectNaNRowsIgnored(prefix: "averageFreeWriteScore_audio_")
    }

    @Test("schedulerEffectivenessProxy_<arm> ignores a NaN row")
    func armProxyIgnoresNaN() {
        expectNaNRowsIgnored(prefix: "schedulerEffectivenessProxy_")
    }

    @Test("letterByArm ignores a NaN row")
    func letterByArmIgnoresNaN() {
        expectNaNRowsIgnored(prefix: "letterByArm,")
    }

    @Test("letterByAudioArm ignores a NaN row")
    func letterByAudioArmIgnoresNaN() {
        expectNaNRowsIgnored(prefix: "letterByAudioArm,")
    }
}
