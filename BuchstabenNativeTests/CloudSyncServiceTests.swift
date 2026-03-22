//  CloudSyncServiceTests.swift
//  BuchstabenNativeTests

import Testing
@testable import BuchstabenNative

private enum TestError: Error, LocalizedError {
    case forced
    var errorDescription: String? { "Forced test error" }
}

private func makeProgressStore() -> JSONProgressStore {
    JSONProgressStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("SyncProgress-\(UUID().uuidString).json"))
}

private func makeStreakStore() -> JSONStreakStore {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
    return JSONStreakStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("SyncStreak-\(UUID().uuidString).json"), calendar: c)
}

@Suite @MainActor struct SyncStateTests {
    @Test func idle_equalToIdle() { #expect(SyncState.idle == .idle) }
    @Test func syncing_equalToSyncing() { #expect(SyncState.syncing == .syncing) }
    @Test func error_equalWithSameMessage() { #expect(SyncState.error("oops") == .error("oops")) }
    @Test func error_notEqualWithDifferentMessage() { #expect(SyncState.error("a") != .error("b")) }
    @Test func idle_notEqualToSyncing() { #expect(SyncState.idle != .syncing) }
}

@Suite @MainActor struct NullSyncServiceTests {
    @Test func initialState_idle() {
        #expect(NullSyncService().syncState == .idle)
    }
    @Test func push_recordsPayload() async {
        let svc = NullSyncService()
        await withCheckedContinuation { cont in
            svc.push(recordType: .progress, payload: ["key": "val"]) { _ in cont.resume() }
        }
        #expect(svc.pushedRecords.count == 1)
        #expect(svc.pushedRecords.first?.0 == .progress)
    }
    @Test func push_storesForFetch() async {
        let svc = NullSyncService()
        await withCheckedContinuation { cont in
            svc.push(recordType: .streak, payload: ["streak": 7]) { _ in cont.resume() }
        }
        let val: Int? = await withCheckedContinuation { cont in
            svc.fetch(recordType: .streak) { result in
                if case .success(let d) = result { cont.resume(returning: d["streak"] as? Int) }
                else { cont.resume(returning: nil) }
            }
        }
        #expect(val == 7)
    }
    @Test func push_successResult() async {
        let svc = NullSyncService()
        let ok: Bool = await withCheckedContinuation { cont in
            svc.push(recordType: .progress, payload: [:]) { result in
                if case .failure = result { cont.resume(returning: false) }
                else { cont.resume(returning: true) }
            }
        }
        #expect(ok)
    }
    @Test func fetch_emptyWhenNotSeeded() async {
        let svc = NullSyncService()
        let empty: Bool = await withCheckedContinuation { cont in
            svc.fetch(recordType: .progress) { result in
                if case .success(let d) = result { cont.resume(returning: d.isEmpty) }
                else { cont.resume(returning: false) }
            }
        }
        #expect(empty)
    }
    @Test func seedRecord_returnedByFetch() async {
        let svc = NullSyncService()
        svc.seedRecord(type: .progress, payload: ["total": 42])
        let val: Int? = await withCheckedContinuation { cont in
            svc.fetch(recordType: .progress) { result in
                if case .success(let d) = result { cont.resume(returning: d["total"] as? Int) }
                else { cont.resume(returning: nil) }
            }
        }
        #expect(val == 42)
    }
    @Test func simulateError_pushFails() async {
        let svc = NullSyncService(); svc.simulateError = TestError.forced
        let failed: Bool = await withCheckedContinuation { cont in
            svc.push(recordType: .progress, payload: [:]) { result in
                if case .failure = result { cont.resume(returning: true) }
                else { cont.resume(returning: false) }
            }
        }
        #expect(failed)
        #expect(svc.syncState == .error("Forced test error"))
    }
    @Test func simulateError_fetchFails() async {
        let svc = NullSyncService(); svc.simulateError = TestError.forced
        let failed: Bool = await withCheckedContinuation { cont in
            svc.fetch(recordType: .streak) { result in
                if case .failure = result { cont.resume(returning: true) }
                else { cont.resume(returning: false) }
            }
        }
        #expect(failed)
    }
    @Test func reset_clearsAll() {
        let svc = NullSyncService()
        svc.push(recordType: .progress, payload: ["x": 1]) { _ in }
        svc.simulateError = TestError.forced
        svc.reset()
        #expect(svc.syncState == .idle)
        #expect(svc.pushedRecords.isEmpty)
        #expect(svc.simulateError == nil)
    }
}

@Suite @MainActor struct SyncCoordinatorTests {
    @Test func pushAll_pushesBothRecordTypes() async {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        await withCheckedContinuation { cont in coord.pushAll { _ in cont.resume() } }
        let types = svc.pushedRecords.map(\.0)
        #expect(types.contains(.progress))
        #expect(types.contains(.streak))
    }
    @Test func pushAll_setsLastSyncDate() async {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        #expect(coord.lastSyncDate == nil)
        await withCheckedContinuation { cont in coord.pushAll { _ in cont.resume() } }
        #expect(coord.lastSyncDate != nil)
    }
    @Test func pushAll_onError_doesNotSetLastSyncDate() async {
        let svc = NullSyncService(); svc.simulateError = TestError.forced
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        await withCheckedContinuation { cont in coord.pushAll { _ in cont.resume() } }
        #expect(coord.lastSyncDate == nil)
    }
    @Test func pushAll_progressPayload_containsTimestamp() async {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        await withCheckedContinuation { cont in coord.pushAll { _ in cont.resume() } }
        let record = svc.pushedRecords.first(where: { $0.0 == .progress })?.1
        #expect(record?["timestamp"] as? String != nil)
    }
    @Test func pushAll_streakPayload_containsStreakFields() async {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        await withCheckedContinuation { cont in coord.pushAll { _ in cont.resume() } }
        let record = svc.pushedRecords.first(where: { $0.0 == .streak })?.1
        #expect(record?["currentStreak"] != nil)
        #expect(record?["totalCompletions"] != nil)
    }
}
