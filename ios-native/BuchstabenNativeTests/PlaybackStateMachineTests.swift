//  PlaybackStateMachineTests.swift
//  BuchstabenNativeTests
//
//  Unit tests for PlaybackStateMachine value type.
//  Pure logic — no audio, no dispatch, no UIKit.

import XCTest
@testable import BuchstabenNative

@MainActor
final class PlaybackStateMachineTests: XCTestCase {

    // MARK: - Initial state

    func testInitialState_isIdle() {
        let m = PlaybackStateMachine()
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(m.isPlaying)
        XCTAssertTrue(m.appIsForeground)
        XCTAssertTrue(m.resumeIntent)
    }

    // MARK: - Happy-path transitions

    func testTransition_idleToActive_returnsPlay() {
        var m = PlaybackStateMachine()
        let cmd = m.transition(to: .active)
        XCTAssertEqual(cmd, .play)
        XCTAssertEqual(m.state, .active)
        XCTAssertTrue(m.isPlaying)
    }

    func testTransition_activeToIdle_returnsStop() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        let cmd = m.transition(to: .idle)
        XCTAssertEqual(cmd, .stop)
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(m.isPlaying)
    }

    // MARK: - No-op transitions (same state)

    func testTransition_idleToIdle_returnsNone() {
        var m = PlaybackStateMachine()
        let cmd = m.transition(to: .idle)
        XCTAssertEqual(cmd, .none)
        XCTAssertEqual(m.state, .idle)
    }

    func testTransition_activeToActive_returnsNone() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        let cmd = m.transition(to: .active)
        XCTAssertEqual(cmd, .none)
        XCTAssertEqual(m.state, .active)
    }

    // MARK: - Guard: appIsForeground == false blocks .active

    func testGuard_appNotForeground_blocksActive_fromIdle() {
        var m = PlaybackStateMachine()
        m.appIsForeground = false
        let cmd = m.transition(to: .active)
        XCTAssertEqual(cmd, .none,  "Should be .none: already idle and resolved to idle")
        XCTAssertEqual(m.state, .idle)
    }

    func testGuard_appNotForeground_blocksActive_fromActive() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        m.appIsForeground = false
        // Requesting .active while in background — should resolve to .idle → stop
        let cmd = m.transition(to: .active)
        XCTAssertEqual(cmd, .stop, "Machine was active; guard resolves to idle → stop")
        XCTAssertEqual(m.state, .idle)
    }

    func testGuard_appNotForeground_idleToIdle_returnsNone() {
        var m = PlaybackStateMachine()
        m.appIsForeground = false
        // idle→active blocked, resolved to idle; already idle → none
        let cmd = m.transition(to: .active)
        XCTAssertEqual(cmd, .none)
    }

    func testGuard_appNotForeground_transitionToIdle_works() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        m.appIsForeground = false
        let cmd = m.transition(to: .idle)
        XCTAssertEqual(cmd, .stop)
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - Guard: resumeIntent == false blocks .active

    func testGuard_noResumeIntent_blocksActive() {
        var m = PlaybackStateMachine()
        m.resumeIntent = false
        let cmd = m.transition(to: .active)
        XCTAssertEqual(cmd, .none)
        XCTAssertEqual(m.state, .idle)
    }

    func testGuard_noResumeIntent_activeToActive_stopsEngine() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        m.resumeIntent = false
        let cmd = m.transition(to: .active)
        XCTAssertEqual(cmd, .stop)
        XCTAssertEqual(m.state, .idle)
    }

    func testGuard_bothFalse_blocksActive() {
        var m = PlaybackStateMachine()
        m.appIsForeground = false
        m.resumeIntent = false
        let cmd = m.transition(to: .active)
        XCTAssertEqual(cmd, .none)
        XCTAssertEqual(m.state, .idle)
    }

    // MARK: - Guard restores: re-enabling allows .active

    func testGuard_restored_allowsActive() {
        var m = PlaybackStateMachine()
        m.appIsForeground = false
        m.transition(to: .active) // blocked
        XCTAssertEqual(m.state, .idle)

        m.appIsForeground = true
        let cmd = m.transition(to: .active)
        XCTAssertEqual(cmd, .play)
        XCTAssertEqual(m.state, .active)
    }

    // MARK: - forceIdle

    func testForceIdle_fromActive_returnsStop() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        let cmd = m.forceIdle()
        XCTAssertEqual(cmd, .stop)
        XCTAssertEqual(m.state, .idle)
    }

    func testForceIdle_fromIdle_returnsNone() {
        var m = PlaybackStateMachine()
        let cmd = m.forceIdle()
        XCTAssertEqual(cmd, .none)
        XCTAssertEqual(m.state, .idle)
    }

    func testForceIdle_bypassesGuards() {
        // forceIdle must work even when guards would normally block
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        m.appIsForeground = false
        m.resumeIntent = false
        // State is currently idle (guard blocked re-entry). Force from active:
        // Set up manually — machine is idle after guard, need to force from active state
        // Let's do: active state → disable fg → forceIdle should still stop
        var m2 = PlaybackStateMachine()
        m2.transition(to: .active) // active
        m2.appIsForeground = false  // guard set but state still active
        // Note: guard only fires on transition(to:), not on state mutation
        // So m2.state is still .active here
        XCTAssertEqual(m2.state, .active)
        let cmd = m2.forceIdle()
        XCTAssertEqual(cmd, .stop)
        XCTAssertEqual(m2.state, .idle)
    }

    // MARK: - isPlaying mirrors state

    func testIsPlaying_mirorsState() {
        var m = PlaybackStateMachine()
        XCTAssertFalse(m.isPlaying)
        m.transition(to: .active)
        XCTAssertTrue(m.isPlaying)
        m.transition(to: .idle)
        XCTAssertFalse(m.isPlaying)
    }

    // MARK: - Value semantics

    func testValueSemantics_copyIsIndependent() {
        var original = PlaybackStateMachine()
        original.transition(to: .active)

        var copy = original
        copy.transition(to: .idle)

        XCTAssertEqual(original.state, .active, "Original must not be affected by copy mutation")
        XCTAssertEqual(copy.state, .idle)
    }

    // MARK: - Rapid churn

    func testRapidChurn_multipleTransitions_consistentState() {
        var m = PlaybackStateMachine()
        for i in 0..<100 {
            let target: PlaybackStateMachine.State = i % 2 == 0 ? .active : .idle
            m.transition(to: target)
        }
        // After 100 transitions (0-indexed, last is i=99 → .idle)
        XCTAssertEqual(m.state, .idle)
        XCTAssertFalse(m.isPlaying)
    }

    // MARK: - Command sequence correctness

    func testCommandSequence_noSpuriousCommands() {
        var m = PlaybackStateMachine()
        var commands: [PlaybackStateMachine.Command] = []

        commands.append(m.transition(to: .active)) // play
        commands.append(m.transition(to: .active)) // none (already active)
        commands.append(m.transition(to: .idle))   // stop
        commands.append(m.transition(to: .idle))   // none (already idle)
        commands.append(m.transition(to: .active)) // play
        commands.append(m.forceIdle())             // stop

        XCTAssertEqual(commands, [.play, .none, .stop, .none, .play, .stop])
    }

    // MARK: - Equatable conformance

    func testEquatable_sameState_areEqual() {
        let m1 = PlaybackStateMachine()
        let m2 = PlaybackStateMachine()
        XCTAssertEqual(m1, m2)
    }

    func testEquatable_differentState_notEqual() {
        var m1 = PlaybackStateMachine()
        var m2 = PlaybackStateMachine()
        m1.transition(to: .active)
        XCTAssertNotEqual(m1, m2)
        m2.transition(to: .active)
        XCTAssertEqual(m1, m2)
    }
}
