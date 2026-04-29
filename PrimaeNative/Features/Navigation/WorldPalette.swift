// WorldPalette.swift
// PrimaeNative
//
// World tints + chrome surface tokens. Both forward into the Primae
// design system (`PrimaeNative/Theme/Colors.swift`), so values flip
// automatically between light and dark mode and stay in sync with the
// design-system spec.

import SwiftUI

enum WorldPalette {

    /// Per-world soft background tint. The Primae spec says world hero
    /// screens get a single soft tinted band over the paper canvas, not
    /// a full gradient. We keep the LinearGradient signature so existing
    /// call sites don't have to change their `.background(...)` modifier.
    static func background(for world: AppWorld) -> LinearGradient {
        let soft = softTint(for: world)
        return LinearGradient(
            colors: [soft, Color.paperDeep],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    /// Primary accent colour for the world — used on rail icons, phase
    /// dots, sticker buttons, and any active-state chrome.
    static func accent(for world: AppWorld) -> Color {
        switch world {
        case .schule:       return .schule
        case .werkstatt:    return .werkstatt
        case .fortschritte: return .fortschritte
        }
    }

    /// Soft variant of the world tint — used as the start of the hero-
    /// band gradient and as the inactive background of rail buttons.
    static func softTint(for world: AppWorld) -> Color {
        switch world {
        case .schule:       return .schuleSoft
        case .werkstatt:    return .werkstattSoft
        case .fortschritte: return .fortschritteSoft
        }
    }
}

// MARK: - Shared surface tokens
//
// Backwards-compatible namespace pointing at the Primae design tokens.
// Existing call sites read these as `AppSurface.card`, `.prompt`, etc.;
// the values now auto-resolve light/dark via the underlying Color.*
// dynamic providers.
enum AppSurface {
    /// Card / pill body colour. Bright surface that floats over the
    /// `--paper-deep` page.
    static let card     = Color.paper
    /// Hairline border around `card` so it doesn't disappear when set
    /// against the same-luminance paper canvas.
    static let cardEdge = Color.paperEdge
    /// Subdued body label colour — replaces `.secondary` on top of
    /// pastel/paper backgrounds where the system grey washes out.
    static let prompt   = Color.ink
    /// Caption-weight label colour — slightly lighter than `prompt`
    /// for hierarchy.
    static let caption  = Color.inkSoft
    /// Mastered-letter tile fill — soft pastel green used in the
    /// FortschritteWorldView gallery and the LetterPickerBar so a
    /// "fully completed" letter looks identical wherever it appears.
    /// Routes through `--success-soft` (emerald-50 / emerald-900).
    static let mastered = Color.successSoft
    /// Foreground colour to pair with `mastered` for letter glyphs.
    /// Saturated success green that reads against the pastel fill.
    static let masteredText = Color.success
    /// Background colour pair for `WorldSwitcherRail`. The rail sits
    /// over the page paper; we use the slightly recessed `paperDeep`
    /// for both stops so the gradient renders as a flat band — paper,
    /// not glass.
    static let railTop    = Color.paper
    static let railBottom = Color.paperDeep
    /// U9 (ROADMAP_V5): unified gold/star tint. Routes through `--star`
    /// in the design system (amber-500 light / amber-400 dark).
    static let starGold = Color.star
}
