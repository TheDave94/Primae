import Testing
import CoreGraphics
@testable import PrimaeNative

struct LearningPhaseControllerTests {

    // MARK: - Initial state

    @Test("Initial phase is observe for three-phase condition")
    func initialPhaseIsObserve() {
        let sut = LearningPhaseController()
        #expect(sut.currentPhase == .observe)
        #expect(!sut.isLetterSessionComplete)
        #expect(sut.starsEarned == 0)
    }

    @Test("Guided-only condition starts at guided")
    func guidedOnlyStartsAtGuided() {
        let sut = LearningPhaseController(condition: .guidedOnly)
        #expect(sut.currentPhase == .guided)
    }

    @Test("Control condition starts at guided")
    func controlStartsAtGuided() {
        let sut = LearningPhaseController(condition: .control)
        #expect(sut.currentPhase == .guided)
    }

    // MARK: - Phase advancement (four-phase)

    @Test("Advance from observe to direct")
    func advanceFromObserveToDirect() {
        var sut = LearningPhaseController()
        let advanced = sut.advance(score: 1.0)
        #expect(advanced)
        #expect(sut.currentPhase == .direct)
        #expect(sut.starsEarned == 1)
        #expect(!sut.isLetterSessionComplete)
    }

    @Test("Advance from direct to guided")
    func advanceFromDirectToGuided() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)
        let advanced = sut.advance(score: 1.0)
        #expect(advanced)
        #expect(sut.currentPhase == .guided)
        #expect(sut.starsEarned == 2)
    }

    @Test("Advance from guided to freeWrite")
    func advanceFromGuidedToFreeWrite() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)
        sut.advance(score: 1.0)
        let advanced = sut.advance(score: 0.85)
        #expect(advanced)
        #expect(sut.currentPhase == .freeWrite)
        #expect(sut.starsEarned == 3)
    }

    @Test("Advance from freeWrite completes session")
    func advanceFromFreeWriteCompletes() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)
        sut.advance(score: 1.0)
        sut.advance(score: 0.85)
        let advanced = sut.advance(score: 0.72)
        #expect(!advanced)
        #expect(sut.isLetterSessionComplete)
        #expect(sut.starsEarned == 4)
    }

    @Test("Full session overall score averages all phases")
    func fullSessionOverallScore() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)
        sut.advance(score: 0.8)
        sut.advance(score: 0.6)
        sut.advance(score: 0.4)
        #expect(abs(sut.overallScore - 0.7) < 0.001)
    }

    // MARK: - Guided-only

    @Test("Guided-only completes after one phase")
    func guidedOnlyCompletesAfterOne() {
        var sut = LearningPhaseController(condition: .guidedOnly)
        let advanced = sut.advance(score: 0.9)
        #expect(!advanced)
        #expect(sut.isLetterSessionComplete)
        #expect(sut.starsEarned == 1)
    }

    /// The `.control` arm runs guided-only, just like `.guidedOnly`.
    /// Plumbing differs (fixedOrder() scheduler etc.) but the phase
    /// controller contract is identical: one advance ends the session
    /// with one star earned.
    @Test("Control completes after one phase")
    func controlCompletesAfterOne() {
        var sut = LearningPhaseController(condition: .control)
        let advanced = sut.advance(score: 0.9)
        #expect(!advanced)
        #expect(sut.isLetterSessionComplete)
        #expect(sut.starsEarned == 1)
        #expect(sut.maxStars == 1, "control arm has only one phase, max stars must match")
    }

    // MARK: - Reset

    @Test("Reset clears all state")
    func resetClearsState() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)
        sut.advance(score: 0.8)
        sut.reset()
        #expect(sut.currentPhase == .observe)
        #expect(sut.phaseScores.isEmpty)
        #expect(!sut.isLetterSessionComplete)
        #expect(sut.starsEarned == 0)
    }

    @Test("Guided-only reset returns to guided")
    func guidedOnlyResetGoesToGuided() {
        var sut = LearningPhaseController(condition: .guidedOnly)
        sut.advance(score: 0.9)
        sut.reset()
        #expect(sut.currentPhase == .guided)
        #expect(!sut.isLetterSessionComplete)
    }

    // MARK: - Score clamping

    @Test("Scores are clamped to 0-1 range",
          arguments: [(1.5, 1.0), (-0.3, 0.0), (0.75, 0.75)])
    func scoreClamping(input: Double, expected: Double) {
        var sut = LearningPhaseController()
        sut.advance(score: CGFloat(input))
        let recorded = sut.phaseScores[.observe] ?? -1
        #expect(abs(Double(recorded) - expected) < 0.001)
    }

    // MARK: - Phase properties

    @Test("Touch enabled per phase",
          arguments: [
            (LearningPhase.observe, false),
            (LearningPhase.direct, true),
            (LearningPhase.guided, true),
            (LearningPhase.freeWrite, true),
          ])
    func touchEnabled(phase: LearningPhase, expected: Bool) {
        var sut = LearningPhaseController()
        while sut.currentPhase != phase && !sut.isLetterSessionComplete {
            sut.advance(score: 1.0)
        }
        #expect(sut.isTouchEnabled == expected)
    }

    @Test("Checkpoint gating per phase",
          arguments: [
            (LearningPhase.observe, false),
            (LearningPhase.direct, false),
            (LearningPhase.guided, true),
            (LearningPhase.freeWrite, false),
          ])
    func checkpointGating(phase: LearningPhase, expected: Bool) {
        var sut = LearningPhaseController()
        while sut.currentPhase != phase && !sut.isLetterSessionComplete {
            sut.advance(score: 1.0)
        }
        #expect(sut.useCheckpointGating == expected)
    }

    // MARK: - Active phases

    @Test("Three-phase has all phases active")
    func threePhasePhasesActive() {
        let sut = LearningPhaseController(condition: .threePhase)
        #expect(sut.activePhases == LearningPhase.allCases)
    }

    @Test("Guided-only has single phase active")
    func guidedOnlyPhasesActive() {
        let sut = LearningPhaseController(condition: .guidedOnly)
        #expect(sut.activePhases == [.guided])
    }

    // MARK: - Resume

    @Test("Resume at specific phase")
    func resumeAtPhase() {
        var sut = LearningPhaseController()
        sut.resume(at: .freeWrite)
        #expect(sut.currentPhase == .freeWrite)
    }

    @Test("Resume ignores inactive phase")
    func resumeIgnoresInactive() {
        var sut = LearningPhaseController(condition: .guidedOnly)
        sut.resume(at: .freeWrite)
        #expect(sut.currentPhase == .guided)
    }

    @Test("Overall score with no completed phases is zero")
    func overallScoreEmpty() {
        let sut = LearningPhaseController()
        #expect(sut.overallScore == 0)
    }
}
