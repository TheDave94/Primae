import CoreGraphics

struct LetterAsset: Identifiable, Equatable {
    let id: String
    let name: String
    let imageName: String
    let audioFiles: [String]
    let strokes: LetterStrokes
}

struct LetterStrokes: Codable, Equatable {
    let letter: String
    let checkpointRadius: CGFloat
    let strokes: [StrokeDefinition]
}

struct StrokeDefinition: Codable, Equatable {
    let id: Int
    let checkpoints: [Checkpoint]
}

struct Checkpoint: Codable, Equatable {
    let x: CGFloat
    let y: CGFloat
}

struct TracingPoint: Equatable {
    let location: CGPoint
    let time: CFTimeInterval
}
