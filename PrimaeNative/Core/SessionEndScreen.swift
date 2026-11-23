// SessionEndScreen.swift
// PrimaeNative
//
// WHEN the study's end-of-session screen appears (David, 2026-11-04: "there
// needs to be a separate visual endscreen after all three letters were
// completed with some sort of victory animation"). The decision lives here,
// a pure value function, because the view that shows the screen is not
// reachable from a test (see CLAUDE.md, "Test Infrastructure" 3).
//
// WHAT COUNTS AS "THE SESSION IS COMPLETE" (protocol r27). The child's whole
// trained set has a completed free-write TRAINING row, AND the final test has
// ended with a completed final-test row for each of those letters. A skipped
// letter is a partial session and gets no end screen, although the set is
// still held for the next child. Everything the decision reads is a fact
// about WHAT was done, never about HOW WELL: the screen is identical in every
// arm and for every score. (Before r27 the screen followed the third training
// letter; the final test now sits between, so it follows the test.)

import Foundation

struct SessionEndScreenDecision: Equatable, Sendable {
    /// The trained set in the fixed study order (`visibleLetterNames`).
    let setLetters: [String]
    /// Letters with a completed, non-probe free-write row already recorded.
    let completedTrainingLetters: Set<String>
    /// Letters with a completed `finalTest` free-write row already recorded.
    let completedFinalTestLetters: Set<String>
    /// The final test has just ended (its last letter is recorded).
    let finalTestEnded: Bool
    /// True once this child has had the screen (it is shown once per child).
    let alreadyPresented: Bool

    /// A one-letter set has no "end of set" (same rule as
    /// `TracingViewModel.isLastLetterOfSet`).
    var shouldPresent: Bool {
        guard !alreadyPresented, finalTestEnded, setLetters.count > 1 else { return false }
        let set = Set(setLetters)
        return set.isSubset(of: completedTrainingLetters)
            && set.isSubset(of: completedFinalTestLetters)
    }
}
