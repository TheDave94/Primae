// BakeoffSources.swift
// PrimaeNativeTests — sonification bake-off harness (BENCH lane, 2026-11-02)
//
// Sources: every bundled `<L>_phoneme1.*` asset the letter repository
// reports (the study letters A F I L M at least) plus the spatial arm's
// `spatial_carrier.wav`, decoded to mono Float32 and resampled to the bench
// rate (48 kHz, and the 44.1 kHz variant the assets are authored at).
// Resampling uses AVAudioConverter (mastering quality) over the loop tiled
// three times, keeping the middle copy, so the loop seam carries no
// converter edge transient.
//
// Also: a minimal 16-bit PCM WAV writer (no AVAudioFile, so the format of
// what David listens to is exactly what is written here).

import AVFAudio
import Foundation
@testable import PrimaeNative

struct BakeoffSource {
    /// e.g. "A_phoneme1", "spatial_carrier".
    let name: String
    /// The letter whose strokes drive this source's trajectories (nil = carrier).
    let letter: String?
    let kind: SourceKind
    let sampleRate: Double
    let samples: [Float]
    /// Fraction of YIN frames voiced; how `kind` was decided for a phoneme.
    let voicedFraction: Double
    /// The synthetic sweep probe (rate metrics only; not a study asset).
    var isProbe: Bool = false
    /// Pitch phase 2: the loudness gain the kernel plays this file at (`AudioEngine.loudnessGain`), applied to the
    /// exported WAVs only; and the file's recorded onset (`PhonemeOnsets`).
    var gain: Float = 1
    var onset: RecordedOnset? = nil
    /// r31 (PITCHWIN / BENCH-R31): original 44.1 kHz recording + onset when `samples` is resampled to 48 kHz, so
    /// `TDPSOLA2` analyses marks/GCIs/firstPeriodicMark at the file rate and scales them to `sampleRate`.
    var fileSource: SonificationSource.FileSource? = nil
    /// PLAYED loop duration (seconds) for voiced sources, read once from the production renderer's own loop bounds
    /// (`TDPSOLA2.playedLoop`), so held scenarios cover an integer number of whole PLAYED loops >= 1.8 s at every
    /// playback rate (0.5 / 1 / 2). Nil for unvoiced / synthetic. Lane BENCHWIN (2026-11-28): this was
    /// `analysis.loopEnd - analysis.loopStart` (A: 1.944 s), but SEAM2 plays a loop shortened by its crossfade
    /// (A: 1.546 s), so the window spanned 1.257 played loops and counted part of the blend twice.
    var loopSeconds: Double? = nil

    /// The source exactly as production hands it to a renderer (`SonificationSource.load`): every phoneme is
    /// `.voicedPhoneme` (TDPSOLA's own analysis downgrades F); `kind` above is the BENCH's YIN classification, which
    /// picks the metric family.
    var sonification: SonificationSource {
        SonificationSource(key: "bench:\(name)", samples: samples, kind: kind == .carrier ? .carrier : .voicedPhoneme,
                           gain: gain, onset: onset, sampleRate: sampleRate, fileSource: fileSource)
    }

    /// Pitch phase 2: the steady segment the source-side references are taken from (measure.py: recorded onset
    /// + 80 ms ... end - 100 ms; without an onset, 100 ms ... end - 100 ms).
    var steadyRange: Range<Int> {
        let from = (onset?.attackEndFrame ?? 0) + Int(((onset == nil ? 0.1 : 0.08) * sampleRate).rounded(.down))
        let to = samples.count - Int(0.1 * sampleRate)
        return min(from, max(0, to - 1))..<max(from + 1, to)
    }

    var kindLabel: String {
        switch kind {
        case .voicedPhoneme: return "voiced"
        case .unvoicedPhoneme: return "unvoiced"
        case .carrier: return "carrier"
        }
    }
}

enum BakeoffSources {

    enum LoadError: Error { case missing(String), decode(String) }

