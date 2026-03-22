//  LetterRepositoryTests.swift
//  BuchstabenNativeTests

import Testing
@testable import BuchstabenNative

private final class MockResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
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
    func addLetter(_ base: String) {
        let jsonName = "\(base)_strokes.json"
        let pbmName  = "\(base).pbm"
        let tmp = FileManager.default.temporaryDirectory
        let jsonURL = tmp.appendingPathComponent(jsonName)
        try? makeJSON(letter: base).write(to: jsonURL)
        resources[jsonName] = jsonURL
        add(pbmName)
        let pathURL = URL(fileURLWithPath: "/mock/\(base)/\(base)1.mp3")
        resources["\(base)/\(base)1.mp3"] = pathURL
    }
}

@MainActor
struct LetterRepositoryTests {

    // MARK: 1 — Empty provider returns fallback
    @Test func emptyProvider_returnsFallbackLetter() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let letters = repo.loadLetters()
        #expect(!letters.isEmpty, "loadLetters() must never return empty — fallback expected")
        #expect(letters.first?.id == "A", "Fallback must be letter A")
    }

    // MARK: 2 — Fallback letter has required fields
    @Test func fallbackLetter_hasRequiredFields() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let letter = repo.loadLetters().first!
        #expect(!letter.name.isEmpty)
        #expect(!letter.audioFiles.isEmpty)
        #expect(!letter.imageName.isEmpty)
    }

    // MARK: 3 — Invalid JSON is skipped
    @Test func invalidJSON_isSkipped_returnsAtLeastFallback() {
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
        #expect(!repo.loadLetters().isEmpty)
    }

    // MARK: 4 — Names are non-empty
    @Test func letterAsset_names_areNonEmpty() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            #expect(!letter.name.isEmpty)
        }
    }

    // MARK: 5 — audioFiles are non-empty
    @Test func letterAsset_audioFiles_areNonEmpty() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            #expect(!letter.audioFiles.isEmpty, "letter \(letter.name) has no audio files")
        }
    }

    // MARK: 6 — Checkpoints in [0,1]
    @Test func defaultStrokes_checkpoints_areNormalized() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            for stroke in letter.strokes.strokes {
                for cp in stroke.checkpoints {
                    #expect(cp.x >= 0.0); #expect(cp.x <= 1.0)
                    #expect(cp.y >= 0.0); #expect(cp.y <= 1.0)
                }
            }
        }
    }

    // MARK: 7 — checkpointRadius is positive
    @Test func defaultStrokes_checkpointRadius_isPositive() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        for letter in repo.loadLetters() {
            #expect(letter.strokes.checkpointRadius > 0.0)
        }
    }

    // MARK: 8 — No duplicate ids
    @Test func loadLetters_noDuplicateIds() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        let ids = repo.loadLetters().map(\.id)
        #expect(ids.count == Set(ids).count, "loadLetters() must not return duplicate ids")
    }

    // MARK: 9 — Idempotent
    @Test func loadLetters_isIdempotent() {
        let repo = LetterRepository(resources: MockResourceProvider(), cache: NullLetterCache())
        #expect(repo.loadLetters() == repo.loadLetters())
    }

    // MARK: 10 — Equatable
    @Test func letterAsset_equatable() {
        let a = LetterAsset(id: "A", name: "A", imageName: "A.pbm",
                            audioFiles: ["A.mp3"], strokes: LetterStrokes(letter: "A", checkpointRadius: 0.06, strokes: []))
        let b = LetterAsset(id: "A", name: "A", imageName: "A.pbm",
                            audioFiles: ["A.mp3"], strokes: LetterStrokes(letter: "A", checkpointRadius: 0.06, strokes: []))
        #expect(a == b)
    }
}
