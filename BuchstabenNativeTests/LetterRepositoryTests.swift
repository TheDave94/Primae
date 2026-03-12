//  LetterRepositoryTests.swift
//  BuchstabenNativeTests
//
//  Unit tests for LetterRepository using a mock resource provider.
//  No bundle I/O — all assets are injected via MockResourceProvider.

import XCTest
@testable import BuchstabenNative

// MARK: - NullLetterCache (empty, never persists — isolates tests from real cache)

private struct NullLetterCache: LetterCacheStoring {
    func save(_ letters: [LetterAsset]) throws { /* no-op */ }
    func load() throws -> [LetterAsset] { [] }
    func clear() { /* no-op */ }
}

// MARK: - MockResourceProvider

private final class MockResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    /// Map from filename → URL (file:///mock/<filename>)
    private var resources: [String: URL] = [:]

    func add(_ filename: String) {
        resources[filename] = URL(string: "file:///mock/\(filename)")!
    }

    func allResourceURLs() -> [URL] { Array(resources.values) }

    func resourceURL(for relativePath: String) -> URL? {
        let key = (relativePath as NSString).lastPathComponent
        return resources[key]
    }
}

// MARK: - Helpers

private func makeJSON(letter: String, radius: Double = 0.06) -> Data {
    let json = """
    {
      "letter": "\(letter)",
      "checkpointRadius": \(radius),
      "strokes": [
        { "id": 1, "checkpoints": [{"x": 0.3, "y": 0.8}, {"x": 0.7, "y": 0.2}] }
      ]
    }
    """
    return json.data(using: .utf8)!
}

private extension MockResourceProvider {
    /// Add a complete valid letter: JSON, PBM, and one MP3.
    func addLetter(_ base: String) {
        let jsonName = "\(base)_strokes.json"
        let mp3Name  = "\(base)/\(base)1.mp3"
        let pbmName  = "\(base).pbm"
        // JSON URL with data embedded isn't possible via URL alone — we use a file path
        // instead and rely on LetterRepository reading Data(contentsOf:).
        // For test isolation we write temp files.
        let tmp = FileManager.default.temporaryDirectory
        let jsonURL = tmp.appendingPathComponent(jsonName)
        try? makeJSON(letter: base).write(to: jsonURL)
        resources[jsonName] = jsonURL

        // PBM and audio just need to be resolvable via resourceURL
        add(pbmName)
        // Audio: use the folder/file format LetterRepository expects
        let audioURL = URL(string: "file:///mock/\(mp3Name)")!
        resources["\(base)1.mp3"] = audioURL
        // also add by path so findAudioAssets resolves the "/base/" marker
        let pathURL = URL(fileURLWithPath: "/mock/\(base)/\(base)1.mp3")
        resources["\(base)/\(base)1.mp3"] = pathURL
    }
}

// MARK: - LetterRepositoryTests

@MainActor
final class LetterRepositoryTests: XCTestCase {

    // MARK: 1 — Empty provider returns fallback (non-empty, non-crash)

    func testEmptyProvider_returnsFallbackLetter() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let letters = repo.loadLetters()
        XCTAssertFalse(letters.isEmpty, "loadLetters() must never return empty — fallback expected")
        XCTAssertEqual(letters.first?.id, "A", "Fallback must be letter A")
    }

    // MARK: 2 — Fallback letter has required fields populated

    func testFallbackLetter_hasRequiredFields() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let letter = repo.loadLetters().first!
        XCTAssertFalse(letter.name.isEmpty, "name must not be empty")
        XCTAssertFalse(letter.audioFiles.isEmpty, "audioFiles must not be empty")
        XCTAssertFalse(letter.imageName.isEmpty, "imageName must not be empty")
    }

    // MARK: 3 — Stroke JSON with invalid data is skipped (no crash)

    func testInvalidJSON_isSkipped_returnsAtLeastFallback() {
        let provider = MockResourceProvider()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bad_strokes.json")
        try? "not json at all {{{{".data(using: .utf8)?.write(to: tmp)
        // Inject bad JSON as if it were a stroke file
        // We can't directly set the internal map key with a URL so we use
        // allResourceURLs to return the bad file path.
        // Since MockResourceProvider is file-based, add directly:
        class BadProvider: LetterResourceProviding {
            var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
            let badURL: URL
            init(url: URL) { badURL = url }
            func allResourceURLs() -> [URL] { [badURL] }
            func resourceURL(for relativePath: String) -> URL? { nil }
        }
        let badURL = FileManager.default.temporaryDirectory.appendingPathComponent("X_strokes.json")
        try? "{{invalid}}".data(using: .utf8)?.write(to: badURL)
        let repo = LetterRepository(resources: BadProvider(url: badURL), cache: NullLetterCache())
        let letters = repo.loadLetters()
        // Should fall through to fallback — must not crash and must return something
        XCTAssertFalse(letters.isEmpty)
    }

    // MARK: 4 — LetterAsset names are non-empty strings

    func testLetterAsset_names_areNonEmpty() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            XCTAssertFalse(letter.name.isEmpty, "Every LetterAsset must have a non-empty name")
        }
    }

    // MARK: 5 — LetterAsset audioFiles are non-empty

    func testLetterAsset_audioFiles_areNonEmpty() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            XCTAssertFalse(letter.audioFiles.isEmpty,
                           "Every LetterAsset must have at least one audio file (letter: \(letter.name))")
        }
    }

    // MARK: 6 — Default strokes checkpoints are in normalized [0,1] range

    func testDefaultStrokes_checkpoints_areNormalized() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            for stroke in letter.strokes.strokes {
                for cp in stroke.checkpoints {
                    XCTAssertGreaterThanOrEqual(cp.x, 0.0, "Checkpoint x must be >= 0")
                    XCTAssertLessThanOrEqual(cp.x,    1.0, "Checkpoint x must be <= 1")
                    XCTAssertGreaterThanOrEqual(cp.y, 0.0, "Checkpoint y must be >= 0")
                    XCTAssertLessThanOrEqual(cp.y,    1.0, "Checkpoint y must be <= 1")
                }
            }
        }
    }

    // MARK: 7 — checkpointRadius is positive

    func testDefaultStrokes_checkpointRadius_isPositive() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            XCTAssertGreaterThan(letter.strokes.checkpointRadius, 0.0,
                                 "checkpointRadius must be > 0 (letter: \(letter.name))")
        }
    }

    // MARK: 8 — No duplicate letter ids in result

    func testLoadLetters_noDuplicateIds() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let ids = repo.loadLetters().map(\.id)
        let unique = Set(ids)
        XCTAssertEqual(ids.count, unique.count, "loadLetters() must not return duplicate ids")
    }

    // MARK: 9 — loadLetters is idempotent (same result on two calls)

    func testLoadLetters_isIdempotent() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let first  = repo.loadLetters()
        let second = repo.loadLetters()
        XCTAssertEqual(first, second, "loadLetters() must return the same result on repeated calls")
    }

    // MARK: 10 — LetterAsset conforms to Equatable

    func testLetterAsset_equatable() {
        let a = LetterAsset(id: "A", name: "A", imageName: "A.pbm",
                            audioFiles: ["A.mp3"], strokes: LetterStrokes(letter: "A", checkpointRadius: 0.06, strokes: []))
        let b = LetterAsset(id: "A", name: "A", imageName: "A.pbm",
                            audioFiles: ["A.mp3"], strokes: LetterStrokes(letter: "A", checkpointRadius: 0.06, strokes: []))
        XCTAssertEqual(a, b)
    }
}
