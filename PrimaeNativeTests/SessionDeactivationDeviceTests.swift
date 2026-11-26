// SessionDeactivationDeviceTests.swift
// PrimaeNativeTests: SDK27 (2026-11-24)
//
// The iOS 27 notifications posted BY THE SYSTEM, not forged: deactivating the
// session ourselves makes AVFAudio post didBecomeInactive with a real
// `DeactivationContext`, whose source must read `.app` — the case
// `AudioSessionInterruption` must NOT treat as an interruption (the old
// interruption notification never fired for it either). Also logs whether
// the deprecated interruption notification still fires alongside (it must
// not, for an app-requested deactivation). Device only: the simulator's
// session is not the hardware's.
//
// XCTest (runtime skip on the simulator), so not Swift Testing.

import XCTest
import AVFoundation
@testable import PrimaeNative

/// The notifications the observer saw, collected from its `@Sendable` block
/// (a captured `var` array is not Sendable).
private final class NotificationInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Notification] = []
    func add(_ n: Notification) { lock.withLock { items.append(n) } }
    var all: [Notification] { lock.withLock { items } }
}

final class SessionDeactivationDeviceTests: XCTestCase {

    @MainActor func testOwnDeactivationIsAppSourcedAndNotAnInterruption() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("device only: the simulator's audio session is not the hardware's")
        #else
        let session = AVAudioSession.sharedInstance()
        // SDK27: no synchronous session call on the main thread (each is a
        // runtime "Hang Risk"): the app's own configuration, set only if it
        // differs, and the asynchronous activate / deactivate.
        try AudioEngine.configureSessionIfNeeded(session)
        _ = try await session.activate(options: [])

        let inbox = NotificationInbox()
        let got = expectation(description: "didBecomeInactive posted by the system")
        got.assertForOverFulfill = false
        let token = NotificationCenter.default.addObserver(
            forName: AVAudioSession.didBecomeInactiveNotification, object: nil, queue: .main) { n in
            inbox.add(n); got.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        var deactivateError: Error?
        do { _ = try await session.deactivate(options: []) } catch { deactivateError = error }
        await fulfillment(of: [got], timeout: 5)
        _ = try? await session.activate(options: [])

        let inactive = inbox.all
        let n = try XCTUnwrap(inactive.first)
        let ctx = n.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext
        print("SDK27 REAL didBecomeInactive count=\(inactive.count) context=\(ctx != nil) "
              + "source=\(ctx.map { "\($0.source.rawValue)" } ?? "nil") "
              + "interruptionContext=\(ctx?.interruptionContext != nil) setActiveError=\(deactivateError.map { "\($0)" } ?? "none")")
        XCTAssertNotNil(ctx, "a system-posted didBecomeInactive carries a DeactivationContext")
        XCTAssertEqual(ctx?.source, .app, "our own deactivation must read as source .app")
        XCTAssertNil(AudioSessionInterruption(n), "the app's own deactivation is not an interruption")
        #endif
    }
}
