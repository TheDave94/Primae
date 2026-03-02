import Foundation

final class LetterRepository {
    /// Native-first repository. Loads JSON-based stroke metadata from bundle when available
    /// and falls back to an embedded sample for first-run safety.
    func loadLetters() -> [LetterAsset] {
        let bundled = loadBundledStrokeLetters()
        if !bundled.isEmpty { return bundled }

        let sample = LetterStrokes(
            letter: "A",
            checkpointRadius: 0.06,
            strokes: [
                .init(id: 1, checkpoints: [.init(x: 0.3, y: 0.8), .init(x: 0.5, y: 0.2), .init(x: 0.7, y: 0.8)]),
                .init(id: 2, checkpoints: [.init(x: 0.38, y: 0.55), .init(x: 0.62, y: 0.55)])
            ]
        )

        return [
            LetterAsset(id: "A", name: "A", imageName: "A.pbm", audioFiles: ["A.mp3"], strokes: sample)
        ]
    }
}


private extension LetterRepository {
    func loadBundledStrokeLetters() -> [LetterAsset] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) else { return [] }
        let decoder = JSONDecoder()
        return urls.compactMap { url in
            guard url.lastPathComponent.hasSuffix("_strokes.json") else { return nil }
            guard let data = try? Data(contentsOf: url),
                  let strokes = try? decoder.decode(LetterStrokes.self, from: data) else { return nil }
            let base = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_strokes", with: "")
            return LetterAsset(id: base, name: base.uppercased(), imageName: "\(base).pbm", audioFiles: ["\(base).mp3"], strokes: strokes)
        }.sorted { $0.name < $1.name }
    }
}
