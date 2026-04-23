import CoreGraphics
import Observation

/// Owns the grid of `LetterCell`s that a `TracingSequence` expands to.
/// Responsibilities: per-cell layout, active-cell tracking, hit-testing,
/// advancement on cell completion, aggregate progress reporting.
///
/// The controller does NOT load stroke JSON or drive the VM — it's a pure
/// state object. Later commits will compose it into `TracingViewModel`.
/// For a length-1 `TracingSequence` with `InputPreset.finger`, the
/// controller produces exactly one cell whose frame equals the canvas,
/// preserving today's single-letter behavior byte-for-byte.
@Observable
final class SequenceGridController {
    private(set) var cells: [LetterCell]
    private(set) var activeCellIndex: Int
    private(set) var preset: InputPreset
    private(set) var sequence: TracingSequence

    init(sequence: TracingSequence, preset: InputPreset) {
        self.sequence = sequence
        self.preset = preset.resolved(forSequenceLength: sequence.items.count)
        self.cells = sequence.items.enumerated().map {
            LetterCell(index: $0.offset, item: $0.element)
        }
        self.activeCellIndex = 0
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
    }

    /// Assign per-cell frames from the calculator. Called from the canvas
    /// layout pass — safe to call repeatedly (idempotent for a given size).
    func layout(in canvasSize: CGSize) {
        let frames = GridLayoutCalculator.cellFrames(canvasSize: canvasSize, preset: preset)
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
