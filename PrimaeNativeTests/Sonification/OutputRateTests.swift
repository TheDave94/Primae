// OutputRateTests.swift
// PrimaeNativeTests — r31 lane PITCHWIN (2026-11-26): the voice renders at the output rate.
//
// The iPad's speaker runs at 48 kHz and iOS refuses a 44.1 kHz session there (MEASURED: fdca7ca8, six activations,
// session 48000). Rendering at 44.1 kHz left one realtime conversion in the main mixer, whose filter rolled F off
// above 19.5 kHz (-0.68 dB on the device). From r31 the kernel, the renderers and the source node run at the output
// rate, and the 44.1 kHz assets are resampled once, at load. These tests pin the pieces: the offline resample (length,
// timing, level up to the top of the band), the recorded onset scaled with it, the kernel's own frame counts, the
// voice's re-rate on a new output rate, and the production renderer's pitch and level at 48 kHz.

import AVFoundation
import Foundation
import Testing
@testable import PrimaeNative

/// A `LiveSonificationOutput` that runs session work at once (the re-rate path reads the rate there).
@MainActor
final class RunningSessionOutput: LiveSonificationOutput {
    var isRunning = true
    var sessionWorkCalls = 0
    func startIfNeeded(then: (@MainActor () -> Void)?) { then?() }
    func performSessionWork(_ work: @escaping @Sendable () -> Void) { sessionWorkCalls += 1; work() }
    func setPan(_ pan: Float) {}
}

@Suite("r31 output rate: the offline resample")
nonisolated struct OutputRateResampleTests {

    static func sine(_ hz: Double, rate: Double, seconds: Double, amp: Double = 0.5) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(amp * sin(2 * .pi * hz * Double($0) / rate)) }
    }
    static func rmsDB(_ x: ArraySlice<Float>) -> Double {
        let e = x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count)
        return 10 * log10(e)
    }

    @Test("44.1 -> 48 kHz: length scales, and an impulse lands at k x 48000/44100 (no added latency)")
    func lengthAndTiming() throws {
        var x = [Float](repeating: 0, count: 44_100)
        x[10_000] = 1
        let y = try SonificationSource.resample(x, from: 44_100, to: 48_000)
        #expect(abs(y.count - 48_000) <= 2, "length \(y.count)")
        let peak = y.indices.max { abs(y[$0]) < abs(y[$1]) }!
        let want = Int((10_000.0 * 48_000 / 44_100).rounded())
        #expect(abs(peak - want) <= 1, "impulse at \(peak), want \(want)")
    }

    @Test("the level is kept across the band, up to 20 kHz (the mixer's realtime filter lost 0.68 dB of F there)",
          arguments: [1_000.0, 8_000.0, 16_000.0, 19_500.0, 20_000.0])
    func levelKept(hz: Double) throws {
        let x = Self.sine(hz, rate: 44_100, seconds: 1)
        let y = try SonificationSource.resample(x, from: 44_100, to: 48_000)
        let a = Self.rmsDB(x[4_410..<39_690]), b = Self.rmsDB(y[4_800..<43_200])
        #expect(abs(b - a) <= 0.05, "\(hz) Hz: \(b - a) dB")
    }

    @Test("a study asset decoded at 48 kHz: its rate, its length, and its recorded onset scaled with it")
    func studyAssetAt48k() throws {
        let url = try #require(PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/I", name: "I_phoneme1", ext: "wav")))
        let a = try #require(SonificationSource.load(url: url, gain: 1, sampleRate: 44_100))
        let b = try #require(SonificationSource.load(url: url, gain: 1, sampleRate: 48_000))
        #expect(a.sampleRate == 44_100 && b.sampleRate == 48_000)
        #expect(abs(Double(b.samples.count) - Double(a.samples.count) * 48_000 / 44_100) <= 2)
        let oa = try #require(a.onset), ob = try #require(b.onset)
        #expect(oa.attackEndFrame == 4_250)
        #expect(ob.attackEndFrame == Int((4_250.0 * 48_000 / 44_100).rounded()))
        #expect(ob.preBlendPeriods == oa.preBlendPeriods)
    }
}

@Suite("r31 output rate: kernel and voice")
@MainActor struct OutputRateVoiceTests {

    static func tone(_ key: String, rate: Double) -> SonificationSource {
        let s = (0..<Int(rate)).map { i -> Float in Float(0.3 * sin(2 * .pi * 200 * Double(i) / rate)) }
        var src = SonificationSource(key: key, samples: s, kind: .voicedPhoneme, gain: 1)
        src.sampleRate = rate
        return src
    }