    /// Decode `url` to mono Float32 at `sampleRate`.
    static func loadMono(url: URL, sampleRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let fmt = file.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw LoadError.decode(url.lastPathComponent)
        }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        let channels = Int(fmt.channelCount)
        guard let data = buf.floatChannelData else { throw LoadError.decode(url.lastPathComponent) }
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels {
            for i in 0..<n { mono[i] += data[c][i] / Float(channels) }
        }
        if abs(fmt.sampleRate - sampleRate) < 0.5 { return mono }
        return try resampleLoop(mono, from: fmt.sampleRate, to: sampleRate)
    }

    private final class FeedState { var fed = false }

    static func resampleLoop(_ loop: [Float], from: Double, to: Double) throws -> [Float] {
        let tiled = loop + loop + loop
        guard let inFmt = AVAudioFormat(standardFormatWithSampleRate: from, channels: 1),
              let outFmt = AVAudioFormat(standardFormatWithSampleRate: to, channels: 1),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(tiled.count)) else {
            throw LoadError.decode("converter")
        }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        conv.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        tiled.withUnsafeBufferPointer { inBuf.floatChannelData![0].update(from: $0.baseAddress!, count: tiled.count) }
        inBuf.frameLength = AVAudioFrameCount(tiled.count)
        let capacity = AVAudioFrameCount(Double(tiled.count) * to / from) + 8192
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: capacity) else {
            throw LoadError.decode("converter out")
        }
        let state = FeedState()
        var error: NSError?
        let status = conv.convert(to: outBuf, error: &error) { _, outStatus in
            if state.fed { outStatus.pointee = .endOfStream; return nil }
            state.fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if status == .error || error != nil { throw LoadError.decode("convert: \(String(describing: error))") }
        let produced = Int(outBuf.frameLength)
        let m = Int((Double(loop.count) * to / from).rounded())
        guard produced >= 2 * m else { throw LoadError.decode("short conversion \(produced) < \(2 * m)") }
        let p = outBuf.floatChannelData![0]
        return Array(UnsafeBufferPointer(start: p + m, count: m))
    }

    /// Every phoneme1 asset + the carrier at `sampleRate`.
    static func all(sampleRate: Double) throws -> [BakeoffSource] {
        var out: [BakeoffSource] = []
        let repo = LetterRepository(resources: BundleLetterResourceProvider(), cache: NullLetterCache(),
                                    weight: .regular)
        let letters = (try? repo.loadBundledLettersOnly().get()) ?? []
        var seen = Set<String>()
        for letter in letters.sorted(by: { $0.name < $1.name }) {
            for file in letter.phonemeAudioFiles where file.contains("_phoneme1") {
                let stem = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
                guard !seen.contains(stem) else { continue }
                guard let url = PrimaeBundle.audioURL(for: file) else { throw LoadError.missing(file) }
                seen.insert(stem)
                let samples = try loadMono(url: url, sampleRate: sampleRate)
                let track = BakeoffMetrics.yinTrack(samples, start: 0, end: samples.count,
                                                    sampleRate: sampleRate, hop: Int(0.01 * sampleRate))
                let vf = BakeoffMetrics.voicedFraction(track)
                out.append(BakeoffSource(name: stem, letter: letter.baseLetter,
                                         kind: vf >= 0.5 ? .voicedPhoneme : .unvoicedPhoneme,
                                         sampleRate: sampleRate, samples: samples, voicedFraction: vf))
            }
        }
        // The five study letters at least, even if the repository missed one.
        for letter in TrainedLetterSubset.studyLetters where !seen.contains("\(letter)_phoneme1") {
            guard let url = PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(
                dir: "Letters/\(letter)", name: "\(letter)_phoneme1", ext: "wav")) else {
                throw LoadError.missing("\(letter)_phoneme1")
            }
            seen.insert("\(letter)_phoneme1")
            let samples = try loadMono(url: url, sampleRate: sampleRate)
            let track = BakeoffMetrics.yinTrack(samples, start: 0, end: samples.count,
                                                sampleRate: sampleRate, hop: Int(0.01 * sampleRate))
            let vf = BakeoffMetrics.voicedFraction(track)
            out.append(BakeoffSource(name: "\(letter)_phoneme1", letter: letter,
                                     kind: vf >= 0.5 ? .voicedPhoneme : .unvoicedPhoneme,
                                     sampleRate: sampleRate, samples: samples, voicedFraction: vf))
        }
        guard let carrierURL = SpatialSonification.carrierToneURL() else {
            throw LoadError.missing(SpatialSonification.carrierToneFile)
        }
        let carrier = try loadMono(url: carrierURL, sampleRate: sampleRate)
        let ctrack = BakeoffMetrics.yinTrack(carrier, start: 0, end: carrier.count,
                                             sampleRate: sampleRate, hop: Int(0.01 * sampleRate))
        out.append(BakeoffSource(name: "spatial_carrier", letter: nil, kind: .carrier,
                                 sampleRate: sampleRate, samples: carrier,
                                 voicedFraction: BakeoffMetrics.voicedFraction(ctrack)))
        // The rate metrics' probe (BakeoffMetrics.sweepTrack), driven like a
        // voiced phoneme (pitch held), trajectories from the letter A.
        out.append(BakeoffSource(name: "probe_sweep", letter: "A", kind: .voicedPhoneme,
                                 sampleRate: sampleRate, samples: BakeoffSynthetic.sweepProbe(sampleRate: sampleRate),
                                 voicedFraction: 1, isProbe: true))
        return out
    }
}

