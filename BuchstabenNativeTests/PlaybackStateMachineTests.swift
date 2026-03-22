//  PlaybackStateMachineTests.swift
//  BuchstabenNativeTests
//
//  Unit tests for PlaybackStateMachine value type.
//  Pure logic — no audio, no dispatch, no UIKit.

import Testing
@testable import BuchstabenNative

struct PlaybackStateMachineTests {

    // MARK: - Initial state

    @Test func initialState_isIdle() {
        let m = PlaybackStateMachine()
        #expect(m.state == .idle)
        #expect(!m.isPlaying)
        #expect(m.appIsForeground)
        #expect(m.resumeIntent)
    }

    // MARK: - Happy-path transitions

    @Test func transition_idleToActive_returnsPlay() {
        var m = PlaybackStateMachine()
        let cmd = m.transition(to: .active)
        #expect(cmd == .play)
        #expect(m.state == .active)
        #expect(m.isPlaying)
    }

    @Test func transition_activeToIdle_returnsStop() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        let cmd = m.transition(to: .idle)
        #expect(cmd == .stop)
        #expect(m.state == .idle)
        #expect(!m.isPlaying)
    }

    // MARK: - No-op transitions (same state)

    @Test func transition_idleToIdle_returnsNone() {
        var m = PlaybackStateMachine()
        let cmd = m.transition(to: .idle)
        #expect(cmd == .none)
        #expect(m.state == .idle)
    }

    @Test func transition_activeToActive_returnsNone() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        let cmd = m.transition(to: .active)
        #expect(cmd == .none)
        #expect(m.state == .active)
    }

    // MARK: - Guard: appIsForeground == false blocks .active

    @Test func guard_appNotForeground_blocksActive_fromIdle() {
        var m = PlaybackStateMachine()
        m.appIsForeground = false
        let cmd = m.transition(to: .active)
        #expect(cmd == .none, "Should be .none: already idle and resolved to idle")
        #expect(m.state == .idle)
    }

    @Test func guard_appNotForeground_blocksActive_fromActive() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        m.appIsForeground = false
        let cmd = m.transition(to: .active)
        #expect(cmd == .stop, "Machine was active; guard resolves to idle → stop")
        #expect(m.state == .idle)
    }

    @Test func guard_appNotForeground_idleToIdle_returnsNone() {
        var m = PlaybackStateMachine()
        m.appIsForeground = false
        let cmd = m.transition(to: .active)
        #expect(cmd == .none)
    }

    @Test func guard_appNotForeground_transitionToIdle_works() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        m.appIsForeground = false
        let cmd = m.transition(to: .idle)
        #expect(cmd == .stop)
        #expect(m.state == .idle)
    }

    // MARK: - Guard: resumeIntent == false blocks .active

    @Test func guard_noResumeIntent_blocksActive() {
        var m = PlaybackStateMachine()
        m.resumeIntent = false
        let cmd = m.transition(to: .active)
        #expect(cmd == .none)
        #expect(m.state == .idle)
    }

    @Test func guard_noResumeIntent_activeToActive_stopsEngine() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        m.resumeIntent = false
        let cmd = m.transition(to: .active)
        #expect(cmd == .stop)
        #expect(m.state == .idle)
    }

    @Test func guard_bothFalse_blocksActive() {
        var m = PlaybackStateMachine()
        m.appIsForeground = false
        m.resumeIntent = false
        let cmd = m.transition(to: .active)
        #expect(cmd == .none)
        #expect(m.state == .idle)
    }

    // MARK: - Guard restores: re-enabling allows .active

    @Test func guard_restored_allowsActive() {
        var m = PlaybackStateMachine()
        m.appIsForeground = false
        m.transition(to: .active) // blocked
        #expect(m.state == .idle)

        m.appIsForeground = true
        let cmd = m.transition(to: .active)
        #expect(cmd == .play)
        #expect(m.state == .active)
    }

    // MARK: - forceIdle

    @Test func forceIdle_fromActive_returnsStop() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        let cmd = m.forceIdle()
        #expect(cmd == .stop)
        #expect(m.state == .idle)
    }

    @Test func forceIdle_fromIdle_returnsNone() {
        var m = PlaybackStateMachine()
        let cmd = m.forceIdle()
        #expect(cmd == .none)
        #expect(m.state == .idle)
    }

    @Test func forceIdle_bypassesGuards() {
        var m = PlaybackStateMachine()
        m.transition(to: .active)
        m.appIsForeground = false
        m.resumeIntent = false
        // State is still .active — guard only fires on transition(to:)
        #expect(m.state == .active)
        let cmd = m.forceIdle()
        #expect(cmd == .stop)
        #expect(m.state == .idle)
    }

    // MARK: - isPlaying mirrors state

    @Test func isPlaying_mirrorsState() {
        var m = PlaybackStateMachine()
        #expect(!m.isPlaying)
        m.transition(to: .active)
        #expect(m.isPlaying)
        m.transition(to: .idle)
        #expect(!m.isPlaying)
    }

    // MARK: - Value semantics

    @Test func valueSemantics_copyIsIndependent() {
        var original = PlaybackStateMachine()
        original.transition(to: .active)

        var copy = original
        copy.transition(to: .idle)

        #expect(original.state == .active, "Original must not be affected by copy mutation")
        #expect(copy.state == .idle)
    }

    // MARK: - Rapid churn

    @Test func rapidChurn_multipleTransitions_consistentState() {
        var m = PlaybackStateMachine()
        for i in 0..<100 {
            let target: PlaybackStateMachine.State = i % 2 == 0 ? .active : .idle
            m.transition(to: target)
        }
        #expect(m.state == .idle)
        #expect(!m.isPlaying)
    }

    // MARK: - Command sequence correctness

    @Test func commandSequence_noSpuriousCommands() {
        var m = PlaybackStateMachine()
        var commands: [PlaybackStateMachine.Command] = []

        commands.append(m.transition(to: .active)) // play
        commands.append(m.transition(to: .active)) // none
        commands.append(m.transition(to: .idle))   // stop
        commands.append(m.transition(to: .idle))   // none
        commands.append(m.transition(to: .active)) // play
        commands.append(m.forceIdle())             // stop

        #expect(commands == [.play, .none, .stop, .none, .play, .stop])
    }

    // MARK: - Equatable conformance

    @Test func equatable_sameState_areEqual() {
        let m1 = PlaybackStateMachine()
        let m2 = PlaybackStateMachine()
        #expect(m1 == m2)
    }

    @Test func equatable_differentState_notEqual() {
        var m1 = PlaybackStateMachine()
        var m2 = PlaybackStateMachine()
        m1.transition(to: .active)
        #expect(m1 != m2)
        m2.transition(to: .active)
        #expect(m1 == m2)
    }
}
