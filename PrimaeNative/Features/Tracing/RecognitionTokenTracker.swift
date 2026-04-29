// RecognitionTokenTracker.swift
// PrimaeNative
//
// D1a (ROADMAP) — first slice of the TracingViewModel decomposition.
// Tracks "which recognition request is currently authoritative" so the
// three async recognizer call sites (freeWrite, freeform-letter,
// freeform-word) can each gate their completion handlers against a
// state-clearing event (letter load, phase transition, canvas clear)
// that happened while inference was in flight.
//
// Before this slice, every entry point hand-rolled the same pair of
// helpers on the VM (`issueRecognitionToken` / `recognitionStillActive`)
// against a `private var activeRecognitionToken: UUID?` field. Pulling
// it into a small reference-typed helper centralises the contract: the
// VM no longer cares whether the token is a UUID or some other id, and
// the helper can grow (e.g. to expose cancellation reasons or per-mode
// tokens) without touching the call sites.
//
// Intentionally narrow: this slice does NOT extract the recognition
// orchestration itself (the freeWrite/freeform-letter/word dispatch +
// completion routing). That's still recommended in ROADMAP but needs
// careful in-loop review — the 3 entry points have distinct side
// effects (lastRecognitionResult, freeform.isRecognizing, paper-
// transfer enqueue, speech wiring, P2 self-explanation re-animation)
// and a one-shot extraction has too many coupling points for safe
// autonomous work.

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
