// LoopXRegressionTests.swift
// PrimaeNativeTests — lane LOOPX (2026-11-03): one pin per confirmed cause of
// the r17 pops (LOOPX.md). Pure buffers through the real kernel
// (LoopXKernelDriver, 256-frame buffers, commands between calls), judged by
// the validated detector (LoopXDetector: dip and cut, the measures that fired
// at every H2 event before the fix on every source, and hf, which catches the
// hard splice a crossover of 0 leaves on M and the carrier).
//
//   H2  a gate-open inside the 0.4 s stop fade: the staged kernel cut the
//       fading voice (3 ms duck) and restarted from silence -> dip/cut.
//       Fixed by the equal-power crossover (crossfadeSeconds).
//       Mutation: crossfadeSeconds = 0 -> RED (hf on M, carrier; the hard
//       splice on A/F/I/L is inside the detector's blind spot, LOOPX.md).
//   H2b a switch to another sound while one sounds (close(0)): a 3 ms linear
//       duck -> cut. Fixed by the quarter-cosine duck (duckSeconds).
//       Mutation: duckSeconds = 0.003 -> RED.
//
// Rate 1 and pan 0 throughout, so nothing but the transition is measured.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("LOOPX transitions")
nonisolated struct LoopXRegressionTests {

    static let sr = LiveSonificationKernel.sampleRate

    /// dip/cut/hf events within 15 ms of `t` in the mono sum of the render.
    static func transitionEvents(_ r: LoopXRender, at t: Double) -> [LoopXDetector.Event] {
        let y = zip(r.left, r.right).map { $0 + $1 }
        return LoopXDetector.merge(LoopXDetector.detect(y, sr: sr), within: 0.010)
            .filter { abs($0.time - t) < 0.015 && ($0.kind.contains("dip") || $0.kind.contains("cut") || $0.kind.contains("hf")) }
    }

    @Test("H2: a stroke that starts inside the stop fade crosses over: no dip, cut or splice",
          arguments: StudySources.names, [0.05, 0.15, 0.30])
    func restartInsideTheFade(name: String, into fade: Double) throws {
        let src = try StudySources.load(name)
        var tl = LoopXTimeline()
        let reopen = 0.6 + fade
        tl.commands = [(0, .rate(1)), (0, .open(name, fadeIn: 0)),
                       (0.6, .close(fade: SoundEnvelope.fadeOutSeconds)),
                       (reopen, .open(name, fadeIn: 0))]
        tl.duration = reopen + 0.5
        let r = LoopXKernelDriver.render(tl, sources: [name: src])
        let e = Self.transitionEvents(r, at: reopen)
        #expect(e.isEmpty, "\(name), reopen \(fade) s into the fade: \(e)")
    }

    @Test("H2b: switching to another sound while one sounds ducks it without a cut",
          arguments: StudySources.names)
    func switchDucks(name: String) throws {
        let src = try StudySources.load(name)
        var tl = LoopXTimeline()
        tl.commands = [(0, .rate(1)), (0, .open(name, fadeIn: 0)), (0.6, .close(fade: 0))]
        tl.duration = 1.0
        let r = LoopXKernelDriver.render(tl, sources: [name: src])
        let e = Self.transitionEvents(r, at: 0.6)
        #expect(e.isEmpty, "\(name), switch-duck at 0.6 s: \(e)")
        let after = Int(0.65 * Self.sr)
        #expect(r.left[after...].allSatisfy { $0 == 0 }, "\(name): sound after the duck")
    }
}
