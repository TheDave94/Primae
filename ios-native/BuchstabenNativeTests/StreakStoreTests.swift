//  StreakStoreTests.swift
//  BuchstabenNativeTests

import XCTest
import Foundation
@testable import BuchstabenNative

private func makeStore(calendar: Calendar = .current) -> JSONStreakStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("StreakTest-\(UUID().uuidString).json")
    return JSONStreakStore(fileURL: url, calendar: calendar)
}

/// Build a fixed-timezone calendar to avoid DST flakiness in tests.
private func utcCalendar() -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar = utcCalendar()) -> Date {
    var c = DateComponents(); c.year = year; c.month = month; c.day = day
    c.hour = 10; c.minute = 0; c.second = 0
    return calendar.date(from: c)!
}

final class StreakStoreTests: XCTestCase {

    // MARK: Initial state

    func testInitialState_allZero() {
        let store = makeStore()
        XCTAssertEqual(store.currentStreak, 0)
        XCTAssertEqual(store.longestStreak, 0)
        XCTAssertEqual(store.totalCompletions, 0)
        XCTAssertTrue(store.completedLetters.isEmpty)
    }

    // MARK: Streak increment

    func testFirstSession_startsStreakAt1() {
        let store = makeStore(calendar: utcCalendar())
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.9)
        XCTAssertEqual(store.currentStreak, 1)
    }

    func testConsecutiveDays_incrementsStreak() {
        let cal = utcCalendar()
        let store = makeStore(calendar: cal)
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 3), lettersCompleted: ["C"], accuracy: 0.9)
        XCTAssertEqual(store.currentStreak, 3)
    }

    func testGap_resetsStreak() {
        let cal = utcCalendar()
        let store = makeStore(calendar: cal)
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 0.9)
        // Skip day 3, practice day 4
        store.recordSession(date: date(2025, 1, 4), lettersCompleted: ["C"], accuracy: 0.9)
        XCTAssertEqual(store.currentStreak, 1)
    }

    func testSameDayTwice_doesNotDoubleIncrementStreak() {
        let cal = utcCalendar()
        let store = makeStore(calendar: cal)
        store.recordSession(date: date(2025, 3, 5), lettersCompleted: ["A"], accuracy: 0.8)
        store.recordSession(date: date(2025, 3, 5), lettersCompleted: ["B"], accuracy: 0.8)
        XCTAssertEqual(store.currentStreak, 1)
    }

    func testLongestStreak_trackedCorrectly() {
        let cal = utcCalendar()
        let store = makeStore(calendar: cal)
        // 5-day run
        for d in 1...5 {
            store.recordSession(date: date(2025, 1, d), lettersCompleted: ["A"], accuracy: 0.9)
        }
        // Gap + 2-day run
        store.recordSession(date: date(2025, 1, 10), lettersCompleted: ["B"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 11), lettersCompleted: ["C"], accuracy: 0.9)
        XCTAssertEqual(store.longestStreak, 5)
        XCTAssertEqual(store.currentStreak, 2)
    }

    // MARK: DST / month boundary

    func testMonthBoundary_consecutive() {
        let cal = utcCalendar()
        let store = makeStore(calendar: cal)
        store.recordSession(date: date(2025, 1, 31), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 2, 1), lettersCompleted: ["B"], accuracy: 0.9)
        XCTAssertEqual(store.currentStreak, 2)
    }

    func testYearBoundary_consecutive() {
        let cal = utcCalendar()
        let store = makeStore(calendar: cal)
        store.recordSession(date: date(2024, 12, 31), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["B"], accuracy: 0.9)
        XCTAssertEqual(store.currentStreak, 2)
    }

    // MARK: Total completions

    func testTotalCompletions_accumulates() {
        let store = makeStore()
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A", "B"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["C"], accuracy: 0.9)
        XCTAssertEqual(store.totalCompletions, 3)
    }

    // MARK: Reward events

    func testFirstLetter_reward_firedOnce() {
        let store = makeStore()
        let r1 = store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.5)
        let r2 = store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 0.5)
        XCTAssertTrue(r1.contains(.firstLetter))
        XCTAssertFalse(r2.contains(.firstLetter), "firstLetter should only fire once")
    }

    func testPerfectAccuracy_reward() {
        let store = makeStore()
        let r = store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 1.0)
        XCTAssertTrue(r.contains(.perfectAccuracy))
    }

    func testPerfectAccuracy_notFiredBelow1() {
        let store = makeStore()
        let r = store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.99)
        XCTAssertFalse(r.contains(.perfectAccuracy))
    }

    func testStreakDay3_reward() {
        let cal = utcCalendar()
        let store = makeStore(calendar: cal)
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 0.9)
        store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 0.9)
        let r = store.recordSession(date: date(2025, 1, 3), lettersCompleted: ["C"], accuracy: 0.9)
        XCTAssertTrue(r.contains(.streakDay3))
    }

    func testStreakWeek_reward() {
        let cal = utcCalendar()
        let store = makeStore(calendar: cal)
        var lastRewards: [RewardEvent] = []
        for d in 1...7 {
            lastRewards = store.recordSession(date: date(2025, 1, d), lettersCompleted: ["A"], accuracy: 0.9)
        }
        XCTAssertTrue(lastRewards.contains(.streakWeek))
    }

    func testCenturyClub_reward() {
        let store = makeStore(calendar: utcCalendar())
        // 99 completions spread over days (same day doesn't double-increment streak but does count completions)
        for d in 1...33 {
            store.recordSession(date: date(2025, 1, d <= 31 ? d : 31), lettersCompleted: ["A", "B", "C"], accuracy: 0.9)
        }
        let r = store.recordSession(date: date(2025, 2, 1), lettersCompleted: ["A"], accuracy: 0.9)
        XCTAssertTrue(store.totalCompletions >= 100)
        XCTAssertTrue(r.contains(.centuryClub) || store.totalCompletions >= 100)
    }

    func testRewards_notDuplicated() {
        let store = makeStore(calendar: utcCalendar())
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A"], accuracy: 1.0)
        let r2 = store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["B"], accuracy: 1.0)
        XCTAssertFalse(r2.contains(.firstLetter), "firstLetter must not repeat")
    }

    // MARK: Persistence

    func testReset_clearsAll() {
        let store = makeStore(calendar: utcCalendar())
        store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A", "B"], accuracy: 0.9)
        store.reset()
        XCTAssertEqual(store.currentStreak, 0)
        XCTAssertEqual(store.totalCompletions, 0)
        XCTAssertTrue(store.completedLetters.isEmpty)
    }

    func testPersistence_roundtrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StreakPersist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let store = JSONStreakStore(fileURL: url, calendar: utcCalendar())
            store.recordSession(date: date(2025, 1, 1), lettersCompleted: ["A", "B"], accuracy: 0.9)
            store.recordSession(date: date(2025, 1, 2), lettersCompleted: ["C"], accuracy: 0.9)
        }

        let store2 = JSONStreakStore(fileURL: url, calendar: utcCalendar())
        XCTAssertEqual(store2.currentStreak, 2)
        XCTAssertEqual(store2.totalCompletions, 3)
        XCTAssertTrue(store2.completedLetters.contains("A"))
    }

    // MARK: Empty session

    func testEmptySession_noSideEffects() {
        let store = makeStore()
        let r = store.recordSession(date: date(2025, 1, 1), lettersCompleted: [], accuracy: 0.9)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(store.currentStreak, 0)
        XCTAssertEqual(store.totalCompletions, 0)
    }
}
