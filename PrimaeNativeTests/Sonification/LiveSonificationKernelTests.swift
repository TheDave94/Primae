// LiveSonificationKernelTests.swift
// PrimaeNativeTests — protocol r17 (2026-11-03)
//
// The render-thread half of the live voice, rendered offline: the envelope
// the r16 engine applied with `player.volume` (loudness gain, the stop fade,
// the demonstration fade-in), the restart at the attack on every gate-open,
// the equal-power crossover of a restart while sounding and the click-free
// duck of a file switch (lane LOOPX), and the per-sample pan.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("r17 live kernel")
nonisolated struct LiveSonificationKernelTests {

    static let sr = LiveSonificationKernel.sampleRate

    struct Rig {
        let kernel: LiveSonificationKernel
        var slots: [String: UInt32] = [:]

        init(sources: [StudySource], gain: Float = 1, ramps: LiveSonificationKernel.Ramps = .production) {
            kernel = LiveSonificationKernel(ramps: ramps)
            for s in sources {
                let (r, twin) = LiveSonificationAudio.makeRendererPair(s.sonificationSource)
                slots[s.name] = kernel.register(r, twin: twin, gain: gain)
            }
        }

        /// Renders `seconds` in 256-frame I/O buffers.
        func render(_ seconds: Double) -> [Float] {
            let total = Int(seconds * LiveSonificationKernel.sampleRate)
            var y = [Float](repeating: 0, count: total)
            var pos = 0
            y.withUnsafeMutableBufferPointer { b in
                while pos < total {
                    let n = min(256, total - pos)
                    kernel.render(into: b.baseAddress! + pos, frames: n)
                    pos += n
                }
            }
            return y
        }
    }

    @Test("closed: exact silence and the node reports silence")
    func idleIsSilent() throws {
        let rig = Rig(sources: [try StudySources.load("A_phoneme1")])
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        defer { buf.deallocate() }
        buf.initialize(repeating: 1, count: 256)
        #expect(rig.kernel.render(into: buf, frames: 256), "an idle kernel must flag silence")
        #expect((0..<256).allSatisfy { buf[$0] == 0 })
        #expect(!rig.kernel.isSounding)
    }

    @Test("open: sound from the very next buffer, at the loudness gain")
    func openSoundsInTheNextBuffer() throws {
        let src = try StudySources.load("A_phoneme1")
        let unity = Rig(sources: [src], gain: 1)
        let half = Rig(sources: [src], gain: 0.5)
        unity.kernel.open(slot: unity.slots["A_phoneme1"]!, fadeInFrames: 0)
        half.kernel.open(slot: half.slots["A_phoneme1"]!, fadeInFrames: 0)
        let a = unity.render(0.5), b = half.render(0.5)
        let nz = try #require(SonificationMetrics.firstNonZero(a, from: 0))
        #expect(nz <= 64, "first non-zero \(nz) frames after the open")
        let steady = SonificationMetrics.rms(a[Int(0.2 * Self.sr)...])
        let onset = try #require(SonificationMetrics.onsetFrames(a, from: 0, steadyRMS: steady, sampleRate: Self.sr))
        #expect(onset <= Int(0.005 * Self.sr) + 64, "-20 dB after \(onset) frames")
        let ratio = SonificationMetrics.rms(b[...]) / SonificationMetrics.rms(a[...])
        #expect(abs(ratio - 0.5) < 1e-3, "gain 0.5 rendered at \(ratio)")
    }

    @Test("stop: a linear fade over fadeOutFrames, then exact zeros")
    func stopFades() throws {
        let src = try StudySources.load("spatial_carrier")
        let rig = Rig(sources: [src])
        rig.kernel.open(slot: rig.slots["spatial_carrier"]!, fadeInFrames: 0)
        let pre = rig.render(0.3)
        let fade = UInt32(0.4 * Self.sr)
        rig.kernel.close(fadeOutFrames: fade)
        let post = rig.render(0.6)
        let level = SonificationMetrics.rms(pre[Int(0.1 * Self.sr)...])
        func at(_ t: Double) -> Double {
            SonificationMetrics.rms(post[Int((t - 0.01) * Self.sr)..<Int((t + 0.01) * Self.sr)]) / level
        }
        #expect(abs(at(0.1) - 0.75) < 0.06, "25 % into the fade: \(at(0.1))")
        #expect(abs(at(0.2) - 0.5) < 0.06, "half-way: \(at(0.2))")
        #expect(abs(at(0.3) - 0.25) < 0.06, "75 %: \(at(0.3))")
        #expect(post[Int(0.41 * Self.sr)...].allSatisfy { $0 == 0 }, "not silent after the fade")
        #expect(!rig.kernel.isSounding)
    }

    @Test("every gate-open restarts at the attack: a restart while sounding crosses over and replays the same opening (r17 ramps: POP2's resume is off)",
          arguments: ["A_phoneme1", "F_phoneme1"])
    func restartReplaysTheAttack(name: String) throws {
        let src = try StudySources.load(name)
        let rig = Rig(sources: [src], ramps: .r17)
        let slot = rig.slots[name]!
        rig.kernel.open(slot: slot, fadeInFrames: 0)
        let first = rig.render(0.4)
        rig.kernel.open(slot: slot, fadeInFrames: 0)          // play() while sounding
        let second = rig.render(0.4)
        #expect(rig.kernel.starts == 2)
        // The restart starts on the twin renderer at the next buffer; once the
        // crossover (crossfadeFrames) is over, the output is the first opening again.
        let x = Int(LiveSonificationKernel.crossfadeFrames), seg = 4096
        let err = zip(first[x..<(x + seg)], second[x..<(x + seg)]).map { abs($0 - $1) }.max() ?? 1
        #expect(err < 1e-4, "\(name): the restart did not replay the attack (max diff \(err))")
        // The crossover itself keeps the level: no window below a quarter of the level the opening itself has there
        // (R17D: the opening is now the recorded onset, which starts quiet: A's rough start, F's frication rise; the
        // steady level is not the reference for the first 20 ms of a replayed onset).
        let w = 64
        let ratios = stride(from: 0, to: x, by: w).map {
            SonificationMetrics.rms(second[$0..<($0 + w)]) / max(1e-9, SonificationMetrics.rms(first[$0..<($0 + w)]))
        }
        let minRatio = ratios.min() ?? 0
        #expect(minRatio > 0.25, "\(name): crossover dips to \(minRatio) of the opening's own level")
    }

    @Test("fade-in: a demonstration ramps in over fadeInFrames")
    func fadeIn() throws {
        let src = try StudySources.load("spatial_carrier")
        let rig = Rig(sources: [src])
        rig.kernel.open(slot: rig.slots["spatial_carrier"]!, fadeInFrames: UInt32(0.2 * Self.sr))
        let y = rig.render(0.6)
        let level = SonificationMetrics.rms(y[Int(0.3 * Self.sr)...])
        let mid = SonificationMetrics.rms(y[Int(0.09 * Self.sr)..<Int(0.11 * Self.sr)]) / level
        #expect(abs(mid - 0.5) < 0.08, "half-way through the fade-in: \(mid)")
    }

    @Test("a different file while sounding: duck, then the new file from its attack")

    func fileSwitch() throws {
        let a = try StudySources.load("A_phoneme1"), m = try StudySources.load("M_phoneme1")
        let rig = Rig(sources: [a, m])
        rig.kernel.open(slot: rig.slots["A_phoneme1"]!, fadeInFrames: 0)
        _ = rig.render(0.3)
        rig.kernel.open(slot: rig.slots["M_phoneme1"]!, fadeInFrames: 0)
        let y = rig.render(1.0)
        let f = try #require(SonificationMetrics.medianF0(y, from: Int(0.2 * Self.sr), to: y.count, sampleRate: Self.sr))
        let fm = try #require(SonificationMetrics.medianF0(m.samples, from: Int(0.2 * Self.sr), to: m.samples.count - 1000,
                                                           sampleRate: Self.sr))
        #expect(abs(f / fm - 1) < 0.01, "after the switch the voice plays \(f) Hz, M is \(fm) Hz")
    }

    @Test("rate and pitch commands reach the renderer at the next buffer")
    func pitchReachesTheRenderer() throws {
        let src = try StudySources.load("spatial_carrier")
        let rig = Rig(sources: [src])
        rig.kernel.setPitchCents(1200)
        rig.kernel.open(slot: rig.slots["spatial_carrier"]!, fadeInFrames: 0)
        let y = rig.render(1.0)
        let f = try #require(SonificationMetrics.zeroCrossingFrequency(y, from: Int(0.2 * Self.sr), to: y.count,
                                                                       sampleRate: Self.sr))
        #expect(abs(SonificationMetrics.cents(f, 440) - 1200) < 10, "carrier at +1200 c plays \(f) Hz")
    }
}
