// Tests that exist only where batch B2 (persistence robustness: StoreCoding,
// lossy archive decode, set-aside files) meets batch B1 (synchronous,
// verified, append-only seal; idempotent re-seal). Integration lane L2-B,
// 2026-10-14.
//
// The hazard both reviews named: B1's seal encoded with a plain
// `JSONEncoder`, whose default strategy THROWS on a non-finite Double, so
// one NaN anywhere in the outgoing child (an abandoned row's NaN score, a
// NaN raw-trace sample, both of which B2 keeps as recorded) made every
// seal throw — and since the wipe now waits for a successful seal,
// "Nächstes Kind" was refused for the rest of the session.
//
// Mutation checks (each confirmed RED with the executed-test count read):
//   M1  `StoreCoding.encoder()` -> `JSONEncoder()` in `archive(_:)`   — all three RED
//   M2  `StoreCoding.decoder(tally:)` -> `JSONDecoder()` in `loadAll` — the
//       round-trip and idempotent-seal tests RED
//   M3  drop the set-aside-marker skip in `loadAll`                  — the
//       set-aside test RED
//
// An EXTENSION of `NewParticipantResetTests` (`.serialized`), like
// `ParticipantIdentityDurabilityTests`: these tests move the process-wide
// `ParticipantStore` identity, and only membership in that suite keeps
// them from interleaving with its tests.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

extension NewParticipantResetTests {

    /// Snapshot and restore what `resetForNewParticipant()` moves.
    fileprivate func withMergeTestIdentity(_ body: () async throws -> Void) async rethrows {
        let pedOverride    = ParticipantStore.conditionOverride
        let audioOverride  = ParticipantStore.audioConditionOverride
        let subsetOverride = ParticipantStore.trainedSubsetOverride
        let enrolled       = ParticipantStore.isEnrolled
        defer {
            ParticipantStore.conditionOverride = pedOverride
            ParticipantStore.audioConditionOverride = audioOverride
            ParticipantStore.trainedSubsetOverride = subsetOverride
            ParticipantStore.isEnrolled = enrolled
        }
        try await body()
    }

