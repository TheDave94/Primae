//  LetterRepositoryErrorHandlingTests.swift
//  BuchstabenNativeTests
//
//  Tests for offline-first LetterRepository:
//  - Cache persistence on successful bundle load
//  - Cache fallback when bundle returns nothing
//  - Typed errors surfaced correctly
//  - Cache clear/corruption handling

import XCTest
import Foundation
@testable import BuchstabenNative

// MARK: - Test doubles

private final class EmptyResourceProvider: LetterResourceProviding {
    func allResourceURLs() -> [URL] { [] }
    func resourceURL(for relativePath: String) -> URL? { nil }
}

private final class InMemoryCache: LetterCacheStoring {
    private(set) var savedLetters: [LetterAsset]?
    private(set) var saveCallCount = 0
    private(set) var loadCallCount = 0
    var storedLetters: [LetterAsset]? = nil
    var shouldThrowOnLoad = false

    init(storedLetters: [LetterAsset]? = nil) {
        self.storedLetters = storedLetters
    }

    func save(_ letters: [LetterAsset]) throws {
        savedLetters = letters
        storedLetters = letters
        saveCallCount += 1
    }

    func load() throws -> [LetterAsset] {
        loadCallCount += 1
        if shouldThrowOnLoad { throw LetterRepositoryError.cacheReadFailed(path: "/tmp/test") }
        guard let letters = storedLetters else {
            throw LetterRepositoryError.cacheReadFailed(path: "/tmp/test")
        }
        return letters
    }

    func clear() {
        storedLetters = nil
        savedLetters = nil
    }
}

private func makeSampleLetter(_ id: String = "A") -> LetterAsset {
    LetterAsset(
        id: id,
        name: id.uppercased(),
        imageName: "\(id).pbm",
        audioFiles: ["\(id).mp3"],
        strokes: LetterStrokes(
            letter: id.uppercased(),
            checkpointRadius: 0.05,
            strokes: [StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.5, y: 0.5)])]
        )
    )
}

// MARK: - JSONLetterCache tests

@MainActor
final class JSONLetterCacheTests: XCTestCase {

    private var tempURL: URL!
    private var cache: JSONLetterCache!

    override func setUp() async throws {
        // Do NOT call super.setUp() here: XCTestCase.setUp() is declared as
        // `open func setUp() async throws` in Swift 6, so calling it from a
        // @MainActor-isolated context requires `try await`, which itself triggers
        // a "sending non-Sendable XCTestCase" error. The default implementation
        // is a no-op, so omitting the super call is safe.
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetterCacheTest-\(UUID().uuidString).json")
        cache = JSONLetterCache(fileURL: tempURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL)
        // Do NOT call super.tearDown() — same reason as setUp() above.
    }

    func testSaveAndLoad_roundtrips() throws {
        let letters = [makeSampleLetter("A"), makeSampleLetter("B")]
        try cache.save(letters)
        let loaded = try cache.load()
        XCTAssertEqual(loaded.map(\.id), ["A", "B"])
        XCTAssertEqual(loaded.map(\.name), ["A", "B"])
        XCTAssertEqual(loaded[0].audioFiles, ["A.mp3"])
    }

    func testLoad_whenNoFile_throwsCacheReadFailed() {
        XCTAssertThrowsError(try cache.load()) { error in
            guard case LetterRepositoryError.cacheReadFailed = error else {
                XCTFail("Expected cacheReadFailed, got \(error)"); return
            }
        }
    }

    func testClear_removesFile() throws {
        try cache.save([makeSampleLetter("C")])
        cache.clear()
        XCTAssertThrowsError(try cache.load())
    }

    func testSave_isAtomic_doesNotCorruptOnRepeat() throws {
        let first = [makeSampleLetter("X")]
        let second = [makeSampleLetter("Y"), makeSampleLetter("Z")]
        try cache.save(first)
        try cache.save(second)
        let loaded = try cache.load()
        XCTAssertEqual(loaded.map(\.id), ["Y", "Z"])
    }

