import CoreGraphics

/// One slot in the `SequenceGridController`'s grid: owns its own
/// `StrokeTracker`, ink path, direct-phase tap set, and audio index so
/// per-cell state never leaks across cell transitions. Reference type
/// (class) so the controller and the VM can share the same cell instance.
///
/// Today's single-letter flow maps to a single `LetterCell` whose frame
/// covers the whole canvas — the migration-neutral contract.
@Observable
final class LetterCell: Identifiable {
    enum State: Equatable {
        case pending
        case active
        case completed
    }

    let id: Int
    let item: SequenceItem
    var frame: CGRect
    var state: State
    let tracker: StrokeTracker
    var activePath: [CGPoint]
    var freeWritePath: [CGPoint]
    var directTappedDots: Set<Int>
    var audioIndex: Int
    var didCommit: Bool

    init(index: Int, item: SequenceItem) {
        self.id = index
        self.item = item
        self.frame = .zero
        self.state = index == 0 ? .active : .pending
        self.tracker = StrokeTracker()
        self.activePath = []
        self.freeWritePath = []
        self.directTappedDots = []
        self.audioIndex = 0
        self.didCommit = false
    }
}
