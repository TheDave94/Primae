// FontRegistration.swift
// PrimaeNative — Theme
//
// Register the bundled Primae / PrimaeText / Playwrite AT fonts with
// CoreText. The fonts ship inside the SPM resource bundle, which
// `UIAppFonts` cannot reach, so resolution goes through `PrimaeBundle`
// (its `.main` probe additionally covers any host copy) and we register
// programmatically with `CTFontManagerRegisterFontURLs` (the non-deprecated,
// asynchronous replacement for `CTFontManagerRegisterFontsForURLs`, R-099).
//
// THE GATE (R-099). The new API reports completion through a handler
// (`done == true`), and a face resolved before that point silently falls back
// to the system font. So registration is a gate, not a fire-and-forget call:
// `await PrimaeFonts.registerAll()` returns only once CoreText says done (or a
// bounded timeout passes, so a handler that never reports cannot blank the
// app), and the host mounts its first view only after that await returns
// (`PrimaeApp`). Idempotent; concurrent callers share one registration.
//
// What the gate does NOT cover: `PrimaeLetterRenderer` / `GlyphSkeleton` load
// glyph outlines straight from the font file (`CGDataProvider` +
// `CGFont`), not by name, so the traced letter never depended on CoreText
// registration. Only `Font.custom` / `UIFont(name:)` — the UI text — does.

import CoreText
import Foundation
import os
import os.log

public enum PrimaeFonts {

    /// Bundled font filenames (no extension). Keep in sync with the
    /// files in `PrimaeNative/Resources/Fonts/` and
    /// `INFOPLIST_KEY_UIAppFonts` in `Primae.xcodeproj`.
    /// `internal`, not `private`: `ResourceResolutionTests` asserts every
    /// entry resolves. A test with its own copy of this list proves the
    /// copy, not the app.
    static let registrations: [(name: String, ext: String)] = [
        ("Primae-Light",                "otf"),
        ("Primae-LightCursive",         "otf"),
        ("Primae-Semilight",            "otf"),
        ("Primae-SemilightCursive",     "otf"),
        ("Primae-Regular",              "otf"),
        ("Primae-Cursive",              "otf"),
        ("Primae-Semibold",             "otf"),
        ("Primae-SemiboldCursive",      "otf"),
        ("Primae-Bold",                 "otf"),
        ("Primae-BoldCursive",          "otf"),
        ("PrimaeText-Light",            "otf"),
        ("PrimaeText-LightCursive",     "otf"),
        ("PrimaeText-Semilight",        "otf"),
        ("PrimaeText-SemilightCursive", "otf"),
        ("PrimaeText-Regular",          "otf"),
        ("PrimaeText-Cursive",          "otf"),
        ("PrimaeText-Semibold",         "otf"),
        ("PrimaeText-SemiboldCursive",  "otf"),
        ("PrimaeText-Bold",             "otf"),
        ("PrimaeText-BoldCursive",      "otf"),
        ("PlaywriteAT-Regular",         "ttf"),
    ]

    private static let log = Logger(subsystem: "buchstaben.primae", category: "fonts")

    /// `kCTFontManagerErrorAlreadyRegistered` — expected on a repeat
    /// registration; never reported as a failure.
    nonisolated private static let alreadyRegisteredCode = 105

    /// How a registration ended.
    nonisolated enum Outcome: Equatable, Sendable {
        /// No face resolved from the bundle; nothing was registered and the
        /// gate stays retryable (class two: running on the system font).
        case noFontsResolved
        /// CoreText reported `done`. `errorCodes` are the failures (not
        /// already-registered) it reported along the way; empty on success.
        case completed(errorCodes: [Int])
        /// CoreText never reported `done` within the timeout.
        case timedOut
    }

    /// The seam: register `urls` and report through `handler` exactly as
    /// `CTFontManagerRegisterFontURLs` does. The handler may be called more
    /// than once; `done == true` ends the registration; returning `false`
    /// asks CoreText to stop. Tests inject their own; production uses
    /// `coreTextRegistrar`.
    typealias Registrar = @Sendable (
        _ urls: [URL],
        _ handler: @escaping @Sendable (_ errors: [CFError], _ done: Bool) -> Bool
    ) -> Void

