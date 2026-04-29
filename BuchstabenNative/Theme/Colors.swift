// Colors.swift
// BuchstabenNative — Theme
//
// Primae design tokens — every named color resolves dynamically to
// the light or dark hex from `design-system/colors_and_type.css`.
// Dark hexes come from the `html[data-theme="dark"]` block; light
// hexes from `:root`. Stay in sync with that file.
//
// Usage:
//   Color.paper, Color.ink, Color.brand, Color.canvasGhost, …
// Or directly with hex literals via Color(hex: 0xFFFFFF).
//
// Implementation note: dynamic resolution lives at the UIColor layer
// (UIColor(dynamicProvider:) is the only API that re-evaluates per
// trait collection). The Swift `Color` extension wraps each dynamic
// UIColor so SwiftUI views can use the friendlier `Color` API.

import SwiftUI
import UIKit

// MARK: - Hex initializers

extension UIColor {
    /// Construct a UIColor from a 0xRRGGBB integer (alpha = 1.0).
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >>  8) & 0xFF) / 255.0
        let b = CGFloat( hex        & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

extension Color {
    /// Construct a SwiftUI Color from a 0xRRGGBB integer.
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(uiColor: UIColor(hex: hex, alpha: CGFloat(alpha)))
    }
}

// MARK: - Dynamic helper

private extension Color {
    /// Build a SwiftUI Color whose hex flips on light/dark trait
    /// collection. Wraps `UIColor(dynamicProvider:)`, so the same
    /// instance re-evaluates whenever the system or override
    /// `userInterfaceStyle` changes — including under SwiftUI's
    /// `.preferredColorScheme()` overrides.
    static func dynamic(light: UInt32, dark: UInt32, alpha: Double = 1.0) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(hex: dark,  alpha: CGFloat(alpha))
                : UIColor(hex: light, alpha: CGFloat(alpha))
        })
    }
}

// MARK: - Surface tokens (paper / ink)

extension Color {
    static let paper      = Color.dynamic(light: 0xFFFFFF, dark: 0x0B1220)
    static let paperDeep  = Color.dynamic(light: 0xF8FAFC, dark: 0x111827)
    static let paperEdge  = Color.dynamic(light: 0xE2E8F0, dark: 0x1F2937)

    static let ink        = Color.dynamic(light: 0x0F172A, dark: 0xF8FAFC)
    static let inkSoft    = Color.dynamic(light: 0x475569, dark: 0xCBD5E1)
    static let inkFaint   = Color.dynamic(light: 0x94A3B8, dark: 0x94A3B8)
    static let inkGhost   = Color.dynamic(light: 0xCBD5E1, dark: 0x475569)
}

// MARK: - Canvas semantics

extension Color {
    /// Writing canvas surface — slightly off the main paper so child
    /// ink + ghost stroke pop.
    static let canvasPaper       = Color.dynamic(light: 0xF8FAFC, dark: 0x111827)
    /// Reference / ghost stroke — blue-600 in light, blue-400 in dark.
    static let canvasGhost       = Color.dynamic(light: 0x2563EB, dark: 0x60A5FA)
    /// Soft variant of the ghost (35 % alpha) for trail / aura uses.
    static let canvasGhostSoft   = Color.dynamic(light: 0x2563EB, dark: 0x60A5FA, alpha: 0.35)
    /// Child ink — emerald-500 in light, emerald-400 in dark.
    static let canvasInkStroke   = Color.dynamic(light: 0x10B981, dark: 0x34D399)
    /// Committed/finalised stroke (slightly deeper).
    static let canvasInkStrokeDeep = Color.dynamic(light: 0x059669, dark: 0x10B981)
    /// Observe-phase guide dot — amber-500 in light, amber-400 in dark.
    static let canvasGuide       = Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24)
    static let canvasGuideSoft   = Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24, alpha: 0.20)
    /// Numbered start dot — slate-900 in light, near-white in dark.
    static let canvasStartDot    = Color.dynamic(light: 0x0F172A, dark: 0xF8FAFC)
}

// MARK: - Brand

extension Color {
    static let brand      = Color.dynamic(light: 0x2563EB, dark: 0x3B82F6)
    static let brandDeep  = Color.dynamic(light: 0x1D4ED8, dark: 0x2563EB)
    static let brandSoft  = Color.dynamic(light: 0xDBEAFE, dark: 0x1E3A8A)
}

// MARK: - World tints

extension Color {
    static let schule          = Color.dynamic(light: 0x2563EB, dark: 0x3B82F6)
    static let schuleSoft      = Color.dynamic(light: 0xDBEAFE, dark: 0x1E3A8A)
    static let werkstatt       = Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24)
    static let werkstattSoft   = Color.dynamic(light: 0xFEF3C7, dark: 0x78350F)
    static let fortschritte    = Color.dynamic(light: 0xEC4899, dark: 0xF472B6)
    static let fortschritteSoft = Color.dynamic(light: 0xFCE7F3, dark: 0x831843)
}

// MARK: - Feedback semantics

extension Color {
    static let success      = Color.dynamic(light: 0x10B981, dark: 0x34D399)
    static let successSoft  = Color.dynamic(light: 0xD1FAE5, dark: 0x064E3B)
    static let warning      = Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24)
    static let warningSoft  = Color.dynamic(light: 0xFEF3C7, dark: 0x78350F)
    static let danger       = Color.dynamic(light: 0xEF4444, dark: 0xF87171)
    static let dangerSoft   = Color.dynamic(light: 0xFEE2E2, dark: 0x7F1D1D)
    static let info         = Color.dynamic(light: 0x2563EB, dark: 0x60A5FA)
    static let infoSoft     = Color.dynamic(light: 0xDBEAFE, dark: 0x1E3A8A)
}

// MARK: - Stars

extension Color {
    static let star      = Color.dynamic(light: 0xF59E0B, dark: 0xFBBF24)
    static let starEmpty = Color.dynamic(light: 0xE2E8F0, dark: 0x1F2937)
}

// MARK: - Adult / parent area

extension Color {
    static let adultPaper   = Color.dynamic(light: 0xF8FAFC, dark: 0x0B1220)
    static let adultCard    = Color.dynamic(light: 0xFFFFFF, dark: 0x111827)
    static let adultInk     = Color.dynamic(light: 0x0F172A, dark: 0xF8FAFC)
    static let adultInkSoft = Color.dynamic(light: 0x475569, dark: 0xCBD5E1)
}
