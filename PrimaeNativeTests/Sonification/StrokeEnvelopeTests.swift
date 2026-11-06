// StrokeEnvelopeTests.swift
// PrimaeNativeTests: lane ENV3 (2026-11-05, protocol r17). Pure values and kernel buffers (runs on the simulator too).
//   1. StrokeTempo: the per-child adaptive hold and stall (seed, slow child, fast child, breaks, clamps)
//   2. the stroke-start pitch glide (F's second stroke in the spatial arm): a two-octave step while the voice is held
//      glides; a small in-stroke step is followed as fast as before (mutation: `ENV3Tuning.pitchGlideSeconds = 0`)
//   3. the export columns for the child's envelope timing
// The touch-path tests (hold passed to the controller, last stroke fades at once) are in ProtocolMatrixTests.

import Testing
import Foundation
@testable import PrimaeNative

@Suite("ENV3 stroke envelope")
@MainActor struct StrokeEnvelopeTests {
    static let sr = LiveSonificationKernel.sampleRate

    // MARK: 1 tempo

    @Test func aChildWithNoGapsYetHearsTodaysHoldAndStall() {
        let t = StrokeTempo()
        #expect(t.holdSeconds == SoundEnvelope.liftHoldSeconds && t.stallSeconds == SoundEnvelope.stallSeconds)
        #expect(t.measured == 0)
    }

    @Test func aSlowChildGetsALongerHoldAndStallAFastChildAShorterHold() {
        var slow = StrokeTempo()
        for _ in 0..<5 { slow.record(gap: 1.2) }
        #expect(abs(slow.holdSeconds - 2.4) < 1e-9, "slow hold \(slow.holdSeconds)")
        #expect(slow.stallSeconds > SoundEnvelope.stallSeconds && slow.stallSeconds <= StrokeTempo.maxStall)
        var fast = StrokeTempo()
        for _ in 0..<5 { fast.record(gap: 0.15) }
        #expect(fast.holdSeconds == StrokeTempo.minHold, "fast hold \(fast.holdSeconds)")
        #expect(fast.stallSeconds == StrokeTempo.minStall)
    }

    @Test func theHoldIsClampedAndABreakIsNotAGap() {
        var t = StrokeTempo()
        for _ in 0..<5 { t.record(gap: 2.9) }
        #expect(t.holdSeconds == StrokeTempo.maxHold)
        #expect(t.stallSeconds == StrokeTempo.maxStall)
        var b = StrokeTempo()
        #expect(b.record(gap: 3.5) == false && b.record(gap: -1) == false && b.record(gap: .nan) == false)
        #expect(b.measured == 0 && b.holdSeconds == SoundEnvelope.liftHoldSeconds)
    }

    @Test func theMedianForgetsOldGaps() {
        var t = StrokeTempo()
        for _ in 0..<5 { t.record(gap: 1.5) }
        for _ in 0..<5 { t.record(gap: 0.3) }
        #expect(t.holdSeconds == 0.6, "after the child speeds up the hold follows: \(t.holdSeconds)")
    }

    // MARK: 3 letter-end fade

    /// The carrier held for 0.5 s, then closed with the letter-end raised cosine; RMS of the 5 ms windows after the close.
    private func windowsAfterLetterEndClose(frames: UInt32) throws -> (steady: Double, w: [Double]) {
        let src = try StudySources.load("spatial_carrier")
        let kernel = LiveSonificationKernel()
        let (r, twin) = LiveSonificationAudio.makeRendererPair(src.sonificationSource)
        let slot = try #require(kernel.register(r, twin: twin, gain: 1))
        var y = [Float](repeating: 0, count: Int(1.0 * Self.sr) / 64 * 64)
        let close = Int(0.5 * Self.sr) / 64 * 64
        y.withUnsafeMutableBufferPointer { b in
            var i = 0
            while i < b.count {
                if i == 0 { kernel.open(slot: slot, fadeInFrames: 0) }
                if i == close { kernel.closeRaisedCosine(frames: frames) }
                kernel.render(into: b.baseAddress! + i, frames: 64)
                i += 64
            }
        }
        func rms(_ a: Int, _ n: Int) -> Double { var s = 0.0; for i in a..<(a + n) { s += Double(y[i] * y[i]) }; return (s / Double(n)).squareRoot() }
        let win = Int(0.005 * Self.sr)
        return (rms(close - 4 * win, 4 * win), (0..<24).map { rms(close + $0 * win, win) })
    }

    /// Mutation: `closeRaisedCosine` storing `frames * 8` (a 0.4 s fade) - RED (the sound is still there at 60 ms).
    @Test func theLetterEndFadeIsShortAndRaisedCosine() throws {
        let frames = UInt32(SoundEnvelope.letterEndFadeSeconds * Self.sr)
        let (steady, w) = try windowsAfterLetterEndClose(frames: frames)
        #expect(steady > 0.01, "precondition: the carrier sounds (\(steady))")
        let total = SoundEnvelope.letterEndFadeSeconds
        #expect(w[0] / steady > 0.9, "the fade starts with a kink: first 5 ms at \(w[0] / steady)")
        let mid = Int(total / 2 / 0.005)
        #expect(w[mid] / steady > 0.25 && w[mid] / steady < 0.75, "mid-fade level \(w[mid] / steady)")
        let after = Int(total / 0.005) + 2
        #expect(w[after] / steady < 0.01, "still sounding \(w[after] / steady) after the fade length")
    }

    // MARK: 2 stroke-start pitch glide

