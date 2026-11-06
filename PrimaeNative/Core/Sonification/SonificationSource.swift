// SonificationSource.swift
// PrimaeNative
//
// One decoded arm sound, ready for a `SonificationRenderer` (protocol r17).
// Decoding and the renderers' init-time analysis run OFF the render thread,
// once per file per process (`LiveSonificationAudio` caches the renderers),
// so a touch-down never decodes.

import AVFoundation
import Foundation
import OSLog

nonisolated struct SonificationSource: Sendable {
    /// Cache key: the resolved file path (symlinks resolved, because iOS
    /// containers appear as both /var and /private/var).
    let key: String
    /// Mono Float32 at `LiveSonificationKernel.sampleRate`.
    let samples: [Float]
    let kind: SourceKind
    /// Per-file loudness gain (ruling AE-2), the value the r16 engine applied
    /// as `player.volume`.
    let gain: Float
    /// R17D: the file's recorded onset (`PhonemeOnsets`), nil for a file without one.
    var onset: RecordedOnset? = nil

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
                                    category: "Sonification")

    /// The carrier is the one tonal source; every other arm file is a phoneme.
    /// Whether a phoneme is voiced is the renderer's own analysis (TDPSOLA
    /// downgrades a source whose voiced fraction is below 0.5, which is how F
    /// takes the unvoiced path), not a hard-coded letter list.
    static func kind(forFileAt url: URL) -> SourceKind {
        url.lastPathComponent == carrierFileName ? .carrier : .voicedPhoneme
    }

    /// The last path component of `SpatialSonification.carrierToneFile`
    /// (a main-actor constant; equality pinned by a test).
    static let carrierFileName = "spatial_carrier.wav"

    static func cacheKey(for url: URL) -> String { url.resolvingSymlinksInPath().path }

    /// Decodes `url` to mono at the kernel rate. Nil (logged) when unreadable.
    static func load(url: URL, gain: Float) -> SonificationSource? {
        do {
            let samples = try decodeMono(url: url, sampleRate: LiveSonificationKernel.sampleRate)
            guard !samples.isEmpty else {
                log.error("\(url.lastPathComponent, privacy: .public): no samples")
                return nil
            }
            return SonificationSource(key: cacheKey(for: url), samples: samples,
                                      kind: kind(forFileAt: url), gain: gain,
                                      onset: PhonemeOnsets.onset(forFileNamed: url.lastPathComponent))
        } catch {
            log.error("\(url.lastPathComponent, privacy: .public): decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    enum DecodeError: Error { case buffer, converter, convert }

    /// Mono (channels averaged) Float32 at `sampleRate`. The study assets are
    /// already 44.1 kHz mono, so the converter runs only for a file that is not.
    static func decodeMono(url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw DecodeError.buffer }
        try file.read(into: inBuf)
        let frames = Int(inBuf.frameLength)
        let channels = Int(inFormat.channelCount)
        guard let data = inBuf.floatChannelData, frames > 0, channels > 0 else { return [] }
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let p = data[c]
            for i in 0..<frames { mono[i] += p[i] }
        }
        if channels > 1 { let s = 1 / Float(channels); for i in 0..<frames { mono[i] *= s } }
        if inFormat.sampleRate == sampleRate { return mono }

        guard let monoIn = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1),
              let monoOut = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let src = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: AVAudioFrameCount(frames)),
              let converter = AVAudioConverter(from: monoIn, to: monoOut)
        else { throw DecodeError.converter }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        src.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }
        let outCap = AVAudioFrameCount(Double(frames) * sampleRate / inFormat.sampleRate + 1024)
        guard let dst = AVAudioPCMBuffer(pcmFormat: monoOut, frameCapacity: outCap) else { throw DecodeError.buffer }
        var fed = false
        var err: NSError?
        let status = converter.convert(to: dst, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true
            outStatus.pointee = .haveData
            return src
        }
        guard status != .error, let out = dst.floatChannelData else { throw err ?? DecodeError.convert }
        return Array(UnsafeBufferPointer(start: out[0], count: Int(dst.frameLength)))
    }
}
