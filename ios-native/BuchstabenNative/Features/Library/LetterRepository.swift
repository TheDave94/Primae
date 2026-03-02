import Foundation

final class LetterRepository {
    /// Placeholder native repository for rewrite phase.
    /// Next milestone: auto-import all existing asset folders from bundle.
    func loadLetters() -> [LetterAsset] {
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
