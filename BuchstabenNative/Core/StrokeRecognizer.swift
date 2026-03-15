import CoreGraphics

// MARK: - Result types

/// The result of evaluating a single traced stroke against a reference.
struct StrokeMatchResult {
    /// Fraction of checkpoints hit (0.0 – 1.0).
    let accuracy: CGFloat
    /// True when all checkpoints in the stroke were hit.
    let isComplete: Bool
    /// Index of the next checkpoint still to be reached (or `checkpointCount` if done).
    let nextCheckpointIndex: Int
    /// Total checkpoints in this stroke definition.
    let checkpointCount: Int
}

/// Summary for a full multi-stroke letter tracing session.
struct LetterMatchResult {
    /// Overall fraction of all checkpoints hit across all strokes.
    let overallAccuracy: CGFloat
    /// True when every stroke is complete.
    let isLetterComplete: Bool
    /// Per-stroke breakdowns.
    let strokeResults: [StrokeMatchResult]
    /// Index of the first incomplete stroke, or `strokeResults.count` if all done.
    var activeStrokeIndex: Int {
        strokeResults.firstIndex(where: { !$0.isComplete }) ?? strokeResults.count
    }
}

// MARK: - Protocol

/// Encapsulates stroke-to-letter matching heuristics.
/// Conforming types decide *how* proximity to a checkpoint is evaluated,
/// making the algorithm independently testable and swappable (e.g. DTW, ML).
protocol StrokeRecognizing {
    /// Returns whether a normalised point hits the checkpoint at `index`
    /// in the given stroke, using `checkpointRadius` as the tolerance.
    func pointHitsCheckpoint(
        _ point: CGPoint,
        checkpoint: Checkpoint,
        radius: CGFloat
    ) -> Bool

    /// Evaluates a single point against the current active checkpoint of a stroke.
    /// - Returns: Updated `StrokeMatchResult`, or `nil` if no update (not near checkpoint).
    func evaluate(
        point: CGPoint,
        stroke: StrokeDefinition,
        current: StrokeMatchResult,
        radius: CGFloat
    ) -> StrokeMatchResult?
}

// MARK: - Default Euclidean implementation

/// Euclidean-distance checkpoint matcher (current production algorithm).
struct EuclideanStrokeRecognizer: StrokeRecognizing {

    func pointHitsCheckpoint(
        _ point: CGPoint,
        checkpoint: Checkpoint,
        radius: CGFloat
    ) -> Bool {
        let dx = point.x - checkpoint.x
        let dy = point.y - checkpoint.y
        return hypot(dx, dy) <= radius
    }

    func evaluate(
        point: CGPoint,
        stroke: StrokeDefinition,
        current: StrokeMatchResult,
        radius: CGFloat
    ) -> StrokeMatchResult? {
        let nextIdx = current.nextCheckpointIndex
        guard nextIdx < stroke.checkpoints.count else { return nil }

        let cp = stroke.checkpoints[nextIdx]
        guard pointHitsCheckpoint(point, checkpoint: cp, radius: radius) else { return nil }

        let newNext = nextIdx + 1
        let complete = newNext >= stroke.checkpoints.count
        let accuracy = CGFloat(newNext) / CGFloat(stroke.checkpoints.count)

        return StrokeMatchResult(
            accuracy: accuracy,
            isComplete: complete,
            nextCheckpointIndex: newNext,
            checkpointCount: stroke.checkpoints.count
        )
    }
}

// MARK: - Session (multi-stroke coordinator)

/// Stateful coordinator that applies a `StrokeRecognizing` algorithm
/// across all strokes of a `LetterStrokes` definition.
final class StrokeRecognizerSession {

    private let recognizer: StrokeRecognizing
    private var strokeResults: [StrokeMatchResult] = []
    private var definition: LetterStrokes?

    init(recognizer: StrokeRecognizing = EuclideanStrokeRecognizer()) {
        self.recognizer = recognizer
    }

    /// Load a letter definition and reset all stroke state.
    func load(_ strokes: LetterStrokes) {
        definition = strokes
        strokeResults = strokes.strokes.map { stroke in
            StrokeMatchResult(
                accuracy: 0,
                isComplete: false,
                nextCheckpointIndex: 0,
                checkpointCount: stroke.checkpoints.count
            )
        }
    }

    func reset() {
        guard let definition else { return }
        load(definition)
    }

    /// Feed a normalised touch point into the session.
    /// - Returns: Updated `LetterMatchResult` or `nil` if definition not loaded.
    @discardableResult
    func update(normalizedPoint point: CGPoint) -> LetterMatchResult? {
        guard let definition else { return nil }

        let activeIdx = strokeResults.firstIndex(where: { !$0.isComplete }) ?? strokeResults.count
        guard activeIdx < strokeResults.count else { return currentResult(definition: definition) }

        let stroke = definition.strokes[activeIdx]
        if let updated = recognizer.evaluate(
            point: point,
            stroke: stroke,
            current: strokeResults[activeIdx],
            radius: definition.checkpointRadius
        ) {
            strokeResults[activeIdx] = updated
        }

        return currentResult(definition: definition)
    }

    /// Current match result without updating.
    var result: LetterMatchResult? {
        guard let definition else { return nil }
        return currentResult(definition: definition)
    }

    // MARK: - Private

    private func currentResult(definition: LetterStrokes) -> LetterMatchResult {
        let totalCheckpoints = definition.strokes.reduce(0) { $0 + $1.checkpoints.count }
        let hitCheckpoints = strokeResults.enumerated().reduce(0) { acc, item in
            let (idx, result) = item
            if result.isComplete { return acc + definition.strokes[idx].checkpoints.count }
            return acc + result.nextCheckpointIndex
        }

        let overall: CGFloat = totalCheckpoints > 0
            ? CGFloat(hitCheckpoints) / CGFloat(totalCheckpoints)
            : 0

        return LetterMatchResult(
            overallAccuracy: overall,
            isLetterComplete: strokeResults.allSatisfy(\.isComplete),
            strokeResults: strokeResults
        )
    }
}
