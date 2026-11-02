// ScoringR16Tests.swift
// Pins the protocol-r16 scoring rulings (fix lane L7, 2026-11-02):
//   B8  (audit B-3)  freeWrite distances isotropic, in canvas-height units
//   B11 (audit B-5)  the r6 fit is taken over the MATCHED strokes only
//   B13 (audit B-8/B-9) tempo = windowed within-stroke speed, lifts excluded
//   B15 (audit B-11) traces resampled to a fixed arc-length spacing
//   B16 (DEV-2)      recogniser scores are softmaxed before calibration
// Built from the round-1 bug-hunt tests (exp-2026-11-01/tracing-tests). Each
// test prints its measurements with the prefix "R16|" so the before/after
// table can be read out of the xcodebuild log. Everything goes through the
// production entry points (`FreeWritePhaseRecorder.assess`,
// `FreeWriteScorer.score`, `CoreMLLetterRecognizer.makeResult`). No global
// state: each test owns its recorder.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

/// SplitMix64, seeded (round-1 `ExpRNG`).
struct R16RNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(Double(next() >> 11) / Double(1 << 53)) }
    mutating func gauss() -> CGFloat {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

/// The A16 study canvas and the study letters' glyph rects on it, as the
/// round-1 device run measured them (`EXP|tol canvas=1084x626`): every
/// Regular capital is 298 pt tall; widths differ. The glyph rect is
/// centred here (the renderer is not reachable from tests). The radius is
/// `checkpointRadius x glyph height`, L8's `StrokeTracker.cellDefinition`.
@MainActor
enum R16Geo {
    static let canvas = CGSize(width: 1084, height: 626)
    static let studyLetters = ["A", "F", "I", "L", "M"]
    static let glyphWidth: [String: CGFloat] = ["A": 212, "F": 164, "I": 45, "L": 156, "M": 275]
    static let glyphHeight: CGFloat = 298

    static let letters: [LetterAsset] =
        LetterRepository(resources: BundleLetterResourceProvider(),
                         cache: NullLetterCache(), weight: .regular).loadLetters()

    /// The cell-fraction reference the tracker and the scorer see.
    static func reference(_ name: String) throws -> LetterStrokes {
        let asset = try #require(letters.first { $0.name == name })
        let w = try #require(glyphWidth[name]) / canvas.width
        let h = glyphHeight / canvas.height
        let gr = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
        return LetterStrokes(
            letter: name,
            checkpointRadius: asset.strokes.checkpointRadius * gr.height,
            strokes: asset.strokes.strokes.map { s in
                StrokeDefinition(id: s.id, checkpoints: s.checkpoints.map {
                    Checkpoint(x: gr.minX + $0.x * gr.width, y: gr.minY + $0.y * gr.height)
                })
            })
    }

    /// Walk a polyline (canvas points) at `speed` pt/s sampled at `hz`.
    static func walk(_ poly: [CGPoint], speed: CGFloat, hz: CGFloat) -> [CGPoint] {
        guard poly.count >= 2 else { return poly }
        let step = speed / hz
        var out: [CGPoint] = [poly[0]]
        var remaining = step
        for i in 1..<poly.count {
            let a = poly[i - 1], b = poly[i]
            let len = hypot(b.x - a.x, b.y - a.y)
            guard len > 0 else { continue }
            var pos: CGFloat = 0
            while len - pos >= remaining {
                pos += remaining
                let t = pos / len
                out.append(CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
                remaining = step
            }
            remaining -= (len - pos)
        }
        if let last = poly.last, out.last != last { out.append(last) }
        return out
    }

    /// The reference strokes traced faithfully, in canvas points.
    static func faithful(_ def: LetterStrokes, hz: CGFloat = 120, speed: CGFloat = 300) -> [[CGPoint]] {
        def.strokes.map { s in
            walk(s.checkpoints.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) },
                 speed: speed, hz: hz)
        }
    }

    static func jitter(_ strokes: [[CGPoint]], sigma: CGFloat, rng: inout R16RNG) -> [[CGPoint]] {
        strokes.map { $0.map { CGPoint(x: $0.x + sigma * rng.gauss(), y: $0.y + sigma * rng.gauss()) } }
    }

    /// Record `strokes` (canvas points) into a fresh recorder at `hz`,
    /// `lift` seconds between strokes, and assess it the way the study does.
    static func assess(_ strokes: [[CGPoint]], ref: LetterStrokes, hz: Double = 120,
                       lift: Double = 0.3) -> (FreeWritePhaseRecorder, WritingAssessment) {
        let r = FreeWritePhaseRecorder()
        r.startSession(now: 1000)
        var t = 1000.0
        for (i, s) in strokes.enumerated() where !s.isEmpty {
            if i > 0 { t += lift }
            r.beginStroke()
            for (j, p) in s.enumerated() {
                if j > 0 { t += 1 / hz }
                r.record(point: p, timestamp: t, force: 0, canvasSize: canvas)
            }
        }
        let a = r.assess(reference: ref, canvasSize: canvas, now: t)
        return (r, a)
    }

    static func deviation(_ strokes: [[CGPoint]], ref: LetterStrokes, hz: Double = 120) -> CGFloat {
        assess(strokes, ref: ref, hz: hz).0.lastSpatialDeviation ?? .nan
    }

    static func fmt(_ x: CGFloat) -> String { String(format: "%.4f", Double(x)) }
}

