// LetterSchedulerTests.swift
// BuchstabenNativeTests

import XCTest
@testable import BuchstabenNative

final class LetterSchedulerTests: XCTestCase {

    private let scheduler = LetterScheduler.standard
    private let letters = ["A", "F", "I", "K", "L", "M", "O"]
    private let now = Date()

    // MARK: - Empty progress

    func testNeverPracticedLettersAllGetHighPriority() {
        let result = scheduler.prioritized(available: letters, progress: [:], now: now)
        XCTAssertEqual(result.count, letters.count)
        // All should have equal priority (all never practised).
        let priorities = Set(result.map { Int($0.priority * 100) })
        XCTAssertEqual(priorities.count, 1, "All unpractised letters should have equal priority")
    }

    func testRecommendNextReturnsNonNilForNonEmptyList() {
        let result = scheduler.recommendNext(available: letters, progress: [:], now: now)
        XCTAssertNotNil(result)
        XCTAssertTrue(letters.contains(result!))
    }

    func testEmptyAvailableReturnsNil() {
        let result = scheduler.recommendNext(available: [], progress: [:], now: now)
        XCTAssertNil(result)
    }

    // MARK: - Recency prioritisation

    func testStaleLetterRanksHigherThanRecent() {
        let threeDaysAgo = now.addingTimeInterval(-3 * 86400)
        let today = now

        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 5, bestAccuracy: 0.9, lastCompletedAt: threeDaysAgo),
            "F": LetterProgress(completionCount: 5, bestAccuracy: 0.9, lastCompletedAt: today),
        ]

        let result = scheduler.prioritized(available: ["A", "F"], progress: progress, now: now)
        XCTAssertEqual(result.first?.letter, "A", "Stale letter 'A' should rank higher")
    }

    func testNeverPracticedRanksHigherThanRecent() {
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 3, bestAccuracy: 0.8, lastCompletedAt: now),
        ]

        let result = scheduler.prioritized(available: ["A", "F"], progress: progress, now: now)
        XCTAssertEqual(result.first?.letter, "F", "Never-practised 'F' should rank higher")
    }

    // MARK: - Accuracy prioritisation

    func testLowAccuracyLetterRanksHigher() {
        let yesterday = now.addingTimeInterval(-86400)
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 5, bestAccuracy: 0.95, lastCompletedAt: yesterday),
            "F": LetterProgress(completionCount: 5, bestAccuracy: 0.40, lastCompletedAt: yesterday),
        ]

        let result = scheduler.prioritized(available: ["A", "F"], progress: progress, now: now)
        XCTAssertEqual(result.first?.letter, "F", "Low-accuracy 'F' should rank higher")
    }

    // MARK: - Novelty prioritisation

    func testLessCompletedLetterRanksHigher() {
        let yesterday = now.addingTimeInterval(-86400)
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 50, bestAccuracy: 0.8, lastCompletedAt: yesterday),
            "F": LetterProgress(completionCount: 1, bestAccuracy: 0.8, lastCompletedAt: yesterday),
        ]

        let result = scheduler.prioritized(available: ["A", "F"], progress: progress, now: now)
        XCTAssertEqual(result.first?.letter, "F",
            "Less-completed 'F' should rank higher than over-practised 'A'")
    }

    // MARK: - Top N

    func testRecommendTopN() {
        let result = scheduler.recommendTopN(3, available: letters, progress: [:], now: now)
        XCTAssertEqual(result.count, 3)
    }

    func testRecommendTopNWithFewerAvailable() {
        let result = scheduler.recommendTopN(10, available: ["A", "F"], progress: [:], now: now)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Custom weights

    func testCustomWeightsAffectOrdering() {
        let yesterday = now.addingTimeInterval(-86400)
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 1, bestAccuracy: 0.4, lastCompletedAt: yesterday),
            "F": LetterProgress(completionCount: 1, bestAccuracy: 0.9, lastCompletedAt: yesterday),
        ]

        // With high accuracy weight, low-accuracy letter should dominate.
        var accuracyFocused = LetterScheduler()
        accuracyFocused.recencyWeight = 0.0
        accuracyFocused.accuracyWeight = 1.0
        accuracyFocused.noveltyWeight = 0.0

        let result = accuracyFocused.prioritized(available: ["A", "F"], progress: progress, now: now)
        XCTAssertEqual(result.first?.letter, "A")
    }

    // MARK: - Determinism

    func testSameInputProducesSameOutput() {
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 3, bestAccuracy: 0.7, lastCompletedAt: now.addingTimeInterval(-86400)),
        ]
        let r1 = scheduler.prioritized(available: letters, progress: progress, now: now)
        let r2 = scheduler.prioritized(available: letters, progress: progress, now: now)
        XCTAssertEqual(r1.map(\.letter), r2.map(\.letter))
    }
}
