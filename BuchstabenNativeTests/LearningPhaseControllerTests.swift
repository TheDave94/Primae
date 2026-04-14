// LearningPhaseControllerTests.swift
// BuchstabenNativeTests

import XCTest
@testable import BuchstabenNative

final class LearningPhaseControllerTests: XCTestCase {

    // MARK: - Initial state

    func testInitialPhaseIsObserve() {
        let sut = LearningPhaseController()
        XCTAssertEqual(sut.currentPhase, .observe)
        XCTAssertFalse(sut.isLetterSessionComplete)
        XCTAssertEqual(sut.starsEarned, 0)
    }

    func testGuidedOnlyConditionStartsAtGuided() {
        let sut = LearningPhaseController(condition: .guidedOnly)
        XCTAssertEqual(sut.currentPhase, .guided)
    }

    func testControlConditionStartsAtGuided() {
        let sut = LearningPhaseController(condition: .control)
        XCTAssertEqual(sut.currentPhase, .guided)
    }

    // MARK: - Phase advancement (three-phase)

    func testAdvanceFromObserveToGuided() {
        var sut = LearningPhaseController()
        let advanced = sut.advance(score: 1.0)
        XCTAssertTrue(advanced)
        XCTAssertEqual(sut.currentPhase, .guided)
        XCTAssertEqual(sut.starsEarned, 1)
        XCTAssertFalse(sut.isLetterSessionComplete)
    }

    func testAdvanceFromGuidedToFreeWrite() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)
        let advanced = sut.advance(score: 0.85)
        XCTAssertTrue(advanced)
        XCTAssertEqual(sut.currentPhase, .freeWrite)
        XCTAssertEqual(sut.starsEarned, 2)
    }

    func testAdvanceFromFreeWriteCompletesSession() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)
        sut.advance(score: 0.85)
        let advanced = sut.advance(score: 0.72)
        XCTAssertFalse(advanced)
        XCTAssertTrue(sut.isLetterSessionComplete)
        XCTAssertEqual(sut.starsEarned, 3)
    }

    func testFullSessionOverallScore() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)
        sut.advance(score: 0.8)
        sut.advance(score: 0.6)
        // Average of 1.0, 0.8, 0.6 = 0.8
        XCTAssertEqual(sut.overallScore, 0.8, accuracy: 0.001)
    }

    // MARK: - Phase advancement (guided-only)

    func testGuidedOnlyCompletesAfterOnePhase() {
        var sut = LearningPhaseController(condition: .guidedOnly)
        let advanced = sut.advance(score: 0.9)
        XCTAssertFalse(advanced)
        XCTAssertTrue(sut.isLetterSessionComplete)
        XCTAssertEqual(sut.starsEarned, 1)
    }

    // MARK: - Reset

    func testResetClearsAllState() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)
        sut.advance(score: 0.8)
        sut.reset()
        XCTAssertEqual(sut.currentPhase, .observe)
        XCTAssertTrue(sut.phaseScores.isEmpty)
        XCTAssertFalse(sut.isLetterSessionComplete)
        XCTAssertEqual(sut.starsEarned, 0)
    }

    func testGuidedOnlyResetGoesToGuided() {
        var sut = LearningPhaseController(condition: .guidedOnly)
        sut.advance(score: 0.9)
        sut.reset()
        XCTAssertEqual(sut.currentPhase, .guided)
        XCTAssertFalse(sut.isLetterSessionComplete)
    }

    // MARK: - Score clamping

    func testScoreClampedToUnitRange() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.5)
        XCTAssertEqual(sut.phaseScores[.observe], 1.0)

        sut.advance(score: -0.3)
        XCTAssertEqual(sut.phaseScores[.guided], 0.0)
    }

    // MARK: - Phase properties

    func testTouchEnabledPerPhase() {
        var sut = LearningPhaseController()
        XCTAssertFalse(sut.isTouchEnabled)  // observe
        sut.advance(score: 1.0)
        XCTAssertTrue(sut.isTouchEnabled)   // guided
        sut.advance(score: 0.8)
        XCTAssertTrue(sut.isTouchEnabled)   // freeWrite
    }

    func testShowCheckpointsPerPhase() {
        var sut = LearningPhaseController()
        XCTAssertTrue(sut.showCheckpoints)   // observe: numbered dots
        sut.advance(score: 1.0)
        XCTAssertTrue(sut.showCheckpoints)   // guided: checkpoint halos
        sut.advance(score: 0.8)
        XCTAssertFalse(sut.showCheckpoints)  // freeWrite: no aids
    }

    func testCheckpointGatingPerPhase() {
        var sut = LearningPhaseController()
        XCTAssertFalse(sut.useCheckpointGating) // observe
        sut.advance(score: 1.0)
        XCTAssertTrue(sut.useCheckpointGating)  // guided
        sut.advance(score: 0.8)
        XCTAssertFalse(sut.useCheckpointGating) // freeWrite
    }

    // MARK: - Active phases

    func testActivePhases() {
        let threePhaseSut = LearningPhaseController(condition: .threePhase)
        XCTAssertEqual(threePhaseSut.activePhases, LearningPhase.allCases)

        let guidedSut = LearningPhaseController(condition: .guidedOnly)
        XCTAssertEqual(guidedSut.activePhases, [.guided])
    }

    // MARK: - Resume

    func testResumeAtPhase() {
        var sut = LearningPhaseController()
        sut.resume(at: .freeWrite)
        XCTAssertEqual(sut.currentPhase, .freeWrite)
    }

    func testResumeIgnoresInactivePhase() {
        var sut = LearningPhaseController(condition: .guidedOnly)
        sut.resume(at: .freeWrite)  // freeWrite not in activePhases
        XCTAssertEqual(sut.currentPhase, .guided) // unchanged
    }

    // MARK: - Equatable

    func testEquatable() {
        let a = LearningPhaseController()
        let b = LearningPhaseController()
        XCTAssertEqual(a, b)
    }

    func testOverallScoreWithNoPhases() {
        let sut = LearningPhaseController()
        XCTAssertEqual(sut.overallScore, 0)
    }
}