// MARK: - B8 (audit B-3): one point of error weighs the same on both axes

@MainActor
struct IsotropicScoringTests {
    @Test("B8: the same 25 pt error scores the same horizontally and vertically")
    func samePhysicalErrorSameDeviation() throws {
        for l in ["F", "L", "A"] {
            let def = try R16Geo.reference(l)
            let base = R16Geo.faithful(def)
            func displaced(_ dx: CGFloat, _ dy: CGFloat) -> [[CGPoint]] {
                base.enumerated().map { i, s in
                    i == base.count - 1 ? s.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } : s
                }
            }
            let h = try #require(R16Geo.assess(displaced(25, 0), ref: def).0.lastSpatialDeviationRaw)
            let v = try #require(R16Geo.assess(displaced(0, 25), ref: def).0.lastSpatialDeviationRaw)
            print("R16|axis letter=\(l) raw(25pt horizontal)=\(R16Geo.fmt(h)) raw(25pt vertical)=\(R16Geo.fmt(v)) ratio=\(R16Geo.fmt(v / h))")
            #expect(abs(h - v) < 0.1 * max(h, v), "\(l): the same physical error scores \(h) vs \(v)")
        }
    }

    @Test("B8: a production is judged in canvas heights on both axes, like the fit")
    func productionExtentIsIsotropic() {
        // 16 pt: above 2% of the height (12.5 pt), below 2% of the width (21.7 pt).
        let canvas = R16Geo.canvas
        let horizontal = [CGPoint(x: 500, y: 300), CGPoint(x: 516, y: 300)]
        let vertical = [CGPoint(x: 500, y: 300), CGPoint(x: 500, y: 316)]
        #expect(StrokeProcessScorer.isProduction(points: horizontal, canvasSize: canvas)
                == StrokeProcessScorer.isProduction(points: vertical, canvasSize: canvas))
    }
}

// MARK: - B11 (audit B-5): a stray contact no longer moves the fit

@MainActor
struct MatchedStrokeFitTests {
    @Test("B11: one stray 3 pt contact leaves the primary outcome where it was")
    func strayContactDoesNotMoveThePrimaryOutcome() throws {
        let canvas = R16Geo.canvas
        for l in R16Geo.studyLetters {
            let def = try R16Geo.reference(l)
            var rng = R16RNG(seed: 21)
            let noisy = R16Geo.jitter(R16Geo.faithful(def), sigma: 4, rng: &rng)
            let stray = [[CGPoint(x: 30, y: canvas.height - 30), CGPoint(x: 33, y: canvas.height - 29)]]
            let clean = R16Geo.deviation(noisy, ref: def)
            let dirty = R16Geo.deviation(noisy + stray, ref: def)
            print("R16|stray letter=\(l) dev clean=\(R16Geo.fmt(clean)) withStray=\(R16Geo.fmt(dirty)) ratio=\(R16Geo.fmt(dirty / clean))")
            #expect(abs(dirty - clean) <= 0.05 * clean + 1e-4,
                    "\(l): a 3 pt stray contact moved the primary outcome from \(clean) to \(dirty)")
        }
    }

    @Test("B11: fewer or equal drawn strokes than reference strokes keep the r6 fit")
    func noExtraStrokesNoChange() throws {
        // Translation stays exactly invariant (the r6 property) when every
        // drawn stroke is matched.
        for l in ["A", "F", "M"] {
            let def = try R16Geo.reference(l)
            var rng = R16RNG(seed: 42)
            let noisy = R16Geo.jitter(R16Geo.faithful(def), sigma: 3, rng: &rng)
            let shifted = noisy.map { $0.map { CGPoint(x: $0.x + 150, y: $0.y - 60) } }
            let d0 = R16Geo.deviation(noisy, ref: def)
            let dT = R16Geo.deviation(shifted, ref: def)
            #expect(abs(dT - d0) < 1e-6, "\(l): \(d0) vs translated \(dT)")
        }
    }
}

