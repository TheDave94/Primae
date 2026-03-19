//  ParentDashboardStoreTests.swift
//  BuchstabenNativeTests

import XCTest
import Foundation
@testable import BuchstabenNative

private func utcCal() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var c = DateComponents(); c.year = year; c.month = month; c.day = day; c.hour = 10
    return utcCal().date(from: c)!
}

private func makeStore() -> JSONParentDashboardStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Dashboard-\(UUID().uuidString).json")
    return JSONParentDashboardStore(fileURL: url, calendar: utcCal())
}

@MainActor
final class LetterAccuracyStatTests: XCTestCase {

    func testAverageAccuracy_empty() async {
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: [])
        XCTAssertEqual(stat.averageAccuracy, 0)
    }

    func testAverageAccuracy_singleSample() async {
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: [0.8])
        XCTAssertEqual(stat.averageAccuracy, 0.8, accuracy: 1e-9)
    }

    func testAverageAccuracy_multipleSamples() async {
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: [0.6, 0.8, 1.0])
        XCTAssertEqual(stat.averageAccuracy, 0.8, accuracy: 1e-9)
    }

    func testTrend_empty_isZero() async {
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: [])
        XCTAssertEqual(stat.trend, 0)
    }

    func testTrend_singleSample_isZero() async {
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: [0.5])
        XCTAssertEqual(stat.trend, 0)
    }

    func testTrend_improvingSequence_positive() async {
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: [0.3, 0.5, 0.7, 0.9])
        XCTAssertGreaterThan(stat.trend, 0)
    }

    func testTrend_decliningSequence_negative() async {
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: [0.9, 0.7, 0.5, 0.3])
        XCTAssertLessThan(stat.trend, 0)
    }

    func testTrend_usesLast10Samples() async {
        // First 5 samples are very bad (should be excluded), last 10 are perfect
        let early = Array(repeating: 0.0, count: 5)
        let recent = Array(repeating: 1.0, count: 10)
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: early + recent)
        // All recent samples identical → slope ≈ 0
        XCTAssertEqual(stat.trend, 0, accuracy: 1e-9)
    }
}

final class DashboardSnapshotTests: XCTestCase {

    func testTopLetters_empty() async {
        let snap = DashboardSnapshot()
        XCTAssertTrue(snap.topLetters.isEmpty)
    }

    func testTopLetters_limitsToFive() async {
        var snap = DashboardSnapshot()
        for (i, letter) in "ABCDEFGH".map(String.init).enumerated() {
            snap.letterStats[letter] = LetterAccuracyStat(
                letter: letter,
                accuracySamples: [Double(i) / 10.0]
            )
        }
        XCTAssertEqual(snap.topLetters.count, 5)
    }

    func testTopLetters_sortedByAccuracyDescending() async {
        var snap = DashboardSnapshot()
        snap.letterStats["A"] = LetterAccuracyStat(letter: "A", accuracySamples: [0.9])
        snap.letterStats["B"] = LetterAccuracyStat(letter: "B", accuracySamples: [0.5])
        snap.letterStats["C"] = LetterAccuracyStat(letter: "C", accuracySamples: [0.7])
        let top = snap.topLetters
        XCTAssertEqual(top.first?.letter, "A")
    }

    func testLettersBelow_filtersCorrectly() async {
        var snap = DashboardSnapshot()
        snap.letterStats["A"] = LetterAccuracyStat(letter: "A", accuracySamples: [0.9])
        snap.letterStats["B"] = LetterAccuracyStat(letter: "B", accuracySamples: [0.4])
        snap.letterStats["C"] = LetterAccuracyStat(letter: "C", accuracySamples: [0.55])
        let below = snap.lettersBelow(accuracy: 0.6)
        XCTAssertEqual(below.map(\.letter), ["B", "C"])
    }

    func testTotalPracticeTime_sumsRecentDays() async {
        var snap = DashboardSnapshot()
        let ref = date(2025, 3, 10)
        snap.sessionDurations = [
            SessionDurationRecord(dateString: "2025-03-04", durationSeconds: 300), // 6 days ago
            SessionDurationRecord(dateString: "2025-03-08", durationSeconds: 600), // 2 days ago
            SessionDurationRecord(dateString: "2025-03-10", durationSeconds: 900), // today
            SessionDurationRecord(dateString: "2025-02-01", durationSeconds: 9999), // old, excluded
        ]
        let total = snap.totalPracticeTime(recentDays: 7, referenceDate: ref, calendar: utcCal())
        XCTAssertEqual(total, 1800, accuracy: 1e-6)
    }
}

final class JSONParentDashboardStoreTests: XCTestCase {

    func testInitialState_empty() async {
        let store = makeStore()
        XCTAssertTrue(store.snapshot.letterStats.isEmpty)
        XCTAssertTrue(store.snapshot.sessionDurations.isEmpty)
    }

    func testRecordSession_updatesLetterStats() async {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 0.8, durationSeconds: 60, date: date(2025, 1, 1))
        XCTAssertEqual(store.snapshot.letterStats["A"]?.accuracySamples, [0.8])
    }

    func testRecordSession_accumulates() async {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 0.6, durationSeconds: 30, date: date(2025, 1, 1))
        store.recordSession(letter: "A", accuracy: 0.9, durationSeconds: 40, date: date(2025, 1, 2))
        XCTAssertEqual(store.snapshot.letterStats["A"]?.accuracySamples.count, 2)
    }

    func testRecordSession_normalizesLetterToUppercase() async {
        let store = makeStore()
        store.recordSession(letter: "a", accuracy: 0.7, durationSeconds: 20, date: date(2025, 1, 1))
        XCTAssertNotNil(store.snapshot.letterStats["A"])
        XCTAssertNil(store.snapshot.letterStats["a"])
    }

    func testRecordSession_zeroDuration_notRecorded() async {
        let store = makeStore()
        store.recordSession(letter: "B", accuracy: 0.5, durationSeconds: 0, date: date(2025, 1, 1))
        XCTAssertTrue(store.snapshot.sessionDurations.isEmpty)
    }

    func testReset_clearsAll() async {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 0.9, durationSeconds: 120, date: date(2025, 1, 1))
        store.reset()
        XCTAssertTrue(store.snapshot.letterStats.isEmpty)
        XCTAssertTrue(store.snapshot.sessionDurations.isEmpty)
    }

    func testPersistence_roundtrip() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashPersist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = JSONParentDashboardStore(fileURL: url, calendar: utcCal())
            store.recordSession(letter: "Z", accuracy: 0.75, durationSeconds: 90, date: date(2025, 6, 1))
        }
        let store2 = JSONParentDashboardStore(fileURL: url, calendar: utcCal())
        XCTAssertEqual(store2.snapshot.letterStats["Z"]?.accuracySamples, [0.75])
        XCTAssertEqual(store2.snapshot.sessionDurations.count, 1)
    }

    func testMultipleLetters_independent() async {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 1.0, durationSeconds: 10, date: date(2025, 1, 1))
        store.recordSession(letter: "B", accuracy: 0.5, durationSeconds: 10, date: date(2025, 1, 1))
        XCTAssertEqual(store.snapshot.letterStats["A"]?.averageAccuracy ?? 0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(store.snapshot.letterStats["B"]?.averageAccuracy ?? 0, 0.5, accuracy: 1e-9)
    }
}
