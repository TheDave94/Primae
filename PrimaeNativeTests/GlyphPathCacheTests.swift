// GlyphPathCacheTests.swift
// Code analysis 2026-11-01, F3: `TracingCanvasView` calls
// `PrimaeLetterRenderer.glyphPath` inside its draw closure, once per cell
// per redraw, and every touch sample redraws. The path and the font had no
// cache, so each redraw re-read and re-parsed the font file. Both are now
// memoized; a hit must return exactly what a fresh build does, and must not
// go back to the font file.
//
// `glyphPath` returns nil under a test host (`isRunningTests`), so these
// drive `renderGlyphPath`, the guard-free body it delegates to.

import Testing
import SwiftUI
@testable import PrimaeNative

// Serialized: the renderer's caches and its counters are static. Every
// test body is synchronous on the main actor, so no other suite's
// `clearCache()` (a script change) can run between two calls in one test.
@Suite(.serialized) @MainActor struct GlyphPathCacheTests {

    private let size = CGSize(width: 300, height: 400)

    @Test("a cache hit returns the same path and does not reload the font")
    func hitDoesNotReload() throws {
        PrimaeLetterRenderer.clearCache()
        let first = try #require(PrimaeLetterRenderer.renderGlyphPath(letter: "A", size: size),
                                 "precondition: the bundled font renders A")
        let loadsAfterFirst = PrimaeLetterRenderer.fontLoadCount
        let buildsAfterFirst = PrimaeLetterRenderer.pathBuildCount
        let second = PrimaeLetterRenderer.renderGlyphPath(letter: "A", size: size)
        #expect(second == first, "a cache hit returned a different path")
        #expect(PrimaeLetterRenderer.pathBuildCount == buildsAfterFirst,
                "a repeated glyph path was rebuilt instead of served from the cache")
        #expect(PrimaeLetterRenderer.fontLoadCount == loadsAfterFirst,
                "a repeated glyph path went back to the font file")
    }

    @Test("a cached path equals a freshly built one")
    func cachedEqualsFresh() throws {
        PrimaeLetterRenderer.clearCache()
        let built = try #require(PrimaeLetterRenderer.renderGlyphPath(letter: "M", size: size))
        let cached = PrimaeLetterRenderer.renderGlyphPath(letter: "M", size: size)
        PrimaeLetterRenderer.clearCache()
        let rebuilt = PrimaeLetterRenderer.renderGlyphPath(letter: "M", size: size)
        #expect(cached == built)
        #expect(rebuilt == built, "the path after clearing the cache differs from the first build")
    }

    @Test("the key separates letter and size; every entry equals its own fresh build")
    func keySeparatesInputs() throws {
        PrimaeLetterRenderer.clearCache()
        let a = try #require(PrimaeLetterRenderer.renderGlyphPath(letter: "A", size: size))
        let f = PrimaeLetterRenderer.renderGlyphPath(letter: "F", size: size)
        let aSmall = PrimaeLetterRenderer.renderGlyphPath(letter: "A",
                                                          size: CGSize(width: 150, height: 200))
        // The features are part of the key too, but not observable here:
        // `getGlyph` maps characters through `CTFontGetGlyphsForCharacters`,
        // which applies no OpenType substitution, so ss02 does not change
        // the path. It must still round-trip through the cache unchanged.
        let kAlt = PrimaeLetterRenderer.renderGlyphPath(letter: "k", size: size,
                                                        openTypeFeatures: ["ss02"])
        #expect(f != a, "a different letter hit A's cache entry")
        #expect(aSmall != a, "a different size hit A's cache entry")
        #expect(kAlt != nil)
        // Each still equals its own uncached build.
        PrimaeLetterRenderer.clearCache()
        #expect(PrimaeLetterRenderer.renderGlyphPath(letter: "F", size: size) == f)
        #expect(PrimaeLetterRenderer.renderGlyphPath(letter: "k", size: size,
                                                     openTypeFeatures: ["ss02"]) == kAlt)
    }

    @Test("makeFont returns the cached font for the same inputs and loads once")
    func fontCached() throws {
        PrimaeLetterRenderer.clearCache()
        let before = PrimaeLetterRenderer.fontLoadCount
        let f1 = try #require(PrimaeLetterRenderer.makeFont(size: 800))
        let f2 = try #require(PrimaeLetterRenderer.makeFont(size: 800))
        #expect(f1 === f2, "the second call built a new font")
        #expect(PrimaeLetterRenderer.fontLoadCount == before + 1)
        _ = PrimaeLetterRenderer.makeFont(size: 400)
        #expect(PrimaeLetterRenderer.fontLoadCount == before + 2, "a different size must be its own entry")
    }
}
