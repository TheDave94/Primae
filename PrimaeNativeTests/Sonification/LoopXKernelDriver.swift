// LoopXKernelDriver.swift
// PrimaeNativeTests — lane LOOPX (2026-11-03): renders a `LoopXTimeline`
// through a real `LiveSonificationKernel` in 256-frame I/O buffers, commands
// landing between buffers (the touch thread's atomics reach the next I/O
// callback), and returns the stereo output plus mechanism marks.
//
// The kernel renders mono; the pan is the source node's `AVAudioMixing.pan`
// in the main mixer, modelled as MEASURED on the iPad (LoopXMixerPanTests,
// LOOPX.md): constant-power gains, each slewing linearly toward its target at
// `panSlewPerSample`, from the first sample of the buffer after the change.
// (A first version stepped the gains at the buffer edge; the device showed
// no step, so that model's "pan-jump" events were the model's own.)
// Tree-specific lines: `treeTag` and the registration in `register`.
//
// Loop wraps are marked from a read-head model of the TDPSOLA renderer the
// slot holds (its own analysis: onset, attack centre, loop bounds), advanced
// with the commanded rate: accurate to well under the detector's 15 ms
// attribution window at the rates the scenarios use.

import Foundation
#if canImport(PrimaeNative)
@testable import PrimaeNative
#endif

nonisolated struct LoopXRender {
    var left: [Float]
    var right: [Float]
    var marks: [(t: Double, label: String)]
}

nonisolated enum LoopXKernelDriver {
    static let buffer = 256
    /// Which tree this driver belongs to (names the WAV folder).
    static let treeTag = "after"
    /// Mixer pan slew, gain units per sample (iPad, offline manual rendering).
    static let panSlewPerSample: Float = 0.000907
    static var sr: Double { LiveSonificationKernel.sampleRate }

    /// Constant-power pan law (the mixer's, as modelled).
    static func panGains(_ p: Float) -> (Float, Float) {
        let a = Double(max(-1, min(1, p)) + 1) * Double.pi / 4
        return (Float(cos(a)), Float(sin(a)))
    }

    /// Per-source detector settings: the lag range of the "res" measure
    /// (nil for noise: F) and its threshold, max(0.5, 1.1 x the largest
    /// "res" the source's own recording reads), so a breathy voice (A,
    /// whose recording alone reads ~0.6) is judged against itself.
    struct Profile { let period: ClosedRange<Double>?; let resThreshold: Double }

    static func profile(samples: [Float], kind: SourceKind, spatial: Bool) -> Profile {
        let period: ClosedRange<Double>?
        if spatial || kind == .carrier {
            period = (sr / 880 * 0.8)...(sr / 220 * 1.25)
        } else {
            let a = TDPSOLAAnalysis.analyse(samples, sampleRate: sr, kind: kind)
            if a.isVoiced {
                let lp = a.periods[a.attackIndex...a.loopEndIndex]
                period = (lp.min()! * 0.8)...(lp.max()! * 1.25)
            } else { period = nil }
        }
        guard let period else { return Profile(period: nil, resThreshold: 1) }
        let end = Double(samples.count) / sr - 0.05
        let own = LoopXDetector.residual(samples, sr: sr, period: period, threshold: 0)
            .filter { $0.time > 0.15 && $0.time < end }.map(\.score).max() ?? 0
        return Profile(period: period, resThreshold: max(LoopXDetector.resThreshold, 1.1 * own))
    }

    struct ReadHead {
        let onset, attackCentre, loopStart, loopEnd: Double
        init(_ a: TDPSOLAAnalysis) {
            onset = Double(a.onset)
            loopStart = a.loopStart; loopEnd = a.loopEnd
            let c = a.isVoiced ? a.marks[a.attackIndex] : a.loopStart
            attackCentre = c - onset
        }
    }

    /// Registers `s` at gain 1 the way production does (after tree: a renderer pair).
    static func register(_ s: StudySource, in kernel: LiveSonificationKernel) -> (UInt32, TDPSOLAAnalysis) {
        let (r, twin) = LiveSonificationAudio.makeRendererPair(s.sonificationSource)
        return (kernel.register(r, twin: twin, gain: 1)!, r.analysis)
    }

    /// `sources`: file name -> source.
    static func render(_ tl: LoopXTimeline, sources: [String: StudySource]) -> LoopXRender {
        let kernel = LiveSonificationKernel()
        var slots: [String: UInt32] = [:], heads: [String: ReadHead] = [:]
        for (name, s) in sources.sorted(by: { $0.key < $1.key }) {
            let (slot, analysis) = register(s, in: kernel)
            slots[name] = slot
            heads[name] = ReadHead(analysis)
        }
        let total = Int(tl.duration * sr)
        var left = [Float](repeating: 0, count: total), right = left
        var marks = tl.marks
        let cmds = tl.commands.enumerated().sorted { ($0.element.t, $0.offset) < ($1.element.t, $1.offset) }.map(\.element)
        var next = 0, pos = 0
        var pan: Float = 0, rate: Float = 1
        var (gl, gr) = panGains(0)
        var head: ReadHead?, s = 0.0, now = 0.0
        let mono = UnsafeMutablePointer<Float>.allocate(capacity: buffer)
        defer { mono.deallocate() }
        while pos < total {
            while next < cmds.count && Int((cmds[next].t * sr).rounded(.up)) <= pos {
                switch cmds[next].cmd {
                case .open(let f, let fi):
                    kernel.open(slot: slots[f]!, fadeInFrames: UInt32(fi * sr))
                    head = heads[f]; s = head!.onset; now = 0
                case .close(let fo): kernel.close(fadeOutFrames: UInt32(fo * sr))
                case .rate(let r): rate = r; kernel.setRate(r)
                case .cents(let c): kernel.setPitchCents(c)
                case .pan(let p): pan = p
                }
                next += 1
            }
            let n = min(buffer, total - pos)
            kernel.render(into: mono, frames: n)
            let (tl_, tr_) = panGains(pan)
            for i in 0..<n {
                left[pos + i] = mono[i] * gl; right[pos + i] = mono[i] * gr
                gl += max(-panSlewPerSample, min(panSlewPerSample, tl_ - gl))
                gr += max(-panSlewPerSample, min(panSlewPerSample, tr_ - gr))
            }
            if let h = head {
                for i in 0..<n {
                    if now + 1 < h.attackCentre { s += 1 } else { s += Double(rate) }
                    now += 1
                    if s >= h.loopEnd { s -= h.loopEnd - h.loopStart; marks.append((Double(pos + i) / sr, "wrap")) }
                }
            }
            pos += n
        }
        return LoopXRender(left: left, right: right, marks: marks)
    }
}
