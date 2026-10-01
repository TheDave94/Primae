import CoreGraphics
import Observation

/// Owns the grid of `LetterCell`s that a `TracingSequence` expands to:
/// per-cell layout, active-cell tracking, hit-testing, advancement on
/// completion, aggregate progress. Pure state object — does not load
/// stroke JSON or drive the VM. A length-1 sequence with `.finger`
/// produces exactly one cell whose frame equals the canvas.
@Observable
final class SequenceGridController {
    private(set) var cells: [LetterCell]
    private(set) var activeCellIndex: Int
    private(set) var preset: InputPreset
    private(set) var sequence: TracingSequence
    /// Whole-word image + per-character bboxes for `.word` sequences;
    /// canvas blits this in one pass so Schreibschrift ligatures
    /// connect across cell boundaries.
    private(set) var wordRendering: PrimaeLetterRenderer.WordRendering?

    /// Reach of each cell's sound gate, as a multiple of the adapted
    /// checkpoint radius — `StudyComparisonSettings.soundGateRadiusFactor`,
    /// the supervisor's "Trigger boundaries", set once by the view model at
    /// session start.
    ///
    /// It lives HERE rather than on the trackers because cells are rebuilt
    /// from scratch on every `load` (every letter, every preset flip), so a
    /// value written onto a tracker in place would be lost at the next
    /// letter — which is the shape that makes a switch silently inert. The
    /// `didSet` re-applies to cells already built, so the assignment is
    /// order-independent.
    var soundGateRadiusFactor: CGFloat =
        CGFloat(StudyComparisonSettings.soundGateRadiusFactorDefault) {
        didSet { applyToTrackers() }
    }

    init(sequence: TracingSequence, preset: InputPreset) {
        self.sequence = sequence
        self.preset = preset.resolved(forSequenceLength: sequence.items.count)
        self.cells = sequence.items.enumerated().map {
            LetterCell(index: $0.offset, item: $0.element)
        }
        self.activeCellIndex = 0
        self.wordRendering = nil
        applyToTrackers()
    }

    /// Replace the sequence and/or preset, rebuilding cells and resetting
    /// the active index. Called whenever a new letter/word is loaded or
    /// the input preset flips (finger ↔ pencil).
    func load(sequence: TracingSequence, preset: InputPreset) {
        self.sequence = sequence
        self.preset = preset.resolved(forSequenceLength: sequence.items.count)
        self.cells = sequence.items.enumerated().map {
            LetterCell(index: $0.offset, item: $0.element)
        }
        self.activeCellIndex = 0
        self.wordRendering = nil
        applyToTrackers()
    }

    /// Push `soundGateRadiusFactor` onto every cell's tracker. Called from
    /// the property's `didSet` and after every rebuild, so no path can leave
    /// a cell carrying the built-in default while the session runs another.
    private func applyToTrackers() {
        for cell in cells { cell.tracker.soundGateRadiusFactor = soundGateRadiusFactor }
    }

    /// Assign per-cell frames. `.word` sequences route through
    /// CoreText so cursive kerning is preserved; other kinds use
    /// even-width cells. Falls back to even-width if word layout fails.
    func layout(in canvasSize: CGSize, schriftArt: SchriftArt = .druckschrift) {
        let frames: [CGRect]
        if case .word(let word) = sequence.kind,
           let rendering = PrimaeLetterRenderer.renderWord(
               word: word, size: canvasSize, schriftArt: schriftArt) {
            frames = rendering.characterFrames
            wordRendering = rendering
        } else {
            frames = GridLayoutCalculator.cellFrames(canvasSize: canvasSize, preset: preset)
            wordRendering = nil
        }
        for (i, frame) in frames.enumerated() where i < cells.count {
            cells[i].frame = frame
        }
    }

    var activeCell: LetterCell { cells[activeCellIndex] }

    /// Hit-test a canvas-space point. Returns `nil` for points in inter-cell
    /// spacing or outside the row — callers decide whether to ignore or
    /// route to the active cell anyway.
    func cell(atCanvasPoint p: CGPoint) -> LetterCell? {
        cells.first { $0.frame.contains(p) }
    }

    /// If the active cell's tracker reports `isComplete`, mark it completed
    /// and advance to the next cell. Returns `true` exactly once — when the
    /// final cell completes — so callers can fire sequence-level commits.
    @discardableResult
    func advanceIfCompleted() -> Bool {
        guard activeCell.tracker.isComplete else { return false }
        activeCell.state = .completed
        guard activeCellIndex + 1 < cells.count else { return true }
        activeCellIndex += 1
        cells[activeCellIndex].state = .active
        return false
    }

    var isSequenceComplete: Bool {
        cells.allSatisfy { $0.state == .completed }
    }

    /// Average of per-cell tracker progress. Drives the existing progress
    /// pill without awareness that the canvas is now a grid.
    var aggregateProgress: CGFloat {
        guard !cells.isEmpty else { return 0 }
        let total = cells.reduce(CGFloat(0)) { $0 + $1.tracker.overallProgress }
        return total / CGFloat(cells.count)
    }
}
