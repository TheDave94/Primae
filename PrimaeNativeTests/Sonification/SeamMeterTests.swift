// SeamMeterTests.swift
// PrimaeNativeTests — lane SEAM2 (2026-11-04): the loop-seam meter (SeamMeter / SeamEvaluator), its controls, and the
// regression on the production renderer.
//
// David (RULINGS 2026-11-04): "the sounds are still not seamlessly looping". LOOPX searched the wrap for pops and
// found none: the seam is a repeating step in level / timbre and a slow drift that resets, so these tests judge
// rendered buffers by loudness and spectrum (SeamMeter), with the wrap instants read from the renderer's read-head.
//
// Controls first (a meter that cannot flag a known defect, or flags a clean tone, proves nothing); then every
// shipped sound at five rates, 12 s steady, against the targets of the brief:
//   - the level step across the wrap (300 ms either side) at most 0.3 dB;
//   - the periodic drift-reset (400 ms either side, mean over the wraps) at most 0.3 dB in magnitude;
//   - the drift inside a cycle (peak-to-peak of the 200 ms level) at most 0.8 dB.
// Mutation (TDPSOLATuning.default loopCrossfadeSeconds / loopFlattenDB = 0, the TDQ loop): RED, count read from the log.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("SEAM2 seam meter controls")
nonisolated struct SeamMeterControlTests {
    static let sr = SeamControls.sr

    static func run(_ y: [Float], wraps: [Double], window: Double = 0.1) -> [String: SeamFeatureResult] {
        let tr = SeamMeter.analyse(y, sr: sr)
        return Dictionary(uniqueKeysWithValues: SeamEvaluator.evaluate(tr, wraps: wraps, start: 1, window: window).map { ($0.name, $0) })
    }

    @Test("a steady tone with a wrap every 2 s flags nothing")
    func steadyToneIsClean() {
        let r = Self.run(SeamControls.steadyTone(), wraps: SeamControls.wraps2s)
        #expect(r.count == 6)
        for f in ["level dB", "timbre dB", "centroid st", "f0 cents", "periodicity"] {
            #expect(r[f]?.flagged == false, "\(f) flagged a steady tone: \(r[f]?.wrapMean ?? -1)")
        }
        #expect((r["level dB"]?.wrapMean ?? 1) < 0.01)
    }

    @Test("a planted level step is flagged and read at its size", arguments: [0.5, 1.5])
    func plantedLevelStep(db: Double) {
        let r = Self.run(SeamControls.levelStep(db: db, at: 6), wraps: [6])
        #expect(r["level dB"]?.flagged == true)
        #expect(abs((r["level dB"]?.wrapMean ?? 0) - db) < 0.05, "read \(r["level dB"]?.wrapMean ?? -1) for a planted \(db) dB")
        #expect(r["timbre dB"]?.flagged == false, "a level step must not read as timbre")
    }

    @Test("a planted brightness step is flagged as timbre and centroid, not as level")
    func plantedTimbreStep() {
        let r = Self.run(SeamControls.timbreStep(at: 6), wraps: [6])
        #expect(r["timbre dB"]?.flagged == true)
        #expect(r["centroid st"]?.flagged == true)
        #expect(r["level dB"]?.flagged == false)
    }

    @Test("a planted sawtooth (0.8 dB falling over each 2 s cycle, then reset) reads as a drift-reset")
    func plantedSawtooth() {
        let tr = SeamMeter.analyse(SeamControls.sawtooth(db: 0.8), sr: Self.sr)
        let d = SeamEvaluator.drift(tr, wraps: SeamControls.wraps2s, start: 0)
        #expect(d.meanReset > 0.3, "reset \(d.meanReset)")
        #expect(d.peakToPeakDB.allSatisfy { $0 > 0.4 })
    }
}

