// PersistenceFailureCenter.swift
// PrimaeNative
//
// Every JSON store in this app (ProgressStore, ParentDashboardStore,
// StreakStore, RawTraceStore, ParticipantArchiveStore, EnrolmentLog) wrote its disk
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

// `nonisolated` on the type, not just the methods: the package target
// default-isolates every declaration to @MainActor
// (`.defaultIsolation(MainActor.self)`, Package.swift), and this type's
// entire reason to exist is being callable from the detached background
// Tasks every store's `persist()` runs its disk write on — an implicit
// `@MainActor` inference here would make every store's fire-and-forget
// `reportFailure` call require `await` from a context that has no
// business suspending on it. Thread safety is via the manual `NSLock`
// below, not actor isolation — hence `@unchecked Sendable`.
nonisolated final class PersistenceFailureCenter: @unchecked Sendable {
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

    /// Non-blocking findings the proctor must still SEE (R-055/R-056,
    /// audit 2026-10-13): a store file moved aside at load, rows dropped
    /// by an element-wise decode, an archived child that could not be
    /// read, a cap that evicted records, a non-finite measurement. None of
    /// these means "the data from now on may not be saving" — that is a
    /// failure, above — so none blocks the session; they are listed in the
    /// parent area (`ResearchDashboardView`), never on a child-facing
    /// screen.
    private var _notices: [String] = []

    init() {}

    /// Registers the MainActor handler that turns a failure into a
    /// visible, blocking message. Replaces any previous subscriber —
    /// there is exactly one live `TracingViewModel` per process.
    ///
    /// REPLAYS every failure already recorded (R-056, audit 2026-10-13):
    /// the stores are built — and load, and may refuse to write — before
    /// the view model exists to subscribe, so a failure reported in that
    /// window used to reach no handler and never block the session.
    func subscribe(_ handler: @escaping @MainActor (String) -> Void) {
        lock.lock()
        onFailure = handler
        let earlier = _failures
        lock.unlock()
        guard !earlier.isEmpty else { return }
        Task { @MainActor in
            for description in earlier { handler(description) }
        }
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

    /// Records a non-blocking finding — see `_notices`. Logged at error
    /// level so it is never quieter than before. Callable from any thread.
    func reportNotice(store: String, message: String) {
        let description = "\(store): \(message)"
        lock.lock(); _notices.append(description); lock.unlock()
        storePersistenceLogger.error("Persistence notice — \(description, privacy: .public)")
    }

    /// Every notice recorded so far this process, in order.
    var notices: [String] {
        lock.lock(); defer { lock.unlock() }
        return _notices
    }

    /// What the parent area shows: nil while nothing has gone wrong.
    var integritySummary: PersistenceIntegritySummary? {
        lock.lock(); defer { lock.unlock() }
        guard !_failures.isEmpty || !_notices.isEmpty else { return nil }
        return PersistenceIntegritySummary(failures: _failures, notices: _notices)
    }

    /// Test-only. Production never clears a live failure signal — a
    /// write failure does not self-heal without a device fix (more disk
    /// space, corrected permissions), and silently clearing it on, say,
    /// the next successful write to a DIFFERENT store would recreate
    /// exactly the "looks fine, actually isn't" gap this type exists to
    /// close.
    func resetForTesting() {
        lock.lock(); _failures = []; _notices = []; onFailure = nil; lock.unlock()
    }
}

/// The parent-area view of `PersistenceFailureCenter` (R-055): counts and
/// the lines behind them, German headline for the proctor.
nonisolated struct PersistenceIntegritySummary: Equatable, Sendable {
    let failures: [String]
    let notices: [String]

    var headline: String {
        var parts: [String] = []
        if !failures.isEmpty { parts.append("\(failures.count) Speicherfehler") }
        if !notices.isEmpty { parts.append("\(notices.count) Datenhinweis\(notices.count == 1 ? "" : "e")") }
        return parts.joined(separator: " · ")
    }
}
