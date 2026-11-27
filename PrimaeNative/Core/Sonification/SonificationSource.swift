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
    /// Mono Float32 at `sampleRate`.
    let samples: [Float]
    let kind: SourceKind
    /// Per-file loudness gain (ruling AE-2), the value the r16 engine applied
    /// as `player.volume`.
    let gain: Float
    /// R17D: the file's recorded onset (`PhonemeOnsets`), nil for a file without one.
    var onset: RecordedOnset? = nil
    /// The rate `samples` are at: the kernel's (r31: the output rate), the file resampled to it once, at load.
    var sampleRate: Double = LiveSonificationKernel.referenceSampleRate
    /// r31 (PITCHWIN): the file as recorded, when `samples` is a resample of it (nil when the file is at
    /// `sampleRate`). The renderer analyses the voice here (pitch marks, glottal closures, the attack's first
    /// periodic mark) and scales the result to `sampleRate`, so a resample moves no mark.
    var fileSource: FileSource? = nil

    /// The file at its own rate, with its recorded onset at that rate.
    struct FileSource: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let onset: RecordedOnset?
    }

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

    /// Decodes `url` to mono at `sampleRate` (the kernel's rate). Nil (logged) when unreadable.
    static func load(url: URL, gain: Float,
                     sampleRate: Double = LiveSonificationKernel.referenceSampleRate) -> SonificationSource? {
        do {
            let (samples, fileRate, fileSamples) = try decodeMonoWithFile(url: url, sampleRate: sampleRate)
            guard !samples.isEmpty else {
                log.error("\(url.lastPathComponent, privacy: .public): no samples")
                return nil
            }
            return SonificationSource(key: cacheKey(for: url), samples: samples,
                                      kind: kind(forFileAt: url), gain: gain,
                                      onset: PhonemeOnsets.onset(forFileNamed: url.lastPathComponent,
                                                                 fileRate: fileRate, renderRate: sampleRate),
                                      sampleRate: sampleRate,
                                      fileSource: fileSamples.map {
                                          FileSource(samples: $0, sampleRate: fileRate,
                                                     onset: PhonemeOnsets.onset(forFileNamed: url.lastPathComponent))
                                      })
        } catch {
            log.error("\(url.lastPathComponent, privacy: .public): decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    enum DecodeError: Error { case buffer, converter, convert }

    /// Mono (channels averaged) Float32 at `sampleRate`. The study assets are
    /// 44.1 kHz mono, so the converter runs only when the kernel is not at 44.1 kHz.
    static func decodeMono(url: URL, sampleRate: Double) throws -> [Float] {
        try decodeMonoWithRate(url: url, sampleRate: sampleRate).samples
    }

    /// `decodeMono`, plus the file's own rate. r31: a file not at `sampleRate` is resampled here, once, off the
    /// render thread, by AVAudioConverter at its highest setting (mastering algorithm, max quality: a long
    /// band-limited polyphase filter), so the live chain itself never converts.
    static func decodeMonoWithRate(url: URL, sampleRate: Double) throws -> (samples: [Float], fileRate: Double) {
        let d = try decodeMonoWithFile(url: url, sampleRate: sampleRate)
        return (d.samples, d.fileRate)
    }

    /// `decodeMonoWithRate`, plus the file's own mono samples when they were resampled (nil when not).
    static func decodeMonoWithFile(url: URL, sampleRate: Double) throws
        -> (samples: [Float], fileRate: Double, file: [Float]?) {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { throw DecodeError.buffer }
        try file.read(into: inBuf)
        let frames = Int(inBuf.frameLength)
        let channels = Int(inFormat.channelCount)
        guard let data = inBuf.floatChannelData, frames > 0, channels > 0 else { return ([], inFormat.sampleRate, nil) }
        var mono = [Float](repeating: 0, count: frames)
        for c in 0..<channels {
            let p = data[c]
            for i in 0..<frames { mono[i] += p[i] }
        }
        if channels > 1 { let s = 1 / Float(channels); for i in 0..<frames { mono[i] *= s } }
        if inFormat.sampleRate == sampleRate { return (mono, sampleRate, nil) }
        return (try resample(mono, from: inFormat.sampleRate, to: sampleRate), inFormat.sampleRate, mono)
    }

    /// `x` at `fromRate` resampled to `sampleRate` (mono Float32), whole-buffer, offline. The converter primes
    /// itself (`.normal`: no added latency), so frame k of the input lands at k * sampleRate / fromRate.
    static func resample(_ x: [Float], from fromRate: Double, to sampleRate: Double) throws -> [Float] {
        let frames = x.count
        guard frames > 0, fromRate != sampleRate else { return x }
        guard let monoIn = AVAudioFormat(standardFormatWithSampleRate: fromRate, channels: 1),
              let monoOut = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let src = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: AVAudioFrameCount(frames)),
              let converter = AVAudioConverter(from: monoIn, to: monoOut)
        else { throw DecodeError.converter }
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        src.frameLength = AVAudioFrameCount(frames)
        x.withUnsafeBufferPointer { src.floatChannelData![0].update(from: $0.baseAddress!, count: frames) }
        let outCap = AVAudioFrameCount(Double(frames) * sampleRate / fromRate + 1024)
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
