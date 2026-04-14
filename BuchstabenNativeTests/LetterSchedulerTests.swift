// LetterSchedulerTests.swift
// BuchstabenNativeTests
//
// Uses Swift Testing (@Test, #expect).

import Testing
@testable import BuchstabenNative

struct LetterSchedulerTests {

    private let scheduler = LetterScheduler.standard
    private let letters = ["A", "F", "I", "K", "L", "M", "O"]
    private let now = Date()

    // MARK: - Empty progress

    @Test("Unpractised letters all get equal priority")
    func unpractisedEqualPriority() {
        let result = scheduler.prioritized(available: letters, progress: [:], now: now)
        #expect(result.count == letters.count)
        let priorities = Set(result.map { Int($0.priority * 100) })
        #expect(priorities.count == 1)
    }

    @Test("Recommend next returns non-nil for non-empty list")
    func recommendNextNonNil() {
        let result = scheduler.recommendNext(available: letters, progress: [:], now: now)
        #expect(result != nil)
        #expect(letters.contains(result!))
    }

    @Test("Empty available returns nil")
    func emptyAvailableReturnsNil() {
        #expect(scheduler.recommendNext(available: [], progress: [:], now: now) == nil)
    }

    // MARK: - Recency

    @Test("Stale letter ranks higher than recent")
    func staleRanksHigher() {
        let threeDaysAgo = now.addingTimeInterval(-3 * 86400)
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 5, bestAccuracy: 0.9, lastCompletedAt: threeDaysAgo),
            "F": LetterProgress(completionCount: 5, bestAccuracy: 0.9, lastCompletedAt: now),
        ]
        let result = scheduler.prioritized(available: ["A", "F"], progress: progress, now: now)
        #expect(result.first?.letter == "A")
    }

    @Test("Never-practised ranks higher than recently practised")
    func neverPractisedRanksHigher() {
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 3, bestAccuracy: 0.8, lastCompletedAt: now),
        ]
        let result = scheduler.prioritized(available: ["A", "F"], progress: progress, now: now)
        #expect(result.first?.letter == "F")
    }

    // MARK: - Accuracy

    @Test("Low accuracy letter ranks higher")
    func lowAccuracyRanksHigher() {
        let yesterday = now.addingTimeInterval(-86400)
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 5, bestAccuracy: 0.95, lastCompletedAt: yesterday),
            "F": LetterProgress(completionCount: 5, bestAccuracy: 0.40, lastCompletedAt: yesterday),
        ]
        let result = scheduler.prioritized(available: ["A", "F"], progress: progress, now: now)
        #expect(result.first?.letter == "F")
    }

    // MARK: - Novelty

    @Test("Less-completed letter ranks higher")
    func lessCompletedRanksHigher() {
        let yesterday = now.addingTimeInterval(-86400)
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 50, bestAccuracy: 0.8, lastCompletedAt: yesterday),
            "F": LetterProgress(completionCount: 1, bestAccuracy: 0.8, lastCompletedAt: yesterday),
        ]
        let result = scheduler.prioritized(available: ["A", "F"], progress: progress, now: now)
        #expect(result.first?.letter == "F")
    }

    // MARK: - Top N

    @Test("Recommend top N returns correct count")
    func topNCount() {
        let result = scheduler.recommendTopN(3, available: letters, progress: [:], now: now)
        #expect(result.count == 3)
    }

    @Test("Recommend top N with fewer available")
    func topNFewerAvailable() {
        let result = scheduler.recommendTopN(10, available: ["A", "F"], progress: [:], now: now)
        #expect(result.count == 2)
    }

    // MARK: - Determinism

    @Test("Same input produces same output")
    func determinism() {
        let progress: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 3, bestAccuracy: 0.7,
                                lastCompletedAt: now.addingTimeInterval(-86400)),
        ]
        let r1 = scheduler.prioritized(available: letters, progress: progress, now: now)
        let r2 = scheduler.prioritized(available: letters, progress: progress, now: now)
        #expect(r1.map(\.letter) == r2.map(\.letter))
    }
}
