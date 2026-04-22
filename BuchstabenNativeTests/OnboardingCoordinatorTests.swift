//  OnboardingCoordinatorTests.swift
//  BuchstabenNativeTests

import Testing
import Foundation
@testable import BuchstabenNative

private func makeCoordinator(steps: [OnboardingStep] = OnboardingStep.allCases) -> OnboardingCoordinator {
    OnboardingCoordinator(steps: steps)
}
private func makeStore() -> JSONOnboardingStore {
    JSONOnboardingStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("Onboarding-\(UUID().uuidString).json"))
}

@Suite @MainActor struct OnboardingCoordinatorTests {
    @Test func initialStep_isWelcome() { #expect(makeCoordinator().currentStep == .welcome) }
    @Test func initialCompletedSteps_empty() { #expect(makeCoordinator().completedSteps.isEmpty) }
    @Test func isComplete_falseInitially() { #expect(!makeCoordinator().isComplete) }
    @Test func advance_movesToNextStep() {
        var c = makeCoordinator(); c.advance()
        #expect(c.currentStep == .traceDemo)
    }
    @Test func advance_marksCurrentAsCompleted() {
        var c = makeCoordinator(); c.advance()
        #expect(c.completedSteps.contains(.welcome))
    }
    @Test func advance_returnsTrue_whenNotAtEnd() {
        var c = makeCoordinator()
        let r = c.advance()
        #expect(r)
    }
    @Test func advance_returnsFalse_atLastStep() {
        var c = makeCoordinator(steps: [.welcome, .complete]); c.advance()
        let r = c.advance()
        #expect(!r)
    }
    @Test func fullAdvance_setsIsComplete() {
        var c = makeCoordinator()
        while !c.isComplete { c.advance() }
        #expect(c.isComplete)
        #expect(c.currentStep == .complete)
    }
    @Test func back_returnsToPreviousStep() {
        var c = makeCoordinator(); c.advance(); c.back()
        #expect(c.currentStep == .welcome)
    }
    @Test func back_returnsFalse_atFirstStep() {
        var c = makeCoordinator()
        let rb = c.back()
        #expect(!rb)
    }
    @Test func canGoBack_falseAtStart() { #expect(!makeCoordinator().canGoBack) }
    @Test func canGoBack_trueAfterAdvance() {
        var c = makeCoordinator(); c.advance()
        #expect(c.canGoBack)
    }
    @Test func skip_jumpsToComplete() {
        var c = makeCoordinator(); c.skip()
        #expect(c.currentStep == .complete)
        #expect(c.isComplete)
    }
    @Test func skip_marksAllNonCompleteStepsAsCompleted() {
        var c = makeCoordinator(); c.skip()
        let expected = Set(OnboardingStep.allCases.filter { $0 != .complete })
        #expect(c.completedSteps == expected)
    }
    @Test func resume_jumpsToSpecifiedStep() {
        var c = makeCoordinator(); c.resume(at: .directDemo)
        #expect(c.currentStep == .directDemo)
    }
    @Test func resume_invalidStep_ignored() {
        var c = makeCoordinator(steps: [.welcome, .complete]); c.resume(at: .rewardIntro)
        #expect(c.currentStep == .welcome)
    }
    @Test func progress_zeroAtStart() { #expect(abs(makeCoordinator().progress) < 1e-9) }
    @Test func progress_oneAtComplete() {
        var c = makeCoordinator()
        while !c.isComplete { c.advance() }
        #expect(abs(c.progress - 1.0) < 1e-9)
    }
    @Test func progress_intermediateStep() {
        // One advance from welcome over N-case flow = 1/(N-1). With the
        // current 7-case flow (welcome, traceDemo, directDemo, guidedDemo,
        // freeWriteDemo, rewardIntro, complete) that's 1/6.
        var c = makeCoordinator(); c.advance()
        let expected = 1.0 / Double(OnboardingStep.allCases.count - 1)
        #expect(abs(c.progress - expected) < 1e-9)
    }
    @Test func customSteps_subset() {
        var c = makeCoordinator(steps: [.welcome, .complete])
        #expect(c.currentStep == .welcome); c.advance()
        #expect(c.currentStep == .complete)
    }
}

@Suite struct JSONOnboardingStoreTests {
    @Test func initial_notCompleted() { #expect(!makeStore().hasCompletedOnboarding) }
    @Test func initial_noSavedStep() { #expect(makeStore().savedStep == nil) }
    @Test func markComplete_setsFlag() {
        let s = makeStore(); s.markComplete()
        #expect(s.hasCompletedOnboarding)
    }
    @Test func markComplete_clearsSavedStep() {
        let s = makeStore(); s.saveProgress(step: .traceDemo); s.markComplete()
        #expect(s.savedStep == nil)
    }
    @Test func saveProgress_storesSavedStep() {
        let s = makeStore(); s.saveProgress(step: .directDemo)
        #expect(s.savedStep == .directDemo)
    }
    @Test func reset_clearsAll() {
        let s = makeStore(); s.markComplete(); s.reset()
        #expect(!s.hasCompletedOnboarding)
        #expect(s.savedStep == nil)
    }
    @Test func persistence_roundtrip() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingPersist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s1 = JSONOnboardingStore(fileURL: url)
        s1.saveProgress(step: .rewardIntro)
        await s1.flush()
        let s2 = JSONOnboardingStore(fileURL: url)
        #expect(s2.savedStep == .rewardIntro)
        #expect(!s2.hasCompletedOnboarding)
    }
    @Test func persistence_completedRoundtrip() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingComplete-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s1 = JSONOnboardingStore(fileURL: url)
        s1.markComplete()
        await s1.flush()
        let s2 = JSONOnboardingStore(fileURL: url)
        #expect(s2.hasCompletedOnboarding)
        #expect(s2.savedStep == nil)
    }
}
