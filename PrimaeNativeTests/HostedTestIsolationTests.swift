// HostedTestIsolationTests.swift
// PrimaeNativeTests
//
// R-052 (audit 2026-10-13): `PrimaeNativeTests` is hosted in the app
// (`TEST_HOST` = Primae.app), and Debug-Study and Release-Study share the
// bundle id `com.flamingistan.primae.study` — so a device test run used to
// write participant identity, overrides and comparison switches straight
// into the PILOT's own preferences domain. These tests pin that the hosted
// test process now writes `UserDefaults.standard` into a separate,
// throw-away domain, leaving the app's own domain untouched.
//
// Mutation check: remove the `HostedTestIsolation.installIfHostingTests()`
// call from `MainEntryPoint.main()` (Primae/Primae/PrimaeApp.swift) → the test
// goes RED. Run with `-only-testing:PrimaeNativeTests/HostedTestIsolationTests`
// and read "Test run with N tests".

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct HostedTestIsolationTests {

    @Test("a write through UserDefaults.standard does not reach the app's own preferences domain")
    func standardWritesDoNotReachTheAppDomain() throws {
        let key = "de.flamingistan.primae.b2-isolation-probe-\(UUID().uuidString)"
        UserDefaults.standard.set("probe", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(UserDefaults.standard.string(forKey: key) == "probe",
                "precondition: the write is readable back through .standard")
        // `UserDefaults()` is a fresh instance over the APP's own domain —
        // it is not obtained through `+standardUserDefaults`.
        #expect(UserDefaults().object(forKey: key) == nil,
                "a hosted test wrote into the app's preferences domain — on the study iPad that is the pilot's")
    }
}