// MARK: - B13 (audit B-8 / B-9): tempo

@MainActor
struct WindowedTempoTests {
    @Test("B13: the length of a pen lift does not change tempo")
    func liftLengthDoesNotMatter() throws {
        let def = try R16Geo.reference("F")
        let strokes = R16Geo.faithful(def)
        let gaps = [0.05, 0.2, 0.3, 0.45, 0.55, 1.0]
        let tempos = gaps.map { R16Geo.assess(strokes, ref: def, lift: $0).1.tempoConsistency }
        print("R16|tempo-gap letter=F \(zip(gaps, tempos).map { "gap\($0)s=\(R16Geo.fmt($1))" }.joined(separator: " "))")
        #expect(tempos.max()! - tempos.min()! < 1e-9, "tempo for identical strokes varies with the lift: \(tempos)")
    }

    @Test("B13: tempo sees a speed change within a stroke")
    func withinStrokeSpeedChangeLowersTempo() throws {
        let def = try R16Geo.reference("I")
        let canvas = R16Geo.canvas
        let poly = def.strokes[0].checkpoints.map { CGPoint(x: $0.x * canvas.width, y: $0.y * canvas.height) }
        func tempo(_ speed: (CGFloat) -> CGFloat) -> CGFloat {
            // 120 Hz samples through the dispatcher's 1.5 pt kept-point filter.
            var lens: [CGFloat] = [0]
            for i in 1..<poly.count { lens.append(lens[i - 1] + hypot(poly[i].x - poly[i-1].x, poly[i].y - poly[i-1].y)) }
            let total = lens.last!
            func at(_ d: CGFloat) -> CGPoint {
                var k = 1; while k < lens.count - 1 && lens[k] < d { k += 1 }
                let u = (d - lens[k-1]) / max(lens[k] - lens[k-1], 1e-9)
                return CGPoint(x: poly[k-1].x + u * (poly[k].x - poly[k-1].x), y: poly[k-1].y + u * (poly[k].y - poly[k-1].y))
            }
            let r = FreeWritePhaseRecorder()
            r.startSession(now: 0)
            var d: CGFloat = 0, t = 0.0, last = at(0)
            r.record(point: last, timestamp: 0, force: 0, canvasSize: canvas)
            while d < total {
                d += speed(d / total) / 120; t += 1.0 / 120
                let p = at(min(d, total))
                if hypot(p.x - last.x, p.y - last.y) >= 1.5 {
                    r.record(point: p, timestamp: t, force: 0, canvasSize: canvas); last = p
                }
            }
            return r.assess(reference: def, canvasSize: canvas, now: t).tempoConsistency
        }
        let const400 = tempo { _ in 400 }
        let const60 = tempo { _ in 60 }
        let ramp = tempo { 250 + 400 * $0 }      // 250 -> 650 pt/s, 2.6x
        let rampAcross = tempo { 60 + 300 * $0 }  // crosses the 180 pt/s filter threshold
        print("R16|tempo-speed const400=\(R16Geo.fmt(const400)) const60=\(R16Geo.fmt(const60)) vary250to650=\(R16Geo.fmt(ramp)) vary60to360=\(R16Geo.fmt(rampAcross))")
        #expect(const400 > 0.99 && const60 > 0.99, "constant speed is consistent: \(const400), \(const60)")
        #expect(ramp < 0.97, "a 2.6x speed change inside one stroke: tempo \(ramp)")
        #expect(rampAcross < ramp, "a 6x change is less consistent than a 2.6x one: \(rampAcross) vs \(ramp)")
    }
}

// MARK: - B15 (audit B-11): sample rate

@MainActor
struct SampleRateInvarianceTests {
    @Test("B15: the same noisy path sampled at 60, 120 and 240 Hz scores alike")
    func deviationDoesNotFollowTheSampleRate() throws {
        var failures: [String] = []
        for l in R16Geo.studyLetters {
            let def = try R16Geo.reference(l)
            var means: [CGFloat] = []
            for hz in [60, 120, 240] as [CGFloat] {
                var acc: CGFloat = 0
                for seed in 0..<40 as Range<UInt64> {
                    var rng = R16RNG(seed: 900 + seed)
                    let noisy = R16Geo.jitter(R16Geo.faithful(def, hz: hz), sigma: 0.5, rng: &rng)
                    acc += R16Geo.deviation(noisy, ref: def, hz: Double(hz))
                }
                means.append(acc / 40)
            }
            let mean = means.reduce(0, +) / 3
            let spread = (means.max()! - means.min()!) / mean
            print("R16|rate letter=\(l) sigma=0.5pt meanDev hz60/120/240=\(means.map(R16Geo.fmt)) spread=\(R16Geo.fmt(spread))")
            // Round-1's single-seed sigma 6 pt case, for the report.
            var single: [CGFloat] = []
            for hz in [60, 120, 240] as [CGFloat] {
                var rng = R16RNG(seed: 42)
                single.append(R16Geo.deviation(R16Geo.jitter(R16Geo.faithful(def, hz: hz), sigma: 6, rng: &rng),
                                               ref: def, hz: Double(hz)))
            }
            print("R16|rate letter=\(l) sigma=6pt seed42 hz60/120/240=\(single.map(R16Geo.fmt))")
            if spread >= 0.2 { failures.append("\(l) \(R16Geo.fmt(spread))") }
        }
        #expect(failures.isEmpty, "deviation spread across 60/120/240 Hz >= 20%: \(failures)")
    }
}

