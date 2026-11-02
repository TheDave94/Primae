// ArmLevelMatchingTests.swift
//
// D13.1 as an executable check (audit D2, from the 2026-11-01 protocol lane's
// ExpProtocolMixingTests.armLevelsMatched): every sound arm reaches the same
// loudness. Renders each arm's file OFFLINE through the engine's exact
// topology (player -> AVAudioUnitTimePitch -> mainMixer) at the gain the
// engine itself computes (`AudioEngine.loudnessGain`), and compares the
// rendered RMS with the spatial carrier's. No hardware, no AVAudioSession.

import Testing
import Foundation
import AVFoundation
@testable import PrimaeNative

@Suite("D13.1: the arm sounds reach the same level through the engine's topology")
struct ArmLevelMatchingTests {

    static func resolve(_ f: String) -> URL? {
        let leaf = (f as NSString).lastPathComponent
        let letter = String(leaf.prefix(1))
        for c in [f, "Letters/\(letter)/\(leaf)", "Resources/Letters/\(letter)/\(leaf)", leaf] {
            if let u = PrimaeBundle.audioURL(for: c) { return u }
        }
        return nil
    }

    /// RMS of the left channel over 1 s after 0.5 s, file played at `volume`
    /// through player -> time-pitch -> mixer (AudioEngine.init's connects).
    static func renderedLevel(file: String, volume: Float) throws -> Double {
        let url = try #require(resolve(file), "missing \(file)")
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: outFormat, maximumFrameCount: 4096)
        engine.attach(player)
        engine.attach(timePitch)
        let mixFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.connect(player, to: timePitch, format: mixFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: mixFormat)
        timePitch.rate = 1.0; timePitch.pitch = 0.0
        let f = try AVAudioFile(forReading: url)
        player.volume = volume
        try engine.start()
        player.scheduleFile(f, at: nil)
        player.play()
        let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                   frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var rendered = 0
        var sum = 0.0, n = 0
        while rendered < Int(44_100 * 1.5) {
            guard try engine.renderOffline(4096, to: out) == .success else { break }
            let l = out.floatChannelData![0]
            for i in 0..<Int(out.frameLength) where rendered + i >= 22_050 {
                sum += Double(l[i] * l[i]); n += 1
            }
            rendered += Int(out.frameLength)
        }
        engine.stop()
        try #require(n > 20_000, "offline render produced too little audio (\(n))")
        return (sum / Double(n)).squareRoot()
    }

    @Test("every phoneme file at its engine gain renders within 1.5 dB of the carrier")
    func armLevelsMatched() throws {
        let phonemes = ["A", "F", "I", "L", "M"].map { "Resources/Letters/\($0)/\($0)_phoneme1.wav" }
        func level(_ f: String) throws -> Double {
            let url = try #require(Self.resolve(f), "missing \(f)")
            AudioEngine.resetLoudnessCache()
            return try Self.renderedLevel(file: f, volume: AudioEngine.loudnessGain(forFileAt: url))
        }
        let carrier = try level(SpatialSonification.carrierToneFile)
        #expect(carrier > 0.001, "the carrier rendered silence")
        for f in phonemes {
            let dB = 20 * log10(try level(f) / carrier)
            #expect(abs(dB) < 1.5, "\(f) renders \(String(format: "%+.2f", dB)) dB against the carrier")
        }
    }
}
