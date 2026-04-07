import CoreGraphics

@MainActor
final class StrokeTracker {
    struct Progress: Sendable {
        var nextCheckpoint = 0
        var complete = false
    }

    private(set) var definition: LetterStrokes?
    private(set) var progress: [Progress] = []

    /// Scales the base `checkpointRadius` for difficulty adaptation.
    /// 1.0 = standard; >1.0 = more lenient (easy); <1.0 = stricter (hard).
    var radiusMultiplier: CGFloat = 1.0

    /// Closure called when a stroke is completed. The integer parameter is the completed stroke index.
    var onStrokeCompleted: (@MainActor (Int) -> Void)?

    var soundEnabled: Bool {
        guard let definition else { return false }
        let current = currentStrokeIndex
        guard current < definition.strokes.count else { return false }
        return progress[current].nextCheckpoint > 0
    }

    var isComplete: Bool {
        guard let definition else { return false }
        return progress.count == definition.strokes.count && progress.allSatisfy(\.complete)
    }

    var overallProgress: CGFloat {
        guard let definition else { return 0 }
        let total = definition.strokes.reduce(0) { $0 + $1.checkpoints.count }
        guard total > 0 else { return 0 }

        let done = definition.strokes.enumerated().reduce(0) { acc, item in
            let (idx, stroke) = item
            if progress[idx].complete { return acc + stroke.checkpoints.count }
            return acc + progress[idx].nextCheckpoint
        }

        return CGFloat(done) / CGFloat(total)
    }

    var currentStrokeIndex: Int {
        for idx in progress.indices where !progress[idx].complete { return idx }
        return progress.count
    }

    func load(_ strokes: LetterStrokes) {
        radiusMultiplier = 1.0
        definition = strokes
        progress = strokes.strokes.map { _ in Progress() }
        onStrokeCompleted = nil
    }

    func reset() {
        definition = nil
        progress = []
        radiusMultiplier = 1.0
        onStrokeCompleted = nil
    }
    func update(normalizedPoint p: CGPoint) {
        guard p.x.isFinite && p.y.isFinite else { return }
        guard (0...1).contains(p.x) && (0...1).contains(p.y) else { return }
        guard let definition else { return }

        let current = currentStrokeIndex
        guard current < definition.strokes.count else { return }

        let stroke = definition.strokes[current]
        let checkpointIndex = self.progress[current].nextCheckpoint
        guard checkpointIndex < stroke.checkpoints.count else { return }

        let cp = stroke.checkpoints[checkpointIndex]
        let dx = p.x - cp.x
        let dy = p.y - cp.y
        let dist = hypot(dx, dy)

        let threshold = definition.checkpointRadius * radiusMultiplier
        if dist <= threshold {
            self.progress[current].nextCheckpoint += 1
            if self.progress[current].nextCheckpoint >= stroke.checkpoints.count {
                self.progress[current].complete = true
                onStrokeCompleted?(current)
            }
        }
    }
