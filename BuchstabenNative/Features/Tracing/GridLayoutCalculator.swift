import CoreGraphics

/// Pure layout function: given a canvas size and an `InputPreset`, return
/// per-cell frames. Extracted from `SequenceGridController` so the math is
/// unit-testable in isolation and can't accidentally touch cell state.
///
/// Migration-neutral contract: with `InputPreset.finger` (cellCount=1,
/// spacing=12, inset=0), the single returned frame equals the whole canvas.
/// The existing single-letter renderer sees no coordinate change when
/// routed through the grid engine.
enum GridLayoutCalculator {
    static func cellFrames(canvasSize: CGSize, preset: InputPreset) -> [CGRect] {
        let n = max(1, preset.cellCount)
        let spacing = preset.cellSpacing
        let inset = preset.horizontalInset
        let available = canvasSize.width - 2 * inset - CGFloat(n - 1) * spacing
        let cellWidth = max(0, available / CGFloat(n))
        return (0..<n).map { i in
            CGRect(
                x: inset + CGFloat(i) * (cellWidth + spacing),
                y: 0,
                width: cellWidth,
                height: canvasSize.height
            )
        }
    }
}
