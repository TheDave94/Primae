//  PlaybackStateMachine.swift
//  PrimaeNative
//
//  Pure value-type state machine for adaptive playback. Side-effect
//  free — callers execute the returned Command. Transitions to
//  `.active` are blocked unless `appIsForeground` and `resumeIntent`
//  are both true; the machine stays/moves to `.idle` otherwise.

import Foundation

struct PlaybackStateMachine: Equatable {

    // MARK: - Nested types

    enum State: Equatable {
        case idle
        case active
    }

    /// Side-effect command returned to the caller.
    enum Command: Equatable {
        case play
        case stop
        /// No state change occurred — caller should do nothing.
        case none
    }

    // MARK: - State

    private(set) var state: State = .idle

    /// Must be true for a transition to .active to succeed.
    var appIsForeground: Bool = true

    /// Must be true for a transition to .active to succeed.
    var resumeIntent: Bool = true

    // MARK: - Transitions

    /// Request a transition to `target`.
    /// Returns the command the caller must execute (`.play`, `.stop`, or `.none`).
    /// The machine applies guards before committing: a request for `.active` while
    /// `appIsForeground == false` or `resumeIntent == false` is resolved to `.idle`.
    @discardableResult
    mutating func transition(to target: State) -> Command {
        let resolved: State
        if target == .active && (!appIsForeground || !resumeIntent) {
            resolved = .idle
        } else {
            resolved = target
        }
        guard resolved != state else { return .none }
        state = resolved
        return resolved == .active ? .play : .stop
    }

    /// Unconditionally move to `.idle`, bypassing guards.
    /// Returns `.stop` if state changed, `.none` if already idle.
    @discardableResult
    mutating func forceIdle() -> Command {
        guard state != .idle else { return .none }
        state = .idle
        return .stop
    }

    // MARK: - Convenience query

    var isPlaying: Bool { state == .active }
}
