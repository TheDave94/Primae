// MainActorPollSupportTests.swift
// Pins the two halves of `pollMainActor`'s give-up rule (audit 2026-11-10,
// P-01). Each test fails if its half is removed: without the poll floor
// the first returns false, without the deadline the second never ends
// early enough to matter and without either bound the third hangs.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("pollMainActor: gives up on the deadline AND the poll floor, never on one alone")
@MainActor
struct MainActorPollSupportTests {

    @Test("a deadline already passed does not end the poll before the floor: a late main-actor job is still seen")
    func pollFloorOutlivesThePassedDeadline() async {
        var polls = 0
        // Deadline 0 s: passed before the first poll. The condition turns
        // true on the 6th poll, as a job queued behind the test would.
        let held = await pollMainActor(deadline: 0, every: .milliseconds(1), minimumPolls: 50) {
            polls += 1
            return polls > 6
        }
        #expect(held, "the poll gave up at the deadline although the floor had not run")
        #expect(polls < 50, "the poll kept going after the condition held (\(polls) checks)")
    }

    @Test("a job that needs real time is waited for past the poll floor, until the deadline")
    func deadlineOutlivesThePollFloor() async {
        let clock = ContinuousClock()
        let start = clock.now
        // Floor 1 poll, reached at once. The condition needs 150 ms of
        // real time, inside the 30 s deadline.
        let held = await pollMainActor(deadline: 30, every: .milliseconds(5), minimumPolls: 1) {
            clock.now - start >= .milliseconds(150)
        }
        #expect(held, "the poll gave up at the floor although the deadline had not passed")
    }

    @Test("a condition that never holds ends the poll once both bounds are spent, and reports false")
    func givesUpWhenBothBoundsAreSpent() async {
        var polls = 0
        let held = await pollMainActor(deadline: 0.05, every: .milliseconds(1), minimumPolls: 20) {
            polls += 1
            return false
        }
        #expect(!held)
        #expect(polls >= 20, "the poll gave up after \(polls) checks, below its floor of 20")
    }
}
