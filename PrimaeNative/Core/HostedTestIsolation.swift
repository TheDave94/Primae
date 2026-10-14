// HostedTestIsolation.swift
// PrimaeNative
//
// R-052 (audit 2026-10-13): keep the hosted unit tests out of the pilot's
// own preferences.
//
// `PrimaeNativeTests` runs INSIDE the app (`TEST_HOST` = Primae.app), and
// Debug-Study and Release-Study share the bundle id
// `com.flamingistan.primae.study` — one install slot. A device test run
// therefore executes ~1000 tests in the study iPad's real container, and
// every test that sets a participant id, an enrolment instant, an arm
// override or a comparison switch through `UserDefaults.standard` wrote it
// into the PILOT's preferences domain. Restores were partial (participantId
// and enrolledAt were never restored by several suites), a run killed at a
// tool timeout skips every `defer`, and the documented recovery
// (uninstall) deletes every un-exported child. Test-side save/restore can
// never be complete, so the fix is at the process boundary instead.
//
// When the process is hosting XCTest — the same `XCTestCase` check
// `MainEntryPoint` already uses to start the empty `TestApp` — the
// `+[NSUserDefaults standardUserDefaults]` class getter is exchanged for
// one that returns a separate suite, wiped at launch. Every read and
// write any test (or code under test) makes through `UserDefaults.standard`
// then lands in that suite; the app's own domain is never touched.
//
// Not reached by the pilot: the shipped app never loads XCTest, and an
// app launched by a UI test does not host it either (the runner is a
// separate process), so `installIfHostingTests()` is a no-op there.
// Application Support is NOT redirected: the study stores are stubbed in
// the test fixture (`TracingDependencies.stub`) and the store tests use
// temporary directories.

import Foundation
import ObjectiveC

nonisolated public enum HostedTestIsolation {
    /// The preferences domain the hosted tests read and write instead of
    /// the app's own.
    public static let suiteName = "de.flamingistan.primae.hosted-tests"

    nonisolated(unsafe) private static var installed = false

    /// Whether `UserDefaults.standard` has been redirected in this process.
    public static var isActive: Bool { installed }

    /// Redirects `UserDefaults.standard` to `suiteName` when this process
    /// hosts XCTest; does nothing otherwise. Call first thing in `main`,
    /// before any code reads a default. Idempotent.
    public static func installIfHostingTests() {
        guard !installed, NSClassFromString("XCTestCase") != nil else { return }
        // A clean domain per run, like a fresh CI simulator.
        UserDefaults().removePersistentDomain(forName: suiteName)
        guard let original = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.standard)),
              let replacement = class_getClassMethod(UserDefaults.self, #selector(getter: UserDefaults.primaeHostedTestStandard))
        else { return }
        method_exchangeImplementations(original, replacement)
        installed = true
    }
}

extension UserDefaults {
    nonisolated(unsafe) fileprivate static let primaeHostedTestSuite =
        UserDefaults(suiteName: HostedTestIsolation.suiteName) ?? UserDefaults()

    /// After the exchange this body answers `UserDefaults.standard`.
    @objc nonisolated fileprivate class var primaeHostedTestStandard: UserDefaults {
        primaeHostedTestSuite
    }
}
