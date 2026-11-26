// SceneResizeSafetyTests.swift
// PrimaeNativeTests
//
// Defence in depth for a canvas that changes size mid-letter. The study
// build stays landscape-only and full screen (UIRequiresFullScreen = YES,
// David's ruling A, 2026-11-25; docs/DECISIONS.md "Rotation and
// UIRequiresFullScreen"), measured to keep the session landscape on
// iPadOS 27.3. Apple has deprecated the key (TN3192), so if a later iPadOS
// stops honouring it these decisions keep a resized session correct; in a
// full-screen landscape session they change nothing (the golden tests pin
// that):
//  - CanvasResizeRemap: where pre-resize ink belongs after the resize;
//  - PrimaeLetterRenderer.glyphFit: the letter fits a narrow canvas, and
//    is unchanged wherever the old placement already fitted;
//  - StrokeTracker.replaceGeometry and the view model's resize path: the
//    child's progress and ink survive a resize;
//  - SessionEndLayout: the end screen shrinks instead of cropping.

import Testing
import Foundation
import CoreGraphics
import UIKit
@testable import PrimaeNative

@Suite @MainActor struct CanvasResizeRemapTests {

    @Test("same canvas: identity")
    func sameCanvasIsIdentity() {
        let size = CGSize(width: 1200, height: 800)
        #expect(CanvasResizeRemap.between(oldCanvas: size, oldGlyphRect: nil,
                                          newCanvas: size, newGlyphRect: nil) == .identity)
    }

    @Test("an empty canvas cannot be mapped")
    func emptyCanvasIsNil() {
        #expect(CanvasResizeRemap.between(oldCanvas: .zero, oldGlyphRect: nil,
                                          newCanvas: CGSize(width: 10, height: 10),
                                          newGlyphRect: nil) == nil)
    }

    @Test("with glyph rects: the old glyph rect's corners land on the new rect's corners")
    func glyphRectCornersMap() throws {
        let oldCanvas = CGSize(width: 1270, height: 874)
        let newCanvas = CGSize(width: 928, height: 1216)
        // A uniformly scaled, horizontally centred glyph, as glyphFit places it.
        let oldRect = CGRect(x: 0.4, y: 0.1, width: 0.2 * 874 / 1270, height: 0.6)
        let newH: CGFloat = 0.6
        let newWpx = oldRect.width * 1270 * (newH * 1216) / (0.6 * 874)
        let newRect = CGRect(x: (928 - newWpx) / 2 / 928, y: 0.1,
                             width: newWpx / 928, height: newH)
        let r = try #require(CanvasResizeRemap.between(oldCanvas: oldCanvas, oldGlyphRect: oldRect,
                                                       newCanvas: newCanvas, newGlyphRect: newRect))
        let tl = r.apply(CGPoint(x: oldRect.minX * 1270, y: oldRect.minY * 874))
        let br = r.apply(CGPoint(x: oldRect.maxX * 1270, y: oldRect.maxY * 874))
        #expect(abs(tl.x - newRect.minX * 928) < 1e-6)
        #expect(abs(tl.y - newRect.minY * 1216) < 1e-6)
        #expect(abs(br.x - newRect.maxX * 928) < 1e-6)
        #expect(abs(br.y - newRect.maxY * 1216) < 1e-6)
    }

    @Test("without glyph rects: scale with the height, keep the horizontal centre and the top")
    func fallbackFollowsThePlacementRule() throws {
        let r = try #require(CanvasResizeRemap.between(
            oldCanvas: CGSize(width: 1000, height: 750), oldGlyphRect: nil,
            newCanvas: CGSize(width: 700, height: 1000), newGlyphRect: nil))
        let centre = r.apply(CGPoint(x: 500, y: 375))
        #expect(abs(centre.x - 350) < 1e-9)
        #expect(abs(centre.y - 500) < 1e-9)
        let top = r.apply(CGPoint(x: 500, y: 0))
        #expect(abs(top.y) < 1e-9)
        // Uniform: a 30 pt horizontal segment becomes 40 pt (1000 / 750).
        let a = r.apply(CGPoint(x: 400, y: 100)), b = r.apply(CGPoint(x: 430, y: 100))
        #expect(abs((b.x - a.x) - 40) < 1e-9)
    }
}

