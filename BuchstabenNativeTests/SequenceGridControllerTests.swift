//  SequenceGridControllerTests.swift
//  BuchstabenNativeTests

import Testing
import CoreGraphics
@testable import BuchstabenNative

@Suite @MainActor struct SequenceGridControllerTests {

    // MARK: - Migration-neutral setup

    @Test func lengthOneSequence_hasSingleActiveCell() {
        let c = SequenceGridController(sequence: .singleLetter("A"), preset: .finger)
        #expect(c.cells.count == 1)
        #expect(c.activeCellIndex == 0)
        #expect(c.activeCell.state == .active)
        #expect(c.activeCell.item.letter == "A")
    }

    @Test func lengthOneLayout_coversWholeCanvas() {
        // The migration-neutral contract: a length-1 finger sequence laid
        // out in a canvas yields a single cell whose frame equals the canvas.
        let c = SequenceGridController(sequence: .singleLetter("A"), preset: .finger)
        let canvas = CGSize(width: 800, height: 600)
        c.layout(in: canvas)
        #expect(c.cells[0].frame == CGRect(origin: .zero, size: canvas))
    }

    // MARK: - Multi-cell expansion

    @Test func wordSequence_expandsToOneCellPerLetter() {
        let c = SequenceGridController(sequence: .word("Affe"), preset: .pencil)
        #expect(c.cells.count == 4)
        #expect(c.cells.map(\.item.letter) == ["A", "f", "f", "e"])
    }

    @Test func fingerPresetWithWord_expandsCellCountToWordLength() {
        // Finger defaults to 1 cell, but a 4-letter word still renders
        // across 4 cells — preset contributes spacing/lineatur only.
        let c = SequenceGridController(sequence: .word("Affe"), preset: .finger)
        #expect(c.cells.count == 4)
        #expect(c.preset.cellCount == 4)
        #expect(c.preset.kind == .finger)
    }

    // MARK: - Cell state initialization

    @Test func firstCellIsActive_othersPending() {
        let c = SequenceGridController(sequence: .word("Affe"), preset: .pencil)
        #expect(c.cells[0].state == .active)
        #expect(c.cells[1].state == .pending)
        #expect(c.cells[2].state == .pending)
        #expect(c.cells[3].state == .pending)
    }

    // MARK: - Hit-testing

    @Test func hitTest_returnsCellForPointInsideFrame() {
        let c = SequenceGridController(sequence: .singleLetter("A"), preset: .finger)
        c.layout(in: CGSize(width: 1024, height: 768))
        let hit = c.cell(atCanvasPoint: CGPoint(x: 100, y: 100))
        #expect(hit?.id == 0)
    }

    @Test func hitTest_returnsNilForPointInInterCellSpacing() {
        let c = SequenceGridController(sequence: .word("Affe"), preset: .pencil)
        c.layout(in: CGSize(width: 1000, height: 600))
        let gapX = (c.cells[0].frame.maxX + c.cells[1].frame.minX) / 2
        let hit = c.cell(atCanvasPoint: CGPoint(x: gapX, y: 300))
        #expect(hit == nil)
    }

    @Test func hitTest_returnsCellTwoForPointInsideThirdCell() {
        let c = SequenceGridController(sequence: .word("Affe"), preset: .pencil)
        c.layout(in: CGSize(width: 1000, height: 600))
        let p = CGPoint(x: c.cells[2].frame.midX, y: c.cells[2].frame.midY)
        let hit = c.cell(atCanvasPoint: p)
        #expect(hit?.id == 2)
    }

    // MARK: - Load

    @Test func load_replacesCellsAndResetsActiveIndex() {
        let c = SequenceGridController(sequence: .singleLetter("A"), preset: .finger)
        c.load(sequence: .word("Oma"), preset: .pencil)
        #expect(c.cells.count == 3)
        #expect(c.activeCellIndex == 0)
        #expect(c.activeCell.item.letter == "O")
        #expect(c.preset.kind == .pencil)
    }

    // MARK: - Sequence completion

    @Test func isSequenceComplete_falseAtStart() {
        let c = SequenceGridController(sequence: .word("Affe"), preset: .pencil)
        #expect(!c.isSequenceComplete)
    }

    @Test func advanceIfCompleted_noopsWhenActiveCellNotComplete() {
        let c = SequenceGridController(sequence: .word("Affe"), preset: .pencil)
        // Fresh cells have empty trackers — isComplete returns false.
        let result = c.advanceIfCompleted()
        #expect(!result)
        #expect(c.activeCellIndex == 0)
        #expect(c.activeCell.state == .active)
    }

    // MARK: - Aggregate progress

    @Test func aggregateProgress_zeroForFreshSequence() {
        let c = SequenceGridController(sequence: .word("Affe"), preset: .pencil)
        #expect(c.aggregateProgress == 0)
    }
}
