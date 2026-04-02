import SwiftUI
import CoreGraphics

/// SwiftUI rendering wrapper around `LetterGuideGeometry`.
/// All path math lives in `LetterGuideGeometry` (CoreGraphics only, no SwiftUI).
struct LetterGuideRenderer {
    /// Returns a SwiftUI `Path` for the given letter scaled to `rect`.
    static func guidePath(for letter: String, in rect: CGRect) -> Path? {
        guard rect.width > 0 && rect.height > 0 else { return nil }
        guard let cgPath = LetterGuideGeometry.cgPath(for: letter, in: rect) else {
            return nil
        }
        return Path(cgPath)
    }}
