// StickerButton.swift
// PrimaeNative — Components
//
// Primary button treatment — the "sticker" pill. SwiftUI port of the
// `.btn-sticker*` styles in `design-system/ui_kits/ipad-app/styles.css`.

import SwiftUI

struct StickerButtonStyle: ButtonStyle {
    /// Fill colour. Defaults to `.brand`; pass a world tint for variants.
    var tint: Color = .brand

    /// Label colour. White pairs with all documented tints.
    var labelColor: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.display(FontSize.base, weight: .bold))
            .foregroundStyle(labelColor)
            .padding(.vertical, 14)
            .padding(.horizontal, 24)
            .background(tint, in: Capsule(style: .continuous))
            .compositingGroup()
            // Two-layer shadow: coloured halo (tint @ 25 %) + ink drop.
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
