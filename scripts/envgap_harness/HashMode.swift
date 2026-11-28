// HashMode.swift — ENVGAP offline bit-identity proof. FNV-1a render hashes for fixed drives, the same construction as
// TDPSOLA2RenderHashTests (C1Make.make at 44.1 kHz, 256-frame buffers) plus production (`LiveSonificationAudio
// .makeRenderer`) at 44.1 and 48 kHz. Run against the original and the modified TDPSOLA2.swift: equal hashes = the
// default (OFF) path is bit-identical.
import Foundation
@testable import PrimaeNative

@MainActor func hashMode() throws {
    func steady(_ r: any SonificationRenderer, sr: Double, seconds: Double, rate: Float, cents: Float) -> [Float] {
        r.reset(); r.setRate(rate); r.setPitchCents(cents); r.setGate(true)
        let total = Int(seconds * sr)
        var out = [Float](repeating: 0, count: total)
        out.withUnsafeMutableBufferPointer { b in
            var pos = 0
            while pos < total { let n = min(256, total - pos); r.render(into: b.baseAddress! + pos, frames: n); pos += n }
        }
        return out
    }
    func fnv(_ x: [Float]) -> UInt64 { var h: UInt64 = 0xcbf29ce484222325; for v in x { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }; return h }
    let drives: [(Float, Float)] = [(0.8, 450), (1, -600), (2, 600), (0.5, 0), (1, 600), (0.5, -300)]
    for letter in ["A", "F", "I", "L", "M"] {
        let url = PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(letter)", name: "\(letter)_phoneme1", ext: "wav"))!
        let raw = try SonificationSource.decodeMono(url: url, sampleRate: 44_100)
        let kind = SonificationSource.kind(forFileAt: url)
        let onset = PhonemeOnsets.onset(forFileNamed: url.lastPathComponent)
        var variants: [(String, TDPSOLA2Options)] = [("default", .default), ("production", .production)]
        variants += EnvgapHash.offVariants
        for (vn, o) in variants {
            var line = "HASH44 \(letter) \(vn)"
            for (r, c) in drives {
                let t = TDPSOLA2(source: raw, sampleRate: 44_100, kind: kind, maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                                 tuning: .default, options: o, onset: onset, outputGain: 1)
                line += " " + String(fnv(steady(t, sr: 44_100, seconds: 2.0, rate: r, cents: c)), radix: 16)
            }
            print(line)
        }
        // Production at 48 kHz through the file-rate path (SonificationSource.load + makeRenderer's construction).
        let gain = AudioEngine.loudnessGain(forFileAt: url)
        let s48 = SonificationSource.load(url: url, gain: gain, sampleRate: 48_000)!
        var v48: [(String, TDPSOLA2Options)] = [("production", .production)]
        v48 += EnvgapHash.offVariants
        for (vn, o) in v48 {
            var line = "HASH48 \(letter) \(vn)"
            for (r, c) in drives {
                let t = TDPSOLA2(source: s48.samples, sampleRate: s48.sampleRate, kind: s48.kind,
                                 maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default, options: o,
                                 onset: s48.onset, outputGain: s48.gain, file: s48.fileSource)
                line += " " + String(fnv(steady(t, sr: 48_000, seconds: 2.0, rate: r, cents: c)), radix: 16)
            }
            print(line)
        }
    }
}

/// Lane BENCHM17: FNV-1a of 2 s steady renders for the R33 listening cells (packet "Listening items"), per variant in
/// `EnvgapHash.listenVariants` (production first), at 44.1 kHz (C1Make's construction, gain 1) and 48 kHz (the
/// production file-rate path). `TDPSOLA2R33CandidateTests.listeningCellHashes` pins these numbers on the device.
/// Run: HASH_LISTEN=1 PRIMAE_RES=... <outdir>/envgap_hash
@MainActor func listenMode() throws {
    func fnv(_ r: TDPSOLA2, sr: Double, rate: Float, cents: Float) -> UInt64 {
        r.reset(); r.setRate(rate); r.setPitchCents(cents); r.setGate(true)
        let total = Int(2.0 * sr)
        var out = [Float](repeating: 0, count: total)
        out.withUnsafeMutableBufferPointer { b in
            var pos = 0
            while pos < total { let n = min(256, total - pos); r.render(into: b.baseAddress! + pos, frames: n); pos += n }
        }
        var h: UInt64 = 0xcbf29ce484222325; for v in out { h = (h ^ UInt64(v.bitPattern)) &* 0x100000001b3 }; return h
    }
    let cells: [(String, Float, Float)] = [("I", 0.5, 600), ("I", 1, 600), ("I", 2, 600), ("L", 0.5, 0), ("L", 0.5, 300),
                                           ("A", 0.5, 0), ("M", 1, 600), ("M", 2, 600)]
    let variants: [(String, TDPSOLA2Options)] = [("production", .production)] + EnvgapHash.listenVariants
    for (letter, rate, cents) in cells {
        let url = PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(letter)", name: "\(letter)_phoneme1", ext: "wav"))!
        let raw = try SonificationSource.decodeMono(url: url, sampleRate: 44_100)
        let kind = SonificationSource.kind(forFileAt: url)
        let onset = PhonemeOnsets.onset(forFileNamed: url.lastPathComponent)
        let s48 = SonificationSource.load(url: url, gain: AudioEngine.loudnessGain(forFileAt: url), sampleRate: 48_000)!
        for (vn, o) in variants {
            let t44 = TDPSOLA2(source: raw, sampleRate: 44_100, kind: kind, maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                               tuning: .default, options: o, onset: onset, outputGain: 1)
            let t48 = TDPSOLA2(source: s48.samples, sampleRate: s48.sampleRate, kind: s48.kind,
                               maxFramesPerRender: LiveSonificationKernel.chunkFrames, tuning: .default, options: o,
                               onset: s48.onset, outputGain: s48.gain, file: s48.fileSource)
            print("LISTEN \(letter) \(rate) \(Int(cents)) \(vn) 0x\(String(fnv(t44, sr: 44_100, rate: rate, cents: cents), radix: 16)) 0x\(String(fnv(t48, sr: 48_000, rate: rate, cents: cents), radix: 16))")
        }
    }
}
