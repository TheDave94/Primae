// WorldPalette.swift
// BuchstabenNative
//
// Warm, high-contrast colour palette for the redesigned UI. Each world
// owns a gradient so the child can tell the three spaces apart at a
// glance without reading labels. The writing canvas itself stays plain
// white — the CoreML recognizer was trained on white-on-black and the
// UI gives the child a clean page to write on.

import SwiftUI

enum WorldPalette {

    /// Per-world background gradient. Rendered behind the chrome so any
    /// translucent material on top (rail icon, dots capsule) picks up
    /// a hint of the world's colour.
    static func background(for world: AppWorld) -> LinearGradient {
        switch world {
        case .schule:
            return LinearGradient(
                colors: [
                    Color(red: 0.86, green: 0.94, blue: 1.00),   // soft sky
                    Color(red: 0.88, green: 0.99, blue: 0.92)    // mint
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .werkstatt:
            return LinearGradient(
                colors: [
                    Color(red: 0.95, green: 0.89, blue: 1.00),   // lavender
                    Color(red: 1.00, green: 0.88, blue: 0.94)    // rose
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .fortschritte:
            return LinearGradient(
                colors: [
                    Color(red: 1.00, green: 0.97, blue: 0.80),   // buttery yellow
                    Color(red: 1.00, green: 0.90, blue: 0.78)    // peach
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }

    /// Primary accent colour for the world — used on cards, phase dots,
    /// and any active-state chrome that wants to echo the background.
    static func accent(for world: AppWorld) -> Color {
        switch world {
        case .schule:       return Color(red: 0.22, green: 0.54, blue: 0.87)
        case .werkstatt:    return Color(red: 0.55, green: 0.30, blue: 0.85)
        case .fortschritte: return Color(red: 0.95, green: 0.55, blue: 0.10)
        }
    }
}

// MARK: - Shared surface tokens
//
// Solid colours used by the world chrome instead of `.ultraThinMaterial`.
// Materials over the white canvas + pastel world backgrounds rendered as
// light gray and crushed `.secondary` labels (see IMG_0337–0340 — the
// "Schreibe einen Buchstaben…" prompt and "Vorschläge:" row were nearly
// invisible). These tokens give every chrome element a predictable
// background so child-facing text stays legible regardless of system
// colour scheme.
enum AppSurface {
    /// Card / pill body colour. Slightly off-white so it floats over a
    /// pure-white canvas and reads as a separate surface.
    static let card     = Color(red: 0.97, green: 0.97, blue: 0.99)
    /// Hairline border around `card` so it doesn't disappear when set
    /// against the white canvas.
    static let cardEdge = Color(red: 0.78, green: 0.78, blue: 0.84)
    /// Subdued body label colour — replaces `.secondary` on top of
    /// pastel/white backgrounds where the system grey washes out.
    static let prompt   = Color(red: 0.20, green: 0.20, blue: 0.25)
    /// Caption-weight label colour — slightly lighter than `prompt`
    /// for hierarchy, still meets WCAG AA on `card`.
    static let caption  = Color(red: 0.32, green: 0.32, blue: 0.40)
    /// Mastered-letter tile fill — soft pastel green used in the
    /// FortschritteWorldView gallery and the LetterPickerBar so a
    /// "fully completed" letter looks identical wherever it appears.
    /// Hand-picked to read as success without overpowering the
    /// neighbouring tiles.
    static let mastered = Color(red: 0.82, green: 0.94, blue: 0.82)
    /// Foreground colour to pair with `mastered` for letter glyphs in
    /// the picker — saturated dark green that reads as success against
    /// the pastel fill. ≈ 4.7:1 contrast, WCAG AA pass for large bold.
    static let masteredText = Color(red: 0.10, green: 0.45, blue: 0.18)
    /// Background gradient for `WorldSwitcherRail`. Subtle warm-to-cool
    /// pastel that sits below the world buttons without competing with
    /// each world's own accent. Token-ised so a future re-skin only
    /// touches WorldPalette instead of grepping for hardcoded RGB.
    static let railTop    = Color(red: 0.99, green: 0.98, blue: 0.96)
    static let railBottom = Color(red: 0.96, green: 0.97, blue: 0.99)
    /// U9 (ROADMAP_V5): unified gold/star tint. Was previously `Color.yellow`
    /// in the celebration overlay and `Color.orange` in the gallery / picker
    /// / SchuleWorld rows; the visual mismatch made a "mastered" letter
    /// look slightly different in two places. One value per surface.
    static let starGold = Color(red: 1.00, green: 0.62, blue: 0.10)
}