    final class Calls { var resolveRates: [Double] = []; var rebuilds: [Double] = [] }

    static func rig(sessionRate: Double = 48_000) -> (LiveSonificationAudio, Calls) {
        let calls = Calls()
        let voice = LiveSonificationAudio(
            host: HostSpy(), output: RunningSessionOutput(), kernel: LiveSonificationKernel(sampleRate: 44_100),
            fadeOutSeconds: 0.05, observeSession: false,
            outputRate: { sessionRate },
            rebuildOutput: { _, rate in
                calls.rebuilds.append(rate)
                return (LiveSonificationKernel(sampleRate: rate), RunningSessionOutput())
            },
            resolve: { name, rate in calls.resolveRates.append(rate); return name == "a" ? OutputRateVoiceTests.tone("a", rate: rate) : nil })
        return (voice, calls)
    }

    static func render(_ k: LiveSonificationKernel, seconds: Double) -> [Float] {
        let n = Int(seconds * k.sampleRate)
        var y = [Float](repeating: 0, count: n)
        var pos = 0
        y.withUnsafeMutableBufferPointer { b in
            while pos < n { let m = min(256, n - pos); _ = k.render(into: b.baseAddress! + pos, frames: m); pos += m }
        }
        return y
    }

    @Test("the voice's fade frames follow the kernel's rate")
    func framesFollowKernel() {
        let (voice, _) = Self.rig()
        #expect(voice.frames(0.1) == 4_410)
        voice.adoptOutputRate(48_000)
        #expect(voice.frames(0.1) == 4_800)
    }

    @Test("a new output rate rebuilds the voice at it: sources decoded and renderers built at the new rate, the loaded sound reloaded and still playing, the controls kept")
    func reRate() {
        let (voice, calls) = Self.rig()
        voice.loadAudioFile(named: "a", autoplay: true)
        voice.kernel.setPressureGain(0.5)
        voice.kernel.setRoughness(0.25)
        #expect(voice.isPlaying && calls.resolveRates == [44_100])
        voice.adoptOutputRate(48_000)
        #expect(calls.rebuilds == [48_000])
        #expect(voice.rateRebuilds == 1)
        #expect(voice.kernel.sampleRate == 48_000)
        #expect(calls.resolveRates == [44_100, 48_000], "the sound must be decoded again at the new rate")
        #expect(voice.loadedKey == "a" && voice.isPlaying, "the loaded sound is reloaded and resumes")
        #expect(voice.kernel.requestedPressureGain == 0.5 && voice.kernel.requestedRoughness == 0.25)
        let y = Self.render(voice.kernel, seconds: 0.3)
        #expect(SonificationMetrics.rms(y[Int(0.2 * 48_000)...]) > 0.05, "the rebuilt voice must sound")
    }

    @Test("the same rate, or no rate, rebuilds nothing")
    func sameRateIsANoOp() {
        let (voice, calls) = Self.rig()
        voice.adoptOutputRate(44_100)
        voice.adoptOutputRate(0)
        voice.adoptOutputRate(.nan)
        #expect(calls.rebuilds.isEmpty && voice.rateRebuilds == 0)
    }

    @Test("the session's rate is read in the session work and adopted on the main actor")
    func sessionRateIsAdopted() async {
        let (voice, calls) = Self.rig(sessionRate: 48_000)
        voice.adoptSessionRate()
        for _ in 0..<200 where voice.rateRebuilds == 0 { await Task.yield() }
        #expect(calls.rebuilds == [48_000] && voice.kernel.sampleRate == 48_000)
    }

    @Test("a route change reads the rate back and re-rates")
    func routeChangeReRates() async {
        let (voice, calls) = Self.rig(sessionRate: 48_000)
        voice.handleRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue)
        for _ in 0..<200 where voice.rateRebuilds == 0 { await Task.yield() }
        #expect(calls.rebuilds == [48_000])
    }
}

