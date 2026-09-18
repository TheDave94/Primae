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

    // MARK: - Phase advancement (three-phase)

    // The session is observe → guided → freeWrite as of 2026-09-18. The
    // `direct` phase ("Richtung lernen" — tapping the numbered
    // stroke-start dots) is out of it. The ENUM CASE stays: it is
    // `Codable` and reachable from stored rows.

    @Test("Advance from observe to guided")
    func advanceFromObserveToGuided() {
        var sut = LearningPhaseController()
        let advanced = sut.advance(score: 1.0)
        #expect(advanced)
        #expect(sut.currentPhase == .guided)
        #expect(sut.starsEarned == 1)
        #expect(!sut.isLetterSessionComplete)
    }

    /// Replaces `advanceFromDirectToGuided`. That test named a transition
    /// which no longer exists, so keeping it would have meant asserting a
    /// destination the controller cannot reach. Deleting it outright would
    /// have dropped the coverage with it — what the old test actually
    /// guarded is "which phase follows observe, and does the session get
    /// there by advancing". That property is still real, so it is guarded
    /// here, against the successor that replaced `direct`: the walk is
    /// exactly observe → guided → freeWrite and `direct` is never entered.
    @Test("A three-phase session walks observe → guided → freeWrite, never direct")
    func sessionNeverEntersTheDirectPhase() {
        var sut = LearningPhaseController()
        var visited: [LearningPhase] = [sut.currentPhase]
        while sut.advance(score: 1.0) {
            visited.append(sut.currentPhase)
        }
        #expect(visited.map(\.rawName) == ["observe", "guided", "freeWrite"],
                "the session walked \(visited.map(\.rawName)) — observe → guided → freeWrite is the three-phase sequence")
        #expect(!visited.contains(.direct),
                "the session entered .direct — the tapping-the-points phase is not part of a session")
    }

    @Test("Advance from guided to freeWrite")
    func advanceFromGuidedToFreeWrite() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)   // observe
        let advanced = sut.advance(score: 0.85)   // guided
        #expect(advanced)
        #expect(sut.currentPhase == .freeWrite)
        #expect(sut.starsEarned == 2)
    }

    @Test("Advance from freeWrite completes session")
    func advanceFromFreeWriteCompletes() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)    // observe
        sut.advance(score: 0.85)   // guided
        let advanced = sut.advance(score: 0.72)   // freeWrite
        #expect(!advanced)
        #expect(sut.isLetterSessionComplete)
        #expect(sut.starsEarned == 3,
                "three phases run, so three is the ceiling a session can earn")
    }

    @Test("Full session overall score averages all phases")
    func fullSessionOverallScore() {
        var sut = LearningPhaseController()
        sut.advance(score: 1.0)   // observe
        sut.advance(score: 0.8)   // guided
        sut.advance(score: 0.6)   // freeWrite
        #expect(sut.phaseScores.count == 3,
                "a three-phase session banks three scores, got \(sut.phaseScores.count)")
        #expect(abs(sut.overallScore - 0.8) < 0.001)
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

    // `.direct` is deliberately absent from both parameter lists. The walk
    // below advances until it reaches the named phase, and a session can no
    // longer reach `.direct` — so a `.direct` row would run the loop to
    // `isLetterSessionComplete`, stop on `.freeWrite`, and assert
    // `.freeWrite`'s property while naming `.direct`. It passed for the
    // wrong reason. The reachability precondition below is what makes the
    // remaining rows mean what they say.

    @Test("Touch enabled per phase",
          arguments: [
            (LearningPhase.observe, false),
            (LearningPhase.guided, true),
            (LearningPhase.freeWrite, true),
          ])
    func touchEnabled(phase: LearningPhase, expected: Bool) {
        var sut = LearningPhaseController()
        while sut.currentPhase != phase && !sut.isLetterSessionComplete {
            sut.advance(score: 1.0)
        }
        #expect(sut.currentPhase == phase,
                "the walk never reached \(phase.rawName) — this row asserts nothing")
        #expect(sut.isTouchEnabled == expected)
    }

    @Test("Checkpoint gating per phase",
          arguments: [
            (LearningPhase.observe, false),
            (LearningPhase.guided, true),
            (LearningPhase.freeWrite, false),
          ])
    func checkpointGating(phase: LearningPhase, expected: Bool) {
        var sut = LearningPhaseController()
        while sut.currentPhase != phase && !sut.isLetterSessionComplete {
            sut.advance(score: 1.0)
        }
        #expect(sut.currentPhase == phase,
                "the walk never reached \(phase.rawName) — this row asserts nothing")
        #expect(sut.useCheckpointGating == expected)
    }

    // MARK: - Active phases

    /// Spelled out, NOT read from `allCases` or from
    /// `allCases.filter { $0 != .direct }` — an expectation written as the
    /// implementation's own expression can never fail, which is the same
    /// defect class as a test that cannot pass.
    @Test("Three-phase runs observe, guided and freeWrite — and not direct")
    func threePhasePhasesActive() {
        let sut = LearningPhaseController(condition: .threePhase)
        #expect(sut.activePhases == [.observe, .guided, .freeWrite],
                "three-phase active phases are \(sut.activePhases.map(\.rawName))")
        #expect(!sut.activePhases.contains(.direct),
                ".direct is not part of a session as of 2026-09-18")
        #expect(sut.maxStars == 3,
                "the celebration overlay renders maxStars — a 4 here would show a star no child can earn")
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
