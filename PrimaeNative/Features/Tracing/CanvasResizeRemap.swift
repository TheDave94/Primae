// CanvasResizeRemap.swift
// PrimaeNative
//
// Where a canvas-space point drawn before a canvas resize belongs after it.
//
// Ink (`activePath`, `lingeringInk`, the freeWrite recorder's points) is
// stored in canvas POINTS. The study build is landscape-only and full
// screen, but if an iPadOS ignores the deprecated UIRequiresFullScreen the
// scene can be resized or rotated mid-letter (defence in depth;
// docs/DECISIONS.md, "Rotation and UIRequiresFullScreen"), and the letter is re-laid-out for the
// new canvas. Without a remap the child's ink stays where it was while the
// letter moves and changes size under it, and the freeWrite score compares
// old-frame points against the new canvas size.
//
// The letter is placed by `PrimaeLetterRenderer.glyphFit`: one uniform
// scale, centred horizontally. So the map from the old glyph rect to the
// new one is a similarity (uniform scale + translation): the ink keeps its
// shape and its place ON THE LETTER. A pure value, so the decision is
// testable without a canvas (the `CanvasDrawPlan` pattern).

import CoreGraphics

struct CanvasResizeRemap: Equatable {
    /// p' = p * scale + offset, in canvas points.
    let scale: CGFloat
    let offset: CGVector

    static let identity = CanvasResizeRemap(scale: 1, offset: .zero)

    /// The remap that carries the glyph's ink rect in the old canvas onto
    /// its rect in the new one. `oldGlyphRect` / `newGlyphRect` are
    /// canvas-normalised (`PrimaeLetterRenderer.normalizedGlyphRect`).
    /// When either rect is missing (the renderer returns nil under tests
    /// and before layout) the placement rule itself is used: the glyph
    /// scales with the canvas HEIGHT and stays centred horizontally,
    /// which is exactly `glyphFit` whenever the width does not cap it.
    /// Nil when either canvas is empty: nothing can be mapped.
    static func between(oldCanvas: CGSize, oldGlyphRect: CGRect?,
                        newCanvas: CGSize, newGlyphRect: CGRect?) -> CanvasResizeRemap? {
        guard oldCanvas.width > 0, oldCanvas.height > 0,
              newCanvas.width > 0, newCanvas.height > 0 else { return nil }
        if oldCanvas == newCanvas { return .identity }
        if let o = oldGlyphRect, let n = newGlyphRect, o.height > 0, n.height > 0 {
            let oldPx = CGRect(x: o.minX * oldCanvas.width, y: o.minY * oldCanvas.height,
                               width: o.width * oldCanvas.width, height: o.height * oldCanvas.height)
            let newPx = CGRect(x: n.minX * newCanvas.width, y: n.minY * newCanvas.height,
                               width: n.width * newCanvas.width, height: n.height * newCanvas.height)
            // Height ratio: the glyph scale is uniform, so it equals the
            // width ratio up to rounding; height is never zero for a glyph.
            let s = newPx.height / oldPx.height
            return CanvasResizeRemap(scale: s,
                                     offset: CGVector(dx: newPx.minX - oldPx.minX * s,
                                                      dy: newPx.minY - oldPx.minY * s))
        }
        let s = newCanvas.height / oldCanvas.height
        return CanvasResizeRemap(scale: s,
                                 offset: CGVector(dx: newCanvas.width / 2 - oldCanvas.width / 2 * s,
                                                  dy: 0))
    }

    func apply(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * scale + offset.dx, y: p.y * scale + offset.dy)
    }

    func apply(_ points: [CGPoint]) -> [CGPoint] {
        self == .identity ? points : points.map(apply)
    }
}
