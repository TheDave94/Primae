// RecognitionTokenTracker.swift
// PrimaeNative
//
// Tracks "which recognition request is currently authoritative" so the
// three async recognizer call sites (freeWrite, freeform-letter,
// freeform-word) can each gate their completion handlers against a
// state-clearing event (letter load, phase transition, canvas clear)
// that happened while inference was in flight.
//
// Centralising the contract behind a small reference-typed helper
// keeps the VM out of the business of token bookkeeping; new
// signalling (cancellation reasons, per-mode tokens) can grow here
// without touching the call sites.

import Foundation

@MainActor
final class RecognitionTokenTracker {
    /// The token of the currently-authoritative recognition request,
    /// or nil when nothing is in flight (state-clearing transitions
    /// nil this so any late-arriving completion is dropped).
    private(set) var current: UUID?

    /// Stamp a fresh token and return it. The caller is responsible
    /// for capturing the returned token in its dispatch closure and
    /// gating the completion handler with `isStillActive(_:)`.
    @discardableResult
    func issue() -> UUID {
        let token = UUID()
        current = token
        return token
    }

    /// True if `token` still represents the active recognition session.
    /// Returns false once `cancel()` has nil'd the current token or a
    /// newer `issue()` call has stamped a fresh one.
    func isStillActive(_ token: UUID) -> Bool {
        current == token
    }

    /// Drop the current token so any late completion is dropped on the
    /// floor. Called from state-clearing transitions: letter load,
    /// phase transition, canvas clear.
    func cancel() {
        current = nil
    }
}
