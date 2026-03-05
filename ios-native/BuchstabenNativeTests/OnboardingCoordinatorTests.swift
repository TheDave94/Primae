//  OnboardingCoordinatorTests.swift
//  BuchstabenNativeTests

import XCTest
@testable import BuchstabenNative

private func makeCoordinator(steps: [OnboardingStep] = OnboardingStep.allCases) -> OnboardingCoordinator {
    OnboardingCoordinator(steps: steps)
}

private func makeStore() -> JSONOnboardingStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("Onboarding-\(UUID().uuidString).json")
    return JSONOnboardingStore(fileURL: url)
}

// MARK: - Coordinator state machine tests

final class OnboardingCoordinatorTests: XCTestCase {

    func testInitialStep_isWelcome() {
        let c = makeCoordinator()
        XCTAssertEqual(c.currentStep, .welcome)
    }

    func testInitialCompletedSteps_empty() {
        let c = makeCoordinator()
        XCTAssertTrue(c.completedSteps.isEmpty)
    }

    func testIsComplete_falseInitially() {
        let c = makeCoordinator()
        XCTAssertFalse(c.isComplete)
    }

    func testAdvance_movesToNextStep() {
        var c = makeCoordinator()
        c.advance()
        XCTAssertEqual(c.currentStep, .traceDemo)
    }

    func testAdvance_marksCurrentAsCompleted() {
        var c = makeCoordinator()
        c.advance()
        XCTAssertTrue(c.completedSteps.contains(.welcome))
    }

    func testAdvance_returnsTrue_whenNotAtEnd() {
        var c = makeCoordinator()
        XCTAssertTrue(c.advance())
    }

    func testAdvance_returnsFalse_atLastStep() {
        var c = makeCoordinator(steps: [.welcome, .complete])
        c.advance()
        XCTAssertFalse(c.advance())
    }

    func testFullAdvance_setsIsComplete() {
        var c = makeCoordinator()
        while !c.isComplete { c.advance() }
        XCTAssertTrue(c.isComplete)
        XCTAssertEqual(c.currentStep, .complete)
    }

    func testBack_returnsToPreviousStep() {
        var c = makeCoordinator()
        c.advance()
        c.back()
        XCTAssertEqual(c.currentStep, .welcome)
    }

    func testBack_returnsFalse_atFirstStep() {
        var c = makeCoordinator()
        XCTAssertFalse(c.back())
    }

    func testCanGoBack_falseAtStart() {
        let c = makeCoordinator()
        XCTAssertFalse(c.canGoBack)
    }

    func testCanGoBack_trueAfterAdvance() {
        var c = makeCoordinator()
        c.advance()
        XCTAssertTrue(c.canGoBack)
    }

    func testSkip_jumpsToComplete() {
        var c = makeCoordinator()
        c.skip()
        XCTAssertEqual(c.currentStep, .complete)
        XCTAssertTrue(c.isComplete)
    }

    func testSkip_marksAllNonCompleteStepsAsCompleted() {
        var c = makeCoordinator()
        c.skip()
        let expectedCompleted = Set(OnboardingStep.allCases.filter { $0 != .complete })
        XCTAssertEqual(c.completedSteps, expectedCompleted)
    }

    func testResume_jumpsToSpecifiedStep() {
        var c = makeCoordinator()
        c.resume(at: .firstTrace)
        XCTAssertEqual(c.currentStep, .firstTrace)
    }

    func testResume_invalidStep_ignored() {
        var c = makeCoordinator(steps: [.welcome, .complete])
        c.resume(at: .rewardIntro)  // not in custom steps
        XCTAssertEqual(c.currentStep, .welcome) // unchanged
    }

    func testProgress_zeroAtStart() {
        let c = makeCoordinator()
        XCTAssertEqual(c.progress, 0.0, accuracy: 1e-9)
    }

    func testProgress_oneAtComplete() {
        var c = makeCoordinator()
        while !c.isComplete { c.advance() }
        XCTAssertEqual(c.progress, 1.0, accuracy: 1e-9)
    }

    func testProgress_intermediateStep() {
        var c = makeCoordinator()
        c.advance() // step 1 of 5 (index 1/4 = 0.25)
        XCTAssertEqual(c.progress, 0.25, accuracy: 1e-9)
    }

    func testCustomSteps_subset() {
        var c = makeCoordinator(steps: [.welcome, .complete])
        XCTAssertEqual(c.currentStep, .welcome)
        c.advance()
        XCTAssertEqual(c.currentStep, .complete)
    }
}

// MARK: - OnboardingStore tests

final class JSONOnboardingStoreTests: XCTestCase {

    func testInitial_notCompleted() {
        let store = makeStore()
        XCTAssertFalse(store.hasCompletedOnboarding)
    }

    func testInitial_noSavedStep() {
        let store = makeStore()
        XCTAssertNil(store.savedStep)
    }

    func testMarkComplete_setsFlag() {
        let store = makeStore()
        store.markComplete()
        XCTAssertTrue(store.hasCompletedOnboarding)
    }

    func testMarkComplete_clearsSavedStep() {
        let store = makeStore()
        store.saveProgress(step: .traceDemo)
        store.markComplete()
        XCTAssertNil(store.savedStep)
    }

    func testSaveProgress_storesSavedStep() {
        let store = makeStore()
        store.saveProgress(step: .firstTrace)
        XCTAssertEqual(store.savedStep, .firstTrace)
    }

    func testReset_clearsAll() {
        let store = makeStore()
        store.markComplete()
        store.reset()
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertNil(store.savedStep)
    }

    func testPersistence_roundtrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingPersist-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        JSONOnboardingStore(fileURL: url).saveProgress(step: .rewardIntro)
        let store2 = JSONOnboardingStore(fileURL: url)
        XCTAssertEqual(store2.savedStep, .rewardIntro)
        XCTAssertFalse(store2.hasCompletedOnboarding)
    }

    func testPersistence_completedRoundtrip() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnboardingComplete-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        JSONOnboardingStore(fileURL: url).markComplete()
        let store2 = JSONOnboardingStore(fileURL: url)
        XCTAssertTrue(store2.hasCompletedOnboarding)
        XCTAssertNil(store2.savedStep)
    }
}