extension BakeoffSources {
    /// r31 output hardware rate on the study iPad (48 kHz; `docs/DECISIONS.md`, "Rendering at the output rate").
    nonisolated static let pitchSampleRate: Double = 48_000

    /// Pitch bench (r31): the five study phonemes (A F I L M) decoded via `SonificationSource.load` at `sampleRate`
    /// (default 48 kHz, matching the iPad output rate, preserving `fileSource` for file-rate mark analysis), with
    /// their loudness gain, scaled recorded onset, and voiced loop duration; `kind` from YIN (F: unvoiced).
    @MainActor
    static func pitchSources(letters: [String]? = nil, sampleRate sr: Double = pitchSampleRate) throws -> [BakeoffSource] {
        try (letters ?? TrainedLetterSubset.studyLetters).map { letter in
            let name = "\(letter)_phoneme1"
            guard let url = PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(letter)", name: name,
                                                                                   ext: "wav")) else {
                throw LoadError.missing(name)
            }
            let gain = AudioEngine.loudnessGain(forFileAt: url)
            guard let loaded = SonificationSource.load(url: url, gain: gain, sampleRate: sr) else {
                throw LoadError.decode(name)
            }
            let track = BakeoffMetrics.yinTrack(loaded.samples, start: 0, end: loaded.samples.count, sampleRate: sr,
                                                hop: Int(0.01 * sr))
            let vf = BakeoffMetrics.voicedFraction(track)
            let kind: SourceKind = vf >= 0.5 ? .voicedPhoneme : .unvoicedPhoneme
            var loopSeconds: Double? = nil
            if kind == .voicedPhoneme {
                let prod = LiveSonificationAudio.makeRenderer(loaded)
                let played = prod.playedLoop
                if prod.analysis.isVoiced, played.end > played.start {
                    loopSeconds = (played.end - played.start) / sr
                }
            }
            return BakeoffSource(name: name, letter: letter, kind: kind,
                                 sampleRate: sr, samples: loaded.samples, voicedFraction: vf,
                                 gain: gain, onset: loaded.onset, fileSource: loaded.fileSource,
                                 loopSeconds: loopSeconds)
        }
    }

    /// The Regular-weight stroke geometry of `letter` (the same
    /// `strokes.json` the app loads and `LetterTracer` traces).
    static func strokes(letter: String) throws -> LetterStrokes {
        guard let url = PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(
            dir: "Letters/Regular/\(letter)", name: "strokes", ext: "json")) else {
            throw LoadError.missing("Letters/Regular/\(letter)/strokes.json")
        }
        return try JSONDecoder().decode(LetterStrokes.self, from: Data(contentsOf: url))
    }
}

enum BakeoffWAV {
    /// 32-bit float mono WAV (WAVE_FORMAT_IEEE_FLOAT), unclipped: the pitch renders keep their level for
    /// `method/build_mushra.py`, which loudness-matches and scales per trial itself.
    static func writeFloat(_ x: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }
        func u16(_ v: UInt16) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 2)) }
        let sr = UInt32(sampleRate.rounded())
        let bytes = UInt32(x.count * 4)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(3); u16(1); u32(sr); u32(sr * 4); u16(4); u16(32)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        x.withUnsafeBytes { data.append(contentsOf: $0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// 16-bit PCM mono WAV, hard-clipped at full scale.
    static func write(_ x: [Float], sampleRate: Double, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }
        func u16(_ v: UInt16) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 2)) }
        let sr = UInt32(sampleRate.rounded())
        let bytes = UInt32(x.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(sr); u32(sr * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        var pcm = [Int16](repeating: 0, count: x.count)
        for i in 0..<x.count { pcm[i] = Int16(max(-32767, min(32767, (x[i] * 32767).rounded()))) }
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}
