// TrackerSpeedAndToleranceTests.swift
//
// Pins the protocol r16 tracker fixes (audit 2026-11-01, tracing B-1/B-2/B-3;
// adapted from that round's ExpTrackerTests / ExpCorpusTests):
//   - B-1: one sample consumes every following checkpoint within the radius,
//     so a brisk faithful trace completes (the A/F crossbars stopped
//     registering above ~300 pt/s at 120 Hz).
//   - B-2: the radius scales by glyph HEIGHT only, so every study letter gets
//     the same tolerance in points (I's used to be 2.5x stricter than M's).
//   - B-3: the hit test is isotropic in points (it was 1.73x wider
//     horizontally on the study cell).
//
// Geometry is the real Regular corpus mapped through the real font's glyph
// rect (`renderGlyphPath`, the guard-free path builder) on the A16 study
// cell, through the production mapper `StrokeTracker.cellDefinition`, and
// fed to the tracker the way TouchDispatcher feeds it (cell-fraction point
// plus the cell's aspect ratio). Nothing here touches global state.

import Testing
import CoreGraphics
import SwiftUI
@testable import PrimaeNative

@MainActor
private enum TrackerFixture {
    /// The A16 landscape study cell (1180x820 minus rail, paddings and
    /// toolbar; the round-1 `ExpCanvas.a16Landscape`).
    static let cell = CGSize(width: 1084, height: 626)
    static var aspect: CGFloat { cell.width / cell.height }
    static let studyLetters = ["A", "F", "I", "L", "M"]

    private static var cache: [LetterAsset]?
    static func letters() -> [LetterAsset] {
        if let cache { return cache }
        let loaded = LetterRepository(resources: BundleLetterResourceProvider(),
                                      cache: NullLetterCache(),
                                      weight: .regular).loadLetters()
        cache = loaded
        return loaded
    }

    /// The glyph's ink rect as a fraction of the cell, from the same font
    /// geometry the canvas renders.
    static func glyphRect(_ letter: String) -> CGRect? {
        guard let path = PrimaeLetterRenderer.renderGlyphPath(letter: letter, size: cell)
        else { return nil }
        let b = path.boundingRect
        guard b.width > 0, b.height > 0 else { return nil }
        return CGRect(x: b.minX / cell.width, y: b.minY / cell.height,
                      width: b.width / cell.width, height: b.height / cell.height)
    }

    static func definition(_ asset: LetterAsset) -> LetterStrokes? {
        guard let gr = glyphRect(asset.name) else { return nil }
        return StrokeTracker.cellDefinition(from: asset.strokes, glyphRect: gr)
    }

    static func definition(_ name: String) -> LetterStrokes? {
        letters().first { $0.name == name }.flatMap(definition)
    }

    /// Each stroke's checkpoint polyline in cell points.
    static func polylines(_ def: LetterStrokes) -> [[CGPoint]] {
        def.strokes.map { $0.checkpoints.map { CGPoint(x: $0.x * cell.width, y: $0.y * cell.height) } }
    }

    /// Walk a polyline at `speed` pt/s sampled at `hz`.
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

    /// A child-like trace: the centreline walked at `speed`, with a lateral
    /// wobble (`amplitude` pt, 40 pt wavelength), per-sample jitter `sigma`
    /// pt, and a 0.5 s jittering pause halfway through each stroke.
    static func wobbly(_ poly: [CGPoint], speed: CGFloat, hz: CGFloat,
                       amplitude: CGFloat, sigma: CGFloat, rng: inout TrackerTestRNG) -> [CGPoint] {
        let centre = walk(poly, speed: speed, hz: hz)
        var out: [CGPoint] = []
        var s: CGFloat = 0
        for j in centre.indices {
            if j > 0 { s += hypot(centre[j].x - centre[j - 1].x, centre[j].y - centre[j - 1].y) }
            let a = centre[max(j - 1, 0)], b = centre[min(j + 1, centre.count - 1)]
            let len = max(hypot(b.x - a.x, b.y - a.y), 1e-9)
            let n = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
            let w = amplitude * sin(2 * .pi * s / 40)
            let q = CGPoint(x: centre[j].x + n.x * w + sigma * rng.gauss(),
                            y: centre[j].y + n.y * w + sigma * rng.gauss())
            out.append(q)
            if j == centre.count / 2 {
                for _ in 0..<Int(0.5 * hz) {
                    out.append(CGPoint(x: q.x + sigma * rng.gauss(), y: q.y + sigma * rng.gauss()))
                }
            }
        }
        return out
    }

    /// Drive a fresh tracker the way TouchDispatcher does.
    static func completes(_ def: LetterStrokes, strokes: [[CGPoint]]) -> Bool {
        let t = StrokeTracker()
        t.load(def)
        for s in strokes {
            for p in s {
                t.update(normalizedPoint: CGPoint(x: p.x / cell.width, y: p.y / cell.height),
                         aspectRatio: aspect)
                if t.isComplete { return true }
            }
        }
        return t.isComplete
    }
}

/// SplitMix64, seeded (deterministic jitter).
private struct TrackerTestRNG {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(Double(next() >> 11) / Double(UInt64(1) << 53)) }
    mutating func gauss() -> CGFloat {
        let u1 = max(unit(), 1e-12), u2 = unit()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}

// MARK: - B-1: brisk traces

@MainActor
@Suite struct TrackerBriskTraceTests {

