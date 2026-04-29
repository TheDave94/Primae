// StickerButton.swift
// BuchstabenNative — Components
//
// Primae's primary button treatment — the "sticker" pill. Idiomatic
// SwiftUI port of the `.btn-sticker*` styles from
// `design-system/ui_kits/ipad-app/styles.css`:
//
//   - Pill capsule, 14 pt vertical / 24 pt horizontal padding.
//   - White label, brand fill (or per-world tint via the `tint`
//     parameter).
//   - Soft elevated shadow that uses the tint colour at low alpha
//     plus a small ink drop. Collapses to a near-flush press shadow
//     on press; the button also nudges 1 pt down via translate.
//
// Usage:
//
//   Button("Weiter") { … }
//       .buttonStyle(StickerButtonStyle())          // brand
//       .buttonStyle(StickerButtonStyle(tint: .schule))
//
// Tint takes a SwiftUI `Color`; pass any of the world-tint tokens or
// the brand. The shadow tint follows `tint`.

import SwiftUI

struct StickerButtonStyle: ButtonStyle {
    /// Fill colour. Defaults to `.brand`. Pass `.schule`,
    /// `.werkstatt`, `.fortschritte` for world-tinted variants.
    var tint: Color = .brand

    /// Label colour. Defaults to white because all four documented
    /// tints (brand blue, world blue, amber, pink) carry white labels
    /// at the contrast level the design system specifies.
    var labelColor: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.display(FontSize.base, weight: .bold))
            .foregroundStyle(labelColor)
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
            .background(tint, in: Capsule(style: .continuous))
            .compositingGroup()
            // Two-layer shadow matching the CSS `.btn-sticker`:
            //   coloured halo (tint @ 25 %) + small ink drop.
            // Press collapses both to a flush near-shadow.
            .shadow(color: tint.opacity(configuration.isPressed ? 0.0 : 0.25),
                    radius: configuration.isPressed ? 0 : 6,
                    x: 0,
                    y: configuration.isPressed ? 0 : 4)
            .shadow(color: Color.black.opacity(configuration.isPressed ? 0.06 : 0.10),
                    radius: configuration.isPressed ? 1 : 3,
                    x: 0,
                    y: configuration.isPressed ? 1 : 2)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .offset(y: configuration.isPressed ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule(style: .continuous))
    }
}
