// MainActorPollSupport.swift
// One poll helper for tests that wait for a main-actor job (a Task the
// view model armed, a frame loop, a timer's continuation).
//
// WHY IT COUNTS POLLS. A wall-clock deadline alone is flaky by
// construction in the parallel suite. Measured on CI, 2026-11-08 (runs
// 42504923240, 42493251286, 42405575398; Debug-Study simulator jobs):
// trivial synchronous tests "passed after 547 seconds", so one main-actor
// turn can take longer than a 300 s deadline. A poll that wakes once after
// its deadline gives up while the job it waits for is still queued behind
// it: `StudyLaunchTests` and `ProtocolMatrixTests` P4 failed that way on
// three of four runs of main, and passed alone and on the iPad.
// `LifecycleTestSupport.waitUntil` already counts polls for this reason
// (2026-10-13); eleven waits that still used a bare deadline use this, and
// a twelfth (`ProtocolMatrixTests`' sampling loop) applies the rule inline.
//
// The loop gives up only when BOTH hold: the deadline has passed AND at
// least `minimumPolls` polls have run. Each poll is one `Task.sleep`, so
// it hands the main actor to whatever is queued. Unstarved, the deadline
// decides; starved, the polls guarantee that many main-actor turns.

import Foundation

/// Poll the main actor until `condition` holds.
///
/// - Parameters:
///   - seconds: wall-clock deadline, for work that needs real time.
///   - interval: sleep between polls.
///   - minimumPolls: polls that run before the loop may give up, however
///     late the deadline is reached. A frame loop needs one turn per
///     frame; pass a count above its frame count.
/// - Returns: whether `condition` held when the loop ended.
@MainActor
@discardableResult
func pollMainActor(deadline seconds: Double,
                   every interval: Duration = .milliseconds(20),
                   minimumPolls: Int = 500,
                   until condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(seconds)
    var polls = 0
    while !condition() && (clock.now < deadline || polls < minimumPolls) {
        try? await Task.sleep(for: interval)
        polls += 1
    }
    return condition()
}