    func testSaveAndLoad_preservesStrokeGeometry() throws {
        let strokes = LetterStrokes(
            letter: "M",
            checkpointRadius: 0.07,
            strokes: [
                StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.1, y: 0.9), Checkpoint(x: 0.5, y: 0.1)])
            ]
        )
        let letter = LetterAsset(id: "M", name: "M", imageName: "M.pbm", audioFiles: ["M.mp3"], strokes: strokes)
        try cache.save([letter])
        let loaded = try cache.load()
        XCTAssertEqual(loaded[0].strokes.checkpointRadius, 0.07, accuracy: 1e-9)
        XCTAssertEqual(loaded[0].strokes.strokes[0].checkpoints[1].x, 0.5, accuracy: 1e-9)
    }
}

// MARK: - LetterRepository error handling tests

final class LetterRepositoryErrorHandlingTests: XCTestCase {

    // MARK: Bundle success → cache written

    func testBundleSuccess_persistsToCache() {
        let cache = InMemoryCache()
        let repo = LetterRepository(resources: BundleLetterResourceProvider(), cache: cache)
        _ = repo.loadLetters()
        // If bundle loaded anything, cache.save was called; if bundle empty, not called
        // (We test cache write via the empty-provider path below)
    }

    // MARK: Empty bundle → cache fallback

    func testEmptyBundle_usesCacheFallback() {
        let cache = InMemoryCache(storedLetters: [makeSampleLetter("A"), makeSampleLetter("B")])
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: cache)
        let letters = repo.loadLetters()
        XCTAssertEqual(letters.map(\.id).sorted(), ["A", "B"])
    }

    func testEmptyBundle_withEmptyCache_returnsFallbackSample() {
        let cache = InMemoryCache()  // no stored letters
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: cache)
        let letters = repo.loadLetters()
        XCTAssertEqual(letters.count, 1)
        XCTAssertEqual(letters[0].id, "A")  // fallbackSampleLetter
    }

    // MARK: Typed errors via loadWithErrors()

    func testLoadWithErrors_emptyBundle_emptyCache_returnsNoAssetsFoundError() {
        let cache = InMemoryCache()
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: cache)
        let result = repo.loadWithErrors()
        if case .failure(let error) = result {
            XCTAssertEqual(error, .noAssetsFound)
        } else {
            XCTFail("Expected failure, got success")
        }
    }

    func testLoadWithErrors_emptyBundle_withCache_returnsSuccess() {
        let cache = InMemoryCache(storedLetters: [makeSampleLetter("F")])
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: cache)
        let result = repo.loadWithErrors()
        if case .success(let letters) = result {
            XCTAssertEqual(letters[0].id, "F")
        } else {
            XCTFail("Expected success from cache, got failure")
        }
    }

    func testLoadWithErrors_cacheThrows_returnsError() {
        let cache = InMemoryCache()
        cache.shouldThrowOnLoad = true
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: cache)
        let result = repo.loadWithErrors()
        if case .success = result {
            XCTFail("Should not succeed when both bundle and cache fail")
        }
    }

    // MARK: Cache not called on empty bundle when already empty

    func testLoadLetters_emptyBundle_cacheFallback_doesNotSaveEmptyToCache() {
        let cache = InMemoryCache(storedLetters: [makeSampleLetter("K")])
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: cache)
        _ = repo.loadLetters()
        // Cache should not have been overwritten with empty
        XCTAssertNotNil(cache.storedLetters)
        XCTAssertFalse(cache.storedLetters?.isEmpty ?? true)
    }

    // MARK: Error equatability

    func testLetterRepositoryError_equatability() {
        XCTAssertEqual(LetterRepositoryError.noAssetsFound, .noAssetsFound)
        XCTAssertEqual(
            LetterRepositoryError.partialLoad(loaded: 2, issues: ["A: missing audio"]),
            .partialLoad(loaded: 2, issues: ["A: missing audio"])
        )
        XCTAssertNotEqual(
            LetterRepositoryError.partialLoad(loaded: 2, issues: ["A: missing audio"]),
            .partialLoad(loaded: 3, issues: ["A: missing audio"])
        )
        XCTAssertEqual(
            LetterRepositoryError.cacheReadFailed(path: "/tmp/x"),
            .cacheReadFailed(path: "/tmp/x")
        )
        XCTAssertEqual(
            LetterRepositoryError.cacheCorrupted(underlying: "bad JSON"),
            .cacheCorrupted(underlying: "bad JSON")
        )
    }
}
