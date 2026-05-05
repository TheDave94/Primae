import CoreGraphics

struct LetterAsset: Identifiable, Equatable {
    let id: String
    let name: String
    /// Grouping key — always the uppercase letter (e.g. "A" for both "A" and "a").
    let baseLetter: String
    let letterCase: LetterCase
    let imageName: String
    let audioFiles: [String]
    /// Phoneme recordings — the *sound* the letter makes (/a/ as in
    /// *Affe*) rather than its name (/aː/). Cycled when the parent
    /// enables "Lautwert wiedergeben"; falls back to `audioFiles` when
    /// empty. Filename convention `<base>_phoneme<n>.mp3`.
    let phonemeAudioFiles: [String]
    let strokes: LetterStrokes
    /// Variant IDs for which a strokes_{id}.json exists alongside
    /// strokes.json (e.g. Austrian Schulschrift 1995).
    let variants: [String]?

    enum LetterCase: String, Codable, Equatable, Sendable {
        case upper, lower
    }

    /// Convenience init preserving backward compatibility (defaults to .upper, no variants).
    init(id: String, name: String, imageName: String,
         audioFiles: [String], strokes: LetterStrokes,
         phonemeAudioFiles: [String] = []) {
        self.id = id
        self.name = name
        self.baseLetter = name.uppercased()
        self.letterCase = .upper
        self.imageName = imageName
        self.audioFiles = audioFiles
        self.phonemeAudioFiles = phonemeAudioFiles
        self.strokes = strokes
        self.variants = nil
    }

    /// Full init with case specification and optional variants.
    init(id: String, name: String, baseLetter: String,
         letterCase: LetterCase, imageName: String,
         audioFiles: [String], strokes: LetterStrokes,
         variants: [String]? = nil,
         phonemeAudioFiles: [String] = []) {
        self.id = id
        self.name = name
        self.baseLetter = baseLetter
        self.letterCase = letterCase
        self.imageName = imageName
        self.audioFiles = audioFiles
        self.phonemeAudioFiles = phonemeAudioFiles
        self.strokes = strokes
        self.variants = variants
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
