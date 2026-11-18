// StrokeMappingCacheTests.swift
// PrimaeNativeTests
//
// Audit R-081 (PERF). The bbox-relative → cell-fraction stroke mapping
// lived twice in `TracingViewModel` (`gridCellStrokes(at:)`,
// `rawGlyphStrokes`) and `TracingCanvasView` re-ran `gridCellStrokes` three
// to four times per cell per frame, re-smoothing the ghost as well. The
// mapping is now `StrokeMapping` (pure) behind `StrokeMappingCache`.
//
// Four properties are pinned, each by its own test:
//   1. the pure mapping is the old arithmetic (exact literals), and a repeat
//      call is a cache HIT returning an equal value — not a second mapping;
//   2. the cache is keyed on everything that changes the result — letter,
//      cell size, script, OpenType features, padding, and the SOURCE strokes
//      (which is what a font weight changes) — and a hit never serves the
//      neighbour's value;
//   3. the ghost's smoothed paths are rebuilt only when the mapped strokes
//      or the frame they are drawn into change;
//   4. both former copies in the view model go through the one cache.
//
// `normalizedGlyphRect` returns nil under the test host, so (4) injects the
// guard-free `computeNormalizedGlyphRect` through `glyphRectProvider`.

import Testing
import Foundation
import CoreGraphics
import SwiftUI
@testable import PrimaeNative

@MainActor
@Suite
struct StrokeMappingCacheTests {

    // MARK: fixtures

    private static func strokes(_ letter: String = "T", radius: CGFloat = 0.1,
                                dx: CGFloat = 0) -> LetterStrokes {
        LetterStrokes(letter: letter, checkpointRadius: radius, strokes: [
            StrokeDefinition(id: 1, checkpoints: [
                Checkpoint(x: 0, y: 0), Checkpoint(x: 0.5 + dx, y: 0.5), Checkpoint(x: 1, y: 1)]),
            StrokeDefinition(id: 2, checkpoints: [Checkpoint(x: 0.25, y: 0.75)]),
        ])
    }

