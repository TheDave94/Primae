//  ParentDashboardStoreTests.swift
//  BuchstabenNativeTests

import Testing
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

@Suite @MainActor struct LetterAccuracyStatTests {
    @Test func averageAccuracy_empty() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: []).averageAccuracy == 0)
    }
    @Test func averageAccuracy_singleSample() {
        #expect(abs(LetterAccuracyStat(letter: "A", accuracySamples: [0.8]).averageAccuracy - 0.8) < 1e-9)
    }
    @Test func averageAccuracy_multipleSamples() {
        #expect(abs(LetterAccuracyStat(letter: "A", accuracySamples: [0.6, 0.8, 1.0]).averageAccuracy - 0.8) < 1e-9)
    }
    @Test func trend_empty_isZero() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: []).trend == 0)
    }
    @Test func trend_singleSample_isZero() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: [0.5]).trend == 0)
    }
    @Test func trend_improvingSequence_positive() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: [0.3, 0.5, 0.7, 0.9]).trend > 0)
    }
    @Test func trend_decliningSequence_negative() {
        #expect(LetterAccuracyStat(letter: "A", accuracySamples: [0.9, 0.7, 0.5, 0.3]).trend < 0)
    }
    @Test func trend_usesLast10Samples() {
        let stat = LetterAccuracyStat(letter: "A", accuracySamples: Array(repeating: 0.0, count: 5) + Array(repeating: 1.0, count: 10))
        #expect(abs(stat.trend) < 1e-9)
    }
}

@Suite struct DashboardSnapshotTests {
    @Test func topLetters_empty() {
        #expect(DashboardSnapshot().topLetters.isEmpty)
    }
    @Test func topLetters_limitsToFive() {
        var snap = DashboardSnapshot()
        for (i, letter) in "ABCDEFGH".map(String.init).enumerated() {
            snap.letterStats[letter] = LetterAccuracyStat(letter: letter, accuracySamples: [Double(i) / 10.0])
        }
        #expect(snap.topLetters.count == 5)
    }
    @Test func topLetters_sortedByAccuracyDescending() {
        var snap = DashboardSnapshot()
        snap.letterStats["A"] = LetterAccuracyStat(letter: "A", accuracySamples: [0.9])
        snap.letterStats["B"] = LetterAccuracyStat(letter: "B", accuracySamples: [0.5])
        snap.letterStats["C"] = LetterAccuracyStat(letter: "C", accuracySamples: [0.7])
        #expect(snap.topLetters.first?.letter == "A")
    }
    @Test func lettersBelow_filtersCorrectly() {
        var snap = DashboardSnapshot()
        snap.letterStats["A"] = LetterAccuracyStat(letter: "A", accuracySamples: [0.9])
        snap.letterStats["B"] = LetterAccuracyStat(letter: "B", accuracySamples: [0.4])
        snap.letterStats["C"] = LetterAccuracyStat(letter: "C", accuracySamples: [0.55])
        #expect(snap.lettersBelow(accuracy: 0.6).map(\.letter) == ["B", "C"])
    }
    @Test func totalPracticeTime_sumsRecentDays() {
        var snap = DashboardSnapshot()
        snap.sessionDurations = [
            SessionDurationRecord(dateString: "2025-03-04", durationSeconds: 300),
            SessionDurationRecord(dateString: "2025-03-08", durationSeconds: 600),
            SessionDurationRecord(dateString: "2025-03-10", durationSeconds: 900),
            SessionDurationRecord(dateString: "2025-02-01", durationSeconds: 9999),
        ]
        let total = snap.totalPracticeTime(recentDays: 7, referenceDate: date(2025, 3, 10), calendar: utcCal())
        #expect(abs(total - 1800) < 1e-6)
    }
}

@Suite struct JSONParentDashboardStoreTests {
    @Test func initialState_empty() {
        let store = makeStore()
        #expect(store.snapshot.letterStats.isEmpty)
        #expect(store.snapshot.sessionDurations.isEmpty)
    }
    @Test func recordSession_updatesLetterStats() {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 0.8, durationSeconds: 60, date: date(2025, 1, 1), condition: .threePhase)
        #expect(store.snapshot.letterStats["A"]?.accuracySamples == [0.8])
    }
    @Test func recordSession_accumulates() {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 0.6, durationSeconds: 30, date: date(2025, 1, 1), condition: .threePhase)
        store.recordSession(letter: "A", accuracy: 0.9, durationSeconds: 40, date: date(2025, 1, 2), condition: .threePhase)
        #expect(store.snapshot.letterStats["A"]?.accuracySamples.count == 2)
    }
    @Test func recordSession_normalizesLetterToUppercase() {
        let store = makeStore()
        store.recordSession(letter: "a", accuracy: 0.7, durationSeconds: 20, date: date(2025, 1, 1), condition: .threePhase)
        #expect(store.snapshot.letterStats["A"] != nil)
        #expect(store.snapshot.letterStats["a"] == nil)
    }
    @Test func recordSession_zeroDuration_notRecorded() {
        let store = makeStore()
        store.recordSession(letter: "B", accuracy: 0.5, durationSeconds: 0, date: date(2025, 1, 1), condition: .threePhase)
        #expect(store.snapshot.sessionDurations.isEmpty)
    }
    @Test func reset_clearsAll() {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 0.9, durationSeconds: 120, date: date(2025, 1, 1), condition: .threePhase)
        store.reset()
        #expect(store.snapshot.letterStats.isEmpty)
        #expect(store.snapshot.sessionDurations.isEmpty)
    }
    @Test func persistence_roundtrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DashPersist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let store = JSONParentDashboardStore(fileURL: url, calendar: utcCal())
            store.recordSession(letter: "Z", accuracy: 0.75, durationSeconds: 90, date: date(2025, 6, 1), condition: .threePhase)
        }
        let store2 = JSONParentDashboardStore(fileURL: url, calendar: utcCal())
        #expect(store2.snapshot.letterStats["Z"]?.accuracySamples == [0.75])
        #expect(store2.snapshot.sessionDurations.count == 1)
    }
    @Test func multipleLetters_independent() {
        let store = makeStore()
        store.recordSession(letter: "A", accuracy: 1.0, durationSeconds: 10, date: date(2025, 1, 1), condition: .threePhase)
        store.recordSession(letter: "B", accuracy: 0.5, durationSeconds: 10, date: date(2025, 1, 1), condition: .threePhase)
        #expect(abs((store.snapshot.letterStats["A"]?.averageAccuracy ?? 0) - 1.0) < 1e-9)
        #expect(abs((store.snapshot.letterStats["B"]?.averageAccuracy ?? 0) - 0.5) < 1e-9)
    }
}
