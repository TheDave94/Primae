// BackgroundFlushAssertion.swift
// PrimaeNative
//
// Keeps the process alive while the background flush drains the stores
// (fix batch C, audit R-051 / A2-07 / H1-11).

import UIKit

/// The two `UIApplication` calls that grant and release background
/// execution time. A seam so a test can see the assertion taken and
/// released without a real application.
@MainActor
protocol BackgroundTaskGranting: AnyObject {
    func begin(name: String, onExpiry: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    func end(_ identifier: UIBackgroundTaskIdentifier)
}

/// The production granter: `UIApplication.shared`, read only when an
/// assertion is actually taken (never at construction).
@MainActor
final class UIApplicationBackgroundTasks: BackgroundTaskGranting {
    init() {}
    func begin(name: String, onExpiry: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name) { onExpiry() }
    }
    func end(_ identifier: UIBackgroundTaskIdentifier) {
        UIApplication.shared.endBackgroundTask(identifier)
    }
}

/// Runs a flush under `beginBackgroundTask` (R-051, audit 2026-10-13).
/// `PrimaeApp` used to wrap the background flush in a plain `Task` and its
/// comment claimed that kept the process alive through the scene's
/// suspension grace window. It does not: only a background-task assertion
/// does. The assertion is taken SYNCHRONOUSLY, before the flush task is
/// even scheduled, and released exactly once — when the flush ends, or
/// when iOS's expiry handler fires first (an assertion not ended by then
/// gets the app killed).
@MainActor
enum BackgroundFlushAssertion {
    @discardableResult
    static func protect(named name: String,
                        using granter: BackgroundTaskGranting,
                        _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let assertion = HeldAssertion(granter: granter)
        assertion.identifier = granter.begin(name: name) { assertion.release() }
        return Task { @MainActor in
            await work()
            assertion.release()
        }
    }

    /// One assertion, released at most once.
    @MainActor
    private final class HeldAssertion {
        let granter: BackgroundTaskGranting
        var identifier: UIBackgroundTaskIdentifier = .invalid
        init(granter: BackgroundTaskGranting) { self.granter = granter }
        func release() {
            guard identifier != .invalid else { return }
            let id = identifier
            identifier = .invalid
            granter.end(id)
        }
    }
}
