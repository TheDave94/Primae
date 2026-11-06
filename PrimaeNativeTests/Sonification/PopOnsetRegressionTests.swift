// PopOnsetRegressionTests.swift
// PrimaeNativeTests: lane POP2 (2026-11-04). One test group per mechanism; each is meant to go RED under its mutation
// (POP2.md lists the mutation and the log line). Pure buffers, no AVAudioEngine (runs on the simulator too).
//   1. the pop meter itself (controls: a planted hard onset reads high, a smooth one reads low)
//   2. a voice that starts from silence rises on a raised cosine (mutation: `Ramps.production.onsetSeconds = 0`)
//   3. a restart after a gap does the same (same mutation)
//   3b. a restart while the same sound sounds continues it (mutation: `Ramps.production.resumeSameSound = false`)
//   4. the production ramps are pinned
//   5. loudness fluctuation (item e): the shipped A, I, M phoneme files were equalised OFFLINE per pitch period
//      (scripts/equalise_phoneme_periods.sh, smoothing 120 ms); the file and its render are pinned
//      (mutation: put the original `A_phoneme1.wav` back, sha256 8d1520f2...)
//   6. Bluetooth routes do not request the 5 ms IO buffer (mutation: drop the Bluetooth test in `ioBufferRequest`)

import Testing
import Foundation
import AVFoundation
@testable import PrimaeNative