@Suite("SEAM2 loop seam, rendered")
nonisolated struct LoopSeamRegressionTests {
    static let rates: [Float] = [0.5, 0.7, 1.0, 1.4, 2.0]

    @Test("the loop wrap is not a step in level, nor a drift that resets (all sounds, five rates)",
          arguments: StudySources.names, LoopSeamRegressionTests.rates)
    func wrapIsNotAStep(name: String, rate: Float) throws {
        let src = try StudySources.load(name)
        let r = SonificationRendererUnderTest.make(src)
        let out = SeamRender.steady(r, rate: rate)
        #expect(out.wraps.count >= 3, "\(name) r\(rate): only \(out.wraps.count) wraps in 12 s")
        let tr = SeamMeter.analyse(out.samples, sr: r.sampleRate)
        let slow = SeamEvaluator.evaluate(tr, wraps: out.wraps, start: out.entry, window: 0.3)
        let level = slow.first { $0.name == "level dB" }!
        let d = SeamEvaluator.drift(tr, wraps: out.wraps, start: out.entry)
        #expect(level.wrapMean <= 0.3, "\(name) r\(rate): level step \(level.wrapMean) dB across the wrap")
        #expect(abs(d.meanReset) <= 0.3, "\(name) r\(rate): drift-reset \(d.meanReset) dB")
        #expect((d.peakToPeakDB.max() ?? 0) <= 0.8, "\(name) r\(rate): in-cycle drift \(d.peakToPeakDB.max() ?? 0) dB")
    }

    /// ENV3 (2026-11-05): the wrap PULSE. POP2 measured the wrap sample-step (max |d1| within one period of the wrap, over the
    /// median of the same measure 2 to 8 periods away) at 2.17x to 2.63x on A and 1.3x to 1.5x on M: the wrap grain read a period
    /// before the loop start, which in the prepared copy was the end of the attack, so the join stepped. The pre-head blend
    /// (TDPSOLALoopSeam.preBlendMarks) makes it continuous. Ceiling 1.8x for A and M at 0.5, 1 and 2x (I and L measured 1.1-1.3x offline, not run here: CPU budget).
    /// Mutation: `TDPSOLALoopSeam.preBlendMarks = 0` (A reads 2.4x to 2.6x again) - RED, count read from the log.
    @Test("ENV3: the loop wrap is not a pulse (max |d1| at the wrap over its neighbourhood), voiced sounds, rates 0.5, 1, 2",
          arguments: StudySources.voicedNames.filter { $0.hasPrefix("A_") || $0.hasPrefix("M_") }, [Float(0.5), 1.0, 2.0])
    func wrapIsNotAPulse(name: String, rate: Float) throws {
        let src = try StudySources.load(name)
        let r = SonificationRendererUnderTest.make(src)
        let out = SeamRender.steady(r, rate: rate, seconds: 9)   // A and M only, 9 s: the device kills the test host above 80 % CPU over 60 s (cpu_resource_fatal, measured 17:44), so this is kept light
        let y = out.samples
        let sr = r.sampleRate
        let per = max(40, Int(r.analysis.medianPeriod.rounded()))
        func pk(_ c: Int, _ h: Int) -> Double {
            var m: Float = 0
            for j in max(1, c - h)..<min(y.count, c + h) { m = max(m, abs(y[j] - y[j - 1])) }
            return Double(m)
        }
        var ratios: [Double] = []
        for w in out.wraps where w > 1.5 && w < Double(y.count) / sr - 0.2 {
            let c = Int(w * sr)
            var ctx: [Double] = []
            for k in 2...8 { ctx.append(pk(c + k * per, per / 2)); ctx.append(pk(c - k * per, per / 2)) }
            ctx.sort()
            ratios.append(pk(c, per) / max(1e-9, ctx[ctx.count / 2]))
        }
        try #require(ratios.count >= 2, "\(name) r\(rate): only \(ratios.count) wraps measured")
        let mean = ratios.reduce(0, +) / Double(ratios.count)
        #expect(mean <= 1.8, "\(name) r\(rate): wrap pulse \(mean)x over \(ratios.count) wraps")
    }

    @Test("the attack still plays once, from silence, unmodified; the loop never re-enters it", arguments: StudySources.voicedNames)
    func attackStillPlaysOnce(name: String) throws {
        let src = try StudySources.load(name)
        let r = SonificationRendererUnderTest.make(src)
        let out = SeamRender.steady(r, rate: 1, seconds: 4)
        let a = r.analysis
        // R17D: with a recorded onset the attack is the onset (A 0.42 s), so the loop is reached just after its declared end.
        let attackEnd = Double(src.onset?.attackEndFrame ?? 0) / src.sampleRate
        #expect(out.entry > 0 && out.entry < attackEnd + 0.2, "the read-head reaches the loop start at \(out.entry)")
        #expect(out.minHeadAfterEntry >= a.loopStart, "the read-head went back into the attack: \(out.minHeadAfterEntry) < \(a.loopStart)")
        #expect(r.debugLoopBounds.start == a.loopStart, "the loop start (end of the attack) is unchanged")
        #expect(r.debugLoopBounds.end < a.loopEnd, "the loop is shortened by the crossfade")
        // Same source, TDQ loop (both loop settings 0): the attack, from the onset to the loop start, is bit for bit the same.
        var tdq = TDPSOLATuning.default
        tdq.loopCrossfadeSeconds = 0; tdq.loopFlattenDB = 0
        let ref = TDPSOLA(source: src.samples, sampleRate: src.sampleRate, kind: src.kind,
                          maxFramesPerRender: LiveSonificationKernel.chunkFrames, analysis: a, tuning: tdq)
        let refOut = SeamRender.steady(ref, rate: 1, seconds: 1).samples
        // ENV3: the last `preBlendMarks` periods before the loop start now morph into the material that precedes the loop end
        // (the wrap-pulse fix, TDPSOLALoopSeam), so everything before that morph is still bit for bit the TDQ attack.
        // R17D: a recorded onset blends over its own `preBlendPeriods`.
        let preBlend = a.recordedOnset?.preBlendPeriods ?? TDPSOLALoopSeam.preBlendMarks
        let morphStart = Int(a.marks[max(0, a.attackIndex - preBlend)].rounded(.up))
        let attackFrames = morphStart - a.onset - 2
        #expect(attackFrames > 16)
        #expect(Array(out.samples[0..<attackFrames]) == Array(refOut[0..<attackFrames]), "\(name): the attack differs from the TDQ attack")
        #expect(abs(out.samples[0]) < 0.05, "the onset starts from silence (the gate ramps in from 0)")
    }
}
