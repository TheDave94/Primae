import CoreGraphics

/// Primary-school ruling rendered behind each letter cell. Pencil mode
/// uses `.fourLine` (Oberlinie/Mittellinie/Grundlinie/Unterlinie); finger
/// mode leaves the cell clean so today's look is preserved.
enum LineaturStyle: Equatable {
    case none
    case simple
    case fourLine
}

/// Geometry preset selected by the detected input mode (finger vs pencil).
/// The preset decides how many cells fit in the canvas and how much
/// padding/spacing surrounds them — it never decides *what* is traced;
/// that's the `TracingSequence`'s job.
///
/// A length-1 sequence rendered with `.finger` reproduces today's
/// single-letter canvas exactly — this is the migration-neutral contract.
struct InputPreset: Equatable {
    enum Kind: String, Equatable {
        case finger
        case pencil
    }

    let kind: Kind
    let cellCount: Int
    let cellSpacing: CGFloat
    let lineaturStyle: LineaturStyle
    let horizontalInset: CGFloat

    static let finger = InputPreset(
        kind: .finger,
        cellCount: 1,
        cellSpacing: 12,
        lineaturStyle: .none,
        horizontalInset: 0
    )

    static let pencil = InputPreset(
        kind: .pencil,
        cellCount: 4,
        cellSpacing: 6,
        lineaturStyle: .fourLine,
        horizontalInset: 8
    )

    /// Expand `cellCount` to fit a sequence that's longer than the preset's
    /// default. A 4-letter word in finger mode still renders 4 cells — the
    /// preset just contributes spacing/lineatur defaults. A shorter-or-equal
    /// sequence returns the preset unchanged.
    func resolved(forSequenceLength length: Int) -> InputPreset {
        let adjusted = max(cellCount, max(1, length))
        guard adjusted != cellCount else { return self }
        return InputPreset(
            kind: kind,
            cellCount: adjusted,
            cellSpacing: cellSpacing,
            lineaturStyle: lineaturStyle,
            horizontalInset: horizontalInset
        )
    }
}
