import Foundation

// MARK: - Typed errors

enum LetterRepositoryError: Error, Equatable {
    case noAssetsFound
    case partialLoad(loaded: Int, issues: [String])
    case cacheCorrupted(underlying: String)
    case cacheReadFailed(path: String)
}

// MARK: - Cache protocol (testable seam)

protocol LetterCacheStoring {
    func save(_ letters: [LetterAsset]) throws
    func load() throws -> [LetterAsset]
    func clear()
}

// MARK: - JSON disk cache

struct JSONLetterCache: LetterCacheStoring {

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let dir = support.appendingPathComponent("BuchstabenNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("letter-cache.json")
        }
    }

    func save(_ letters: [LetterAsset]) throws {
        let data = try JSONEncoder().encode(letters.map(CodableLetterAsset.init))
        try data.write(to: fileURL, options: .atomic)
    }

    func load() throws -> [LetterAsset] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw LetterRepositoryError.cacheReadFailed(path: fileURL.path)
        }
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode([CodableLetterAsset].self, from: data)
        return decoded.map(\.asset)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

// MARK: - Codable bridge for LetterAsset

/// `LetterAsset` uses `CGFloat` which isn't JSON-friendly on all platforms.
/// This bridge serializes via `Double` for clean JSON.
private struct CodableLetterAsset: Codable {
    let id: String
    let name: String
    let imageName: String
    let audioFiles: [String]
    let strokes: LetterStrokes

    init(_ asset: LetterAsset) {
        id = asset.id
        name = asset.name
        imageName = asset.imageName
        audioFiles = asset.audioFiles
        strokes = asset.strokes
    }

    var asset: LetterAsset {
        LetterAsset(id: id, name: name, imageName: imageName, audioFiles: audioFiles, strokes: strokes)
    }
}
