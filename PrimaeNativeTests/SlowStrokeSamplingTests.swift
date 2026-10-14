// SlowStrokeSamplingTests.swift
// PrimaeNativeTests
//
// Audit E2-01 (2026-10-13), protocol r7: the 1.5 pt jitter filter in
// `TouchDispatcher.updateTouch` measured each sample against the PREVIOUS
// SAMPLE. Every coalesced sample is delivered (#21), so the filter was a
// speed threshold — 1.5 pt × sample rate, ≈180 pt/s for a finger at 120 Hz,
// ≈360 pt/s for the Pencil at 240 Hz — and a slow stroke, and the
// decelerating end of every stroke, never reached the ink or the scored,
// exported freeWrite trace.
//
// Every stroke here goes through the REAL touch path
// (`vm.beginTouch` / `vm.updateTouch` / `vm.endTouch` → `TouchDispatcher`)
// at a realistic sample rate, and the recorded trace is scored with the
// same `FreeWritePhaseRecorder.assess` production calls
// (`PhaseTransitionCoordinator.scoreFreeWrite`). A slow stroke is compared
// with a FAST stroke of the same geometry: the two must record the same
// letter.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct SlowStrokeSamplingTests {

    private static let canvas = CGSize(width: 1000, height: 750)

    // MARK: - Geometry

    enum Shape: String, CaseIterable, Sendable {
        /// A 300 pt horizontal bar.
        case line
        /// A 270° arc of radius 150 pt — a C-like, letter-sized curve.
        case curve

        var polyline: [CGPoint] {
            switch self {
            case .line:
                return [CGPoint(x: 200, y: 375), CGPoint(x: 500, y: 375)]
            case .curve:
                let c = CGPoint(x: 500, y: 375), r: CGFloat = 150
                let a0 = -CGFloat.pi / 4, a1 = CGFloat.pi * 5 / 4
                return (0...240).map { i in
                    let a = a0 + (a1 - a0) * CGFloat(i) / 240
                    return CGPoint(x: c.x + r * cos(a), y: c.y - r * sin(a))
                }
            }
        }
    }

    private static func length(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The point at arc length `s` along `poly`.
    private static func point(_ poly: [CGPoint], at s: CGFloat) -> CGPoint {
        var remaining = max(0, s)
        for (a, b) in zip(poly, poly.dropFirst()) {
            let seg = hypot(b.x - a.x, b.y - a.y)
            if remaining <= seg, seg > 0 {
                let f = remaining / seg
                return CGPoint(x: a.x + f * (b.x - a.x), y: a.y + f * (b.y - a.y))
            }
            remaining -= seg
        }
        return poly.last ?? .zero
    }

    /// One sample per 1/rate s at constant `speed`, the last one exactly
    /// at the end of the path (the moment the pen arrives there).
    private static func constantSpeedSamples(_ poly: [CGPoint], speed: CGFloat, rate: CGFloat)
        -> [(CGPoint, CFTimeInterval)] {
        let total = length(poly)
        let duration = total / speed
        let n = Int((duration * rate).rounded(.up))
        return (0...n).map { k in
            let t = min(CGFloat(k) / rate, duration)
            return (point(poly, at: speed * t), CFTimeInterval(t))
        }
    }

    /// A stroke decelerating linearly from `v0` to rest over `duration` s.
    private static func deceleratingSamples(_ poly: [CGPoint], v0: CGFloat, duration: CGFloat, rate: CGFloat)
        -> [(CGPoint, CFTimeInterval)] {
        let n = Int((duration * rate).rounded(.up))
        return (0...n).map { k in
            let t = min(CGFloat(k) / rate, duration)
            let s = v0 * (t - t * t / (2 * duration))
            return (point(poly, at: s), CFTimeInterval(t))
        }
    }

    // MARK: - Driving the real touch path

    private func freeWriteVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = Self.canvas
        vm.phaseController.resume(at: .freeWrite)
        return vm
    }

    private struct Recorded {
        var points: [CGPoint]
        var inkLength: CGFloat
        var span: Double?
        var velocityAtEnd: CGFloat
    }

    /// Pen-down at the first sample, every later sample as a move, lift.
    private func drive(_ vm: TracingViewModel, _ samples: [(CGPoint, CFTimeInterval)],
                       t0: CFTimeInterval = 1000) -> Recorded {
        guard let first = samples.first else { return Recorded(points: [], inkLength: 0, span: nil, velocityAtEnd: 0) }
        vm.beginTouch(at: first.0, t: t0 + first.1)
        for (p, t) in samples.dropFirst() {
            vm.updateTouch(at: p, t: t0 + t, canvasSize: Self.canvas)
        }
        // Read the ink and the smoothed velocity BEFORE the lift clears them.
        let ink = Self.length(vm.activePath)
        let velocity = vm.touchDispatcher.smoothedVelocity
        vm.endTouch()
        return Recorded(points: vm.freeWritePoints, inkLength: ink,
                        span: vm.freeWriteRecorder.measuredSpanSeconds,
                        velocityAtEnd: velocity)
    }

    /// The reference the trace is scored against: the same geometry, in
    /// the canvas-normalised space `assess(cellFrame: nil)` maps into.
    private func reference(_ poly: [CGPoint]) -> LetterStrokes {
        let total = Self.length(poly)
        let cps = (0...40).map { i -> Checkpoint in
            let p = Self.point(poly, at: total * CGFloat(i) / 40)
            return Checkpoint(x: p.x / Self.canvas.width, y: p.y / Self.canvas.height)
        }
        return LetterStrokes(letter: "X", checkpointRadius: 0.05,
                             strokes: [StrokeDefinition(id: 1, checkpoints: cps)])
    }

    private func spatialDeviation(_ vm: TracingViewModel, _ poly: [CGPoint]) -> CGFloat? {
        vm.freeWriteRecorder.assess(reference: reference(poly), canvasSize: Self.canvas,
                                    cellFrame: nil,
                                    now: vm.freeWriteTimestamps.last ?? 0)
        return vm.freeWriteRecorder.lastSpatialDeviation
    }

    // MARK: - Slow strokes record the letter a fast stroke records

    /// (shape, speed pt/s, sample rate Hz). 100 pt/s at 120 Hz is a slow,
    /// careful finger (0.83 pt per sample); 300 pt/s at 240 Hz is an
    /// ordinary Pencil stroke (1.25 pt per sample). Both sit under the
    /// filter's old per-sample threshold.
    @Test("a slow stroke records its whole path, ends where the pen did, and scores like a fast one",
          arguments: [(Shape.line, CGFloat(100), CGFloat(120)),
                      (Shape.curve, CGFloat(100), CGFloat(120)),
                      (Shape.line, CGFloat(300), CGFloat(240)),
                      (Shape.curve, CGFloat(300), CGFloat(240))])
    func slowStrokeRecordsTheWholePath(shape: Shape, speed: CGFloat, rate: CGFloat) {
        let poly = shape.polyline
        let total = Self.length(poly)
        let end = poly.last!

        let slowVM = freeWriteVM()
        let slow = drive(slowVM, Self.constantSpeedSamples(poly, speed: speed, rate: rate))
        let slowDev = spatialDeviation(slowVM, poly)

        let fastVM = freeWriteVM()
        _ = drive(fastVM, Self.constantSpeedSamples(poly, speed: 1200, rate: 120))
        let fastDev = spatialDeviation(fastVM, poly)

        let recordedLength = Self.length(slow.points)
        let endGap = slow.points.last.map { hypot($0.x - end.x, $0.y - end.y) } ?? .infinity
        let step = speed / rate
        print("E2-01 \(shape.rawValue) \(Int(speed))pt/s@\(Int(rate))Hz: points=\(slow.points.count) recordedLength=\(recordedLength)/\(total) ink=\(slow.inkLength) endGap=\(endGap) span=\(String(describing: slow.span)) dev=\(String(describing: slowDev)) fastDev=\(String(describing: fastDev))")

        #expect(recordedLength >= total * 0.99,
                "the recorded trace covers \(recordedLength) of the \(total) pt the pen travelled")
        #expect(endGap < 0.01, "the trace must end where the pen lifted; it ends \(endGap) pt short")
        #expect(slow.inkLength >= total - 1.5 - 0.01,
                "the ink on screen covers \(slow.inkLength) of \(total) pt")
        // Kept points are >= 1.5 pt apart and at most 1.5 pt + one sample
        // step: the density is set by the path, not by the speed.
        #expect(slow.points.count >= Int(total / (1.5 + step)),
                "\(slow.points.count) points for \(total) pt at \(step) pt/sample")
        #expect(slow.points.count <= Int(total / 1.5) + 2,
                "\(slow.points.count) points for \(total) pt: the 1.5 pt hysteresis must still thin the trace")
        let duration = Double(total / speed)
        #expect(abs((slow.span ?? 0) - duration) < 1e-6,
                "measured span \(String(describing: slow.span)) s for a \(duration) s stroke")
        guard let s = slowDev, let f = fastDev else {
            Issue.record("no spatial deviation: slow \(String(describing: slowDev)), fast \(String(describing: fastDev))")
            return
        }
        // 0.002 canvas-normalised ≈ 2 pt on this canvas.
        #expect(abs(s - f) < 0.002, "slow \(s) vs fast \(f): the same letter must score the same")
    }

    /// The tail of an ordinary stroke: decelerating from 250 pt/s to rest
    /// over 0.3 s (37.5 pt) at 120 Hz. The audit's simulation of the old
    /// filter lost the last 18.8 pt of it.
    @Test("a decelerating stroke keeps its tail")
    func deceleratingStrokeKeepsItsTail() {
        let poly = [CGPoint(x: 200, y: 375), CGPoint(x: 237.5, y: 375)]
        let vm = freeWriteVM()
        let rec = drive(vm, Self.deceleratingSamples(poly, v0: 250, duration: 0.3, rate: 120))
        let end = poly.last!
        let endGap = rec.points.last.map { hypot($0.x - end.x, $0.y - end.y) } ?? .infinity
        print("E2-01 decelerating 250->0pt/s over 0.3s@120Hz: points=\(rec.points.count) recordedLength=\(Self.length(rec.points))/37.5 ink=\(rec.inkLength) endGap=\(endGap) span=\(String(describing: rec.span))")
        #expect(endGap < 0.01, "the trace ends \(endGap) pt short of where the pen stopped")
        #expect(rec.inkLength >= 37.5 - 1.5 - 0.01, "the ink covers \(rec.inkLength) of 37.5 pt")
        #expect(abs((rec.span ?? 0) - 0.3) < 1e-6, "span \(String(describing: rec.span)) s for a 0.3 s stroke")
    }

    // MARK: - What must NOT change

    /// The filter's purpose: a resting finger's jitter (never 1.5 pt from
    /// where it rests) adds no motion — and a stationary contact, flushed
    /// at the lift or not, stays the one-sample contact a palm is.
    @Test("a held finger's jitter records nothing beyond the pen-down")
    func heldJitterAddsNothing() {
        let vm = freeWriteVM()
        let rest = CGPoint(x: 300, y: 300)
        let offsets = [CGPoint(x: 0.6, y: 0), CGPoint(x: 0, y: 0.6),
                       CGPoint(x: -0.6, y: 0), CGPoint(x: 0, y: -0.6)]
        let samples = (0..<120).map { k -> (CGPoint, CFTimeInterval) in
            let o = k == 0 ? .zero : offsets[k % offsets.count]
            return (CGPoint(x: rest.x + o.x, y: rest.y + o.y), CFTimeInterval(k) / 120)
        }
        let rec = drive(vm, samples)
        #expect(rec.points.count == 1, "jitter around a resting finger recorded \(rec.points.count) points")
        #expect(rec.inkLength == 0, "jitter drew \(rec.inkLength) pt of ink")
    }

    // MARK: - What counts as a production (r7 review, D1)

    /// A free-write contact. Canvas 1000 x 750, so 2% of the canvas
    /// (`StrokeProcessScorer.scribbleExtent`) is 20 pt across, 15 pt down.
    enum Contact: String, CaseIterable, Sendable {
        /// A palm or finger creeping 0.1 pt per sample for 40 samples
        /// (4 pt): under the kept-point filter this records 4 points.
        case creep
        /// Pen down, pen up.
        case tap
        /// A deliberate horizontal mark of 19 pt: 1.9% of the width.
        case markJustUnder
        /// A deliberate horizontal mark of 21 pt: 2.1% of the width.
        case markJustOver
        /// A deliberate vertical mark of 16 pt: 2.13% of the height.
        case verticalMarkJustOver
        /// A genuine 300 pt stroke at a slow 100 pt/s.
        case slowStroke

        var isProduction: Bool {
            switch self {
            case .creep, .tap, .markJustUnder: return false
            case .markJustOver, .verticalMarkJustOver, .slowStroke: return true
            }
        }

        var samples: [(CGPoint, CFTimeInterval)] {
            let o = CGPoint(x: 300, y: 300)
            switch self {
            case .creep:
                return (0...40).map { k in
                    (CGPoint(x: o.x + 0.1 * CGFloat(k), y: o.y), CFTimeInterval(k) / 120)
                }
            case .tap:
                return [(o, 0)]
            case .markJustUnder:
                return SlowStrokeSamplingTests.constantSpeedSamples(
                    [o, CGPoint(x: o.x + 19, y: o.y)], speed: 100, rate: 120)
            case .markJustOver:
                return SlowStrokeSamplingTests.constantSpeedSamples(
                    [o, CGPoint(x: o.x + 21, y: o.y)], speed: 100, rate: 120)
            case .verticalMarkJustOver:
                return SlowStrokeSamplingTests.constantSpeedSamples(
                    [o, CGPoint(x: o.x, y: o.y + 16)], speed: 100, rate: 120)
            case .slowStroke:
                return SlowStrokeSamplingTests.constantSpeedSamples(
                    Shape.line.polyline, speed: 100, rate: 120)
            }
        }
    }

    /// Both places that decide "this contact was a production" must agree,
    /// and must use the r6 scribble extent: the lift (schedules the 2 s
    /// auto-advance that scores and records the trial) and the unload
    /// finalisation (scores and records it when the proctor moves on inside
    /// that window). Under the kept-point filter a creeping contact reaches
    /// the old `>= 2 points` test, which a one-sample palm never did.
    @Test("a free-write contact is a production only if it spans 2% of the canvas, at the lift and at the unload",
          arguments: Contact.allCases)
    func productionNeedsTheScribbleExtent(contact: Contact) {
        let liftVM = freeWriteVM()
        let rec = drive(liftVM, contact.samples)
        print("D1 \(contact.rawValue): points=\(rec.points.count) scheduled=\(liftVM.touchDispatcher.isFreeWriteAdvanceScheduled)")
        #expect(liftVM.touchDispatcher.isFreeWriteAdvanceScheduled == contact.isProduction,
                "\(contact.rawValue) (\(rec.points.count) points): the lift \(contact.isProduction ? "must" : "must not") schedule the auto-advance")
        liftVM.touchDispatcher.resetTouchState()   // cancel the window, if any

        let unloadVM = freeWriteVM()
        _ = drive(unloadVM, contact.samples)
        unloadVM.touchDispatcher.resetTouchState()
        let finalized = unloadVM.phaseTransitions.finalizeFinishedFreeWriteIfPending()
        #expect(finalized == contact.isProduction,
                "\(contact.rawValue): the unload \(contact.isProduction ? "must" : "must not") score and record it as a completed trial")
        #expect(unloadVM.isPhaseSessionComplete == contact.isProduction,
                "\(contact.rawValue): the trial's completion must follow the same rule")
    }

    /// End to end for the reported case: a creeping contact left alone past
    /// the 2.0 s quiet window does not complete the trial.
    @Test("a creeping contact left past the quiet window does not complete the trial")
    func creepNeverCompletesTheTrial() async {
        let vm = freeWriteVM()
        _ = drive(vm, Contact.creep.samples)
        try? await Task.sleep(for: .milliseconds(2600))
        // `didCompleteCurrentLetter` latches synchronously when the window's
        // advance fires, before the recognizer hop.
        #expect(!vm.didCompleteCurrentLetter && !vm.isPhaseSessionComplete && vm.learningPhase == .freeWrite,
                "a 4 pt creep completed the free-write trial")
    }

    /// The velocity behind the arm sound's rate still sees EVERY sample:
    /// only the ink/trace filter moved to the kept point.
    @Test("the smoothed velocity still tracks the pen's real speed on a slow stroke")
    func velocityStillSeesEverySample() {
        let vm = freeWriteVM()
        let rec = drive(vm, Self.constantSpeedSamples(Shape.line.polyline, speed: 100, rate: 120))
        #expect(abs(rec.velocityAtEnd - 100) < 3,
                "smoothed velocity \(rec.velocityAtEnd) pt/s for a 100 pt/s stroke")
    }
}