@Suite("r31 output rate: the production renderer at 48 kHz")
nonisolated struct OutputRateRendererTests {

    static func source48(_ name: String) throws -> SonificationSource {
        let letter = String(name.prefix(1))
        let url = try #require(PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(letter)", name: name, ext: "wav")))
        return try #require(SonificationSource.load(url: url, gain: 1, sampleRate: 48_000))
    }

    /// The steady part of a held render at 48 kHz (0.6 .. 2.4 s).
    static func steady(_ r: TDPSOLA2, cents: Float) -> ArraySlice<Float> {
        SonificationDriver.steady(r, seconds: 2.6 * 48_000 / LiveSonificationKernel.referenceSampleRate, rate: 1,
                                  cents: cents)[Int(0.6 * 48_000)..<Int(2.4 * 48_000)]
    }

    @Test("held at +-300 / +-600 c: F0 moves by the pitch factor (+-5 c) and the level stays within 0.5 dB of 0 cents",
          arguments: StudySources.voicedNames)
    func pitchAndLevel(name: String) throws {
        let s = try Self.source48(name)
        let r = LiveSonificationAudio.makeRenderer(s)
        #expect(r.sampleRate == 48_000)
        let ref = Self.steady(r, cents: 0)
        // C1Metrics reads at 44.1 kHz; a ratio of two readings at one rate is the same at any rate.
        let f0 = try #require(C1Metrics.medianF0(ref))
        let l0 = C1Metrics.rms(ref)
        for c: Float in [-600, -300, 300, 600] {
            let seg = Self.steady(r, cents: c)
            let pf = exp2(Double(c) / 1200)
            let f = try #require(C1Metrics.f0Near(seg, expected: f0 * pf))
            #expect(abs(C1Metrics.cents(f, f0 * pf)) <= 5, "\(name) \(c) c: \(C1Metrics.cents(f, f0 * pf)) c")
            let d = C1Metrics.dB(C1Metrics.rms(seg), l0)
            #expect(abs(d) <= 0.5, "\(name) \(c) c: level \(d) dB re 0 cents")
        }
    }

    @Test("a voiced source at 48 kHz is analysed at its file rate: marks, periods, loop and the attack's first periodic mark are the 44.1 kHz analysis scaled",
          arguments: StudySources.voicedNames)
    func marksAreTheFileRateMarksScaled(name: String) throws {
        let letter = String(name.prefix(1))
        let url = try #require(PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\(letter)", name: name, ext: "wav")))
        let s44 = try #require(SonificationSource.load(url: url, gain: 1, sampleRate: 44_100))
        let s48 = try #require(SonificationSource.load(url: url, gain: 1, sampleRate: 48_000))
        #expect(s44.fileSource == nil && s48.fileSource?.sampleRate == 44_100)
        let r44 = LiveSonificationAudio.makeRenderer(s44), r48 = LiveSonificationAudio.makeRenderer(s48)
        let k = 48_000.0 / 44_100, a = r44.analysis, b = r48.analysis
        #expect(a.isVoiced && b.isVoiced)
        #expect(b.marks.count == a.marks.count && b.periods.count == a.periods.count)
        let dm = zip(a.marks, b.marks).map { abs($0 * k - $1) }.max() ?? .infinity
        let dp = zip(a.periods, b.periods).map { abs($0 * k - $1) }.max() ?? .infinity
        #expect(dm <= 1e-6, "\(name): marks off the scaled 44.1 kHz marks by \(dm) samples")
        #expect(dp <= 1e-6, "\(name): periods off by \(dp) samples")
        #expect(b.attackIndex == a.attackIndex && b.loopEndIndex == a.loopEndIndex)
        #expect(abs(b.loopStart - a.loopStart * k) <= 1e-6 && abs(b.loopEnd - a.loopEnd * k) <= 1e-6)
        #expect(r48.attackFirstMark == r44.attackFirstMark, "\(name): first periodic mark \(r48.attackFirstMark) vs \(r44.attackFirstMark)")
        #expect((r48.epochReport?.applied) == (r44.epochReport?.applied))
    }

    /// 0.2 dB: production measures 0.06 dB worst at 48 kHz (bench 2026-11-26T23:07Z); F without item 8 measured
    /// 0.91 dB on the 44.1 kHz bench.
    @Test("F (unvoiced) at 48 kHz keeps its level within 0.2 dB at +-300 / +-600 c")
    func fLevel() throws {
        let r = LiveSonificationAudio.makeRenderer(try Self.source48("F_phoneme1"))
        let l0 = C1Metrics.rms(Self.steady(r, cents: 0))
        for c: Float in [-600, -300, 300, 600] {
            let d = C1Metrics.dB(C1Metrics.rms(Self.steady(r, cents: c)), l0)
            #expect(abs(d) <= 0.2, "F \(c) c: level \(d) dB re 0 cents")
        }
    }
}
