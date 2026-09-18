// RepositoryEnumerationCostTests.swift
// PrimaeNativeTests
//
// The load is O(files), NOT O(files × letters).
//
// WHY THIS FILE EXISTS. Reported from the device 2026-09-18: "the app takes
// really long to load". Cause, measured in `LetterRepository`: the letter
// loop calls `findAudioAssets(for:)` once per letter, and that function
// called `resources.allResourceURLs()` ITSELF. That enumeration walks BOTH
// search bundles and does, PER FILE, a `resourceValues(forKeys:)` stat and a
// `resolvingSymlinksInPath()` — two filesystem operations each. With 157
// files in the shipped resource tree and ~59 letters, the load was on the
// order of `59 × 157 × 2 bundles × 2 calls` ≈ 37,000 filesystem operations,
// for a value that cannot change during a load.
//
// The fix hoists the enumeration to once per load. **This test pins the
// hoist, not the speed** — a timing assertion would be flaky on a loaded
// machine and would silently pass on a fast one. Counting the CALLS is the
// property that actually distinguishes the two implementations: it is
// exact, machine-independent, and it fails the moment someone re-derives
// the list inside the loop.
//
// It would have failed before the fix: the count was one per letter.

import Testing
import Foundation
@testable import PrimaeNative

/// Wraps a fixture tree and counts how many times the bundle is enumerated.
/// `allResourceURLs()` is the expensive call — everything else in the
/// protocol is a dictionary lookup or a path join.
private final class CountingResourceProvider: LetterResourceProviding {
    let bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    private let root: URL

    /// Counts calls that actually walked the filesystem. Set before the
    /// load under test and read after it.
    private(set) var enumerationCount = 0

    init(root: URL) { self.root = root }

    func allResourceURLs() -> [URL] {
        enumerationCount += 1
        guard let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return e.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func resourceURL(for relativePath: String) -> URL? {
        let url = root.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

@Suite struct RepositoryEnumerationCostTests {

    /// Eight letters, each with a `strokes.json` and an audio file — enough
    /// that a per-letter enumeration would be unmistakable, small enough
    /// that the test is instant.
    private static func makeRoot(letterCount: Int = 8) -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnumCost-\(UUID().uuidString)", isDirectory: true)
        for i in 0..<letterCount {
            let name = String(UnicodeScalar(65 + i)!)          // A, B, C, …
            let dir = root.appendingPathComponent("Letters/Regular/\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let json: [String: Any] = [
                "letter": name,
                "checkpointRadius": 0.1,
                "strokes": [["id": 1, "checkpoints": [["x": 0.1, "y": 0.5], ["x": 0.9, "y": 0.5]]]]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? data.write(to: dir.appendingPathComponent("strokes.json"))
            }
            try? Data().write(to: dir.appendingPathComponent("\(name).mp3"))
        }
        return root
    }

    /// THE CLAIM: the bundle is walked a CONSTANT number of times, however
    /// many letters are loaded.
    @Test("the bundle is enumerated once per load, not once per letter")
    func enumerationIsNotPerLetter() {
        let provider = CountingResourceProvider(root: Self.makeRoot(letterCount: 8))
        let repo = LetterRepository(resources: provider, cache: NullLetterCache())

        guard case .success(let letters) = repo.loadBundledLettersOnly() else {
            Issue.record("the fixture bundle failed to load — the assertion below would be vacuous")
            return
        }
        #expect(letters.count == 8, "expected 8 fixture letters, got \(letters.map(\.name))")

        // The load must have consulted the bundle, or this test proves
        // nothing about a load that skipped it.
        #expect(provider.enumerationCount >= 1,
                "the load never enumerated the bundle — the fixture is not exercising the path under test")

        // THE REGRESSION GUARD. Before the fix this was one call PER
        // LETTER, so it would have been >= 8 here. Constant, not linear.
        #expect(provider.enumerationCount <= 2,
                "the bundle was enumerated \(provider.enumerationCount) times for \(letters.count) letters — the per-letter re-derivation is back, and the load is quadratic in files × letters again")
    }

    /// And the guard scales: ten times the letters must not mean ten times
    /// the enumerations.
    @Test("enumerations do not grow with the letter count")
    func enumerationDoesNotScaleWithLetters() {
        let small = CountingResourceProvider(root: Self.makeRoot(letterCount: 4))
        let large = CountingResourceProvider(root: Self.makeRoot(letterCount: 12))

        _ = LetterRepository(resources: small, cache: NullLetterCache()).loadBundledLettersOnly()
        _ = LetterRepository(resources: large, cache: NullLetterCache()).loadBundledLettersOnly()

        #expect(small.enumerationCount == large.enumerationCount,
                "4 letters enumerated the bundle \(small.enumerationCount)× and 12 letters \(large.enumerationCount)× — the count tracks the letter count, which is the quadratic load")
    }
}
