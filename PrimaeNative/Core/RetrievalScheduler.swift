// RetrievalScheduler.swift
// PrimaeNative
//
// P1 (ROADMAP_V5): retrieval-practice scheduling. Roediger & Karpicke
// (2006) showed that retrieval tests produce better long-term retention
// than additional study: the act of *generating* an answer beats the
// act of *re-encoding* it. The app already implements spaced practice
// via LetterScheduler (Ebbinghaus + accuracy + novelty); this scheduler
// adds a parallel signal — every Nth letter selection, present a brief
// recognition test before the tracing phases.
//
// Configurable knobs:
// - `interval`: every Nth selection triggers a retrieval prompt
//   (default 3). Lower N = more retrieval; thesis can sweep this.
// - `minimumPriorCompletions`: skip retrieval until the child has
//   completed the letter at least this many times — testing on a
//   never-seen letter is just guessing (default 1).
//
// Persistence: per-letter `retrievalAttempts: [Bool]?` (recent 10) so
// the dashboard / export can compute retrieval accuracy alongside form
// accuracy. The `recordOutcome` API mutates a `ProgressStoring` so the
// scheduler stays decoupled from the disk layer.

import Foundation

@MainActor
final class RetrievalScheduler {
    /// Selection-counter modulus. `1` = retrieve every letter; `0` =
    /// disabled (always returns false).
    var interval: Int = 3
    /// Letters with fewer than this many prior completions skip
    /// retrieval. Testing on a never-seen letter is just guessing.
    var minimumPriorCompletions: Int = 1

    /// Total retrieval-eligible letter selections. Persisted in
    /// UserDefaults so the cadence survives an app relaunch.
    private(set) var selectionsSinceRetrieval: Int

    /// UserDefaults key for the rolling counter.
    private static let counterKey = "de.flamingistan.primae.retrievalCounter"

    init(initialCounter: Int? = nil) {
        if let v = initialCounter {
            self.selectionsSinceRetrieval = v
        } else {
            let stored = UserDefaults.standard.integer(forKey: Self.counterKey)
            self.selectionsSinceRetrieval = max(0, stored)
        }
    }

    /// Returns `true` when the next letter selection should fire a
    /// retrieval prompt. Bumps the counter regardless so subsequent
    /// non-firing selections still progress toward the next test.
    /// Returns `false` for letters with insufficient prior completions
    /// — we don't test on what the child hasn't seen.
    func shouldPrompt(for letter: String, progress: LetterProgress) -> Bool {
        guard interval > 0 else { return false }
        guard progress.completionCount >= minimumPriorCompletions else { return false }
        selectionsSinceRetrieval += 1
        let fire = selectionsSinceRetrieval >= interval
        if fire {
            selectionsSinceRetrieval = 0
        }
        UserDefaults.standard.set(selectionsSinceRetrieval, forKey: Self.counterKey)
        return fire
    }

    /// Reset the cadence counter without recording an outcome. Used by
    /// the test target and by the parent's "Erinnerungstest neu starten"
    /// action (not yet exposed in UI).
    func reset() {
        selectionsSinceRetrieval = 0
        UserDefaults.standard.set(0, forKey: Self.counterKey)
    }
}
