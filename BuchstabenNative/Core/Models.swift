import CoreGraphics

struct LetterAsset: Identifiable, Equatable {
    let id: String
    let name: String
    /// Grouping key — always the uppercase letter (e.g. "A" for both "A" and "a").
    let baseLetter: String
    let letterCase: LetterCase
    let imageName: String
    let audioFiles: [String]
    let strokes: LetterStrokes

    enum LetterCase: String, Codable, Equatable, Sendable {
        case upper, lower
    }

    /// Convenience init preserving backward compatibility (defaults to .upper).
    init(id: String, name: String, imageName: String,
         audioFiles: [String], strokes: LetterStrokes) {
        self.id = id
        self.name = name
        self.baseLetter = name.uppercased()
        self.letterCase = .upper
        self.imageName = imageName
        self.audioFiles = audioFiles
        self.strokes = strokes
    }

    /// Full init with case specification.
    init(id: String, name: String, baseLetter: String,
         letterCase: LetterCase, imageName: String,
         audioFiles: [String], strokes: LetterStrokes) {
        self.id = id
        self.name = name
        self.baseLetter = baseLetter
        self.letterCase = letterCase
        self.imageName = imageName
        self.audioFiles = audioFiles
        self.strokes = strokes
    }
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
