// LearningPhaseController.swift
// BuchstabenNative
//
// Manages phase transitions and per-phase scoring for a single letter session.
// Pure value type with no side effects — fully testable without mocks.

import CoreGraphics
import Foundation

/// Coordinates the three-phase learning flow for one letter.
///
/// Usage:
/// ```swift
/// var controller = LearningPhaseController()
/// controller.advance(score: 1.0)   // observe → guided
/// controller.advance(score: 0.85)  // guided → freeWrite
/// controller.advance(score: 0.72)  // freeWrite → complete
/// assert(controller.isLetterSessionComplete)
/// assert(controller.starsEarned == 3)
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

    /// Number of phases that have been scored (0–3).
    var starsEarned: Int { phaseScores.count }

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
        case .guided:    return true
        case .freeWrite: return true
        }
    }

    /// Whether checkpoints should be visually rendered on the canvas.
    var showCheckpoints: Bool {
        switch currentPhase {
        case .observe:   return true   // Show numbered dots
        case .guided:    return true   // Show checkpoint halos
        case .freeWrite: return false  // No visual aid
        }
    }

    /// Whether the checkpoint-matching stroke tracker gates progress.
    var useCheckpointGating: Bool {
        switch currentPhase {
        case .observe:   return false
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
