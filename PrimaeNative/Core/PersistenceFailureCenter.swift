// PersistenceFailureCenter.swift
// PrimaeNative
//
// Every JSON store in this app (ProgressStore, ParentDashboardStore,
// StreakStore, RawTraceStore, ParticipantArchiveStore) wrote its disk
// save the same way: `try? data.write(to: url, options: .atomic)`
// inside a `do`/`catch` that logged a warning to OSLog and otherwise
// let the app carry on as if nothing had happened. Nobody watches
// OSLog during a pilot session. That shape is not hardening for study
// data — it is the exact defect that let an enrolment LOOK like it
// worked, in memory, for the rest of the running process, while
// nothing durable ever reached disk: the next launch, the next
// participant's archive read, or the end-of-session export would all
// have quietly come up short, with no signal anywhere that anything
// was wrong (2026-09-14).
//
// This is a process-wide, thread-safe signal that any store's
// background persist Task can report to from wherever it runs, and
// that `TracingViewModel` subscribes to on MainActor to turn the FIRST
// failure into a hard, visible session stop — the pilot runs once per
// child, with no second chance to collect, so a degrade-and-continue
// response to "the data may not be saving" is never the right default
// here, unlike the letter-name-audio-fallback shape elsewhere in this
// app that IS an acceptable degrade for a non-critical feature.

import Foundation

final class PersistenceFailureCenter: @unchecked Sendable {
    /// Production instance every JSON store reports to. Tests that want
    /// to drive the reporting/subscribing mechanism itself construct
    /// their OWN `PersistenceFailureCenter()` instead of touching this
    /// one — it is a genuine process-wide singleton shared with every
    /// OTHER test suite running in the same process, and a test that set
    /// `.shared`'s failure flag without very carefully undoing it would
    /// risk making every unrelated test after it see a stuck "session
    /// blocked" state. `init` is public specifically so that isolation is
    /// possible.
    static let shared = PersistenceFailureCenter()

    private let lock = NSLock()
    private var _failures: [String] = []
    /// MainActor-isolated subscriber, set once by the live VM. Every
    /// actual invocation of the handler is dispatched onto MainActor via
    /// `reportFailure`, so the closure body itself never runs off-actor
    /// even though `reportFailure` can be called from any thread (every
    /// store's background persist Task calls it from its own detached
    /// context).
    private var onFailure: (@MainActor (String) -> Void)?

    init() {}

    /// Registers the MainActor handler that turns a failure into a
    /// visible, blocking message. Replaces any previous subscriber —
    /// there is exactly one live `TracingViewModel` per process.
    func subscribe(_ handler: @escaping @MainActor (String) -> Void) {
        lock.lock(); onFailure = handler; lock.unlock()
    }

    /// Records a disk-write failure for `store` and notifies the
    /// subscriber, if any, on MainActor. Callable from any thread.
    func reportFailure(store: String, error: Error) {
        let description = "\(store): \(error.localizedDescription)"
        lock.lock()
        _failures.append(description)
        let handler = onFailure
        lock.unlock()
        Task { @MainActor in handler?(description) }
    }

    /// Every failure recorded so far this process, in order.
    var failures: [String] {
        lock.lock(); defer { lock.unlock() }
        return _failures
    }

    var hasFailed: Bool { !failures.isEmpty }

    /// Test-only. Production never clears a live failure signal — a
    /// write failure does not self-heal without a device fix (more disk
    /// space, corrected permissions), and silently clearing it on, say,
    /// the next successful write to a DIFFERENT store would recreate
    /// exactly the "looks fine, actually isn't" gap this type exists to
    /// close.
    func resetForTesting() {
        lock.lock(); _failures = []; onFailure = nil; lock.unlock()
    }
}
