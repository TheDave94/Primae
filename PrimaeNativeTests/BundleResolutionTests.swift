// Regression guard for resource-bundle resolution.
//
// Nothing covered this, and the cost was measured rather than guessed:
// `recognition_predicted` was empty in 194 of 194 recognition-bearing
// records across 41 sessions and 7 bundle IDs, 2026-05-06 to 2026-08-16.
// Three exported columns have never carried a value, because the model
// was never found and `recognize(…)` returned nil every time.
//
// The failure was silent by construction: a missing model logs a warning
// and degrades to Fréchet-only scoring, which is the correct runtime
// behaviour and the reason nobody noticed for three months.
//
// These tests fail loudly instead.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct BundleResolutionTests {

    @Test("the module's resource bundle resolves to something other than .main")
    func resourceBundleResolves() {
        #expect(PrimaeBundle.resources != .main,
                "fell back to Bundle.main — the resource bundle was not located, and every bundled resource is now looked up in the wrong place")
    }

    /// Both shipped forms are DIRECTORIES, which is what
    /// `url(forResource:withExtension:)` failed to resolve. Asserting on
    /// the path probe pins the fix rather than the symptom.
    ///
    /// This probes `CoreMLLetterRecognizer.resolveModelURL()` — the SAME
    /// list the loader uses — rather than a path of its own. A test with
    /// its own hard-coded path stays green while the loader fails, which
    /// is precisely how 194 records came back empty under coverage.
    @Test("the CoreML model is present in the resource bundle")
    func modelIsPresent() throws {
        let found = try #require(
            CoreMLLetterRecognizer.resolveModelURL(),
            "GermanLetterRecognizer not found at any probed location — the resource stopped shipping, and recognition is silently disabled")
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: found.url.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue,
                "expected a directory-shaped .mlmodelc/.mlpackage — a file here means the resource rule changed and the probe order should follow")
    }

    /// `.process("MLResources")` exists to ship the COMPILED model.
    /// Under `.copy` the raw `.mlpackage` shipped instead and every cold
    /// load ran `MLModel.compileModel(at:)`, relying on runtime
    /// compilation of an uncompiled package — undocumented behaviour in
    /// the one feature already known to fail silently.
    ///
    /// If this goes red while `modelIsPresent` stays green, the model is
    /// shipping but SwiftPM did not compile it: the `.process` rule is
    /// not doing what it was added for.
    @Test("the shipped model is the compiled form, not a raw .mlpackage")
    func modelShipsCompiled() throws {
        let found = try #require(CoreMLLetterRecognizer.resolveModelURL())
        #expect(found.isCompiled,
                "shipped as \(found.url.lastPathComponent) — expected GermanLetterRecognizer.mlmodelc from the .process rule")
    }

    /// THE guard. `isModelAvailable()` returning false is exactly the
    /// state that produced 194 empty records.
    @Test("the recognizer reports its model available")
    func recognizerFindsItsModel() async {
        let recognizer = CoreMLLetterRecognizer(classifier: { _ in [] })
        #expect(await recognizer.isModelAvailable(),
                "the model did not load — recognition is disabled and recognitionPredicted/Confidence/Correct will export empty")
    }

    /// The letter loader resolved through the one surviving probe of
    /// three, which is an accident rather than a design. Pin it.
    @Test("the real bundle letter provider finds bundled letters")
    func letterProviderFindsLetters() {
        let provider = BundleLetterResourceProvider()
        let urls = provider.allResourceURLs()
        #expect(!urls.isEmpty, "no resources enumerated from the bundle at all")
        #expect(urls.contains { $0.lastPathComponent == "strokes.json" },
                "no strokes.json among \(urls.count) enumerated resources")
    }

    // MARK: - The memoisation cache is lock-protected

    /// STRUCTURAL GUARD, deliberately not behavioural (2026-10-18, #58
    /// follow-up).
    ///
    /// WHY NOT A RACE. `LetterRepository`'s memoisation cache
    /// (`BundleLetterResourceProvider.resourceURLCache`) shipped as
    /// `nonisolated(unsafe) private static var … = [:]` — a shared mutable
    /// Dictionary with no lock. The audit expected the test suites to be
    /// hammering it from several threads; they are not, and cannot. Both
    /// targets set `.defaultIsolation(MainActor.self)` (Package.swift:50,
    /// Package.swift:91) and a witness of the nonisolated
    /// `LetterResourceProviding` protocol is inferred MainActor under that
    /// default, so `allResourceURLs()` — the only door to the cache — is
    /// reachable only ON the main actor. A stress test would therefore be
    /// GREEN with the lock removed: a test that cannot fail, which is worse
    /// than no test.
    ///
    /// What is observable is the shape of the declaration, and that is what
    /// this pins: the cache must be the `Mutex`, and every use of it must go
    /// through `withLock`. Same reasoning, same instrument and the same
    /// visible skip as
    /// `AudioSignalProbeTests.tapIsNotInstalledWithAnInlineClosure`.
    ///
    /// It fails on the declaration this exists to prevent: reverting to an
    /// unlocked `nonisolated(unsafe) … var` turns it RED (mutation-checked
    /// 2026-10-18).
    @Test("the resource-URL cache is never an unlocked static",
          .enabled(if: Self.repositorySourceIsReadable,
                   "LetterRepository.swift is not readable here (#filePath is a Mac path; on the physical iPad the checkout does not exist)"))
    func cacheIsNotAnUnlockedStatic() throws {
        let code = Self.stripComments(
            try String(contentsOf: Self.repositorySourceURL, encoding: .utf8))
        let cacheLines = code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.contains("resourceURLCache") }

        // Not vacuous: the declaration plus its two uses. A rename that made
        // the assertions below vacuous fails HERE instead of passing quietly.
        #expect(cacheLines.count >= 3,
                "expected at least a declaration and two uses of resourceURLCache in LetterRepository.swift, found \(cacheLines.count): \(cacheLines)")

        #expect(!code.contains("nonisolated(unsafe) private static var resourceURLCache"),
                "resourceURLCache is an unsynchronised nonisolated(unsafe) static var again — the shared Dictionary is written with no lock at all")

        #expect(code.contains("private static let resourceURLCache = Mutex<"),
                "resourceURLCache is no longer a Mutex — nothing in the type system protects the shared cache")

        let unlocked = cacheLines.filter {
            !$0.contains("private static let resourceURLCache = Mutex<")
                && !$0.contains(".withLock")
        }
        #expect(unlocked.isEmpty,
                "resourceURLCache is read or written outside the lock: \(unlocked)")
    }

    nonisolated private static var repositorySourceIsReadable: Bool {
        FileManager.default.isReadableFile(atPath: repositorySourceURL.path)
    }

    /// `#filePath` is this test file's absolute path AT COMPILE TIME, so
    /// walking up from it reaches the repo root with no dependence on bundle
    /// layout, build directory shape, or working directory.
    nonisolated private static var repositorySourceURL: URL {
        URL(fileURLWithPath: #filePath)      // …/PrimaeNativeTests/BundleResolutionTests.swift
            .deletingLastPathComponent()      // …/PrimaeNativeTests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("PrimaeNative/Features/Library/LetterRepository.swift")
    }

    /// Remove `//` line comments, so the prohibition does not fire on the
    /// comment that explains it. Deliberately simple (it over-strips "//"
    /// inside a string literal at worst): the assertions target a
    /// declaration and its call shape.
    private static func stripComments(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }
}
