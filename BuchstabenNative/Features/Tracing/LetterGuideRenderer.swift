import SwiftUI
import CoreGraphics

/// SwiftUI rendering wrapper around `LetterGuideGeometry`.
/// All path math lives in `LetterGuideGeometry` (CoreGraphics only, no SwiftUI).
struct LetterGuideRenderer {
    /// Returns a SwiftUI `Path` for the given letter scaled to `rect`.
    /// Pass `glyphRect` (from `PrimaeLetterRenderer.normalizedGlyphRect`) to align
    /// the ghost with the dynamically rendered letter instead of the calibration PBM.
    static func guidePath(for letter: String, in rect: CGRect,
                           glyphRect: CGRect? = nil) -> Path? {
        guard rect.width > 0 && rect.height > 0 else { return nil }
        guard let cgPath = LetterGuideGeometry.cgPath(for: letter, in: rect,
                                                       glyphRect: glyphRect) else {
            return nil
        }
        return Path(cgPath)
    }
}
