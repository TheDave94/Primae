//  GridLayoutCalculatorTests.swift
//  BuchstabenNativeTests

import Testing
import CoreGraphics
@testable import BuchstabenNative

@Suite @MainActor struct GridLayoutCalculatorTests {

    // MARK: - Migration-neutral guarantee

    @Test func lengthOneFingerPreset_producesWholeCanvasFrame() {
        // The critical invariant: a length-1 finger grid cell equals the
        // entire canvas, so today's single-letter renderer sees no change.
        let frames = GridLayoutCalculator.cellFrames(
            canvasSize: CGSize(width: 800, height: 600),
            preset: .finger
        )
        #expect(frames == [CGRect(x: 0, y: 0, width: 800, height: 600)])
    }

    @Test func arbitraryCanvasSize_lengthOneCellCoversWholeCanvas() {
        let canvas = CGSize(width: 1024, height: 768)
        let frames = GridLayoutCalculator.cellFrames(canvasSize: canvas, preset: .finger)
        #expect(frames[0] == CGRect(origin: .zero, size: canvas))
    }

    // MARK: - Multi-cell layout

    @Test func fourCellPencilPreset_producesFourContiguousFrames() {
        let frames = GridLayoutCalculator.cellFrames(
            canvasSize: CGSize(width: 1000, height: 600),
            preset: .pencil
        )
        #expect(frames.count == 4)
        #expect(frames.allSatisfy { $0.height == 600 })
    }

    @Test func cellFrames_respectHorizontalInset() {
        let frames = GridLayoutCalculator.cellFrames(
            canvasSize: CGSize(width: 1000, height: 600),
            preset: .pencil
        )
        // Pencil inset is 8pt each side
        #expect(frames.first?.minX == 8)
        #expect(frames.last?.maxX == 1000 - 8)
    }

    @Test func cellFrames_haveEqualWidths() {
        let frames = GridLayoutCalculator.cellFrames(
            canvasSize: CGSize(width: 1000, height: 600),
            preset: .pencil
        )
        let widths = Set(frames.map(\.width))
        #expect(widths.count == 1)
    }

    @Test func cellFrames_haveSpacingBetweenThem() {
        let frames = GridLayoutCalculator.cellFrames(
            canvasSize: CGSize(width: 1000, height: 600),
            preset: .pencil
        )
        let gap = frames[1].minX - frames[0].maxX
        #expect(gap == InputPreset.pencil.cellSpacing)
    }

    @Test func expandedSequenceLength_producesNFrames() {
        let preset = InputPreset.finger.resolved(forSequenceLength: 3)
        let frames = GridLayoutCalculator.cellFrames(
            canvasSize: CGSize(width: 900, height: 600),
            preset: preset
        )
        #expect(frames.count == 3)
    }

    // MARK: - Edge cases

    @Test func zeroWidthCanvas_producesZeroWidthFrames() {
        let frames = GridLayoutCalculator.cellFrames(
            canvasSize: .zero,
            preset: .pencil
        )
        #expect(frames.count == 4)
        #expect(frames.allSatisfy { $0.width == 0 })
    }
}
