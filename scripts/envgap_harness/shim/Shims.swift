// Shims.swift — ENVGAP offline harness only (never part of the app/package build).
// Minimal stand-ins for app-level symbols the pitch bench touches, so the production DSP
// (PrimaeNative/Core/Sonification) + BENCH-R31 metric files compile as a macOS command-line tool.
import Foundation
import CoreGraphics

nonisolated enum HarnessPaths {
    static let resourcesRoot: String = ProcessInfo.processInfo.environment["PRIMAE_RES"] ?? "PrimaeNative/Resources"
}

nonisolated enum PrimaeBundle {
    static func layouts(dir: String, name: String, ext: String) -> [String] { ["\(dir)/\(name).\(ext)"] }
    static func resourceURL(firstOf relativePaths: [String]) -> URL? {
        for p in relativePaths {
            let u = URL(fileURLWithPath: HarnessPaths.resourcesRoot + "/" + p)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
    static func audioURL(for fileName: String) -> URL? {
        let stripped = fileName.hasPrefix("Resources/") ? String(fileName.dropFirst("Resources/".count)) : fileName
        return resourceURL(firstOf: [stripped])
    }
}

nonisolated enum TrainedLetterSubset {
    static let studyLetters = ["A", "F", "I", "L", "M"]
}

nonisolated enum SpatialSonification {
    static let carrierToneFile = "Resources/Sonification/spatial_carrier.wav"
    static func carrierToneURL() -> URL? { PrimaeBundle.audioURL(for: carrierToneFile) }
    // Verbatim from PrimaeNative/Core/SpatialSonification.swift.
    static let centsSpan: Float = 2400
    static func pitchCents(forNormalizedY y: CGFloat) -> Float {
        let clamped = max(0.0, min(1.0, y))
        return Float(1200.0 - 2400.0 * clamped)
    }
    static func pitchCents(forNormalizedY y: CGFloat, spanCents: Int) -> Float {
        if spanCents == Int(centsSpan) { return pitchCents(forNormalizedY: y) }
        let clamped = max(0.0, min(1.0, y))
        let half = Double(spanCents) / 2
        return Float(half - Double(spanCents) * clamped)
    }
}

// Verbatim from PrimaeNative/Features/Tracing/TouchDispatcher.swift (mapVelocityToSpeed).
nonisolated enum TouchDispatcher {
    static func mapVelocityToSpeed(_ v: CGFloat) -> Float {
        let low: CGFloat = 50, mid: CGFloat = 150, high: CGFloat = 400
        if v <= low  { return 0.8 }
        if v >= high { return 1.25 }
        if v <= mid  { return Float(0.8 + 0.2 * ((v - low) / (mid - low))) }
        return Float(1.0 + 0.25 * ((v - mid) / (high - mid)))
    }
}

nonisolated enum PilotAudioCondition: String, Sendable { case phoneme, spatial, silent }

// Stroke geometry (fields the bench reads; from PrimaeNative/Core/Models.swift).
nonisolated struct Checkpoint: Codable, Equatable, Sendable { let x: CGFloat; let y: CGFloat }
nonisolated struct StrokeDefinition: Codable, Equatable, Sendable { let id: Int; let checkpoints: [Checkpoint] }
nonisolated struct LetterStrokes: Codable, Equatable, Sendable {
    let letter: String
    let checkpointRadius: CGFloat
    let strokes: [StrokeDefinition]
}

nonisolated final class AudioEngine {}

nonisolated enum LiveSonificationKernel {
    static let referenceSampleRate: Double = 44_100
    static let chunkFrames = 512
}

nonisolated enum LiveSonificationAudio {
    // Verbatim from PrimaeNative/Core/Sonification/LiveSonificationAudio.swift (rendererOptions / makeRenderer).
    static func rendererOptions(for kind: SourceKind) -> TDPSOLA2Options {
        kind == .carrier ? .r27 : .production
    }
    static func makeRenderer(_ source: SonificationSource) -> TDPSOLA2 {
        TDPSOLA2(source: source.samples, sampleRate: source.sampleRate,
                 kind: source.kind, maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                 tuning: .default, options: rendererOptions(for: source.kind), onset: source.onset,
                 outputGain: source.gain, file: source.fileSource)
    }
}
