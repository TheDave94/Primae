// Radii.swift
// BuchstabenNative — Theme
//
// Primae corner-radius scale, mirroring the `--r-*` CSS vars in
// `design-system/colors_and_type.css`. Friendly but not toy-round.

import CoreGraphics

enum Radii {
    /// 8 px — tooltip / inline label.
    static let sm: CGFloat = 8
    /// 14 px — chip / small card.
    static let md: CGFloat = 14
    /// 20 px — primary card.
    static let lg: CGFloat = 20
    /// 28 px — large card / canvas frame.
    static let xl: CGFloat = 28
    /// 40 px — bottom-sheet / parent-area panel.
    static let xxl: CGFloat = 40
    /// Full pill for buttons + chips. SwiftUI uses an explicit
    /// pill shape via `.clipShape(Capsule())`; this exists as a
    /// large numeric fallback for radius-driven contexts.
    static let pill: CGFloat = 9999
}