@Suite @MainActor struct GlyphFitTests {
    // Primae-Regular metrics at the 800 pt probe are not needed: the rule
    // is arithmetic. Ascent/descent/ink below mimic a wide capital (W,
    // 0.701 em, measured with CoreText 2026-11-24).
    private let ascent: CGFloat = 700
    private let descent: CGFloat = 300
    private var ink: CGSize { CGSize(width: 701, height: 650) }

    @Test("a landscape canvas: exactly the old height-only placement")
    func landscapeIsUnchanged() {
        let size = CGSize(width: 1270, height: 874)
        let fit = PrimaeLetterRenderer.glyphFit(canvasSize: size, pad: 0.10,
                                                ascent: ascent, descent: descent, inkSize: ink)
        let oldScale = size.height * 0.8 / (ascent + descent)
        #expect(fit.scale == oldScale)
        #expect(fit.baselineY == size.height * 0.10 + ascent * oldScale)
    }

    @Test("full-screen portrait (12.9-inch): still the old placement")
    func portraitIsUnchanged() {
        let size = CGSize(width: 928, height: 1216)
        let fit = PrimaeLetterRenderer.glyphFit(canvasSize: size, pad: 0.10,
                                                ascent: ascent, descent: descent, inkSize: ink)
        #expect(fit.scale == size.height * 0.8 / (ascent + descent))
    }

    @Test("a narrow canvas: the ink fits the width inside the pad, centred vertically")
    func narrowCanvasIsCapped() {
        let size = CGSize(width: 404, height: 1216)
        let fit = PrimaeLetterRenderer.glyphFit(canvasSize: size, pad: 0.10,
                                                ascent: ascent, descent: descent, inkSize: ink)
        #expect(ink.width * fit.scale <= size.width * 0.8 + 1e-9)
        #expect(fit.scale < size.height * 0.8 / (ascent + descent))
        // Centred: equal free space above and below the em box.
        let emTop = fit.baselineY - ascent * fit.scale
        let emBottom = fit.baselineY + descent * fit.scale
        #expect(abs(emTop - (size.height - emBottom)) < 1e-9)
    }

    @Test("the real W stays inside a narrow canvas")
    func realGlyphRectFitsNarrowCanvas() throws {
        let rect = try #require(PrimaeLetterRenderer.computeNormalizedGlyphRect(
            for: "W", canvasSize: CGSize(width: 404, height: 1216)))
        #expect(rect.minX >= 0.0999)
        #expect(rect.maxX <= 0.9001)
    }
}

@Suite @MainActor struct StrokeTrackerReplaceGeometryTests {
    private func letter(_ dx: CGFloat) -> LetterStrokes {
        LetterStrokes(letter: "T", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.1 + dx, y: 0.1),
                                                  Checkpoint(x: 0.5 + dx, y: 0.1)]),
            StrokeDefinition(id: 2, checkpoints: [Checkpoint(x: 0.3 + dx, y: 0.1),
                                                  Checkpoint(x: 0.3 + dx, y: 0.9)])
        ])
    }

    @Test("the same letter re-mapped keeps every stroke's progress")
    func keepsProgress() {
        let t = StrokeTracker()
        t.load(letter(0))
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.1))
        #expect(t.currentStrokeIndex == 1)
        let before = t.overallProgress
        #expect(t.replaceGeometry(letter(0.05)))
        #expect(t.currentStrokeIndex == 1)
        #expect(t.overallProgress == before)
        #expect(abs((t.definition?.strokes[0].checkpoints[0].x ?? 0) - 0.15) < 1e-9)
    }

    @Test("a different shape (checkpoint count) starts over, like load")
    func differentShapeStartsOver() {
        let t = StrokeTracker()
        t.load(letter(0))
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.1))
        let other = LetterStrokes(letter: "I", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.5, y: 0.1),
                                                  Checkpoint(x: 0.5, y: 0.5),
                                                  Checkpoint(x: 0.5, y: 0.9)])])
        #expect(!t.replaceGeometry(other))
        #expect(t.overallProgress == 0)
    }

    @Test("same stroke count but a different checkpoint count starts over")
    func differentCheckpointCountStartsOver() {
        let t = StrokeTracker()
        t.load(letter(0))
        t.update(normalizedPoint: CGPoint(x: 0.1, y: 0.1))
        t.update(normalizedPoint: CGPoint(x: 0.5, y: 0.1))
        #expect(t.currentStrokeIndex == 1)
        let other = LetterStrokes(letter: "T", checkpointRadius: 0.05, strokes: [
            StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.1, y: 0.1),
                                                  Checkpoint(x: 0.3, y: 0.1),
                                                  Checkpoint(x: 0.5, y: 0.1)]),
            StrokeDefinition(id: 2, checkpoints: [Checkpoint(x: 0.3, y: 0.1),
                                                  Checkpoint(x: 0.3, y: 0.9)])])
        #expect(!t.replaceGeometry(other))
        #expect(t.currentStrokeIndex == 0)
        #expect(t.overallProgress == 0)
    }

    @Test("only a size change of the same letter counts as a geometry-only rebuild")
    func geometryOnlyDecision() {
        typealias Key = TracingViewModel.CheckpointBuildKey
        let a = Key(letter: "A", size: CGSize(width: 1270, height: 874), schriftArt: .druckschrift, showingVariant: false)
        let resized = Key(letter: "A", size: CGSize(width: 928, height: 1216), schriftArt: .druckschrift, showingVariant: false)
        let otherLetter = Key(letter: "F", size: resized.size, schriftArt: .druckschrift, showingVariant: false)
        let variant = Key(letter: "A", size: resized.size, schriftArt: .druckschrift, showingVariant: true)
        #expect(TracingViewModel.isGeometryOnlyChange(from: a, to: resized))
        #expect(!TracingViewModel.isGeometryOnlyChange(from: a, to: a))
        #expect(!TracingViewModel.isGeometryOnlyChange(from: a, to: otherLetter))
        #expect(!TracingViewModel.isGeometryOnlyChange(from: a, to: variant))
        #expect(!TracingViewModel.isGeometryOnlyChange(from: nil, to: a))
    }
}

