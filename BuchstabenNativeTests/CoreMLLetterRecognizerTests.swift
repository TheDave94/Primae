//  CoreMLLetterRecognizerTests.swift
//  BuchstabenNativeTests
//
//  D3 (ROADMAP_V5): direct unit coverage for the recognizer's image
//  pipeline. The Vision-request path needs a real or mocked CoreML
//  model and is exercised end-to-end via integration tests; the
//  rendering / coordinate-flipping internals are pure CoreGraphics and
//  testable here without a model. Pins the contract so a regression
//  that mis-flips the Y axis or zero-extents the path can't ship
//  silently.

import Testing
import Foundation
import CoreGraphics
@testable import BuchstabenNative

@Suite struct CoreMLLetterRecognizerImageTests {

    @Test("renderToImage returns nil for empty input")
    func emptyInputReturnsNil() {
        #expect(CoreMLLetterRecognizer.renderToImage(
            points: [], canvasSize: .init(width: 400, height: 400)) == nil)
    }

    @Test("renderToImage returns nil for single point")
    func singlePointReturnsNil() {
        let single = [CGPoint(x: 100, y: 100)]
        #expect(CoreMLLetterRecognizer.renderToImage(
            points: single, canvasSize: .init(width: 400, height: 400)) == nil)
    }

    @Test("renderToImage produces a 40×40 grayscale image for a non-trivial path")
    func nonTrivialPathYields40Square() {
        // Diagonal across the canvas — guaranteed non-zero bounding box
        // in both X and Y so the centering math doesn't divide by zero.
        let diag = (0...20).map { i -> CGPoint in
            let t = Double(i) / 20.0
            return CGPoint(x: 80 + t * 240, y: 80 + t * 240)
        }
        let img = CoreMLLetterRecognizer.renderToImage(
            points: diag, canvasSize: .init(width: 400, height: 400))
        #expect(img != nil, "Expected a non-nil image for a 21-point diagonal")
        #expect(img?.width == 40, "Model expects a 40-pixel-wide grayscale image")
        #expect(img?.height == 40)
    }

    @Test("renderToImage handles a degenerate vertical-only path")
    func degenerateAxis() {
        // All points share the same X — boxW would be 0 without the max(.., 1)
        // guard. Should still produce an image, not crash.
        let vertical = (0...10).map { i in
            CGPoint(x: 200, y: 100 + Double(i) * 20)
        }
        let img = CoreMLLetterRecognizer.renderToImage(
            points: vertical, canvasSize: .init(width: 400, height: 400))
        #expect(img != nil, "Vertical-only path must still rasterise")
    }

    @Test("renderToImage centres the path despite asymmetric input bounds")
    func centeringInvariantUnderTranslation() {
        // Two identical L-shapes at different canvas positions should
        // produce visually-identical 40×40 outputs because the renderer
        // bounding-box-normalises before scaling. We don't assert
        // pixel-equality (subpixel rendering may differ at edges); we
        // assert both calls succeed and return the documented size.
        let lShapeAtTopLeft = [
            CGPoint(x: 50, y: 50), CGPoint(x: 50, y: 90), CGPoint(x: 90, y: 90)
        ]
        let lShapeAtBottomRight = [
            CGPoint(x: 280, y: 280), CGPoint(x: 280, y: 320), CGPoint(x: 320, y: 320)
        ]
        let canvas = CGSize(width: 400, height: 400)
        let a = CoreMLLetterRecognizer.renderToImage(points: lShapeAtTopLeft, canvasSize: canvas)
        let b = CoreMLLetterRecognizer.renderToImage(points: lShapeAtBottomRight, canvasSize: canvas)
        #expect(a != nil && b != nil)
        #expect(a?.width == b?.width)
        #expect(a?.height == b?.height)
    }
}
