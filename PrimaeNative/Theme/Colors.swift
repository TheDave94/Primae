// Colors.swift
// PrimaeNative — Theme
//
// Primae design tokens, mirroring the hexes from
// `design-system/colors_and_type.css`.
//
// **Light only for now.** The previous revision used
// `UIColor(dynamicProvider:)` to flip light/dark per trait
// collection. Under Swift 6 `.defaultIsolation(MainActor.self)`
// the closure inherits MainActor isolation, but UIKit / SwiftUI
// can sample a dynamic provider from `com.apple.SwiftUI.AsyncRenderer`
// (a non-main thread); the runtime traps with `EXC_BREAKPOINT` and
// the app hangs as the renderer dies under the main thread.
//
// Holding pattern: every token is a static `Color(red:green:blue:)`
// constructed from the light hex. Dark mode regresses to "light
// tokens on iOS dark background" — visibly less polished but
// stable. Proper dark-mode flip goes through Asset-Catalog
// colorsets in a follow-up commit (each colorset has explicit
// light + dark variants, no closure-isolation concerns).

import SwiftUI

// MARK: - Hex initializer

extension Color {
    /// Construct a SwiftUI Color from a 0xRRGGBB integer. Pure
    /// arithmetic — safe to call from any thread, no UIColor
    /// dynamic-provider involvement.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Surface tokens (paper / ink)

extension Color {
    static let paper      = Color(hex: 0xFFFFFF)
    static let paperDeep  = Color(hex: 0xF8FAFC)
    static let paperEdge  = Color(hex: 0xE2E8F0)

    static let ink        = Color(hex: 0x0F172A)
    static let inkSoft    = Color(hex: 0x475569)
    static let inkFaint   = Color(hex: 0x94A3B8)
    static let inkGhost   = Color(hex: 0xCBD5E1)
}

// MARK: - Canvas semantics

extension Color {
    /// Writing canvas surface — slightly off the main paper so child
    /// ink + ghost stroke pop.
    static let canvasPaper       = Color(hex: 0xF8FAFC)
    /// Reference / ghost stroke — blue-600.
    static let canvasGhost       = Color(hex: 0x2563EB)
    /// Soft variant of the ghost (35 % alpha) for trail / aura uses.
    static let canvasGhostSoft   = Color(hex: 0x2563EB, alpha: 0.35)
    /// Child ink — emerald-500.
    static let canvasInkStroke   = Color(hex: 0x10B981)
    /// Committed/finalised stroke (slightly deeper).
    static let canvasInkStrokeDeep = Color(hex: 0x059669)
    /// Observe-phase guide dot — amber-500.
    static let canvasGuide       = Color(hex: 0xF59E0B)
    static let canvasGuideSoft   = Color(hex: 0xF59E0B, alpha: 0.20)
    /// Numbered start dot — slate-900.
    static let canvasStartDot    = Color(hex: 0x0F172A)
}

// MARK: - Brand

extension Color {
    static let brand      = Color(hex: 0x2563EB)
    static let brandDeep  = Color(hex: 0x1D4ED8)
    static let brandSoft  = Color(hex: 0xDBEAFE)
}

// MARK: - World tints

extension Color {
    static let schule          = Color(hex: 0x2563EB)
    static let schuleSoft      = Color(hex: 0xDBEAFE)
    static let werkstatt       = Color(hex: 0xF59E0B)
    static let werkstattSoft   = Color(hex: 0xFEF3C7)
    static let fortschritte    = Color(hex: 0xEC4899)
    static let fortschritteSoft = Color(hex: 0xFCE7F3)
}

// MARK: - Feedback semantics

extension Color {
    static let success      = Color(hex: 0x10B981)
    static let successSoft  = Color(hex: 0xD1FAE5)
    static let warning      = Color(hex: 0xF59E0B)
    static let warningSoft  = Color(hex: 0xFEF3C7)
    static let danger       = Color(hex: 0xEF4444)
    static let dangerSoft   = Color(hex: 0xFEE2E2)
    static let info         = Color(hex: 0x2563EB)
    static let infoSoft     = Color(hex: 0xDBEAFE)
}

// MARK: - Stars

extension Color {
    static let star      = Color(hex: 0xF59E0B)
    static let starEmpty = Color(hex: 0xE2E8F0)
}

// MARK: - Adult / parent area

extension Color {
    static let adultPaper   = Color(hex: 0xF8FAFC)
    static let adultCard    = Color(hex: 0xFFFFFF)
    static let adultInk     = Color(hex: 0x0F172A)
    static let adultInkSoft = Color(hex: 0x475569)
}
