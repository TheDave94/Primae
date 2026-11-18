// RepositorySkeletonDecodeTests.swift
// PrimaeNativeTests
//
// Audit R-082: the launch-time repository load decoded the calibrator's
// baked `skeleton`, `skeletonAdj` and `bridgeEdges` payloads for every
// letter — about a third of the shipped stroke JSON (1.67 MB of 5.0 MB in
// the Regular tree) — and nothing in a study build ever reads them: the
// only reader, `StrokeCalibrationOverlay.makeBakedSkeleton`, is compiled out
// under `STUDY_BUILD`, and the view-model's glyph-relative mapping rebuilds
// `LetterStrokes` without them.
//
// WHAT THIS PINS, and what it cannot. It pins WHICH payload the load
// materialises, through the repository's own seam, by counting what comes
// out of a fixture bundle. It does NOT measure wall-clock `repoLoad`: that
// needs the physical iPad, which this change was written without. The
// decoded-array count is exact and machine-independent; a time assertion
// would be neither.

import Testing
import Foundation
@testable import PrimaeNative

/// A fixture bundle whose stroke files carry a real-shaped skeleton payload.
private final class SkeletonFixtureProvider: LetterResourceProviding {
    let bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    let root: URL

    static let letters = ["A", "B", "C"]
    static let skeletonPointCount = 200

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkeletonDecode-\(UUID().uuidString)", isDirectory: true)
        for name in Self.letters {
            let dir = root.appendingPathComponent("Letters/Regular/\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let n = Self.skeletonPointCount
            let json: [String: Any] = [
                "letter": name,
                "checkpointRadius": 0.1,
                "strokes": [["id": 1, "checkpoints": [["x": 0.1, "y": 0.5], ["x": 0.9, "y": 0.5]]]],
                "skeleton": (0..<n).map { ["x": Double($0) / Double(n), "y": 0.5] },
                "skeletonAdj": (0..<n).map { i in [max(0, i - 1), min(n - 1, i + 1)] },
                "bridgeEdges": [[0, 5], [10, 20]]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: json) {
                try? data.write(to: dir.appendingPathComponent("strokes.json"))
            }
            try? Data().write(to: dir.appendingPathComponent("\(name).mp3"))
        }
    }

    /// Counts full-bundle enumerations (R-082's other half).
    nonisolated(unsafe) var enumerationCount = 0

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

@Suite struct RepositorySkeletonDecodeTests {

    /// THE CLAIM: a default load (study build) does not materialise the
    /// calibrator payload, and loses nothing the app reads.
    @Test("the default bundle load does not decode the skeleton payload")
    func defaultLoadSkipsSkeleton() {
        let provider = SkeletonFixtureProvider()
        let repo = LetterRepository(resources: provider, cache: NullLetterCache(), weight: .regular)

        guard case .success(let letters) = repo.loadBundledLettersOnly() else {
            Issue.record("the fixture bundle failed to load — the assertions below would be vacuous")
            return
        }
        #expect(letters.map(\.name) == SkeletonFixtureProvider.letters,
                "expected the fixture letters, got \(letters.map(\.name))")

        for letter in letters {
            #expect(letter.strokes.skeleton == nil,
                    "\(letter.name): skeleton was decoded (\(letter.strokes.skeleton?.count ?? 0) points) — nothing in a study build reads it")
            #expect(letter.strokes.skeletonAdj == nil, "\(letter.name): skeletonAdj was decoded")
            #expect(letter.strokes.bridgeEdges == nil, "\(letter.name): bridgeEdges was decoded")

            // What the app DOES read is intact.
            #expect(letter.strokes.letter == letter.name)
            #expect(letter.strokes.checkpointRadius == 0.1)
            #expect(letter.strokes.strokes == [
                StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.1, y: 0.5), Checkpoint(x: 0.9, y: 0.5)])
            ])
        }
    }

    /// The load enumerates the bundle ONCE for the whole load, however many
    /// letters it holds (the audit counted ~112 enumerations; the hoist in
    /// `loadBundledStrokeLettersWithValidation` and the per-roots memo in
    /// `BundleLetterResourceProvider` closed that). Counted through the
    /// provider seam, so it is machine-independent.
    @Test("the bundle is enumerated once per load, not once per letter")
    func enumeratesOncePerLoad() {
        let provider = SkeletonFixtureProvider()
        let repo = LetterRepository(resources: provider, cache: NullLetterCache(), weight: .regular)
        guard case .success(let letters) = repo.loadBundledLettersOnly() else {
            Issue.record("the fixture bundle failed to load")
            return
        }
        #expect(letters.count == SkeletonFixtureProvider.letters.count)
        #expect(provider.enumerationCount == 1,
                "allResourceURLs() ran \(provider.enumerationCount) times for \(letters.count) letters")
    }
}