    fileprivate func mergeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("L2B-\(UUID().uuidString)", isDirectory: true)
    }

    /// A raw trace with a NaN sample and a NaN force — kept as recorded
    /// by `JSONRawTraceStore` (B2, R-053).
    fileprivate func nanTrace(letter: String = "F") -> RawTrace {
        RawTrace(id: UUID(), letter: letter, recordedAt: Date(timeIntervalSince1970: 1_790_000_100),
                 points: [CGPoint(x: 1, y: 2), CGPoint(x: CGFloat.nan, y: 4)],
                 timestamps: [0.0, 0.1],
                 forces: [CGFloat.nan, 0.5],
                 strokeStartIndices: [0],
                 canvasSize: CGSize(width: 100, height: 100))
    }

    /// An outgoing child whose record carries NaN in a phase row (an
    /// abandoned trial, score NaN — B2 stores it as NaN, not 1.0) and in a
    /// raw trace.
    fileprivate func nanBearingRecord(_ id: UUID, enrolledAt: Date, archivedAt: Date) -> ArchivedParticipant {
        var snapshot = DashboardSnapshot()
        snapshot.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "F", phase: "freeWrite", completed: false, score: .nan,
            schedulerPriority: 0, recordedAt: enrolledAt.addingTimeInterval(60)))
        snapshot.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "F", phase: "guided", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: enrolledAt.addingTimeInterval(30)))
        var progress = LetterProgress(); progress.completionCount = 1
        return ArchivedParticipant(participantId: id, enrolledAt: enrolledAt,
                                   archivedAt: archivedAt, snapshot: snapshot,
                                   progress: ["F": progress], rawTraces: [nanTrace()])
    }

    /// The sealed `.json` files in `dir` (staging and set-aside excluded).
    fileprivate func sealFiles(in dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json"
                && !$0.lastPathComponent.contains(StoreFileQuarantine.setAsideMarker) }
    }

    // MARK: - (a) a NaN-bearing child seals, round-trips, and can be handed over

    @Test("a NaN-bearing record seals and round-trips through archive() and the loader, tally clean")
    func nanBearingRecordSealsAndRoundTrips() throws {
        let dir = mergeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let center = PersistenceFailureCenter()
        let store = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: center)
        let id = UUID()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)

        try store.archive(nanBearingRecord(id, enrolledAt: t0, archivedAt: t0.addingTimeInterval(600)))

        #expect(center.notices.isEmpty && !center.hasFailed,
                "a NaN-bearing seal must not be refused or reported: \(center.notices) \(center.failures)")
        #expect(store.archivedParticipants.map(\.participantId) == [id])

        // On disk, decoded by the store's own coder: nothing dropped.
        let file = try #require(try sealFiles(in: dir).first, "no seal file on disk")
        let tally = StoreDecodeTally()
        let onDisk = try StoreCoding.decoder(tally: tally)
            .decode(ArchivedParticipant.self, from: Data(contentsOf: file))
        #expect(tally.dropped.isEmpty, "the sealed file lost elements: \(tally.dropped)")
        #expect(onDisk.snapshot.phaseSessionRecords.count == 2)
        #expect(onDisk.rawTraces.count == 1 && onDisk.progress.count == 1)

        // Next launch: the loader reads it back, NaN intact, with no notice.
        let reloadCenter = PersistenceFailureCenter()
        let reopened = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: reloadCenter)
        let child = try #require(reopened.archivedParticipants.first, "the NaN-bearing child vanished on reload")
        #expect(reloadCenter.notices.isEmpty, "the reload dropped or set aside something: \(reloadCenter.notices)")
        #expect(child.participantId == id)
        #expect(child.snapshot.phaseSessionRecords.first { !$0.completed }?.score.isNaN == true,
                "the abandoned row's NaN must stay NaN, not become a number")
        #expect(child.rawTraces.first?.forces.first?.isNaN == true)
        #expect(child.rawTraces.first?.points.last?.x.isNaN == true)
    }

    @Test("Nächstes Kind hands over a child whose rows and traces carry NaN")
    func resetForNewParticipantSealsANaNBearingChild() async throws {
        try await withMergeTestIdentity {
            let dir = mergeTempDirectory()
            let dashboardURL = dir.appendingPathComponent("dashboard.json")
            let tracesURL = dir.appendingPathComponent("rawtraces.json")
            let archiveDir = dir.appendingPathComponent("ParticipantArchive", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let center = PersistenceFailureCenter()
            let dashboard = JSONParentDashboardStore(fileURL: dashboardURL, failureCenter: center)
            let traces = JSONRawTraceStore(fileURL: tracesURL, failureCenter: center)
            let archive = JSONParticipantArchiveStore(directoryURL: archiveDir, failureCenter: center)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(rawTraceStore: traces)
                .with(participantArchive: archive)
                .with(studyMode: true))
            let outgoing = vm.resetForNewParticipant()
            // An abandoned trial (NaN score) and a NaN-bearing trace.
            dashboard.recordPhaseSession(letter: "F", phase: "freeWrite", completed: false,
                                         score: .nan, schedulerPriority: 0, condition: .threePhase)
            traces.append(nanTrace())
            #expect(vm.dashboardSnapshot.phaseSessionRecords.first?.score.isNaN == true,
                    "precondition: the live row carries NaN")

            let next = vm.resetForNewParticipant()

            #expect(vm.participantSealFailure == nil,
                    "a NaN-bearing child was refused: \(vm.participantSealFailure ?? "")")
            #expect(next != outgoing, "Nächstes Kind was refused for a NaN-bearing child")
            #expect(!vm.dashboardSnapshot.phaseSessionRecords.contains { $0.score.isNaN },
                    "the sealed child was not wiped")
            #expect(!center.notices.contains { $0.hasPrefix("ParticipantArchiveStore:") },
                    "the seal reported a problem: \(center.notices)")
            let onDisk = JSONParticipantArchiveStore(directoryURL: archiveDir).archivedParticipants
            let sealed = try #require(onDisk.last, "the outgoing child is not in the archive on disk")
            #expect(onDisk.count == 1 && sealed.participantId == outgoing,
                    "\(onDisk.map(\.participantId)) vs \(outgoing)")
            #expect(sealed.snapshot.phaseSessionRecords.first?.score.isNaN == true)
            #expect(sealed.rawTraces.first?.forces.first?.isNaN == true)
        }
    }

    // MARK: - (b) the idempotent-seal key with a NaN-bearing record

    /// B1's re-seal reuse (review item 3) matches a seal ON RECORD — i.e.
    /// one the relaunched store LOADED from disk. If the NaN-bearing seal
    /// could not be read back by the loader, the key would find nothing and
    /// the same session would be sealed twice (or, with a throwing encoder,
    /// never sealed at all).
    @Test("a NaN-bearing session already sealed is reused after a relaunch, not sealed twice")
    func nanBearingSealIsReusedAfterRelaunch() async throws {
        try await withMergeTestIdentity {
            let dir = mergeTempDirectory()
            let dashboardURL = dir.appendingPathComponent("dashboard.json")
            let archiveDir = dir.appendingPathComponent("ParticipantArchive", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let dashboard = JSONParentDashboardStore(fileURL: dashboardURL)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: JSONParticipantArchiveStore(directoryURL: archiveDir))
                .with(studyMode: true))
            let child = vm.resetForNewParticipant()
            dashboard.recordPhaseSession(letter: "F", phase: "freeWrite", completed: false,
                                         score: .nan, schedulerPriority: 0, condition: .threePhase)
            // The seal half of resetForNewParticipant, then "the process dies".
            try vm.participantArchive.archive(ArchivedParticipant(
                participantId: child, enrolledAt: ParticipantStore.enrolledAt,
                archivedAt: Date(), snapshot: dashboard.snapshot,
                progress: [:], rawTraces: [nanTrace()]))

            // Relaunch: the archive is re-read from disk; identity and live
            // rows unchanged; the proctor taps again.
            let reloaded = JSONParticipantArchiveStore(directoryURL: archiveDir)
            #expect(reloaded.archivedParticipants.map(\.participantId) == [child],
                    "precondition: the relaunched store must hold the NaN-bearing seal")
            let relaunched = TracingViewModel(.stub
                .with(dashboardStore: dashboard)
                .with(participantArchive: reloaded)
                .with(studyMode: true))
            let next = relaunched.resetForNewParticipant()

            #expect(next != child, "the reset must still go through")
            #expect(relaunched.participantSealFailure == nil)
            let all = JSONParticipantArchiveStore(directoryURL: archiveDir).archivedParticipants
            var sealCount = 0
            for record in all where record.participantId == child { sealCount += 1 }
            #expect(sealCount == 1, "the same NaN-bearing session was sealed \(sealCount) times")
            let files = try sealFiles(in: archiveDir)
            #expect(files.count == 1, "\(files.map(\.lastPathComponent))")
        }
    }

    // MARK: - (c) a set-aside file next to a sealed child

    /// B1 names seals `<uuid>_<ms>.json`; B2 sets an undecodable file aside
    /// as `<stem>.undecodable-<stamp>.json` and must skip such names on
    /// every later launch. Here both live in one directory: the child
    /// (NaN-bearing) loads, the corrupt neighbour is set aside ONCE, and
    /// the next launch neither re-reads nor renames it, but still lists it.
    @Test("a set-aside corrupt file beside a sealed child is skipped while the child loads")
    func setAsideFileBesideASealedChildIsSkipped() throws {
        let dir = mergeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let id = UUID()
        try JSONParticipantArchiveStore(directoryURL: dir, failureCenter: PersistenceFailureCenter())
            .archive(nanBearingRecord(id, enrolledAt: t0, archivedAt: t0.addingTimeInterval(600)))
        // A corrupt neighbour under B1's naming scheme.
        try Data("{not json".utf8).write(
            to: dir.appendingPathComponent("\(UUID().uuidString)_1790000000000.json"))

        let first = PersistenceFailureCenter()
        let firstLaunch = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: first)
        #expect(firstLaunch.archivedParticipants.map(\.participantId) == [id])
        #expect(first.notices.filter { $0.contains("moved aside") }.count == 1, "\(first.notices)")
        let setAsideAfterFirst = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(StoreFileQuarantine.setAsideMarker) }
        #expect(setAsideAfterFirst.count == 1, "\(setAsideAfterFirst)")

        let second = PersistenceFailureCenter()
        let secondLaunch = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: second)
        let child = try #require(secondLaunch.archivedParticipants.first,
                                 "the sealed child did not load beside a set-aside file")
        #expect(secondLaunch.archivedParticipants.count == 1)
        #expect(child.participantId == id)
        #expect(child.snapshot.phaseSessionRecords.contains { $0.score.isNaN })
        let setAsideAfterSecond = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.contains(StoreFileQuarantine.setAsideMarker) }
        #expect(setAsideAfterSecond == setAsideAfterFirst,
                "the set-aside file was re-read and renamed: \(setAsideAfterSecond)")
        #expect(second.notices.count == 1 && second.notices[0].contains("set aside earlier"),
                "the second launch must skip the file yet still list it: \(second.notices)")
    }
}
