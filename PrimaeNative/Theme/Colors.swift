// Colors.swift
// PrimaeNative — Theme
//
// Primae design tokens. Each named color resolves through the
// **Asset Catalog** at
// `Primae/Primae/Assets.xcassets/Colors/<name>.colorset/`, where
// every colorset declares an explicit light + dark variant.
//
// Why this shape (not `UIColor(dynamicProvider:)`):
//   - Asset-Catalog colors are compiled into the host app's `.car`
//     and resolved by UIKit/SwiftUI directly from the trait
//     collection — no Swift closure runs at render time, so there
//     is no chance of tripping a Swift 6 `MainActor` isolation
//     trap on `com.apple.SwiftUI.AsyncRenderer`. The earlier
//     dynamic-provider path crashed the app on every view re-render
//     (commit `52c50de` reverted it to a static light-only set as
//     a holding pattern; this restores dark mode safely).
//   - Hexes stay in sync with `design-system/colors_and_type.css`
//     via `scripts/gen_colorsets.py` (re-run when the design
//     system updates).
//
// Bundle: assets live in the host app's Asset Catalog, so the
// lookup uses `Color("name")` (default `.main` bundle). When the
// SPM target runs in the host app process, `.main` is the host
// app — perfect. SwiftUI Previews from inside the SPM (without a
// host) won't find these; that's an acceptable trade-off.
//
// Bundled hex values are still available via `Color(hex:)` for
// one-off cases that don't need dark-mode adaptation.

import SwiftUI

// MARK: - Hex initializer (one-off, non-asset use)

extension Color {
    /// Construct a SwiftUI Color from a 0xRRGGBB integer.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Asset-backed token helper

private extension Color {
    /// Convenience wrapper around `Color(name:)` so token call sites
    /// stay readable. Asset name is the lowerCamelCase token name —
    /// matches the colorset folder under
    /// `Assets.xcassets/Colors/<name>.colorset/`.
    static func asset(_ name: String) -> Color {
        Color(name)
    }
}

// MARK: - Surface tokens (paper / ink)

extension Color {
    static let paper      = Color.asset("paper")
    static let paperDeep  = Color.asset("paperDeep")
    static let paperEdge  = Color.asset("paperEdge")

    static let ink        = Color.asset("ink")
    static let inkSoft    = Color.asset("inkSoft")
    static let inkFaint   = Color.asset("inkFaint")
    static let inkGhost   = Color.asset("inkGhost")
}

// MARK: - Canvas semantics

extension Color {
    /// Writing canvas surface — slightly off the main paper so child
    /// ink + ghost stroke pop.
    static let canvasPaper       = Color.asset("canvasPaper")
    /// Reference / ghost stroke — blue-600 light, blue-400 dark.
    static let canvasGhost       = Color.asset("canvasGhost")
    /// Soft variant of the ghost (35 % alpha) for trail / aura uses.
    static let canvasGhostSoft   = Color.asset("canvasGhostSoft")
    /// Child ink — emerald-500 light, emerald-400 dark.
    static let canvasInkStroke   = Color.asset("canvasInkStroke")
    /// Committed/finalised stroke (slightly deeper).
    static let canvasInkStrokeDeep = Color.asset("canvasInkStrokeDeep")
    /// Observe-phase guide dot — amber-500 light, amber-400 dark.
    static let canvasGuide       = Color.asset("canvasGuide")
    static let canvasGuideSoft   = Color.asset("canvasGuideSoft")
    /// Numbered start dot — slate-900 light, near-white dark.
    static let canvasStartDot    = Color.asset("canvasStartDot")
}

// MARK: - Brand

extension Color {
    static let brand      = Color.asset("brand")
    static let brandDeep  = Color.asset("brandDeep")
    static let brandSoft  = Color.asset("brandSoft")
}

// MARK: - World tints

extension Color {
    static let schule          = Color.asset("schule")
    static let schuleSoft      = Color.asset("schuleSoft")
    static let werkstatt       = Color.asset("werkstatt")
    static let werkstattSoft   = Color.asset("werkstattSoft")
    static let fortschritte    = Color.asset("fortschritte")
    static let fortschritteSoft = Color.asset("fortschritteSoft")
}

// MARK: - Feedback semantics

extension Color {
    static let success      = Color.asset("success")
    static let successSoft  = Color.asset("successSoft")
    static let warning      = Color.asset("warning")
    static let warningSoft  = Color.asset("warningSoft")
    static let danger       = Color.asset("danger")
    static let dangerSoft   = Color.asset("dangerSoft")
    static let info         = Color.asset("info")
    static let infoSoft     = Color.asset("infoSoft")
}

// MARK: - Stars

extension Color {
    static let star      = Color.asset("star")
    static let starEmpty = Color.asset("starEmpty")
}

// MARK: - Adult / parent area

extension Color {
    static let adultPaper   = Color.asset("adultPaper")
    static let adultCard    = Color.asset("adultCard")
    static let adultInk     = Color.asset("adultInk")
    static let adultInkSoft = Color.asset("adultInkSoft")
}