@Suite(.serialized) @MainActor struct ViewModelCanvasResizeTests {
    private func studyVM() -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        let vm = TracingViewModel(deps)
        vm.canvasSize = CGSize(width: 1000, height: 750)
        return vm
    }

    @Test("a resize mid-letter keeps the tracker's progress")
    func resizeKeepsTrackerProgress() throws {
        let vm = studyVM()
        let def = try #require(vm.strokeTracker.definition)
        let first = try #require(def.strokes.first?.checkpoints.first)
        vm.strokeTracker.update(normalizedPoint: CGPoint(x: first.x, y: first.y))
        let before = vm.strokeTracker.overallProgress
        #expect(before > 0)
        vm.canvasSize = CGSize(width: 700, height: 1000)
        #expect(vm.strokeTracker.overallProgress == before)
    }

    @Test("a resize in freeWrite carries the recorded points onto the letter's new place")
    func resizeRemapsFreeWriteInk() {
        let vm = studyVM()
        vm.phaseController.resume(at: .freeWrite)
        vm.beginTouch(at: CGPoint(x: 400, y: 200), t: 1000, force: 0)
        vm.updateTouch(at: CGPoint(x: 460, y: 260), t: 1000.02, canvasSize: vm.canvasSize)
        let before = vm.freeWriteRecorder.points
        #expect(before.count == 2)
        let old = vm.canvasSize, new = CGSize(width: 700, height: 1000)
        let expected = vm.inkRemapForCanvasResize(from: old, to: new)!
        vm.canvasSize = new
        #expect(vm.freeWriteRecorder.points == before.map(expected.apply))
        #expect(vm.activePath == before.map(expected.apply))
        // The normalised KP path is rebuilt against the new canvas.
        let p = vm.freeWriteRecorder.points[1], q = vm.freeWriteRecorder.path[1]
        #expect(abs(q.x - p.x / new.width) < 1e-9 && abs(q.y - p.y / new.height) < 1e-9)
    }
}

@Suite @MainActor struct SessionEndLayoutTests {
    @Test("a full landscape scene shows the end screen at its natural size")
    func fullSceneIsUnscaled() {
        #expect(SessionEndLayout.fitScale(letterCount: 3, available: CGSize(width: 1302, height: 1024)) == 1)
    }

    @Test("a small scene shrinks the whole composition to fit, with its margin")
    func smallSceneShrinks() {
        let available = CGSize(width: 440, height: 560)
        let s = SessionEndLayout.fitScale(letterCount: 3, available: available)
        let n = SessionEndLayout.naturalSize(letterCount: 3)
        #expect(s < 1)
        #expect(n.width * s <= available.width - 2 * SessionEndLayout.margin + 1e-9)
        #expect(n.height * s <= available.height - 2 * SessionEndLayout.margin + 1e-9)
    }
}
