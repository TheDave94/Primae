// FontRegistrationGateTests.swift — audit R-099.
//
// `PrimaeFonts` registered its faces with `CTFontManagerRegisterFontsForURLs`
// (deprecated since iOS 13). The replacement, `CTFontManagerRegisterFontURLs`,
// is asynchronous: it reports completion through a handler (`done == true`),
// and a glyph resolved before that point silently falls back to the system
// font. So the move is only safe if the registration is a GATE — nothing
// proceeds until `done` — and these tests pin the gate, not the CoreText call.
//
// Every test except the last builds its OWN `PrimaeFonts.Gate` with a fake
// registrar, so none of them touches the process-wide registration or any other
// global (suites run in parallel). The last one drives the real CoreText path
// through the shared `PrimaeFonts.registerAll()`, which is idempotent and is
// what `FontNameResolutionTests` already does.

import Testing
import SwiftUI
import UIKit
import CoreText
import os
@testable import PrimaeNative

/// A registrar the test drives by hand: it records every call, hands the
/// handler back, and delivers nothing until the test says so.
private final class ManualRegistrar: @unchecked Sendable {
    typealias Handler = @Sendable ([CFError], Bool) -> Bool
    private let state = OSAllocatedUnfairLock(initialState: State())
    struct State {
        var calls: [[URL]] = []
        var handler: Handler?
    }

    var calls: [[URL]] { state.withLock { $0.calls } }

    var registrar: PrimaeFonts.Registrar {
        { [self] urls, handler in
            state.withLock {
                $0.calls.append(urls)
                $0.handler = handler
            }
        }
    }

    /// Deliver one handler call exactly as CoreText would.
    @discardableResult
    func deliver(errors: [CFError] = [], done: Bool) -> Bool? {
        let handler = state.withLock { $0.handler }
        return handler?(errors, done)
    }
}

private func fontError(code: Int) -> CFError {
    CFErrorCreate(nil, kCTFontManagerErrorDomain, code, nil)
}

private let twoURLs = [URL(fileURLWithPath: "/fake/A.otf"), URL(fileURLWithPath: "/fake/B.otf")]

/// The timeout for every test that pins ORDER, not the timeout. The timeout
/// timer runs on a global queue, but these tests deliver from the MainActor, and
/// in the full suite on the iPad the MainActor was busy for minutes at a time:
/// with the 10 s default, all four ordering tests came back `.timedOut`
/// (measured 2026-11-24, 1942 tests in 259 suites). A day cannot race a
/// starved MainActor; `neverDoneTimesOut` owns the timeout itself.
private let orderingOnlyTimeout: TimeInterval = 24 * 60 * 60

@Suite @MainActor struct FontRegistrationGateTests {

    @Test("the gate stays closed until CoreText says done, however often it reports progress")
    func gateWaitsForDone() async {
        let manual = ManualRegistrar()
        let gate = PrimaeFonts.Gate(urls: { twoURLs }, registrar: manual.registrar,
                                   timeout: orderingOnlyTimeout)
        let finished = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task { @MainActor in
            _ = await gate.ready()
            finished.withLock { $0 = true }
        }
        // Let the registrar be called, then report progress (done == false).
        while manual.calls.isEmpty { await Task.yield() }
        manual.deliver(errors: [], done: false)
        manual.deliver(errors: [], done: false)
        for _ in 0..<50 { await Task.yield() }
        #expect(!finished.withLock { $0 }, "the gate opened on a progress callback, before done == true")

        manual.deliver(errors: [], done: true)
        await waiter.value
        #expect(finished.withLock { $0 })
    }

    @Test("every resolved URL goes through the seam exactly once, however many callers wait")
    func registersOnceThroughTheSeam() async {
        let manual = ManualRegistrar()
        let gate = PrimaeFonts.Gate(urls: { twoURLs }, registrar: manual.registrar,
                                   timeout: orderingOnlyTimeout)
        async let first = gate.ready()
        async let second = gate.ready()
        while manual.calls.isEmpty { await Task.yield() }
        manual.deliver(done: true)
        let (a, b) = await (first, second)
        #expect(a == .completed(errorCodes: []))
        #expect(b == a)
        #expect(manual.calls == [twoURLs], "one registration, with all URLs, through the injected registrar")
        // A later call is already open and does not register again.
        let again = await gate.ready()
        #expect(again == .completed(errorCodes: []))
        #expect(manual.calls.count == 1)
    }

    @Test("a registration error is reported, never fatal; already-registered (105) is ignored")
    func errorsAreReportedNotFatal() async {
        let manual = ManualRegistrar()
        let gate = PrimaeFonts.Gate(urls: { twoURLs }, registrar: manual.registrar,
                                   timeout: orderingOnlyTimeout)
        async let outcome = gate.ready()
        while manual.calls.isEmpty { await Task.yield() }
        let keepGoing = manual.deliver(
            errors: [fontError(code: 105), fontError(code: 104)], done: false)
        #expect(keepGoing == true, "the handler must keep registering the rest after an error")
        manual.deliver(errors: [], done: true)
        #expect(await outcome == .completed(errorCodes: [104]))
    }

    @Test("a registration that never reports done times out instead of blanking the app")
    func neverDoneTimesOut() async {
        let manual = ManualRegistrar()
        let gate = PrimaeFonts.Gate(urls: { twoURLs }, registrar: manual.registrar, timeout: 0.05)
        #expect(await gate.ready() == .timedOut)
        // A late `done` after the timeout is harmless (no double resume).
        manual.deliver(done: true)
    }

    @Test("no resolvable URL registers nothing and stays retryable")
    func noFontsStaysRetryable() async {
        let manual = ManualRegistrar()
        let available = OSAllocatedUnfairLock(initialState: false)
        let gate = PrimaeFonts.Gate(
            urls: { available.withLock { $0 } ? twoURLs : [] }, registrar: manual.registrar,
            timeout: orderingOnlyTimeout)
        #expect(await gate.ready() == .noFontsResolved)
        #expect(manual.calls.isEmpty, "the registrar must not be called with an empty list")

        available.withLock { $0 = true }
        async let outcome = gate.ready()
        while manual.calls.isEmpty { await Task.yield() }
        manual.deliver(done: true)
        #expect(await outcome == .completed(errorCodes: []))
    }

    @Test("after the real gate, the Primae, PrimaeText and Playwrite families resolve")
    func familiesResolveAfterTheGate() async {
        await PrimaeFonts.registerAll()
        let names = [
            primaePostScriptName(for: .regular, italic: false),
            primaePostScriptName(for: .bold, italic: false),
            primaeTextPostScriptName(for: .regular, italic: false),
            "PlaywriteAT-Regular",
        ]
        for name in names {
            #expect(UIFont(name: name, size: 17) != nil, "\(name) did not resolve after registerAll() returned")
        }
        // The gate is idempotent: a second await returns immediately, and the
        // faces are still there.
        await PrimaeFonts.registerAll()
        #expect(UIFont(name: names[0], size: 17) != nil)
    }
}
