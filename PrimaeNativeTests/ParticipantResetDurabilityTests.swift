// ParticipantResetDurabilityTests.swift
// PrimaeNativeTests
//
// B-21 (audit 2026-11-01, B-tracing.md:36). "Nächstes Kind" wipes the
// participant stores (`wipeLiveParticipantState`) and then writes the new
// identity (`ParticipantStore.startNewParticipant()`). The stores' `reset()`
// only QUEUED a background write, so a kill between the two relaunched the
// OUTGOING child's rows under the NEW id.
//
// The fix keeps `resetForNewParticipant()` synchronous (82 call sites, the
// rail's single gesture) and makes each store's `reset()` durable: the empty
// state is on disk when it returns, ordered after any write already in
// progress by `StoreWriteGate`. The identity write that follows is therefore
// the last step.
//
// What these tests read: the FILE, through a second store instance opened
// on it, immediately after `reset()` and with NO `flush()` — a flush is the
// thing the old code needed and the production path never calls.
//
// Store-level tests use only temporary files and a private failure center;
// none touches UserDefaults. The one view-model test cannot avoid the
// participant keys (`startNewParticipant` writes them) and restores them,
// like every other `resetForNewParticipant` suite.
//
// MUTATION CHECKS (SUITE-level `-only-testing:`; read "Test run with N
// tests" every time):
//   PrimaeNative/Core/ParentDashboardStore.swift `reset()`: replace
//     `persistNow()` with `persist()` → `dashboardResetIsOnDiskWhenItReturns`
//     and `participantResetIsOnDiskBeforeTheIdentitySwitchReturns` go RED
//     (the same edit in ProgressStore.resetAll / StreakStore.reset /
//     RawTraceStore.reset turns the matching test RED).
//   PrimaeNative/Core/StoreFileQuarantine.swift `writeUnlessCancelled`:
//     delete `guard !Task.isCancelled else { return false }` →
//     `aCancelledBackgroundWriteNeverLandsAfterTheWipe` goes RED.
//   NOT pinned: the lock itself. It orders `writeNow` against a write
//   ALREADY in progress, which a test cannot hold open; the in-lock
//   cancellation check above is the part a test can reach.
//   `aFailedWipeWriteIsReportedSynchronously`: in `ParentDashboardStore.reset()`
//   `persistNow()` → `persist()` turns it RED only when the background
//   failure report loses the race to the assertion (it usually does).

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite @MainActor struct StoreResetDurabilityTests {

    private func tempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("B21-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func trace() -> RawTrace {
        RawTrace(id: UUID(), letter: "A", recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
                 points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)], timestamps: [0.0, 0.1],
                 forces: [0.5, 0.5], strokeStartIndices: [0], canvasSize: CGSize(width: 100, height: 100))
    }

    /// Each round first FLUSHES the outgoing child's rows to disk and checks
    /// they are there, so the wipe has something to remove: without that, a
    /// deferred reset() whose own write cancels the pending pre-wipe write
    /// leaves the earlier empty file in place and the read passes with the
    /// fix reverted (measured on the iPad, 2026-11-16: `resetAll()` back on
    /// the deferred `save()` stayed green). Repeated, because the unfixed
    /// code then loses a race (its background write against this thread's
    /// read): one pass could slip through, fifty cannot.
    private static let rounds = 50

    @Test("dashboard reset is on disk when it returns — no flush")
    func dashboardResetIsOnDiskWhenItReturns() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dashboard.json")
        let store = JSONParentDashboardStore(fileURL: url, failureCenter: PersistenceFailureCenter())
        for round in 0..<Self.rounds {
            store.recordPhaseSession(letter: "A", phase: "freeWrite", completed: true, score: 0.5,
                                     schedulerPriority: 0, condition: .threePhase)
            await store.flush()
            #expect(!JSONParentDashboardStore(fileURL: url, failureCenter: PersistenceFailureCenter()).snapshot.phaseSessionRecords.isEmpty,
                    "round \(round): precondition — the outgoing child's rows must be on disk before the wipe")
            store.reset()
            let onDisk = JSONParentDashboardStore(fileURL: url, failureCenter: PersistenceFailureCenter())
            #expect(onDisk.snapshot.phaseSessionRecords.isEmpty,
                    "round \(round): the outgoing child's rows were still on disk after reset()")
        }
        await store.flush()
        let settled = JSONParentDashboardStore(fileURL: url, failureCenter: PersistenceFailureCenter())
        #expect(settled.snapshot.phaseSessionRecords.isEmpty,
                "a write queued before the wipe landed after it and put the old rows back")
    }

    @Test("progress reset is on disk when it returns — no flush")
    func progressResetIsOnDiskWhenItReturns() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("progress.json")
        let store = JSONProgressStore(fileURL: url, failureCenter: PersistenceFailureCenter())
        for round in 0..<Self.rounds {
            store.recordCompletion(for: "A", accuracy: 0.5)
            await store.flush()
            #expect(!JSONProgressStore(fileURL: url, failureCenter: PersistenceFailureCenter()).allProgress.isEmpty,
                    "round \(round): precondition — the outgoing child's progress must be on disk before the wipe")
            store.resetAll()
            let onDisk = JSONProgressStore(fileURL: url, failureCenter: PersistenceFailureCenter())
            #expect(onDisk.allProgress.isEmpty,
                    "round \(round): the outgoing child's progress was still on disk after resetAll()")
        }
        await store.flush()
        #expect(JSONProgressStore(fileURL: url, failureCenter: PersistenceFailureCenter()).allProgress.isEmpty,
                "a write queued before the wipe landed after it")
    }

    @Test("streak reset is on disk when it returns — no flush")
    func streakResetIsOnDiskWhenItReturns() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("streak.json")
        let store = JSONStreakStore(fileURL: url, failureCenter: PersistenceFailureCenter())
        for round in 0..<Self.rounds {
            store.recordSession(date: Date(timeIntervalSince1970: 1_770_000_000),
                                lettersCompleted: ["A"], accuracy: 0.9)
            await store.flush()
            #expect(!JSONStreakStore(fileURL: url, failureCenter: PersistenceFailureCenter()).completedLetters.isEmpty,
                    "round \(round): precondition — the outgoing child's streak must be on disk before the wipe")
            store.reset()
            let onDisk = JSONStreakStore(fileURL: url, failureCenter: PersistenceFailureCenter())
            #expect(onDisk.completedLetters.isEmpty && onDisk.currentStreak == 0,
                    "round \(round): the outgoing child's streak was still on disk after reset()")
        }
        await store.flush()
        #expect(JSONStreakStore(fileURL: url, failureCenter: PersistenceFailureCenter()).completedLetters.isEmpty,
                "a write queued before the wipe landed after it")
    }

    @Test("raw-trace reset is on disk when it returns — no flush")
    func rawTraceResetIsOnDiskWhenItReturns() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("rawtraces.json")
        let store = JSONRawTraceStore(fileURL: url, failureCenter: PersistenceFailureCenter())
        for round in 0..<Self.rounds {
            store.append(trace())
            await store.flush()
            #expect(!JSONRawTraceStore(fileURL: url, failureCenter: PersistenceFailureCenter()).traces.isEmpty,
                    "round \(round): precondition — the outgoing child's raw traces must be on disk before the wipe")
            store.reset()
            let onDisk = JSONRawTraceStore(fileURL: url, failureCenter: PersistenceFailureCenter())
            #expect(onDisk.traces.isEmpty,
                    "round \(round): the outgoing child's raw traces were still on disk after reset()")
        }
        await store.flush()
        #expect(JSONRawTraceStore(fileURL: url, failureCenter: PersistenceFailureCenter()).traces.isEmpty,
                "a write queued before the wipe landed after it")
    }

    /// The ordering half of the gate, with no store and no race: a
    /// background write whose task is cancelled before it takes the gate
    /// must not write, even though it is past its own earlier check. This is
    /// the line `writeUnlessCancelled`'s in-lock `Task.isCancelled` guards.
    @Test("a cancelled background write never lands after the wipe")
    func aCancelledBackgroundWriteNeverLandsAfterTheWipe() async throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("gate.json")
        let gate = StoreWriteGate()
        try gate.writeNow(Data("wiped".utf8), to: url)

        let stale = Task.detached { () -> (wrote: Bool, error: String?) in
            // Park until this task has been cancelled, then try to write.
            while !Task.isCancelled { await Task.yield() }
            do { return (try gate.writeUnlessCancelled(Data("old child".utf8), to: url), nil) }
            catch { return (false, "\(error)") }
        }
        stale.cancel()
        let outcome = await stale.value

        #expect(outcome.error == nil)
        #expect(outcome.wrote == false, "a cancelled write took the gate and wrote")
        #expect(try Data(contentsOf: url) == Data("wiped".utf8), "the old child's bytes replaced the wipe")

        // …and an uncancelled one still writes (the gate is not a no-op).
        let live = Task.detached { try gate.writeUnlessCancelled(Data("next".utf8), to: url) }
        #expect(try await live.value == true)
        #expect(try Data(contentsOf: url) == Data("next".utf8))
    }

    @Test("a failed wipe write is reported before reset() returns, not later")
    func aFailedWipeWriteIsReportedSynchronously() throws {
        let dir = try tempDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        // A path whose parent is a regular FILE: every write fails.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let center = PersistenceFailureCenter()
        let store = JSONParentDashboardStore(fileURL: blocker.appendingPathComponent("dashboard.json"),
                                             failureCenter: center)
        store.reset()
        #expect(center.failures.contains { $0.hasPrefix("ParentDashboardStore:") },
                "the wipe's failure must reach the center synchronously: \(center.failures)")
    }
}

