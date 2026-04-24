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
