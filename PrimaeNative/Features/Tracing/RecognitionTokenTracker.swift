// RecognitionTokenTracker.swift
// PrimaeNative
//
// Gates recognizer completion handlers against state-clearing events
// (letter load, phase transition, canvas clear) that fire while
// inference is in flight.

import Foundation

@MainActor
final class RecognitionTokenTracker {
    /// Token of the currently-authoritative recognition request, or
    /// nil when nothing is in flight.
    private(set) var current: UUID?

    /// Stamp a fresh token; caller captures it in the dispatch closure
    /// and gates the completion handler with `isStillActive(_:)`.
    @discardableResult
    func issue() -> UUID {
        let token = UUID()
        current = token
        return token
    }

    /// True if `token` still represents the active recognition session.
    func isStillActive(_ token: UUID) -> Bool {
        current == token
    }

    /// Drop the current token so any late completion is dropped.
    /// Called from state-clearing transitions.
    func cancel() {
        current = nil
    }
}