@Suite("POP2 pops and loudness")
nonisolated struct PopOnsetRegressionTests {
    static let sr = LiveSonificationKernel.sampleRate

    // MARK: 1 the meter

    @Test func meterReadsAPlantedHardOnsetHighAndASmoothOneLow() {
        func read(_ ramp: Double) -> PopMeter.Onset {
            let x = PopMeter.plantedOnset(ramp: ramp)
            let hp = PopMeter.highPass(x, sr: Self.sr), ref = PopMeter.reference(x, hp: hp, sr: Self.sr)
            return PopMeter.onset(x, hp: hp, at: Int(0.2 * Self.sr), sr: Self.sr, ref: ref)
        }
        let hard = read(0), smooth = read(0.020)
        #expect(hard.splatterDB > 1.0, "hard onset splatter \(hard.splatterDB)")
        #expect(hard.slopeDB > 20, "hard onset slope \(hard.slopeDB)")
        #expect(smooth.splatterDB < -2.0 && smooth.slopeDB < -3, "smooth \(smooth)")
        #expect(PopMeter.silenceOnsets(PopMeter.plantedOnset(start: 0, ramp: 0), sr: Self.sr).isEmpty)
    }

    @Test func fluctuationMeterReadsAPlantedModulation() {
        let flat = PopMeter.fluctuation(PopMeter.amplitudeModulated(hz: 8, depthDB: 0), sr: Self.sr)
        let am = PopMeter.fluctuation(PopMeter.amplitudeModulated(hz: 8, depthDB: 0.5), sr: Self.sr)
        #expect(flat.p95 < 0.01 && flat.modRMS < 0.01)
        #expect(abs(am.modPeak - 0.5) < 0.1 && am.modPeakHz == 8, "peak \(am.modPeak) at \(am.modPeakHz) Hz")
        #expect(am.p95 > 0.35)
    }

    // MARK: 2, 3 onset ramp

    private func onsets(_ name: String, restart: Bool) throws -> (y: [Float], at: [Int]) {
        let src = try StudySources.load(name)
        let kernel = LiveSonificationKernel()
        let (r, twin) = LiveSonificationAudio.makeRendererPair(src.sonificationSource)
        let slot = try #require(kernel.register(r, twin: twin, gain: 1))
        var y = [Float](repeating: 0, count: Int(4 * Self.sr) / 256 * 256)
        var at: [Int] = [], silent = 0, phase = 0, t0 = 0
        y.withUnsafeMutableBufferPointer { b in
            var i = 0
            while i < b.count {
                if phase == 0 && i >= 2048 { kernel.open(slot: slot, fadeInFrames: 0); at.append(i); phase = 1; t0 = i }
                if phase == 1 && i - t0 >= Int(0.5 * Self.sr) { kernel.close(fadeOutFrames: UInt32(0.1 * Self.sr)); phase = 2; t0 = i }
                if phase == 2 && restart && silent >= 1 { kernel.open(slot: slot, fadeInFrames: 0); at.append(i); phase = 3 }
                let s = kernel.render(into: b.baseAddress! + i, frames: 256)
                silent = s ? silent + 1 : 0
                i += 256
            }
        }
        return (y, at)
    }

    /// RMS of the first `ms` of the voice that starts at the first nonzero sample at or after `from`.
    private func headRMS(_ y: [Float], from: Int, ms: Double) -> (rms: Double, steady: Double) {
        let i = y[from...].firstIndex { $0 != 0 } ?? from
        let n = Int(ms / 1000 * Self.sr)
        return (PopMeter.power(y, i, n).squareRoot(), PopMeter.power(y, i + Int(0.2 * Self.sr), Int(0.1 * Self.sr)).squareRoot())
    }

    @Test(arguments: ["spatial_carrier", "A_phoneme1", "M_phoneme1"])
    func aVoiceFromSilenceRisesOnARaisedCosine(name: String) throws {
        let r = try onsets(name, restart: false)
        let h = headRMS(r.y, from: r.at[0], ms: 1)
        #expect(h.rms < 0.03 * h.steady, "\(name): first ms at \(h.rms / h.steady) of the steady level (r17 hard onset: 0.3+)")
        // Splatter on the clean tone: below its own steady state with margin (r17: +0.1 dB, 8 ms ramp: -0.7 dB).
        if name == "spatial_carrier" {
            let s = PopMeter.summarise(r.y, sr: Self.sr)
            #expect(s.n == 1 && s.maxSplatter < -0.3, "carrier onset splatter \(s.maxSplatter) dB")
        }
    }

    @Test(arguments: ["spatial_carrier", "A_phoneme1"])
    func aRestartAfterAGapRisesToo(name: String) throws {
        let r = try onsets(name, restart: true)
        try #require(r.at.count == 2)
        let h = headRMS(r.y, from: r.at[1], ms: 1)
        #expect(h.rms < 0.03 * h.steady, "\(name): restart first ms at \(h.rms / h.steady)")
    }

    // MARK: 3b restart while sounding

    /// Restarts at several offsets into the 0.4 s stop fade; returns the dip (dB) of each.
    private func restartDips(_ name: String) throws -> [Double] {
        let src = try StudySources.load(name)
        var dips: [Double] = []
        for off in stride(from: 0.10, through: 0.30, by: 0.0123) {
            let kernel = LiveSonificationKernel()
            let (r, twin) = LiveSonificationAudio.makeRendererPair(src.sonificationSource)
            let slot = try #require(kernel.register(r, twin: twin, gain: 1))
            var y = [Float](repeating: 0, count: Int(2 * Self.sr) / 256 * 256)
            var at = -1, phase = 0, t0 = 0
            y.withUnsafeMutableBufferPointer { b in
                var i = 0
                while i < b.count {
                    if phase == 0 && i >= Int(0.2 * Self.sr) { kernel.open(slot: slot, fadeInFrames: 0); phase = 1; t0 = i }
                    if phase == 1 && i - t0 >= Int(0.6 * Self.sr) { kernel.close(fadeOutFrames: UInt32(0.4 * Self.sr)); phase = 2; t0 = i }
                    if phase == 2 && Double(i - t0) >= off * Self.sr { kernel.open(slot: slot, fadeInFrames: 0); phase = 3; at = i }
                    kernel.render(into: b.baseAddress! + i, frames: 256)
                    i += 256
                }
            }
            dips.append(PopMeter.crossover(y, at: at, len: Int(0.02 * Self.sr), sr: Self.sr).dipDB)
        }
        return dips
    }

    @Test(arguments: ["spatial_carrier", "M_phoneme1", "I_phoneme1"])
    func aRestartInsideTheStopFadeDoesNotCancel(name: String) throws {
        let worst = try restartDips(name).min()!
        // r17's crossover of two copies at unrelated phase: worst -12 dB (carrier), -19 (M), -14 (I); the continued voice: -1.0, -1.3, -1.4
        #expect(worst > -3.0, "\(name): worst dip \(worst) dB over 17 restart phases")
    }

    // MARK: 4 pins

    @Test func productionRampsArePinned() {
        #expect(LiveSonificationKernel.Ramps.production == .init(onsetSeconds: 0.008, crossfadeSeconds: 0.020, duckSeconds: 0.020, resumeSameSound: true, pitchGlideSeconds: 0.040))
        #expect(LiveSonificationKernel.Ramps.r17.onsetSeconds == 0)
    }

    // MARK: 5 loudness fluctuation (offline-equalised assets)

    /// 20 ms level-step p95 (dB) of the shipped file after 0.15 s, with the recording's own value before processing.
    /// Originals (sha256 in POP2.md): A 0.62, I 0.32, M 0.32. L 0.46 and F (unvoiced) were left as recorded.
    static let fileCeiling: [String: Double] = ["A_phoneme1": 0.55, "I_phoneme1": 0.25, "M_phoneme1": 0.25]

    @Test(arguments: ["A_phoneme1", "I_phoneme1", "M_phoneme1"])
    func theShippedFileIsEqualisedAndKeepsItsFormat(name: String) throws {
        let src = try StudySources.load(name)
        let f = PopMeter.fluctuation(src.samples, sr: Self.sr, from: Int(0.15 * Self.sr))
        let ceiling = try #require(Self.fileCeiling[name])
        #expect(f.p95 < ceiling, "\(name) file p95 \(f.p95) dB, ceiling \(ceiling)")
        // no clipping, the level is the recording's (about -22 dB RMS)
        #expect((src.samples.map { abs($0) }.max() ?? 0) < 0.999)
        let rms = PopMeter.db(PopMeter.power(src.samples, 0, src.samples.count))
        #expect(rms > -23.5 && rms < -21.5, "\(name) RMS \(rms) dB")
    }

    @Test(arguments: ["A_phoneme1", "I_phoneme1", "M_phoneme1"])
    func theRenderedVoiceFluctuatesNoMoreThanItsRecording(name: String) throws {
        let src = try StudySources.load(name)
        let raw = PopMeter.fluctuation(src.samples, sr: Self.sr, from: Int(0.15 * Self.sr))
        let k = LiveSonificationKernel()
        let (r, twin) = LiveSonificationAudio.makeRendererPair(src.sonificationSource)
        let slot = try #require(k.register(r, twin: twin, gain: 1))
        k.open(slot: slot, fadeInFrames: 0)
        var y = [Float](repeating: 0, count: Int(8 * Self.sr) / 256 * 256)
        y.withUnsafeMutableBufferPointer { b in var i = 0; while i < b.count { k.render(into: b.baseAddress! + i, frames: 256); i += 256 } }
        let f = PopMeter.fluctuation(y, sr: Self.sr, from: Int(0.5 * Self.sr))
        #expect(f.p95 <= raw.p95 + 0.05, "\(name) rendered p95 \(f.p95) dB vs file \(raw.p95) dB")
        #expect(f.p95 < (Self.fileCeiling[name] ?? 1), "\(name) rendered p95 \(f.p95) dB (A before: 0.66)")
    }

    // MARK: 6 Bluetooth

    @MainActor @Test func theFiveMillisecondBufferIsRequestedOnlyOffBluetooth() {
        #expect(SoundEnvelope.ioBufferRequest(outputs: [.builtInSpeaker]) == 0.005)
        #expect(SoundEnvelope.ioBufferRequest(outputs: [.headphones]) == 0.005)
        #expect(SoundEnvelope.ioBufferRequest(outputs: [.usbAudio]) == 0.005)
        #expect(SoundEnvelope.ioBufferRequest(outputs: [.bluetoothA2DP]) == nil)
        #expect(SoundEnvelope.ioBufferRequest(outputs: [.bluetoothHFP]) == nil)
        #expect(SoundEnvelope.ioBufferRequest(outputs: [.bluetoothLE]) == nil)
        #expect(SoundEnvelope.ioBufferRequest(outputs: [.builtInSpeaker, .bluetoothA2DP]) == nil)
        #expect(SoundEnvelope.ioBufferRequest(outputs: []) == 0.005)
    }

    /// Device only (the simulator's session has no hardware buffer to move): asking for 0 returns the system default,
    /// which is what a Bluetooth route gets. Logs the figures (POP2.md quotes them).
    @MainActor @Test func askingForZeroGivesBackTheSystemDefaultBuffer() throws {
        #if targetEnvironment(simulator)
        return
        #else
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback)
        try session.setPreferredIOBufferDuration(SoundEnvelope.preferredIOBufferSeconds)
        try session.setActive(true)
        let small = session.ioBufferDuration
        try session.setPreferredIOBufferDuration(0)
        try session.setActive(false)
        try session.setActive(true)
        let reset = session.ioBufferDuration
        print("POP2 IOBUF route=\(session.currentRoute.outputs.map { $0.portType.rawValue }) requested 5 ms -> effective \(small * 1000) ms; after asking for 0 -> \(reset * 1000) ms")
        #expect(small < 0.008)
        #expect(reset > 0.015, "asking for 0 did not return the default buffer: \(reset * 1000) ms")
        #endif
    }
}
