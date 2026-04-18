// LetterScheduler.swift
// BuchstabenNative
//
// Implements a lightweight spaced repetition algorithm for selecting
// which letter to practice next. Uses data already collected by
// JSONProgressStore (accuracy, completion count, recency).
//
// The algorithm prioritises letters the child:
//   1. Has never practised (highest priority)
//   2. Hasn't practised recently (recency urgency, Ebbinghaus-style decay)
//   3. Struggles with (low accuracy)
//   4. Has practised least (low completion count)
//
// References:
// - Pearson & Gallagher (1983) Gradual Release of Responsibility
// - Ebbinghaus (1885) forgetting curve: R(t) = e^(-t/S)
// - Cepeda et al. (2006) spacing effect meta-analysis

import Foundation

struct LetterScheduler {

    // MARK: - Scored letter

    /// A letter with its computed practice priority.
    struct ScoredLetter: Comparable, Equatable {
        let letter: String
        let priority: Double

        static func < (lhs: ScoredLetter, rhs: ScoredLetter) -> Bool {
            lhs.priority > rhs.priority  // Higher priority first
        }
    }

    // MARK: - Tuning weights

    /// How much recency urgency (Ebbinghaus-style forgetting) affects priority.
    var recencyWeight: Double = 0.40

    /// How much accuracy deficit affects priority.
    var accuracyWeight: Double = 0.35

    /// How much novelty (low completion count) affects priority.
    var noveltyWeight: Double = 0.25

    /// Ebbinghaus memory stability in days. Controls how fast urgency saturates —
    /// shorter stability → faster rise toward 1.0. 7 days approximates the
    /// half-decay observed in word-list memory for typical learners.
    var memoryStabilityDays: Double = 7.0

    /// Days assigned to letters never practised (treated as "very stale").
    var neverPracticedDays: Double = 30.0

    // MARK: - API

    /// Returns all available letters ordered by practice priority (highest first).
    func prioritized(
        available: [String],
        progress: [String: LetterProgress],
        now: Date = Date()
    ) -> [ScoredLetter] {
        available.map { letter in
            score(letter: letter, progress: progress[letter], now: now)
        }.sorted()
    }

    /// Returns the single best letter to practice next.
    func recommendNext(
        available: [String],
        progress: [String: LetterProgress],
        now: Date = Date()
    ) -> String? {
        prioritized(available: available, progress: progress, now: now).first?.letter
    }

    /// Returns the top `n` recommended letters.
    func recommendTopN(
        _ n: Int,
        available: [String],
        progress: [String: LetterProgress],
        now: Date = Date()
    ) -> [ScoredLetter] {
        Array(prioritized(available: available, progress: progress, now: now).prefix(n))
    }

    // MARK: - Scoring

    private func score(
        letter: String,
        progress: LetterProgress?,
        now: Date
    ) -> ScoredLetter {
        let p = progress ?? LetterProgress()

        // Recency: days since last practice.
        let daysSince: Double
        if let last = p.lastCompletedAt {
            daysSince = max(0, now.timeIntervalSince(last) / 86400)
        } else {
            daysSince = neverPracticedDays
        }

        // Accuracy deficit: lower accuracy → higher need for practice.
        let accuracyDeficit = 1.0 - p.bestAccuracy

        // Novelty: fewer completions → more practice needed.
        // Logarithmic decay: 1/(1+count) so the first few completions
        // reduce priority quickly, then it levels off.
        let novelty = 1.0 / (1.0 + Double(p.completionCount))

        // Ebbinghaus recency urgency: 1 - e^(-t/S). Saturates toward 1 as memory
        // decays, matching the forgetting curve's exponential shape. Two letters
        // both long-untouched are treated as similarly urgent, rather than one
        // being twice as urgent as the other (which linear days would imply).
        let recencyUrgency = 1.0 - exp(-daysSince / memoryStabilityDays)

        // Weighted sum. All three factors are in [0, 1], scaled to [0, 100]
        // so the weights act as interpretable percentages.
        let priority = recencyUrgency  * 100 * recencyWeight
                     + accuracyDeficit * 100 * accuracyWeight
                     + novelty         * 100 * noveltyWeight

        return ScoredLetter(letter: letter, priority: priority)
    }
}

// MARK: - Static convenience

extension LetterScheduler {
    /// Default scheduler with standard weights.
    static let standard = LetterScheduler()
}
