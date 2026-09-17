// RecognitionTokenTrackerTests.swift
// PrimaeNativeTests
//
// The staleness gate on in-flight recognizer completions.
//
// WHY THIS FILE EXISTS. `RecognitionTokenTracker` is a small, pure,
// dependency-free `@MainActor` class with thirteen call sites inside
// `TracingViewModel` — the study's core view model — and until now it had
// ZERO tests. An independent coverage sweep put it third on the study-risk
// list and its own words were that a file like this "would be the first
// thing tested". It is exactly the shape that goes untested because it
// looks too simple to need it, while the thing it guards is subtle.
//
// WHAT IT GUARDS. A recognition result arrives asynchronously. Between the
// request and the reply the letter, the phase, or the whole canvas can
// change. A verdict from the previous letter attached to the current one
// records a WRONG STIMULUS against a child; a dropped verdict records
// missing data. Both are silent.

import Testing
import Foundation
@testable import PrimaeNative

@MainActor
@Suite struct RecognitionTokenTrackerTests {

    @Test("a fresh tracker has nothing in flight")
    func freshTrackerIsIdle() {
        let tracker = RecognitionTokenTracker()
        #expect(tracker.current == nil, "a new tracker must not claim a request is in flight")
    }

    @Test("an issued token is the current one and reports itself active")
    func issuedTokenIsActive() {
        let tracker = RecognitionTokenTracker()
        let token = tracker.issue()
        #expect(tracker.current == token)
        #expect(tracker.isStillActive(token))
    }

    @Test("issue() returns a distinct token every time")
    func tokensAreDistinct() {
        let tracker = RecognitionTokenTracker()
        let a = tracker.issue()
        let b = tracker.issue()
        #expect(a != b, "two requests shared a token — a stale completion could pass the gate")
    }

    /// The property the whole class exists for: a later request invalidates
    /// an earlier one, so the earlier completion is dropped rather than
    /// landing on whatever is on screen now.
    @Test("issuing a new token invalidates the previous one")
    func newTokenInvalidatesPrevious() {
        let tracker = RecognitionTokenTracker()
        let first = tracker.issue()
        let second = tracker.issue()

        #expect(tracker.isStillActive(first) == false,
                "the superseded token still reads active — a late result for the previous request would be recorded against the current letter")
        #expect(tracker.isStillActive(second))
        #expect(tracker.current == second)
    }

    /// A state-clearing transition (letter load, phase change, canvas clear)
    /// drops the token, so every in-flight completion is refused.
    @Test("cancel() deactivates whatever was in flight")
    func cancelDeactivatesCurrent() {
        let tracker = RecognitionTokenTracker()
        let token = tracker.issue()
        tracker.cancel()

        #expect(tracker.current == nil)
        #expect(tracker.isStillActive(token) == false,
                "a completion survived a cancel — a result could be recorded after the canvas was cleared")
    }

    @Test("cancel() on an idle tracker is harmless")
    func cancelIsIdempotent() {
        let tracker = RecognitionTokenTracker()
        tracker.cancel()
        tracker.cancel()
        #expect(tracker.current == nil)
    }

    /// After a cancel, a NEW request must work normally — a gate that stayed
    /// shut would silently drop every recognition result for the rest of the
    /// session, which is the missing-data half of the failure.
    @Test("a token issued after a cancel is active")
    func issueAfterCancelWorks() {
        let tracker = RecognitionTokenTracker()
        _ = tracker.issue()
        tracker.cancel()

        let fresh = tracker.issue()
        #expect(tracker.isStillActive(fresh),
                "a request issued after a cancel is refused — every result for the rest of the session would be dropped")
    }

    /// A token from a DIFFERENT tracker must never read as active here —
    /// the gate is per-tracker, not global.
    @Test("a token from another tracker is not active")
    func foreignTokenIsRejected() {
        let mine = RecognitionTokenTracker()
        let theirs = RecognitionTokenTracker()
        _ = mine.issue()
        let foreign = theirs.issue()
        #expect(mine.isStillActive(foreign) == false)
    }
}
