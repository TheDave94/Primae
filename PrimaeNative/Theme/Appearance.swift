// Appearance.swift
// PrimaeNative — Theme
//
// Maps the persisted `primaeAppearance` AppStorage string ("system" /
// "light" / "dark") onto SwiftUI's `ColorScheme?` so the host app can
// apply it via `.preferredColorScheme(...)`. The toggle UI lives in
// `SettingsView`; this is the shared resolver.
//
// **Light only for now.** The Primae color tokens were temporarily
// reverted to static light-only values because the
// `UIColor(dynamicProvider:)`-based flip tripped a Swift 6
// `MainActor` isolation trap on the SwiftUI AsyncRenderer thread
// and crashed the app on every view re-render. Until the tokens
// migrate to Asset-Catalog colorsets (proper light/dark variants
// with no closure isolation concern), we lock the app to light
// mode regardless of what the parent-area picker says — otherwise
// a "Dunkel" choice would render light tokens on iOS's dark
// background and look broken. The picker stays in Settings so
// the wiring is ready for the colorset migration.

import SwiftUI

public enum PrimaeAppearance {
    /// AppStorage key — keep in sync with SettingsView.
    public static let storageKey = "primaeAppearance"

    /// Resolve a stored string into a `.preferredColorScheme(...)`
    /// argument. While the design tokens are light-only, this
    /// always returns `.light` so the canvas semantics
    /// (`canvasGhost` blue, `canvasInkStroke` green, paper white)
    /// stay legible regardless of the user's iOS setting or the
    /// in-app override.
    public static func resolve(_ stored: String) -> ColorScheme? {
        // TODO(Primae): once Colors.swift uses Asset-Catalog
        // colorsets with light/dark variants, restore the
        // original switch:
        //   case "light": return .light
        //   case "dark":  return .dark
        //   default:      return nil
        _ = stored
        return .light
    }
}
