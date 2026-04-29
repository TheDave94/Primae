//  CloudSyncServiceTests.swift
//  PrimaeNativeTests

import Testing
import Foundation
@testable import PrimaeNative

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
    @Test func idle_equalToIdle()             { #expect(SyncState.idle == .idle) }
    @Test func syncing_equalToSyncing()       { #expect(SyncState.syncing == .syncing) }
    @Test func error_equalWithSameMessage()   { #expect(SyncState.error("oops") == .error("oops")) }
    @Test func error_notEqualWithDifferentMessage() { #expect(SyncState.error("a") != .error("b")) }
    @Test func idle_notEqualToSyncing()       { #expect(SyncState.idle != .syncing) }
}

@Suite @MainActor struct NullSyncServiceTests {

    @Test func initialState_idle() {
        #expect(NullSyncService().syncState == .idle)
    }

    @Test func push_recordsPayload() async throws {
        let svc = NullSyncService()
        try await svc.push(recordType: .progress, payload: ["key": "val"])
        #expect(svc.pushedRecords.count == 1)
        #expect(svc.pushedRecords.first?.0 == .progress)
    }

    @Test func push_storesForFetch() async throws {
        let svc = NullSyncService()
        try await svc.push(recordType: .streak, payload: ["streak": 7])
        let result = try await svc.fetch(recordType: .streak)
        #expect(result["streak"] as? Int == 7)
    }

    @Test func push_doesNotThrowOnSuccess() async {
        let svc = NullSyncService()
        await #expect(throws: Never.self) {
            try await svc.push(recordType: .progress, payload: [:])
        }
    }

    @Test func fetch_emptyWhenNotSeeded() async throws {
        let svc = NullSyncService()
        let result = try await svc.fetch(recordType: .progress)
        #expect(result.isEmpty)
    }

    @Test func seedRecord_returnedByFetch() async throws {
        let svc = NullSyncService()
        svc.seedRecord(type: .progress, payload: ["total": 42])
        let result = try await svc.fetch(recordType: .progress)
        #expect(result["total"] as? Int == 42)
    }

    @Test func simulateError_pushFails() async {
        let svc = NullSyncService(); svc.simulateError = TestError.forced
        do {
            try await svc.push(recordType: .progress, payload: [:])
            Issue.record("Expected push to throw")
        } catch {
            #expect(svc.syncState == .error("Forced test error"))
        }
    }

    @Test func simulateError_fetchFails() async {
        let svc = NullSyncService(); svc.simulateError = TestError.forced
        do {
            _ = try await svc.fetch(recordType: .streak)
            Issue.record("Expected fetch to throw")
        } catch {
            #expect(svc.syncState == .error("Forced test error"))
        }
    }

    @Test func reset_clearsAll() async throws {
        let svc = NullSyncService()
        try await svc.push(recordType: .progress, payload: ["x": 1])
        svc.simulateError = TestError.forced
        svc.reset()
        #expect(svc.syncState == .idle)
        #expect(svc.pushedRecords.isEmpty)
        #expect(svc.simulateError == nil)
    }
}

@Suite @MainActor struct SyncCoordinatorTests {

    @Test func pushAll_pushesBothRecordTypes() async throws {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        try await coord.pushAll()
        let types = svc.pushedRecords.map(\.0)
        #expect(types.contains(.progress))
        #expect(types.contains(.streak))
    }

    @Test func pushAll_setsLastSyncDate() async throws {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        #expect(coord.lastSyncDate == nil)
        try await coord.pushAll()
        #expect(coord.lastSyncDate != nil)
    }

    @Test func pushAll_onError_doesNotSetLastSyncDate() async {
        let svc = NullSyncService(); svc.simulateError = TestError.forced
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        try? await coord.pushAll()
        #expect(coord.lastSyncDate == nil)
    }

    @Test func pushAll_progressPayload_containsTimestamp() async throws {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        try await coord.pushAll()
        let record = svc.pushedRecords.first(where: { $0.0 == .progress })?.1
        #expect(record?["timestamp"] as? String != nil)
    }

    @Test func pushAll_streakPayload_containsStreakFields() async throws {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        try await coord.pushAll()
        let record = svc.pushedRecords.first(where: { $0.0 == .streak })?.1
        #expect(record?["currentStreak"] != nil)
        #expect(record?["totalCompletions"] != nil)
    }
}
