// TransientMessagePresenter.swift
// PrimaeNative
//
// Owns two short-lived UI messages published by the view model:
//   - a generic toast that auto-dismisses after ~1.3 s
//   - a celebration HUD that auto-dismisses after ~1.8 s or on user tap
//
// Extracted from TracingViewModel so both messages (each with its own
// cancellation Task + equality-guarded auto-clear) live in one focused place.
//
// The sleep used for the auto-clear timers is injectable so tests can drive
// the dismissal deterministically without relying on wall-clock pauses.

import Foundation

@MainActor
@Observable
final class TransientMessagePresenter {

    // MARK: - Published state (bound by views)

    /// Currently displayed short toast, or nil. Auto-clears ~1.3 s after `show(toast:)`.
    private(set) var toastMessage: String? = nil

    /// Currently displayed completion HUD message, or nil. Auto-clears ~1.8 s after
    /// `show(completion:)` or when the user calls `dismissCompletion()`.
    private(set) var completionMessage: String? = nil

    // MARK: - Timings

    let toastDuration:      TimeInterval = 1.3
    let completionDuration: TimeInterval = 1.8

    // MARK: - Tasks (exposed read-only so tests can await pending auto-clears)

    private(set) var toastTask:      Task<Void, Never>?
    private(set) var completionTask: Task<Void, Never>?

    // MARK: - Sleep injection

    typealias Sleeper = @Sendable (Duration) async throws -> Void
    private let sleep: Sleeper

    init(sleep: @escaping Sleeper = { try await Task.sleep(for: $0) }) {
        self.sleep = sleep
    }

    // MARK: - API

    /// Display a transient toast. Cancels and replaces any in-flight toast.
    func show(toast text: String) {
        toastMessage = text
        toastTask?.cancel()
        let sleeper = sleep
        let duration = toastDuration
        toastTask = Task { [weak self] in
            try? await sleeper(.seconds(duration))
            guard let self, !Task.isCancelled, self.toastMessage == text else { return }
            // Equality-guard prevents clobbering a newer message queued during our sleep.
            self.toastMessage = nil
            self.toastTask    = nil
        }
    }

    /// Display a completion HUD message. Cancels and replaces any existing one.
    func show(completion text: String) {
        completionTask?.cancel()
        completionMessage = text
        let sleeper = sleep
        let duration = completionDuration
        completionTask = Task { [weak self] in
            try? await sleeper(.seconds(duration))
            guard let self, !Task.isCancelled, self.completionMessage == text else { return }
            self.completionMessage = nil
        }
    }

    /// Dismiss the completion HUD immediately (user-driven tap).
    func dismissCompletion() {
        completionTask?.cancel()
        completionMessage = nil
    }

    /// Clear the completion HUD without cancelling (used by resetLetter paths
    /// that want to wipe state but keep the task slot for a subsequent show).
    func clearCompletionState() {
        completionTask?.cancel()
        completionMessage = nil
    }
}
