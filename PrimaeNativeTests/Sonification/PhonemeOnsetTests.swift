// PhonemeOnsetTests.swift
// PrimaeNativeTests — R17D (RULINGS 2026-11-05 "phoneme onset + loop" ... 2026-11-06 "rate decisions delegated")
//
// The onset + loop phoneme files, the F loop L5, U1 (the unvoiced path is not
// time-stretched), mapping M3's demonstration speed, and the observe fade.
// Pure buffers through the production renderer and kernel (no AVAudioEngine),
// so everything here runs in CI. Each pin was mutation-checked RED (R17D.md).

import Testing
import Foundation
import CryptoKit
@testable import PrimaeNative

@Suite("R17D: phoneme onsets, F unstretched, demonstration speed")
nonisolated struct PhonemeOnsetTests {

    static let sr = LiveSonificationKernel.referenceSampleRate
    static let phonemes = ["A_phoneme1", "F_phoneme1", "I_phoneme1", "L_phoneme1", "M_phoneme1"]
    /// sha256 (first 16 hex) of the shipped files the `PhonemeOnsets` hints were built for
    /// (onset/ONSET.md section 4, floop/FLOOP.md section 2: F = F_ONSET1 + L5).
    static let fileSHA16: [String: String] = [
        "A_phoneme1": "82662b128b859223", "F_phoneme1": "87f66b505d50c9ec", "I_phoneme1": "14fcbd97b618663e",
        "L_phoneme1": "fa54666a0a254a68", "M_phoneme1": "ecd939f12b27bb67",
    ]

    static func url(_ name: String) throws -> URL {
        let letter = String(name.prefix(1))
        return try #require(PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(letter)", name: name, ext: "wav")))
    }

    @Test("every study phoneme declares an onset, and its hint belongs to the shipped file (sha256)", arguments: phonemes)
    func hintBelongsToTheShippedFile(name: String) throws {
        let data = try Data(contentsOf: try Self.url(name))
        let sha16 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)
        #expect(String(sha16) == Self.fileSHA16[name], "\(name): a new file needs its own attack-end hint (PhonemeOnsets)")
        #expect(PhonemeOnsets.onset(forFileNamed: "\(name).wav") != nil)
        #expect(PhonemeOnsets.onset(forFileNamed: "spatial_carrier.wav") == nil, "the carrier has no recorded onset")
    }

    @Test("the loop starts at the declared attack end, not at the -3 dB rule inside the onset", arguments: phonemes)
    func loopStartsAtTheDeclaredAttackEnd(name: String) throws {
        let src = try StudySources.load(name)
        let onset = try #require(src.onset)
        let a = SonificationRendererUnderTest.make(src).analysis
        let h = Double(onset.attackEndFrame)
        #expect(a.recordedOnset == onset)
        #expect(a.loopStart >= h, "\(name): loop starts at \(a.loopStart) before the onset ends at \(h)")
        if a.isVoiced {
            #expect(a.loopStart < h + 1.5 * a.medianPeriod, "\(name): loop start \(a.loopStart) is not the first mark after \(h)")
        } else {
            #expect(a.loopStart == h)
        }
        let plain = TDPSOLAAnalysis.analyse(src.samples, sampleRate: Self.sr, kind: src.kind)
        #expect(plain.loopStart < h, "\(name): the renderer's own rule would end the attack at \(plain.loopStart)")
    }

    // MARK: (a) the onset plays once, as recorded, at pen-down

    @Test("(a) pen-down from silence plays the recorded onset (as recorded up to the first periodic mark, then at the steady F0), the onset blends into the loop over its declared length, and the loop never re-enters it",
          arguments: phonemes)
    func onsetPlaysOnceAtPenDown(name: String) throws {
        let src = try StudySources.load(name)
        let rig = LiveSonificationKernelTests.Rig(sources: [src], ramps: .production)
        rig.kernel.open(slot: rig.slots[name]!, fadeInFrames: 0)
        let y = rig.render(1.0)
        let r = SonificationRendererUnderTest.make(src)
        let a = r.analysis
        let pre = try #require(a.recordedOnset).preBlendPeriods
        let o = a.onset
        let from = Int(0.011 * Self.sr)
        // The renderer's material: the played samples ARE the file from the onset up to the start of the hand-over
        // into the loop (the 64-sample taper of `keepRecordedOnset` excluded). The pulse limiter would have rewritten
        // A's and I's starts.
        let keepEnd = (a.isVoiced ? Int(a.marks[a.attackIndex - pre]) : Int(a.loopStart)) - 64
        #expect(keepEnd > o + from + Int(0.03 * Self.sr), "\(name): onset region too short to test (\(keepEnd))")
        let played = r.playedSamples
        let kept = (o..<keepEnd).map { abs(played[$0] - src.samples[$0]) }.max() ?? 1
        #expect(kept < 1e-6, "\(name): the renderer's onset material is not the recording (max diff \(kept))")
        // What pen-down plays (r31, item 7: the voiced attack is PSOLA'd at the steady F0, ProductionRendererTests):
        // after the kernel's 8 ms start ramp and the gate's 2 ms ramp, up to the first periodic mark (the flat grain:
        // I's breath, A's rough glottal start) the output IS the file (gain 1, rate 1: output frame i = source frame
        // onset + i); F (unvoiced) plays the file up to the hand-over. A voiced letter that starts periodic at once
        // (L from its 2nd mark, M at its first) has no flat grain longer than the ramps; for it only the material
        // above and the steady-F0 attack (ProductionRendererTests.attackFollowsPitch) apply.
        // The flat grain plays the renderer's material verbatim, and that material is the file up to `keepEnd`. On I the
        // two ends cross: its periodic attack is short (marks 14-25) and the declared 12-period hand-over into the loop
        // starts at mark 13, inside the breath, so from keepEnd on the flat grain plays the blend, not the file
        // (MEASURED, lane PITCHWIN macOS driver: I output == played to 0.0 up to mark 14; the file differs from 2359).
        let flatEnd = (a.isVoiced ? Int(a.marks[r.attackFirstMark]) - 2 : keepEnd) - o
        if flatEnd > from {
            let err = (from..<flatEnd).map { abs(y[$0] - played[$0 + o]) }.max() ?? 1
            #expect(err < 1e-5, "\(name): the onset at pen-down is not the renderer's material up to frame \(flatEnd) (max diff \(err))")
            let fileEnd = min(flatEnd, keepEnd - o)
            let errFile = (from..<fileEnd).map { abs(y[$0] - src.samples[$0 + o]) }.max() ?? 1
            #expect(errFile < 1e-5, "\(name): the onset at pen-down is not the recording up to frame \(fileEnd) (max diff \(errFile))")
        }
        #expect(!a.isVoiced || r.attackFirstMark < a.attackIndex, "\(name): the attack is not shifted (first mark \(r.attackFirstMark))")
        if a.isVoiced && pre > 4 {
            // The hand-over spans the declared pre-blend (not the default 2 periods): between its middle and the
            // default blend's start the renderer's material already differs from the file.
            let lo = Int(a.marks[a.attackIndex - pre / 2]), hi = Int(a.marks[a.attackIndex - TDPSOLALoopSeam.preBlendMarks])
            let blend = (lo..<hi).map { abs(played[$0] - src.samples[$0]) }.max() ?? 0
            #expect(blend > 1e-3, "\(name): no blend over the declared \(pre) periods (max diff \(blend))")
        }
        // Once: after the entry into the loop the read-head never goes back into the onset.
        let out = SeamRender.steady(r, rate: 1, seconds: 4)
        #expect(out.entry > 0, "\(name): never reached the loop")
        #expect(out.minHeadAfterEntry >= a.loopStart, "\(name): the read-head re-entered the onset")
    }

    // MARK: (b) / (c) resume inside the hold vs restart after a stop

    @Test("(b) a stroke inside the stop fade (the hold's tail) continues the loop: it does not replay the onset", arguments: phonemes)
    func resumeInsideTheHoldDoesNotReplayTheOnset(name: String) throws {
        let src = try StudySources.load(name)
        let ref = LiveSonificationKernelTests.Rig(sources: [src], ramps: .production)
        ref.kernel.open(slot: ref.slots[name]!, fadeInFrames: 0)
        let straight = ref.render(1.6)
        let rig = LiveSonificationKernelTests.Rig(sources: [src], ramps: .production)
        let slot = rig.slots[name]!
        rig.kernel.open(slot: slot, fadeInFrames: 0)
        var y = rig.render(1.0)
        rig.kernel.close(fadeOutFrames: UInt32(0.4 * Self.sr))
        y += rig.render(0.1)
        rig.kernel.open(slot: slot, fadeInFrames: 0)          // pen down again, the voice still sounding
        y += rig.render(0.5)
        #expect(rig.kernel.starts == 2)
        // Once the level is back (crossover length), the output is the uninterrupted voice, not its onset.
        let from = Int(1.15 * Self.sr), to = Int(1.6 * Self.sr)
        var num = 0.0, den = 0.0
        for i in from..<to { let d = Double(y[i] - straight[i]); num += d * d; den += Double(straight[i]) * Double(straight[i]) }
        #expect(num / den < 1e-4, "\(name): the resumed voice is not the continuing loop (residual \(num / den))")
        var onsetNum = 0.0
        for i in from..<to { let d = Double(y[i] - straight[i - Int(1.1 * Self.sr)]); onsetNum += d * d }
        #expect(onsetNum / den > 0.1, "\(name): the resumed voice replays the opening")
    }

    @Test("(c) a stroke after a real stop restarts at the onset", arguments: phonemes)
    func restartAfterAStopReplaysTheOnset(name: String) throws {
        let src = try StudySources.load(name)
        let rig = LiveSonificationKernelTests.Rig(sources: [src], ramps: .production)
        let slot = rig.slots[name]!
        rig.kernel.open(slot: slot, fadeInFrames: 0)
        let first = rig.render(0.6)
        rig.kernel.close(fadeOutFrames: UInt32(0.4 * Self.sr))
        let gap = rig.render(1.0)
        #expect(!rig.kernel.isSounding && gap.suffix(1000).allSatisfy { $0 == 0 }, "precondition: the voice stopped")
        rig.kernel.open(slot: slot, fadeInFrames: 0)
        let second = rig.render(0.6)
        #expect(rig.kernel.starts == 2)
        let err = zip(first, second).map { abs($0 - $1) }.max() ?? 1
        #expect(err < 1e-6, "\(name): the restart after a stop is not the opening again (max diff \(err))")
    }

    // MARK: (d) U1: F is not time-stretched

    @Test("(d) U1: the unvoiced phoneme (F) renders identically at rates 0.8, 1 and 1.25; a voiced one does not")
    func unvoicedPathIgnoresTheRate() throws {
        let f = try StudySources.load("F_phoneme1")
        #expect(!SonificationRendererUnderTest.make(f).analysis.isVoiced, "precondition: F takes the unvoiced path")
        let slow = SonificationDriver.steady(SonificationRendererUnderTest.make(f), seconds: 6, rate: 0.8)
        let one = SonificationDriver.steady(SonificationRendererUnderTest.make(f), seconds: 6, rate: 1.0)
        let fast = SonificationDriver.steady(SonificationRendererUnderTest.make(f), seconds: 6, rate: 1.25)
        #expect(slow == one, "F at 0.8 differs from F at 1")
        #expect(fast == one, "F at 1.25 differs from F at 1")
        // Control: the voiced path still follows the rate (the instrument can see a rate).
        let a = try StudySources.load("A_phoneme1")
        let aSlow = SonificationDriver.steady(SonificationRendererUnderTest.make(a), seconds: 2, rate: 0.8)
        let aFast = SonificationDriver.steady(SonificationRendererUnderTest.make(a), seconds: 2, rate: 1.25)
        #expect(aSlow != aFast, "control: A ignores the rate too")
    }

    // MARK: AE-2 on the loop part

    @Test("AE-2: a phoneme with an onset is level-matched on its loop part (A's onset would turn it down by 5 dB)")
    @MainActor func loudnessIsMeasuredOnTheLoop() throws {
        let url = try Self.url("A_phoneme1")
        AudioEngine.resetLoudnessCache()
        defer { AudioEngine.resetLoudnessCache() }
        let loop = try #require(AudioEngine.fileRMS(at: url, fromFrame: 18601))
        let whole = try #require(AudioEngine.fileRMS(at: url))
        let gain = AudioEngine.loudnessGain(forFileAt: url)
        #expect(abs(gain - AudioEngine.loudnessTargetRMS / loop) < 1e-5, "A's gain \(gain) is not the loop-part gain")
        #expect(20 * log10(Double(whole / loop)) > 3, "precondition: A's onset moves the whole-file level (\(whole) vs \(loop))")
    }

    // MARK: (f) the demonstration's dot is the r16 dot; M3 gives it its rate

    /// The guide's cell units along the study iPad's vertical strokes, pt (MEASURED, R17D: I's stem tracked at rate
    /// 1.0301595 under the r16 map at 0.36 units/s = 315.08 pt/s).
    static let studyCellUnitPoints: CGFloat = 875.2

    @Test("(f) the observe dot is unchanged from r16 (0.36 units/s) and M3 plays it at the rate its constants give (both arms share the guide and the map)")
    @MainActor func demonstrationDotIsUnchanged() {
        let dot = AnimationGuideController.observeUnitsPerSecond
        #expect(abs(dot - 0.9 * AnimationSpeed.slow.multiplier) < 1e-9, "the dot moved: \(dot) units/s")
        let v = CGFloat(dot) * Self.studyCellUnitPoints
        // M3's own anchors: 50 -> 0.8, 150 -> 1.0, 400 -> 1.25, linear between.
        let expected = Float(1.0 + 0.25 * ((v - 150) / (400 - 150)))
        let rate = TouchDispatcher.mapVelocityToSpeed(v)
        #expect(abs(rate - expected) < 0.01, "the demonstration plays at \(rate)x, M3 gives \(expected) (dot \(v) pt/s)")
        #expect(rate > 1.1 && rate < 1.25, "the demonstration plays at \(rate)x")
    }

    // MARK: the observe fade does not eat the onset

    @Test("a sound with a recorded onset starts like a stroke when the demonstration asks for a fade-in; the carrier keeps its fade")
    @MainActor func demonstrationFadeSparesTheOnset() {
        func tone(_ key: String, onset: RecordedOnset?) -> SonificationSource {
            let s = (0..<Int(Self.sr)).map { i in Float(0.3 * sin(2 * .pi * 200 * Double(i) / Self.sr)) }
            return SonificationSource(key: key, samples: s, kind: .voicedPhoneme, gain: 1, onset: onset)
        }
        func opening(_ src: SonificationSource, fade: TimeInterval) -> [Float] {
            let voice = LiveSonificationAudio(host: nil, output: FakeLiveOutput(), kernel: LiveSonificationKernel(),
                                              fadeOutSeconds: 0.05, observeSession: false, resolve: { _, _ in src })
            voice.loadAudioFile(named: "x", autoplay: false)
            if fade > 0 { voice.play(fadeInSeconds: fade) } else { voice.play() }
            var y = [Float](repeating: 0, count: Int(0.15 * Self.sr))
            y.withUnsafeMutableBufferPointer { _ = voice.kernel.render(into: $0.baseAddress!, frames: $0.count) }
            return y
        }
        let withOnset = tone("p", onset: RecordedOnset(attackEndFrame: 2000, preBlendPeriods: 2))
        #expect(opening(withOnset, fade: 0.12) == opening(withOnset, fade: 0), "the 120 ms fade was applied over the onset")
        let carrier = tone("c", onset: nil)
        #expect(opening(carrier, fade: 0.12) != opening(carrier, fade: 0), "control: a sound without an onset keeps the fade")
    }
}
