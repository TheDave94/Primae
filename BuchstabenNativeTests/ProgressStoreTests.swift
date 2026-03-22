//  ProgressStoreTests.swift
//  BuchstabenNativeTests

import Testing
import Foundation
@testable import BuchstabenNative

@Suite @MainActor struct ProgressStoreTests {

    let tempURL: URL
    let store: JSONProgressStore

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempURL = dir.appendingPathComponent("progress.json")
        store = JSONProgressStore(fileURL: tempURL)
    }

    @Test func initialState_isEmpty() {
        #expect(store.totalCompletions == 0)
        #expect(store.currentStreakDays == 0)
        #expect(store.allProgress.isEmpty)
    }
    @Test func initialProgress_forUnknownLetter_returnsDefault() {
        let p = store.progress(for: "Z")
        #expect(p.completionCount == 0)
        #expect(p.bestAccuracy == 0.0)
        #expect(p.lastCompletedAt == nil)
    }
    @Test func recordCompletion_incrementsCount() {
        store.recordCompletion(for: "A", accuracy: 0.9)
        #expect(store.progress(for: "A").completionCount == 1)
    }
    @Test func recordCompletion_multipleTimes_incrementsCount() {
        store.recordCompletion(for: "B", accuracy: 0.5)
        store.recordCompletion(for: "B", accuracy: 0.7)
        store.recordCompletion(for: "B", accuracy: 0.6)
        #expect(store.progress(for: "B").completionCount == 3)
    }
    @Test func recordCompletion_tracksBestAccuracy() {
        store.recordCompletion(for: "C", accuracy: 0.5)
        store.recordCompletion(for: "C", accuracy: 0.9)
        store.recordCompletion(for: "C", accuracy: 0.7)
        #expect(abs(store.progress(for: "C").bestAccuracy - 0.9) < 1e-9)
    }
    @Test func recordCompletion_setsLastCompletedAt() {
        let before = Date()
        store.recordCompletion(for: "D", accuracy: 1.0)
        let after = Date()
        let ts = store.progress(for: "D").lastCompletedAt
        #expect(ts != nil)
        #expect(ts! >= before)
        #expect(ts! <= after)
    }
    @Test func recordCompletion_isCaseInsensitive() {
        store.recordCompletion(for: "a", accuracy: 0.8)
        store.recordCompletion(for: "A", accuracy: 0.6)
        #expect(store.progress(for: "A").completionCount == 2)
        #expect(store.progress(for: "a").completionCount == 2)
    }
    @Test func recordCompletion_clampsAccuracyToUnit() {
        store.recordCompletion(for: "E", accuracy: 2.5)
        #expect(store.progress(for: "E").bestAccuracy <= 1.0)
        store.recordCompletion(for: "F", accuracy: -0.5)
        #expect(store.progress(for: "F").bestAccuracy >= 0.0)
    }
    @Test func totalCompletions_sumsAcrossAllLetters() {
        store.recordCompletion(for: "A", accuracy: 1.0)
        store.recordCompletion(for: "A", accuracy: 1.0)
        store.recordCompletion(for: "B", accuracy: 0.8)
        #expect(store.totalCompletions == 3)
    }
    @Test func persistence_survivesReinit() {
        store.recordCompletion(for: "G", accuracy: 0.75)
        store.recordCompletion(for: "G", accuracy: 0.95)
        let reloaded = JSONProgressStore(fileURL: tempURL)
        #expect(reloaded.progress(for: "G").completionCount == 2)
        #expect(abs(reloaded.progress(for: "G").bestAccuracy - 0.95) < 1e-9)
    }
    @Test func persistence_totalCompletionsSurvivesReinit() {
        store.recordCompletion(for: "H", accuracy: 1.0)
        store.recordCompletion(for: "I", accuracy: 0.9)
        #expect(JSONProgressStore(fileURL: tempURL).totalCompletions == 2)
    }
    @Test func resetAll_clearsEverything() {
        store.recordCompletion(for: "J", accuracy: 1.0)
        store.recordCompletion(for: "K", accuracy: 0.8)
        store.resetAll()
        #expect(store.totalCompletions == 0)
        #expect(store.allProgress.isEmpty)
        #expect(store.currentStreakDays == 0)
    }
    @Test func resetAll_persistsOnDisk() {
        store.recordCompletion(for: "L", accuracy: 1.0)
        store.resetAll()
        #expect(JSONProgressStore(fileURL: tempURL).totalCompletions == 0)
    }
    @Test func streak_singleCompletionToday_isOne() {
        store.recordCompletion(for: "M", accuracy: 1.0)
        #expect(store.currentStreakDays >= 1)
    }
    @Test func streak_noCompletions_isZero() {
        #expect(store.currentStreakDays == 0)
    }
    @Test func streak_multipleCompletionsSameDay_countsOnce() {
        for _ in 0..<5 { store.recordCompletion(for: "N", accuracy: 1.0) }
        #expect(store.currentStreakDays == 1)
    }
    @Test func allProgress_containsAllRecordedLetters() {
        store.recordCompletion(for: "O", accuracy: 0.9)
        store.recordCompletion(for: "P", accuracy: 0.5)
        let all = store.allProgress
        #expect(all.keys.contains("O"))
        #expect(all.keys.contains("P"))
        #expect(!all.keys.contains("Q"))
    }
}
