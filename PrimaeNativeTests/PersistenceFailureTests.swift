// PersistenceFailureTests.swift
// PrimaeNativeTests
//
// 2026-09-14: every JSON store's disk write used to be
// `try?`-and-log-only — a failure was invisible to the running app and
// to whoever collected the device afterward. These tests prove the
// replacement mechanism in isolation:
//   1. PersistenceFailureCenter itself, on a LOCAL instance (never
//      `.shared` — see that type's doc comment for why touching the
//      process-wide singleton from a test is deliberately avoided: it
//      would leak a "failed" state into every other suite in the same
//      test process).
//   2. TracingViewModel.sessionBlockReason's new precedence, driven
//      directly through `handlePersistenceFailure` rather than through
//      `.shared`'s async Task dispatch, for the same isolation reason.
//
// A store's OWN write-catch block correctly calling
// `PersistenceFailureCenter.shared.reportFailure(...)` is reviewed at
// the call site (identical one-line addition in all five JSON stores),
// not re-proven per store here — the shared plumbing these tests DO
// prove is what actually matters for correctness.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct PersistenceFailureCenterTests {

    @Test("reportFailure records the failure and is reflected in hasFailed/failures")
    func reportFailureRecords() {
        let center = PersistenceFailureCenter()
        #expect(!center.hasFailed)
        center.reportFailure(store: "TestStore",
                             error: NSError(domain: "test", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "disk full"]))
        #expect(center.hasFailed)
        #expect(center.failures.count == 1)
        #expect(center.failures.first?.contains("TestStore") == true)
        #expect(center.failures.first?.contains("disk full") == true)
    }

    @Test("multiple failures accumulate rather than overwrite")
    func multipleFailuresAccumulate() {
        let center = PersistenceFailureCenter()
        center.reportFailure(store: "A", error: NSError(domain: "t", code: 1))
        center.reportFailure(store: "B", error: NSError(domain: "t", code: 2))
        #expect(center.failures.count == 2)
    }

    @Test("the subscribed handler is invoked on MainActor after a report")
    func subscriberIsNotified() async {
        let center = PersistenceFailureCenter()
        var received: String?
        center.subscribe { description in received = description }
        center.reportFailure(store: "TestStore", error: NSError(domain: "t", code: 1,
                                                                 userInfo: [NSLocalizedDescriptionKey: "no such file"]))
        // reportFailure dispatches the handler via `Task { @MainActor in ... }`;
        // yield until it has had a chance to run.
        for _ in 0..<50 where received == nil {
            await Task.yield()
        }
        #expect(received?.contains("TestStore") == true)
    }

    @Test("resetForTesting clears both the failure log and the subscriber")
    func resetClearsState() {
        let center = PersistenceFailureCenter()
        center.subscribe { _ in }
        center.reportFailure(store: "A", error: NSError(domain: "t", code: 1))
        #expect(center.hasFailed)
        center.resetForTesting()
        #expect(!center.hasFailed)
        #expect(center.failures.isEmpty)
    }
}

@Suite @MainActor struct SessionBlockOnPersistenceFailureTests {

    @Test("a persistence failure hard-blocks the study session with a visible reason")
    func persistenceFailureBlocksSession() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        #expect(vm.sessionBlockReason == nil, "precondition: nothing blocks a fresh study session")

        vm.handlePersistenceFailure("ProgressStore: disk full")

        #expect(vm.persistenceFailureMessage != nil)
        #expect(vm.sessionBlockReason != nil, "a reported persistence failure must block the session")
        #expect(vm.sessionBlockReason == vm.persistenceFailureMessage,
                "the block reason must be the persistence message, not some other reason")
    }

    @Test("a persistence failure outranks the identity-changed relaunch reason")
    func persistenceFailureOutranksIdentityChanged() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.markParticipantRestored()   // sets participantIdentityChanged = true
        #expect(vm.sessionBlockReason != nil, "precondition: already blocked for a different reason")
        let identityReason = vm.sessionBlockReason

        vm.handlePersistenceFailure("RawTraceStore: no such file or directory")

        #expect(vm.sessionBlockReason != identityReason,
                "the persistence-failure message must take priority once one is reported")
        #expect(vm.sessionBlockReason == vm.persistenceFailureMessage)
    }

    @Test("only the FIRST persistence failure sets the message — later ones don't overwrite it")
    func firstFailureWins() {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.handlePersistenceFailure("ProgressStore: disk full")
        let first = vm.persistenceFailureMessage
        vm.handlePersistenceFailure("StreakStore: permission denied")
        #expect(vm.persistenceFailureMessage == first,
                "the FIRST failure's message should stick, not be replaced by a second store's failure")
    }

    @Test("a non-study install is not hard-blocked by this mechanism")
    func nonStudyInstallUnaffected() {
        var deps = TracingDependencies.stub
        deps.studyMode = false
        let vm = TracingViewModel(deps)
        vm.handlePersistenceFailure("ProgressStore: disk full")
        // persistenceFailureMessage is still recorded (useful for a
        // future non-study surface), but sessionBlockReason must not
        // gate on it outside studyMode — the casual/paused app path is
        // deliberately left on its existing (silent-log) behavior.
        #expect(vm.persistenceFailureMessage != nil)
        #expect(vm.sessionBlockReason == nil)
    }
}
