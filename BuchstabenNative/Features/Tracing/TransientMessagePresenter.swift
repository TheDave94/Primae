// TransientMessagePresenter.swift
// BuchstabenNative
//
// Owns two short-lived UI messages published by the view model:
//   - a generic toast that auto-dismisses after ~1.3 s
//   - a celebration HUD that auto-dismisses after ~1.8 s or on user tap
//
// Extracted from TracingViewModel so both messages (each with its own
// cancellation Task + equality-guarded auto-clear) live in one focused place.

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

    // MARK: - Timings (override for tests if needed)

    let toastDuration:      TimeInterval = 1.3
    let completionDuration: TimeInterval = 1.8

    // MARK: - Tasks

    private var toastTask:      Task<Void, Never>?
    private var completionTask: Task<Void, Never>?

    // MARK: - API

    /// Display a transient toast. Cancels and replaces any in-flight toast.
    func show(toast text: String) {
        toastMessage = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(self?.toastDuration ?? 1.3)) } catch { return }
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
        completionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.completionDuration ?? 1.8))
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