    private static let rect = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)

    private static func key(_ letter: String = "T", art: SchriftArt = .druckschrift,
                            features: [String] = [], pad: CGFloat = 0.10,
                            size: CGSize = CGSize(width: 1000, height: 600))
        -> StrokeMappingCache.Key {
        StrokeMappingCache.Key(letter: letter, schriftArt: art, features: features,
                               pad: pad, cellSize: size)
    }

    // MARK: 1. the mapping is the old arithmetic, and a repeat is a hit

    @Test("the pure mapping is the old arithmetic, and the second lookup is a cache hit")
    func mappingIsGoldenAndRepeatsFromCache() throws {
        let src = Self.strokes()
        let direct = StrokeMapping.map(src, into: Self.rect)

        // Golden literals: minX + x*w, minY + y*h; radius * sqrt(w*h).
        let cps = try #require(direct.strokes.first?.checkpoints)
        #expect(cps.count == 3)
        #expect(abs(cps[0].x - 0.2) < 1e-12 && abs(cps[0].y - 0.3) < 1e-12)
        #expect(abs(cps[1].x - 0.4) < 1e-12 && abs(cps[1].y - 0.4) < 1e-12)
        #expect(abs(cps[2].x - 0.6) < 1e-12 && abs(cps[2].y - 0.5) < 1e-12)
        #expect(abs(direct.checkpointRadius - 0.1 * (0.4 * 0.2).squareRoot()) < 1e-12)
        #expect(direct.letter == "T" && direct.strokes.map(\.id) == [1, 2])

        let cache = StrokeMappingCache()
        var rectCalls = 0
        let first = cache.strokes(for: src, key: Self.key()) { rectCalls += 1; return Self.rect }
        let again = cache.strokes(for: src, key: Self.key()) { rectCalls += 1; return Self.rect }
        let third = cache.strokes(for: src, key: Self.key()) { rectCalls += 1; return Self.rect }

        #expect(first == direct && again == direct && third == direct)
        #expect(cache.mappingMisses == 1, "mapped once, not once per lookup")
        #expect(cache.mappingHits == 2)
        #expect(rectCalls == 1, "a hit must not ask for the glyph rect")
    }

    // MARK: 2. keyed on everything that changes the result

    @Test("a different letter, size, script, features, padding or source never gets the neighbour's mapping")
    func cacheIsKeyedOnEverythingThatChangesTheResult() throws {
        let cache = StrokeMappingCache()
        let base = Self.strokes()
        // Each variant has its OWN rect, as the font would give it.
        func rectFor(_ i: Int) -> CGRect {
            CGRect(x: 0.1 + 0.01 * CGFloat(i), y: 0.2, width: 0.3 + 0.01 * CGFloat(i), height: 0.4)
        }
        struct Variant { let name: String; let key: StrokeMappingCache.Key; let source: LetterStrokes }
        let variants: [Variant] = [
            Variant(name: "baseline",  key: Self.key(), source: base),
            Variant(name: "letter",    key: Self.key("Z"), source: base),
            Variant(name: "cell w",    key: Self.key(size: CGSize(width: 1270, height: 600)), source: base),
            Variant(name: "cell h",    key: Self.key(size: CGSize(width: 1000, height: 874)), source: base),
            Variant(name: "script",    key: Self.key(art: .schreibschrift), source: base),
            Variant(name: "features",  key: Self.key(features: ["ss02"]), source: base),
            Variant(name: "padding",   key: Self.key(pad: 0.0), source: base),
            // Same key, different source strokes: what Light vs Regular is.
            Variant(name: "weight",    key: Self.key(), source: Self.strokes(dx: 0.1)),
        ]
        var results: [LetterStrokes] = []
        for (i, v) in variants.enumerated() {
            let r = cache.strokes(for: v.source, key: v.key) { rectFor(i) }
            #expect(r == StrokeMapping.map(v.source, into: rectFor(i)),
                    "\(v.name): served a mapping that is not its own")
            results.append(r)
        }
        // Eight distinct lookups, eight mappings, none served from another's slot.
        #expect(cache.mappingMisses == variants.count)
        #expect(cache.mappingHits == 0)
        for i in results.indices {
            for j in results.indices where j > i {
                #expect(results[i] != results[j], "\(variants[i].name) and \(variants[j].name) collided")
            }
        }
        // And each variant, asked again, is a hit that still returns ITS value.
        for (i, v) in variants.enumerated() where v.name != "weight" {
            let r = cache.strokes(for: v.source, key: v.key) { rectFor(99) }
            #expect(r == results[i], "\(v.name): a repeat changed value")
        }
    }

    @Test("a real Light and Regular weight of one letter map to different strokes under one key")
    func realWeightsDoNotCollide() throws {
        func asset(_ w: FontWeight) throws -> LetterStrokes {
            let letters = LetterRepository(resources: BundleLetterResourceProvider(),
                                           cache: NullLetterCache(), weight: w).loadLetters()
            return try #require(letters.first { $0.name == "A" }).strokes
        }
        let light = try asset(.light), regular = try asset(.regular)
        try #require(light.strokes != regular.strokes, "the bundle's two weights must differ for this to mean anything")
        let cache = StrokeMappingCache()
        let a = cache.strokes(for: regular, key: Self.key("A")) { Self.rect }
        let b = cache.strokes(for: light, key: Self.key("A")) { Self.rect }
        #expect(a == StrokeMapping.map(regular, into: Self.rect))
        #expect(b == StrokeMapping.map(light, into: Self.rect))
        #expect(a != b)
    }

    // MARK: 3. ghost paths

    @Test("ghost paths are rebuilt only when the mapped strokes or the frame change")
    func ghostPathsAreReused() {
        let cache = StrokeMappingCache()
        let mapped = StrokeMapping.map(Self.strokes(), into: Self.rect)
        let frame = CGRect(x: 10, y: 20, width: 1000, height: 600)

        let p1 = cache.ghostPaths(cell: 0, strokes: mapped, frame: frame)
        let p2 = cache.ghostPaths(cell: 0, strokes: mapped, frame: frame)
        #expect(p1 == p2)
        #expect(p1.count == 1, "the one-checkpoint stroke is skipped, as the canvas always did")
        #expect(cache.ghostMisses == 1 && cache.ghostHits == 1)

        let moved = cache.ghostPaths(cell: 0, strokes: mapped, frame: frame.offsetBy(dx: 5, dy: 0))
        #expect(moved != p1, "a moved frame is a different ghost")
        let other = StrokeMapping.map(Self.strokes(dx: 0.1), into: Self.rect)
        let changed = cache.ghostPaths(cell: 0, strokes: other, frame: frame.offsetBy(dx: 5, dy: 0))
        #expect(changed != moved, "changed strokes are a different ghost")
        #expect(cache.ghostMisses == 3 && cache.ghostHits == 1)

        // The path is the old per-frame construction: origin + fraction * size.
        let pts = mapped.strokes[0].checkpoints.map {
            CGPoint(x: frame.minX + $0.x * frame.width, y: frame.minY + $0.y * frame.height)
        }
        #expect(p1[0] == StrokeMapping.smoothedPath(through: pts))
    }

    // MARK: 4. both view-model sites share the one mapping

    @Test("rawGlyphStrokes and gridCellStrokes are one mapping, computed once however often they are read")
    func viewModelSitesShareOneCachedMapping() throws {
        let canvas = CGSize(width: 1084, height: 626)
        var deps = TracingDependencies.stub
        deps.repo = LetterRepository(resources: BundleLetterResourceProvider(),
                                     cache: NullLetterCache(),
                                     userDefaults: UserDefaults(suiteName: "r081-\(UUID().uuidString)") ?? .standard,
                                     weight: .regular)
        let vm = TracingViewModel(deps)
        vm.glyphRectProvider = { letter, size, art, features, pad in
            PrimaeLetterRenderer.computeNormalizedGlyphRect(
                for: letter, canvasSize: size, schriftArt: art,
                openTypeFeatures: features, pad: pad)
        }
        vm.canvasSize = canvas
        vm.loadLetter(name: "A")
        let source = try #require(vm.glyphRelativeStrokes)
        let cellSize = vm.gridCells[vm.gridActiveCellIndex].frame.size
        try #require(cellSize.width > 0 && cellSize.height > 0, "the headless VM must have laid out a cell")
        let rect = try #require(PrimaeLetterRenderer.computeNormalizedGlyphRect(
            for: "A", canvasSize: cellSize, schriftArt: vm.schriftArt, openTypeFeatures: vm.currentGlyphFeatures))
        let expected = StrokeMapping.map(source, into: rect)
        #expect(expected != source, "the mapping must actually move the strokes")

        let before = vm.strokeMappingCache.mappingMisses
        for _ in 0..<5 {
            #expect(vm.rawGlyphStrokes == expected)
            #expect(vm.gridCellStrokes(at: vm.gridActiveCellIndex) == expected)
        }
        #expect(vm.strokeMappingCache.mappingMisses == before + 1,
                "ten reads through both sites, one mapping")
        #expect(vm.strokeMappingCache.mappingHits >= 9)
    }
}
