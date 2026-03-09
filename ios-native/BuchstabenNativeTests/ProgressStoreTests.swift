//  ProgressStoreTests.swift
//  BuchstabenNativeTests
//
//  Unit tests for JSONProgressStore (ProgressStoring protocol).
//  Uses a temp-directory backed store so production data is never touched.

import XCTest
@testable import BuchstabenNative

@MainActor
final class ProgressStoreTests: XCTestCase {

    private var tempURL: URL!
    private var store: JSONProgressStore!

    override func setUp() async throws {
        try await super.setUp()
        // async throws override ensures @MainActor isolation is preserved (Swift 6).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("progress.json")
        store = JSONProgressStore(fileURL: tempURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL.deletingLastPathComponent())
        try await super.tearDown()
    }

    // MARK: - Initial state

    func testInitialState_isEmpty() {
        XCTAssertEqual(store.totalCompletions, 0)
        XCTAssertEqual(store.currentStreakDays, 0)
        XCTAssertTrue(store.allProgress.isEmpty)
    }

    func testInitialProgress_forUnknownLetter_returnsDefault() {
        let p = store.progress(for: "Z")
        XCTAssertEqual(p.completionCount, 0)
        XCTAssertEqual(p.bestAccuracy, 0.0)
        XCTAssertNil(p.lastCompletedAt)
    }

    // MARK: - recordCompletion

    func testRecordCompletion_incrementsCount() {
        store.recordCompletion(for: "A", accuracy: 0.9)
        XCTAssertEqual(store.progress(for: "A").completionCount, 1)
    }

    func testRecordCompletion_multipleTimes_incrementsCount() {
        store.recordCompletion(for: "B", accuracy: 0.5)
        store.recordCompletion(for: "B", accuracy: 0.7)
        store.recordCompletion(for: "B", accuracy: 0.6)
        XCTAssertEqual(store.progress(for: "B").completionCount, 3)
    }

    func testRecordCompletion_tracksBestAccuracy() {
        store.recordCompletion(for: "C", accuracy: 0.5)
        store.recordCompletion(for: "C", accuracy: 0.9)
        store.recordCompletion(for: "C", accuracy: 0.7)
        XCTAssertEqual(store.progress(for: "C").bestAccuracy, 0.9, accuracy: 1e-9)
    }

    func testRecordCompletion_setsLastCompletedAt() {
        let before = Date()
        store.recordCompletion(for: "D", accuracy: 1.0)
        let after = Date()
        let ts = store.progress(for: "D").lastCompletedAt
        XCTAssertNotNil(ts)
        XCTAssertGreaterThanOrEqual(ts!, before)
        XCTAssertLessThanOrEqual(ts!, after)
    }

    func testRecordCompletion_isCaseInsensitive() {
        store.recordCompletion(for: "a", accuracy: 0.8)
        store.recordCompletion(for: "A", accuracy: 0.6)
        XCTAssertEqual(store.progress(for: "A").completionCount, 2)
        XCTAssertEqual(store.progress(for: "a").completionCount, 2)
    }

    func testRecordCompletion_clampsAccuracyToUnit() {
        store.recordCompletion(for: "E", accuracy: 2.5)   // over
        XCTAssertLessThanOrEqual(store.progress(for: "E").bestAccuracy, 1.0)
        store.recordCompletion(for: "F", accuracy: -0.5)  // under
        XCTAssertGreaterThanOrEqual(store.progress(for: "F").bestAccuracy, 0.0)
    }

    // MARK: - totalCompletions

    func testTotalCompletions_sumsAcrossAllLetters() {
        store.recordCompletion(for: "A", accuracy: 1.0)
        store.recordCompletion(for: "A", accuracy: 1.0)
        store.recordCompletion(for: "B", accuracy: 0.8)
        XCTAssertEqual(store.totalCompletions, 3)
    }

    // MARK: - Persistence (reload from disk)

    func testPersistence_survivesReinit() {
        store.recordCompletion(for: "G", accuracy: 0.75)
        store.recordCompletion(for: "G", accuracy: 0.95)

        // Reload from same file URL
        let reloaded = JSONProgressStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.progress(for: "G").completionCount, 2)
        XCTAssertEqual(reloaded.progress(for: "G").bestAccuracy, 0.95, accuracy: 1e-9)
    }

    func testPersistence_totalCompletionsSurvivesReinit() {
        store.recordCompletion(for: "H", accuracy: 1.0)
        store.recordCompletion(for: "I", accuracy: 0.9)
        let reloaded = JSONProgressStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.totalCompletions, 2)
    }

    // MARK: - resetAll

    func testResetAll_clearsEverything() {
        store.recordCompletion(for: "J", accuracy: 1.0)
        store.recordCompletion(for: "K", accuracy: 0.8)
        store.resetAll()
        XCTAssertEqual(store.totalCompletions, 0)
        XCTAssertTrue(store.allProgress.isEmpty)
        XCTAssertEqual(store.currentStreakDays, 0)
    }

    func testResetAll_persistsOnDisk() {
        store.recordCompletion(for: "L", accuracy: 1.0)
        store.resetAll()
        let reloaded = JSONProgressStore(fileURL: tempURL)
        XCTAssertEqual(reloaded.totalCompletions, 0)
    }

    // MARK: - Streak

    func testStreak_singleCompletionToday_isOne() {
        store.recordCompletion(for: "M", accuracy: 1.0)
        // Streak should be at least 1 (completed today)
        XCTAssertGreaterThanOrEqual(store.currentStreakDays, 1)
    }

    func testStreak_noCompletions_isZero() {
        XCTAssertEqual(store.currentStreakDays, 0)
    }

    func testStreak_multipleCompletionsSameDay_countsOnce() {
        for _ in 0..<5 {
            store.recordCompletion(for: "N", accuracy: 1.0)
        }
        XCTAssertEqual(store.currentStreakDays, 1)
    }

    // MARK: - allProgress dictionary

    func testAllProgress_containsAllRecordedLetters() {
        store.recordCompletion(for: "O", accuracy: 0.9)
        store.recordCompletion(for: "P", accuracy: 0.5)
        let all = store.allProgress
        XCTAssertTrue(all.keys.contains("O"))
        XCTAssertTrue(all.keys.contains("P"))
        XCTAssertFalse(all.keys.contains("Q"))
    }
}
