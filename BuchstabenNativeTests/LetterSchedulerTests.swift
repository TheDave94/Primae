// LetterSchedulerTests.swift
// BuchstabenNativeTests
//
// Uses Swift Testing (@Test, #expect).

import Foundation
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

    @Test("Recency urgency saturates (Ebbinghaus-exponential, not linear)")
    func recencySaturates() {
        // 60 days vs 15 days: linear would give 4x urgency; exponential saturates
        // (both values are close to 1 when memoryStability=7d).
        let fifteenDaysAgo = now.addingTimeInterval(-15 * 86400)
        let sixtyDaysAgo   = now.addingTimeInterval(-60 * 86400)
        let progressShort: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 5, bestAccuracy: 0.9,
                                 lastCompletedAt: fifteenDaysAgo),
        ]
        let progressLong: [String: LetterProgress] = [
            "A": LetterProgress(completionCount: 5, bestAccuracy: 0.9,
                                 lastCompletedAt: sixtyDaysAgo),
        ]
        let pShort = scheduler.prioritized(available: ["A"], progress: progressShort, now: now).first!.priority
        let pLong  = scheduler.prioritized(available: ["A"], progress: progressLong,  now: now).first!.priority
        // 60-day urgency must be greater than 15-day urgency, but strictly less
        // than 2× the 15-day value (what linear would produce).
        #expect(pLong > pShort,
                "Longer absence must not be less urgent: 60d=\(pLong) vs 15d=\(pShort)")
        #expect(pLong < 2 * pShort,
                "Recency must saturate (Ebbinghaus), not scale linearly: 60d=\(pLong), 2x15d=\(2 * pShort)")
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