    /// 40 checkpoints 0.0026 apart, samples 0.02 apart: one sweep must
    /// consume them all (it consumed one per sample before r16).
    @Test func denseStrokeCompletesInOneBriskSweep() {
        let cps = (0..<40).map { Checkpoint(x: 0.40 + CGFloat($0) * 0.1 / 39, y: 0.5) }
        let t = StrokeTracker()
        t.load(LetterStrokes(letter: "X", checkpointRadius: 0.02,
                             strokes: [StrokeDefinition(id: 1, checkpoints: cps)]))
        for x in stride(from: 0.40 as CGFloat, through: 0.5001, by: 0.02) {
            t.update(normalizedPoint: CGPoint(x: x, y: 0.5))
        }
        #expect(t.isComplete, "progress \(t.progress[0].nextCheckpoint)/40")
    }

    /// Round-1 `faithfulTraceCompletesAtChildAndAdultSpeeds`: an exact
    /// centreline trace of every study letter completes at 60/120/240 Hz up
    /// to 2500 pt/s (the A and F crossbars failed above 300 pt/s at 120 Hz).
    @Test func briskFaithfulTraceCompletesOnEveryStudyLetter() throws {
        var failures: [String] = []
        for l in TrackerFixture.studyLetters {
            let def = try #require(TrackerFixture.definition(l), "no geometry for \(l)")
            let polys = TrackerFixture.polylines(def)
            for hz in [60, 120, 240] as [CGFloat] {
                for speed in [300, 600, 1000, 1500, 2500] as [CGFloat] {
                    let samples = polys.map { TrackerFixture.walk($0, speed: speed, hz: hz) }
                    if !TrackerFixture.completes(def, strokes: samples) {
                        failures.append("\(l)@\(Int(hz))Hz/\(Int(speed))pt/s")
                    }
                }
            }
        }
        #expect(failures.isEmpty, "faithful traces that did not complete: \(failures)")
    }
}

// MARK: - B-2 / B-3: tolerance

@MainActor
@Suite struct TrackerToleranceTests {

    /// Round-1 `hitToleranceInPoints`: the hit tolerance in points is the
    /// same for every study letter (it spread 2.45x, I 15x8 pt vs M 37x21).
    @Test func toleranceIsTheSameForEveryStudyLetter() throws {
        var radiusPt: [String: CGFloat] = [:]
        for l in TrackerFixture.studyLetters {
            let def = try #require(TrackerFixture.definition(l), "no geometry for \(l)")
            // Height units -> points.
            radiusPt[l] = def.checkpointRadius * TrackerFixture.cell.height
        }
        let v = Array(radiusPt.values)
        let spread = v.max()! / v.min()!
        #expect(spread < 1.05, "tolerance spread \(spread): \(radiusPt)")
    }

    /// Round-1 `toleranceIsIsotropic`: shift the whole faithful trace by d pt
    /// horizontally, then vertically; the largest d that still completes is
    /// the same in both directions (it was 1.74-1.88x wider horizontally).
    @Test func toleranceIsIsotropicInPoints() throws {
        var aniso: [String] = []
        for l in TrackerFixture.studyLetters {
            let def = try #require(TrackerFixture.definition(l), "no geometry for \(l)")
            let polys = TrackerFixture.polylines(def)
            func maxOffset(dx: CGFloat, dy: CGFloat) -> CGFloat {
                var best: CGFloat = 0
                for d in stride(from: 1 as CGFloat, through: 120, by: 1) {
                    let shifted = polys.map { $0.map { CGPoint(x: $0.x + dx * d, y: $0.y + dy * d) } }
                    let s = shifted.map { TrackerFixture.walk($0, speed: 300, hz: 120) }
                    if TrackerFixture.completes(def, strokes: s) { best = d } else { break }
                }
                return best
            }
            let h = maxOffset(dx: 1, dy: 0), v = maxOffset(dx: 0, dy: 1)
            if h == 0 || v == 0 || abs(h - v) > 0.1 * max(h, v) {
                aniso.append("\(l): h=\(Int(h)) v=\(Int(v))")
            }
        }
        #expect(aniso.isEmpty, "anisotropic guided tolerance: \(aniso)")
    }

    /// Real traces keep completing under the new tolerance: every Regular
    /// letter, an exact trace and a child-like wobbly one (6 pt wobble,
    /// 0.7 pt jitter, a half-second pause mid-stroke) at 60/120/240 Hz.
    @Test func everyRegularLetterCompletesExactAndWobbly() throws {
        var failures: [String] = []
        var checked = 0
        for asset in TrackerFixture.letters() {
            guard let def = TrackerFixture.definition(asset), !def.strokes.isEmpty else { continue }
            checked += 1
            let polys = TrackerFixture.polylines(def)
            for hz in [60, 120, 240] as [CGFloat] {
                if !TrackerFixture.completes(def, strokes: polys.map {
                    TrackerFixture.walk($0, speed: 400, hz: hz) }) {
                    failures.append("\(asset.name) exact@\(Int(hz))")
                }
                var rng = TrackerTestRNG(seed: 7)
                let wob = polys.map {
                    TrackerFixture.wobbly($0, speed: 150, hz: hz, amplitude: 6, sigma: 0.7, rng: &rng)
                }
                if !TrackerFixture.completes(def, strokes: wob) {
                    failures.append("\(asset.name) wobbly@\(Int(hz))")
                }
            }
        }
        #expect(checked >= 50, "only \(checked) Regular letters had geometry")
        #expect(failures.isEmpty, "real traces that did not complete: \(failures)")
    }
}