    /// The real registrar. `nonisolated`: CoreText calls the handler on an
    /// arbitrary queue, and a MainActor-isolated closure would trap there.
    nonisolated static let coreTextRegistrar: Registrar = { urls, handler in
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true) { errors, done in
            handler((errors as? [CFError]) ?? [], done)
        }
    }

    /// Mutable state of one in-flight registration.
    private nonisolated struct Pending: Sendable {
        var continuation: CheckedContinuation<Outcome, Never>?
        var errorCodes: [Int] = []
    }

    /// Register `urls` through `registrar` and suspend until it reports
    /// `done` (or `timeout` seconds pass). Resumes exactly once.
    nonisolated static func register(_ urls: [URL],
                                     using registrar: Registrar,
                                     timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let pending = OSAllocatedUnfairLock(initialState: Pending(continuation: continuation))

            @Sendable func finish(_ makeOutcome: @Sendable ([Int]) -> Outcome) {
                let taken = pending.withLock { state -> (CheckedContinuation<Outcome, Never>, [Int])? in
                    guard let c = state.continuation else { return nil }
                    state.continuation = nil
                    return (c, state.errorCodes)
                }
                if let (c, codes) = taken { c.resume(returning: makeOutcome(codes)) }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish { _ in .timedOut }
            }
            registrar(urls) { errors, done in
                let codes = errors.map { CFErrorGetCode($0) }.filter { $0 != alreadyRegisteredCode }
                pending.withLock { $0.errorCodes.append(contentsOf: codes) }
                if done { finish { .completed(errorCodes: $0) } }
                // Keep going after an error: register every face we can,
                // like the synchronous call did.
                return true
            }
        }
    }

    /// The gate callers await. One per registration seam; the app uses
    /// `PrimaeFonts.shared`.
    final class Gate {
        private let urls: () -> [URL]
        private let registrar: Registrar
        private let timeout: TimeInterval
        private var inFlight: Task<Outcome, Never>?
        private var latched: Outcome?

        init(urls: @escaping () -> [URL] = { PrimaeFonts.fontURLs() },
             registrar: @escaping Registrar = PrimaeFonts.coreTextRegistrar,
             timeout: TimeInterval = 10) {
            self.urls = urls
            self.registrar = registrar
            self.timeout = timeout
        }

        /// Suspends until the faces are registered; every caller after the
        /// first gets the same outcome without registering again. Not latched
        /// when nothing resolved, so a later call can still succeed.
        @discardableResult
        func ready() async -> Outcome {
            if let latched { return latched }
            if let inFlight { return await inFlight.value }

            // Resolution goes through `PrimaeBundle`, whose `.main` probe covers
            // the host's `INFOPLIST_KEY_UIAppFonts` copies. Previously this used
            // `Bundle.module`, which calls `fatalError` when it cannot resolve
            // (`cb7291d`), behind a `urls.isEmpty` warning that degraded the whole
            // type system to the system font with nothing failing.
            let resolved = urls()
            guard !resolved.isEmpty else {
                PrimaeFonts.log.warning("PrimaeFonts.registerAll: no font URLs resolved — Resources/Fonts/ may be missing from the bundle.")
                return .noFontsResolved
            }

            let registrar = self.registrar
            let timeout = self.timeout
            let task = Task { await PrimaeFonts.register(resolved, using: registrar, timeout: timeout) }
            inFlight = task
            let outcome = await task.value
            inFlight = nil
            latched = outcome

            switch outcome {
            case .completed(let codes) where !codes.isEmpty:
                PrimaeFonts.log.error("PrimaeFonts: register failed codes=\(codes)")
            case .timedOut:
                PrimaeFonts.log.error("PrimaeFonts: registration did not report completion within \(self.timeout)s; continuing")
            default:
                break
            }
            return outcome
        }
    }

    /// The process-wide gate behind `registerAll()`.
    static let shared = Gate()

    /// The URL of every registered face that resolves, through
    /// `PrimaeBundle`. `roots:` is the seam `ResourceResolutionTests` uses
    /// to take the package bundle away and see what registration gets.
    static func fontURLs(roots: [URL] = PrimaeBundle.searchRoots) -> [URL] {
        registrations.compactMap { name, ext in
            PrimaeBundle.resourceURL(
                firstOf: PrimaeBundle.layouts(dir: "Fonts", name: name, ext: ext), roots: roots)
        }
    }

    /// Register every bundled face and suspend until CoreText reports it
    /// done. Safe to call repeatedly and concurrently. Await it before the
    /// first view that uses `Font.display` / `.body` / `.cursive` is mounted.
    public static func registerAll() async {
        await shared.ready()
    }
}
