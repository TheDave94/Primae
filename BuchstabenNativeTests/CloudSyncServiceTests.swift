//  CloudSyncServiceTests.swift
//  BuchstabenNativeTests

import XCTest
@testable import BuchstabenNative

// MARK: - Helpers

private enum TestError: Error, LocalizedError {
    case forced
    var errorDescription: String? { "Forced test error" }
}

private func makeProgressStore() -> JSONProgressStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SyncProgress-\(UUID().uuidString).json")
    return JSONProgressStore(fileURL: url)
}

private func makeStreakStore() -> JSONStreakStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SyncStreak-\(UUID().uuidString).json")
    return JSONStreakStore(fileURL: url, calendar: {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }())
}

// MARK: - SyncState equality

@MainActor
final class SyncStateTests: XCTestCase {
    func testIdle_equalToIdle() {
        XCTAssertEqual(SyncState.idle, .idle)
    }
    func testSyncing_equalToSyncing() {
        XCTAssertEqual(SyncState.syncing, .syncing)
    }
    func testError_equalWithSameMessage() {
        XCTAssertEqual(SyncState.error("oops"), .error("oops"))
    }
    func testError_notEqualWithDifferentMessage() {
        XCTAssertNotEqual(SyncState.error("a"), .error("b"))
    }
    func testIdle_notEqualToSyncing() {
        XCTAssertNotEqual(SyncState.idle, .syncing)
    }
}

// MARK: - NullSyncService tests

@MainActor
final class NullSyncServiceTests: XCTestCase {

    func testInitialState_idle() {
        let svc = NullSyncService()
        XCTAssertEqual(svc.syncState, .idle)
    }

    func testPush_recordsPayload() {
        let svc = NullSyncService()
        let exp = expectation(description: "push")
        svc.push(recordType: .progress, payload: ["key": "val"]) { _ in exp.fulfill() }
        waitForExpectations(timeout: 1)
        XCTAssertEqual(svc.pushedRecords.count, 1)
        XCTAssertEqual(svc.pushedRecords.first?.0, .progress)
    }

    func testPush_storesForFetch() {
        let svc = NullSyncService()
        let exp1 = expectation(description: "push")
        let exp2 = expectation(description: "fetch")
        svc.push(recordType: .streak, payload: ["streak": 7]) { _ in exp1.fulfill() }
        wait(for: [exp1], timeout: 1)
        svc.fetch(recordType: .streak) { result in
            if case .success(let d) = result {
                XCTAssertEqual(d["streak"] as? Int, 7)
            } else { XCTFail("Expected success") }
            exp2.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testPush_successResult() {
        let svc = NullSyncService()
        let exp = expectation(description: "push")
        svc.push(recordType: .progress, payload: [:]) { result in
            if case .failure = result { XCTFail("Expected success") }
            exp.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testFetch_emptyWhenNotSeeded() {
        let svc = NullSyncService()
        let exp = expectation(description: "fetch")
        svc.fetch(recordType: .progress) { result in
            if case .success(let d) = result { XCTAssertTrue(d.isEmpty) }
            else { XCTFail() }
            exp.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testSeedRecord_returnedByFetch() {
        let svc = NullSyncService()
        svc.seedRecord(type: .progress, payload: ["total": 42])
        let exp = expectation(description: "fetch")
        svc.fetch(recordType: .progress) { result in
            if case .success(let d) = result { XCTAssertEqual(d["total"] as? Int, 42) }
            else { XCTFail() }
            exp.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testSimulateError_pushFails() {
        let svc = NullSyncService()
        svc.simulateError = TestError.forced
        let exp = expectation(description: "push")
        svc.push(recordType: .progress, payload: [:]) { result in
            if case .success = result { XCTFail("Expected failure") }
            exp.fulfill()
        }
        waitForExpectations(timeout: 1)
        XCTAssertEqual(svc.syncState, .error("Forced test error"))
    }

    func testSimulateError_fetchFails() {
        let svc = NullSyncService()
        svc.simulateError = TestError.forced
        let exp = expectation(description: "fetch")
        svc.fetch(recordType: .streak) { result in
            if case .success = result { XCTFail("Expected failure") }
            exp.fulfill()
        }
        waitForExpectations(timeout: 1)
    }

    func testReset_clearsAll() {
        let svc = NullSyncService()
        svc.push(recordType: .progress, payload: ["x": 1]) { _ in }
        svc.simulateError = TestError.forced
        svc.reset()
        XCTAssertEqual(svc.syncState, .idle)
        XCTAssertTrue(svc.pushedRecords.isEmpty)
        XCTAssertNil(svc.simulateError)
    }
}

// MARK: - SyncCoordinator tests

@MainActor
final class SyncCoordinatorTests: XCTestCase {

    func testPushAll_pushesBothRecordTypes() {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        let exp = expectation(description: "pushAll")
        coord.pushAll { _ in exp.fulfill() }
        waitForExpectations(timeout: 1)
        let types = svc.pushedRecords.map(\.0)
        XCTAssertTrue(types.contains(.progress))
        XCTAssertTrue(types.contains(.streak))
    }

    func testPushAll_setsLastSyncDate() {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        XCTAssertNil(coord.lastSyncDate)
        let exp = expectation(description: "pushAll")
        coord.pushAll { _ in exp.fulfill() }
        waitForExpectations(timeout: 1)
        XCTAssertNotNil(coord.lastSyncDate)
    }

    func testPushAll_onError_doesNotSetLastSyncDate() {
        let svc = NullSyncService()
        svc.simulateError = TestError.forced
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        let exp = expectation(description: "pushAll")
        coord.pushAll { _ in exp.fulfill() }
        waitForExpectations(timeout: 1)
        XCTAssertNil(coord.lastSyncDate)
    }

    func testPushAll_progressPayload_containsTimestamp() {
        let svc = NullSyncService()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: makeStreakStore())
        let exp = expectation(description: "pushAll")
        coord.pushAll { _ in exp.fulfill() }
        waitForExpectations(timeout: 1)
        let progressRecord = svc.pushedRecords.first(where: { $0.0 == .progress })?.1
        XCTAssertNotNil(progressRecord?["timestamp"] as? String)
    }

    func testPushAll_streakPayload_containsStreakFields() {
        let svc = NullSyncService()
        let streakStore = makeStreakStore()
        let coord = SyncCoordinator(sync: svc, progressStore: makeProgressStore(), streakStore: streakStore)
        let exp = expectation(description: "pushAll")
        coord.pushAll { _ in exp.fulfill() }
        waitForExpectations(timeout: 1)
        let streakRecord = svc.pushedRecords.first(where: { $0.0 == .streak })?.1
        XCTAssertNotNil(streakRecord?["currentStreak"])
        XCTAssertNotNil(streakRecord?["totalCompletions"])
    }
}