    /// Zero-crossing period (samples) of `y` over [a, b).
    private func period(_ y: [Float], _ a: Int, _ b: Int) -> Double {
        var z: [Int] = []
        var i = a + 1
        while i < b { if y[i - 1] <= 0 && y[i] > 0 { z.append(i) }; i += 1 }
        return z.count < 2 ? 0 : Double(z.last! - z.first!) / Double(z.count - 1)
    }

    /// The carrier, held, then a pitch step of `cents` at t = 1.0 s. Returns (rendered, step index).
    private func steppedCarrier(from: Float, to: Float) throws -> ([Float], Int) {
        let src = try StudySources.load("spatial_carrier")
        let kernel = LiveSonificationKernel()
        let (r, twin) = LiveSonificationAudio.makeRendererPair(src.sonificationSource)
        let slot = try #require(kernel.register(r, twin: twin, gain: 1))
        var y = [Float](repeating: 0, count: Int(2 * Self.sr) / 256 * 256)
        let step = Int(1.0 * Self.sr) / 256 * 256
        kernel.setPitchCents(from)
        y.withUnsafeMutableBufferPointer { b in
            var i = 0
            while i < b.count {
                if i == 0 { kernel.open(slot: slot, fadeInFrames: 0) }
                if i == step { kernel.setPitchCents(to) }
                kernel.render(into: b.baseAddress! + i, frames: 256)
                i += 256
            }
        }
        return (y, step)
    }

    @Test func aTwoOctaveJumpWhileTheVoiceIsHeldGlidesInsteadOfStepping() throws {
        let (y, n0) = try steppedCarrier(from: -1200, to: 1200)
        let before = period(y, n0 - Int(0.1 * Self.sr), n0)
        let target = period(y, n0 + Int(0.5 * Self.sr), n0 + Int(0.8 * Self.sr))
        #expect(before / target > 3.5, "the carrier does not span two octaves: \(before) vs \(target)")
        // 4-14 ms after the step the pitch is still well short of the target (a 2 ms follow would be there already)...
        let early = period(y, n0 + Int(0.004 * Self.sr), n0 + Int(0.014 * Self.sr))
        #expect(early > 1.3 * target, "no glide: the period is already \(early / target)x the target's 10 ms after the step")
        // ...and it has arrived by 80 ms.
        let late = period(y, n0 + Int(0.080 * Self.sr), n0 + Int(0.120 * Self.sr))
        #expect(abs(late - target) / target < 0.06, "the glide has not arrived by 80 ms: \(late / target)x")
    }

    @Test func anInStrokePitchStepIsFollowedAsFastAsBefore() throws {
        let (y, n0) = try steppedCarrier(from: 0, to: 120)
        let target = period(y, n0 + Int(0.5 * Self.sr), n0 + Int(0.8 * Self.sr))
        let at20 = period(y, n0 + Int(0.020 * Self.sr), n0 + Int(0.040 * Self.sr))
        #expect(abs(at20 - target) / target < 0.03, "a 120 cent step is not followed within 20 ms: \(at20 / target)x")
        #expect(ENV3Tuning.pitchGlideSeconds <= 0.08 && ENV3Tuning.pitchGlideSeconds >= 0.02)
    }

    // MARK: 3 export

    @Test func theEnvelopeColumnsAreAppendedLastAndCarryTheRowsValues() {
        #expect(Array(ParentDashboardExporter.phaseRowAppendedColumns.suffix(5))
                == ["soundEngine", "liftHoldSeconds", "stallSeconds", "strokeGaps", "strokeGapMedianSeconds"])
        let d = PhaseDelivery(soundEngine: "TDPSOLA", liftHoldSeconds: 1.6, stallSeconds: 0.6, strokeGaps: 3, strokeGapMedianSeconds: 0.8)
        let rec = PhaseSessionRecord(letter: "F", phase: "guided", completed: true, score: 1, schedulerPriority: 0,
                                     context: PhaseRowContext(delivery: d))
        let f = ParentDashboardExporter.phaseRowAppendedFields(rec, participantId: UUID())
        #expect(Array(f.suffix(5)) == ["TDPSOLA", "1.600", "0.600", "3", "0.800"])
        #expect(f.count == ParentDashboardExporter.phaseRowAppendedColumns.count)
    }

    @Test func aRowWithNoDeliveryLeavesTheEnvelopeCellsEmpty() {
        let rec = PhaseSessionRecord(letter: "F", phase: "guided", completed: true, score: 1, schedulerPriority: 0)
        #expect(Array(ParentDashboardExporter.phaseRowAppendedFields(rec, participantId: UUID()).suffix(4)) == ["", "", "", ""])
    }

    @Test func theTrackerCountsAPhasesGapsAndKeepsTheChildsTempo() {
        var tr = PhaseDeliveryTracker()
        tr.beginLetter(in: .guided, counters: LifecycleCounters(), environment: EnvironmentStamp())
        var tempo = StrokeTempo()
        for g in [0.9, 1.1, 1.3] { tempo.record(gap: g); tr.noteGap(g); tr.setTempo(tempo) }
        let d = tr.delivery(for: .guided, counters: LifecycleCounters(), outputRouteNow: nil)
        #expect(d?.strokeGaps == 3)
        #expect(d?.strokeGapMedianSeconds == 1.1)
        #expect(d?.liftHoldSeconds == tempo.holdSeconds)
        tr.transition(to: .freeWrite, counters: LifecycleCounters(), environment: EnvironmentStamp())
        #expect(tr.delivery(for: .guided, counters: LifecycleCounters(), outputRouteNow: nil)?.strokeGaps == 3, "the closed phase keeps its own gaps")
        #expect(tr.delivery(for: .freeWrite, counters: LifecycleCounters(), outputRouteNow: nil)?.strokeGaps == 0)
    }
}