// MARK: - Jitter per letter (report table; B8 + L8 radius)

@MainActor
struct JitterPerLetterTests {
    @Test("Form falls monotonically with jitter for every study letter")
    func formFallsWithJitter() throws {
        for l in R16Geo.studyLetters {
            let def = try R16Geo.reference(l)
            let base = R16Geo.faithful(def)
            var forms: [CGFloat] = [], devs: [CGFloat] = []
            for sigma in [0, 1, 2, 4] as [CGFloat] {
                var f: CGFloat = 0, d: CGFloat = 0
                for seed in 0..<10 as Range<UInt64> {
                    var rng = R16RNG(seed: 200 + seed)
                    let (r, a) = R16Geo.assess(R16Geo.jitter(base, sigma: sigma, rng: &rng), ref: def)
                    f += a.formAccuracy; d += r.lastSpatialDeviation ?? .nan
                }
                forms.append(f / 10); devs.append(d / 10)
            }
            print("R16|jitter letter=\(l) form(sigma 0,1,2,4pt)=\(forms.map(R16Geo.fmt)) dev=\(devs.map(R16Geo.fmt)) maxAcceptable=\(R16Geo.fmt(3 * def.checkpointRadius))")
            #expect(zip(forms, forms.dropFirst()).allSatisfy { $0 >= $1 - 1e-9 }, "\(l): \(forms)")
            #expect(forms[0] > 0.95, "\(l): a faithful trace scores \(forms[0])")
        }
    }
}

// MARK: - B16 (DEV-2): calibrated confidence is a probability

struct RecogniserSoftmaxTests {
    @Test("B16: raw model scores are softmaxed before calibration; the raw column stays raw")
    func calibratedConfidenceIsAProbability() throws {
        let cal = ConfidenceCalibrator(confusableLetters: [])
        // Scores of the shape the device measured: a clean A (15.5) and a
        // scribble read as F (3.67, close competitors).
        let clean = try #require(CoreMLLetterRecognizer.makeResult(
            from: [LetterClassification(identifier: "A", confidence: 15.54),
                   LetterClassification(identifier: "H", confidence: 9.0),
                   LetterClassification(identifier: "R", confidence: 3.0)],
            expectedLetter: "A", calibrator: cal, historicalFormScores: []))
        let scribble = try #require(CoreMLLetterRecognizer.makeResult(
            from: [LetterClassification(identifier: "F", confidence: 3.67),
                   LetterClassification(identifier: "E", confidence: 3.3),
                   LetterClassification(identifier: "P", confidence: 2.9)],
            expectedLetter: "F", calibrator: cal, historicalFormScores: []))
        let expectedClean = 1 / (1 + exp(9.0 - 15.54) + exp(3.0 - 15.54))
        let expectedScribble = 1 / (1 + exp(3.3 - 3.67) + exp(2.9 - 3.67))
        print("R16|softmax clean conf=\(clean.confidence) raw=\(clean.rawConfidence ?? .nan) scribble conf=\(scribble.confidence) raw=\(scribble.rawConfidence ?? .nan)")
        #expect(abs(Double(clean.confidence) - expectedClean) < 1e-5, "clean A: \(clean.confidence)")
        #expect(abs(Double(scribble.confidence) - expectedScribble) < 1e-5, "scribble F: \(scribble.confidence)")
        #expect(scribble.confidence < 0.7, "a scribble with close competitors is not a confident F")
        #expect(abs((clean.rawConfidence ?? 0) - 15.54) < 1e-4, "the raw column keeps the model score")
        let probs = scribble.topThree.map(\.confidence).reduce(0, +)
        #expect(probs <= 1 + 1e-6, "the candidates' probabilities sum to at most 1: \(probs)")
    }
}
