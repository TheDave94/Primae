// BackgroundFlushAssertionTests.swift
// R-051 (audit 2026-10-13, A2-07 / H1-11): the background flush ran in a
// plain `Task`, and `PrimaeApp`'s comment claimed that kept the process
// alive. It does not — only a background-task assertion does — and the
// datum at risk is the session's LAST trial. The flush now runs under
// `beginBackgroundTask`, taken synchronously before the flush starts and
// released exactly once, when the flush ends or the time expires.

import Testing
import SwiftUI
import UIKit
@testable import PrimaeNative

@MainActor
final class SpyBackgroundTasks: BackgroundTaskGranting {
    private(set) var begun: [UIBackgroundTaskIdentifier] = []
    private(set) var ended: [UIBackgroundTaskIdentifier] = []
    private(set) var expiry: (@MainActor @Sendable () -> Void)?
    private var next = 41
    func begin(name: String, onExpiry: @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier {
        next += 1
        let id = UIBackgroundTaskIdentifier(rawValue: next)
        begun.append(id)
        expiry = onExpiry
        return id
    }
    func end(_ identifier: UIBackgroundTaskIdentifier) { ended.append(identifier) }
}

@Suite @MainActor struct BackgroundFlushAssertionTests {

    @Test("the assertion is taken BEFORE the flush starts and released once, after it ends")
    func takenBeforeReleasedAfter() async {
        let spy = SpyBackgroundTasks()
        var ranWhileHeld = false
        let task = BackgroundFlushAssertion.protect(named: "flush", using: spy) {
            ranWhileHeld = spy.begun.count == 1 && spy.ended.isEmpty
        }
        #expect(spy.begun.count == 1, "no background time was requested before the flush task was even scheduled")
        await task.value
        #expect(ranWhileHeld, "the flush ran without the assertion held")
        #expect(spy.ended == spy.begun, "begun \(spy.begun) ended \(spy.ended)")
    }

    @Test("expiry releases the assertion, and the flush's own end does not release it twice")
    func expiryReleasesOnce() async {
        let spy = SpyBackgroundTasks()
        let gate = AsyncStream<Void>.makeStream()
        let task = BackgroundFlushAssertion.protect(named: "flush", using: spy) {
            for await _ in gate.stream { break }
        }
        #expect(spy.begun.count == 1)
        spy.expiry?()
        #expect(spy.ended == spy.begun, "the expiry handler must end the task, or iOS kills the app")
        gate.continuation.yield(())
        gate.continuation.finish()
        await task.value
        #expect(spy.ended.count == 1, "ended twice: \(spy.ended)")
    }

    @Test("the scene's background transition runs the stores' flush under the assertion")
    func backgroundSceneUsesTheAssertion() async {
        let spy = SpyBackgroundTasks()
        let traces = StubRawTraceStore()
        let rig = LifecycleRig { deps in
            deps.backgroundTasks = spy
            deps.rawTraceStore = traces
        }
        let task = rig.vm.scenePhaseDidChange(to: .background)
        #expect(spy.begun.count == 1, "the background flush was not protected")
        await task?.value
        #expect(traces.flushCount == 1, "precondition: the flush ran")
        #expect(spy.ended == spy.begun)
    }
}
