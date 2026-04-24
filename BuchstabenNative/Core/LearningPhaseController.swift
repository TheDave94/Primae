// LearningPhaseController.swift
// BuchstabenNative
//
// Manages phase transitions and per-phase scoring for a single letter session.
// Pure value type with no side effects — fully testable without mocks.

import CoreGraphics
import Foundation

/// Coordinates the four-phase learning flow for one letter.
///
/// Usage:
/// ```swift
/// var controller = LearningPhaseController()
/// controller.advance(score: 1.0)   // observe → direct
/// controller.advance(score: 1.0)   // direct → guided
/// controller.advance(score: 0.85)  // guided → freeWrite
/// controller.advance(score: 0.72)  // freeWrite → complete
/// assert(controller.isLetterSessionComplete)
/// assert(controller.starsEarned == 4)
/// ```
struct LearningPhaseController: Equatable {

    // MARK: - State

    /// The currently active learning phase.
    private(set) var currentPhase: LearningPhase = .observe

    /// Scores recorded for each completed phase (0–1).
    private(set) var phaseScores: [LearningPhase: CGFloat] = [:]

    /// True once all three phases have been completed.
    private(set) var isLetterSessionComplete = false

    /// Thesis evaluation mode. Determines which phases are active.
    let condition: ThesisCondition

    // MARK: - Init

    init(condition: ThesisCondition = .threePhase) {
        self.condition = condition
        switch condition {
        case .threePhase:
            currentPhase = .observe
        case .guidedOnly, .control:
            // Skip observe phase — start directly at guided.
            currentPhase = .guided
        }
    }

    // MARK: - Computed properties

    /// Stars earned in this letter session, 0…N where N is the number of
    /// active phases under the current thesis condition. A phase earns
    /// its star only when the recorded score meets its quality threshold
    /// (see `starThreshold(for:)`) — so a child who ran through guided +
    /// freeWrite without actually tracing anything gets 2 observe/direct
    /// stars at most, not 4.
    var starsEarned: Int {
        phaseScores.reduce(0) { acc, entry in
            acc + (entry.value >= Self.starThreshold(for: entry.key) ? 1 : 0)
        }
    }

    /// Lowest phase score required to earn that phase's star.
    /// - observe / direct: 0 — completing them always earns the star
    ///   because they're pass/fail (score stored as 1.0 on completion).
    /// - guided: 0.5 — at least half the checkpoints reached in order.
    /// - freeWrite: 0.4 — form-accuracy roughly matches the reference
    ///   (Fréchet distance under 3× checkpoint radius).
    /// Exposed as a static so UI code can mirror the threshold when
    /// explaining to parents why a letter got 2 stars instead of 4.
    static func starThreshold(for phase: LearningPhase) -> CGFloat {
        switch phase {
        case .observe, .direct: return 0.0
        case .guided:           return 0.5
        case .freeWrite:        return 0.4
        }
    }

    /// The phases that are active under the current thesis condition.
    var activePhases: [LearningPhase] {
        switch condition {
        case .threePhase:
            return LearningPhase.allCases
        case .guidedOnly, .control:
            return [.guided]
        }
    }

    /// Overall session score — average across all completed phases.
    var overallScore: CGFloat {
        guard !phaseScores.isEmpty else { return 0 }
        return phaseScores.values.reduce(0, +) / CGFloat(phaseScores.count)
    }

    /// Whether the current phase requires touch input from the child.
    var isTouchEnabled: Bool {
        switch currentPhase {
        case .observe:   return false
        case .direct:    return true   // Tap the numbered start dots
        case .guided:    return true
        case .freeWrite: return true
        }
    }

    /// Whether checkpoints should be visually rendered on the canvas.
    /// Direct phase manages its own dot overlay (DirectPhaseDotsOverlay).
    var showCheckpoints: Bool {
        switch currentPhase {
        case .observe:   return true   // Show numbered dots
        case .direct:    return false  // Overlay handles rendering
        case .guided:    return true   // Show checkpoint halos
        case .freeWrite: return false  // No visual aid
        }
    }

    /// Whether the checkpoint-matching stroke tracker gates progress.
    var useCheckpointGating: Bool {
        switch currentPhase {
        case .observe:   return false
        case .direct:    return false  // Tap-based — not stroke-gated
        case .guided:    return true
        case .freeWrite: return false  // Freehand — scored post-hoc
        }
    }

    // MARK: - Mutations

    /// Complete the current phase and advance to the next one.
    ///
    /// - Parameter score: Accuracy for the completed phase (0–1).
    /// - Returns: `true` if advanced to a new phase, `false` if the
    ///   letter session is now complete.
    @discardableResult
    mutating func advance(score: CGFloat) -> Bool {
        let clamped = max(0, min(1, score))
        phaseScores[currentPhase] = clamped

        // Determine next phase under current condition
        let nextPhase: LearningPhase?
        switch condition {
        case .threePhase:
            nextPhase = currentPhase.next
        case .guidedOnly, .control:
            // Only one phase — always complete after guided.
            nextPhase = nil
        }

        guard let next = nextPhase else {
            isLetterSessionComplete = true
            return false
        }
        currentPhase = next
        return true
    }

    /// Reset for a new letter. Clears all phase scores.
    mutating func reset() {
        switch condition {
        case .threePhase:
            currentPhase = .observe
        case .guidedOnly, .control:
            currentPhase = .guided
        }
        phaseScores = [:]
        isLetterSessionComplete = false
    }

    /// Force-set phase (for resuming from persisted state).
    mutating func resume(at phase: LearningPhase) {
        guard activePhases.contains(phase) else { return }
        currentPhase = phase
    }
}
