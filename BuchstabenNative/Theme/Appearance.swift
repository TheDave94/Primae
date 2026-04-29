// Appearance.swift
// BuchstabenNative — Theme
//
// Maps the persisted `primaeAppearance` AppStorage string ("system" /
// "light" / "dark") onto SwiftUI's `ColorScheme?` so the host app can
// apply it via `.preferredColorScheme(...)`. The toggle UI lives in
// `SettingsView`; this is the shared resolver.

import SwiftUI

public enum PrimaeAppearance {
    /// AppStorage key — keep in sync with SettingsView.
    public static let storageKey = "primaeAppearance"

    /// Resolve a stored string into a `.preferredColorScheme(...)`
    /// argument. `nil` means "follow the system" (the default).
    public static func resolve(_ stored: String) -> ColorScheme? {
        switch stored {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil  // "system" / unknown → follow iOS
        }
    }
}