// MARK: - Through the view model

@Suite(.serialized) @MainActor struct ParticipantResetDurabilityTests {

    /// Restores the participant keys `startNewParticipant` writes, as the
    /// other `resetForNewParticipant` suites do (it has no defaults seam).
    private func withRestoredIdentity(_ body: () throws -> Void) rethrows {
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
        try body()
    }

    /// The new-participant path, end to end on real stores: by the time
    /// `resetForNewParticipant()` has written the NEW identity, every
    /// participant store's file already holds nothing of the outgoing child
    /// — read with no flush.
    @Test("by the time the new identity is written, no store file still holds the outgoing child")
    func participantResetIsOnDiskBeforeTheIdentitySwitchReturns() throws {
        try withRestoredIdentity {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("B21-vm-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let center = PersistenceFailureCenter()
            let dashboardURL = dir.appendingPathComponent("dashboard.json")
            let progressURL  = dir.appendingPathComponent("progress.json")
            let streakURL    = dir.appendingPathComponent("streak.json")
            let tracesURL    = dir.appendingPathComponent("rawtraces.json")
            let dashboard = JSONParentDashboardStore(fileURL: dashboardURL, failureCenter: center)
            let progress  = JSONProgressStore(fileURL: progressURL, failureCenter: center)
            let streak    = JSONStreakStore(fileURL: streakURL, failureCenter: center)
            let traces    = JSONRawTraceStore(fileURL: tracesURL, failureCenter: center)
            let archive   = JSONParticipantArchiveStore(directoryURL: dir.appendingPathComponent("archive", isDirectory: true),
                                                        failureCenter: center)
            let vm = TracingViewModel(.stub
                .with(dashboardStore: dashboard).with(progressStore: progress)
                .with(streakStore: streak).with(rawTraceStore: traces)
                .with(participantArchive: archive).with(studyMode: true))

            // The outgoing child did something, in every store.
            dashboard.recordPhaseSession(letter: "A", phase: "freeWrite", completed: true, score: 0.5,
                                         schedulerPriority: 0, condition: .threePhase)
            progress.recordCompletion(for: "A", accuracy: 0.5)
            streak.recordSession(date: Date(timeIntervalSince1970: 1_770_000_000),
                                 lettersCompleted: ["A"], accuracy: 0.9)
            traces.append(RawTrace(id: UUID(), letter: "A", recordedAt: Date(timeIntervalSince1970: 1_770_000_000),
                                   points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)], timestamps: [0.0, 0.1],
                                   forces: [0.5, 0.5], strokeStartIndices: [0],
                                   canvasSize: CGSize(width: 100, height: 100)))
            let outgoing = ParticipantStore.participantId

            let incoming = vm.resetForNewParticipant()

            #expect(vm.participantSealFailure == nil, "precondition: the seal succeeded")
            #expect(incoming != outgoing && ParticipantStore.participantId == incoming,
                    "precondition: the new identity is written")
            // Fresh instances on the files, NO flush: what a relaunch right now would read.
            let fresh = PersistenceFailureCenter()
            #expect(JSONParentDashboardStore(fileURL: dashboardURL, failureCenter: fresh)
                        .snapshot.phaseSessionRecords.isEmpty,
                    "the new id would own the outgoing child's phase rows")
            #expect(JSONProgressStore(fileURL: progressURL, failureCenter: fresh).allProgress.isEmpty,
                    "the new id would own the outgoing child's letter progress")
            #expect(JSONStreakStore(fileURL: streakURL, failureCenter: fresh).completedLetters.isEmpty,
                    "the new id would own the outgoing child's stars")
            #expect(JSONRawTraceStore(fileURL: tracesURL, failureCenter: fresh).traces.isEmpty,
                    "the new id would own the outgoing child's raw traces")
            #expect(center.failures.isEmpty, "\(center.failures)")
        }
    }
}
