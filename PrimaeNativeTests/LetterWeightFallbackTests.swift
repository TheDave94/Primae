// LetterWeightFallbackTests.swift
// PrimaeNativeTests
//
// The Light→Regular polyline fallback in `LetterRepository`.
//
// WHY THIS FILE EXISTS. `Letters/Light/` ships 29 files against
// `Regular`'s 87, so the bundle is deliberately partial and
// `loadBundledStrokeLettersWithValidation` splices in the Regular polyline
// for every letter the active weight lacks — "letters whose Light spec
// isn't tuned fall back silently to the Regular polyline". Until this file,
// `grep` for `activeWeight`, `fallbackWeight` or `isInOtherWeight` across
// both test targets returned ZERO. The fallback is silent by design, and
// its failure mode is a study-corrupting mismatch rather than a crash: the
// ghost is drawn with the ACTIVE weight's font while the traced and scored
// checkpoints come from whichever polyline won the splice, so a wrong
// splice puts the reference in one place and the letter in another.
//
// The default weight is `.regular`, at which the fallback branch is not
// taken at all — which is why this could sit untested without any pilot
// symptom. It is reachable, and it was reachable on this device's own
// history: `de.flamingistan.primae.fontWeight` is read straight from
// UserDefaults and nothing in the UI writes it, but a launch argument or an
// older build can.

import Testing
import Foundation
@testable import PrimaeNative

/// Serves letters from a temporary tree whose weight subtrees we choose, so
/// the splice can be driven without depending on which letters the shipped
/// Light bundle happens to contain today.
private final class TwoWeightProvider: LetterResourceProviding {
    let bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    private let root: URL

    init(root: URL) { self.root = root }

    func allResourceURLs() -> [URL] {
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

@Suite struct LetterWeightFallbackTests {

    /// A one-stroke letter whose LAST checkpoint differs per weight, so a
    /// test can tell from the loaded geometry which polyline won.
    private static func writeLetter(_ dir: URL, endX: Double) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "letter": dir.lastPathComponent,
            "checkpointRadius": 0.1,
            "strokes": [[
                "id": 1,
                "checkpoints": [["x": 0.10, "y": 0.50],
                                ["x": 0.50, "y": 0.50],
                                ["x": endX, "y": 0.50]]
            ]]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("strokes.json"))
        }
    }

    /// A tree with: A in BOTH weights, B in Regular only. `lightEnd` and
    /// `regularEnd` are the last checkpoint's x, so a loaded letter says
    /// which subtree it came from.
    private static func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeightFallback-\(UUID().uuidString)", isDirectory: true)
        writeLetter(root.appendingPathComponent("Letters/Light/A"),   endX: 0.60)
        writeLetter(root.appendingPathComponent("Letters/Regular/A"), endX: 0.90)
        writeLetter(root.appendingPathComponent("Letters/Regular/B"), endX: 0.70)
        return root
    }

    /// Injects the weight through `LetterRepository`'s seam. The first
    /// version wrote the global `de.flamingistan.primae.fontWeight` default
    /// instead, which under Swift Testing's PARALLEL execution made every
    /// concurrently-running test load the wrong weight — it broke
    /// `StrokeGeometryGoldenTests`, whose golden read Light geometry while
    /// this suite had the key flipped. A test must not reach outside itself.
    private func loadLetters(weight: FontWeight) -> [LetterAsset] {
        let repo = LetterRepository(resources: TwoWeightProvider(root: Self.makeRoot()),
                                    cache: NullLetterCache(),
                                    weight: weight)
        guard case .success(let letters) = repo.loadBundledLettersOnly() else { return [] }
        return letters
    }

    private func lastX(_ asset: LetterAsset) -> Double? {
        guard let cp = asset.strokes.strokes.last?.checkpoints.last else { return nil }
        return Double(cp.x)
    }

    @Test("with Regular active, no fallback branch is taken")
    func regularActive_usesRegularForEverything() {
        let letters = loadLetters(weight: .regular)
        #expect(letters.count == 2, "expected A and B, got \(letters.map(\.name))")
        #expect(lastX(letters.first { $0.name == "A" }!) == 0.90, "A must come from Regular")
        #expect(lastX(letters.first { $0.name == "B" }!) == 0.70, "B must come from Regular")
    }

    @Test("with Light active, a letter present in Light uses the Light polyline")
    func lightActive_prefersLight() {
        let letters = loadLetters(weight: .light)
        let a = letters.first { $0.name == "A" }
        #expect(a != nil, "A missing with Light active — got \(letters.map(\.name))")
        #expect(lastX(a!) == 0.60,
                "A came from Regular while Light is active — the active weight must win wherever it has the letter")
    }

    @Test("with Light active, a letter Light lacks falls back to the Regular polyline")
    func lightActive_fallsBackForMissingLetters() {
        let letters = loadLetters(weight: .light)
        let b = letters.first { $0.name == "B" }
        #expect(b != nil,
                "B vanished with Light active — the fallback did not splice it in, so a partial weight bundle would ship a MISSING LETTER rather than a mismatched one")
        #expect(lastX(b!) == 0.70, "B must carry the Regular polyline")
    }

    /// The invariant the fallback exists to preserve: with a partial active
    /// weight, the letter SET is the same as Regular's. A missing letter is
    /// the loud failure; a mismatched one is the quiet one.
    @Test("the letter set is identical whichever weight is active")
    func letterSetIsWeightIndependent() {
        let regular = Set(loadLetters(weight: .regular).map(\.name))
        let light   = Set(loadLetters(weight: .light).map(\.name))
        #expect(regular == light,
                "the active weight changed WHICH letters exist: Regular=\(regular.sorted()) Light=\(light.sorted()). A partial weight must not remove letters.")
    }
}
