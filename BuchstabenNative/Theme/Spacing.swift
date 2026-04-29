// Spacing.swift
// BuchstabenNative — Theme
//
// Primae spacing scale, mirroring the `--sp-*` CSS vars in
// `design-system/colors_and_type.css`. 4 px base, 8 px primary
// rhythm.

import CoreGraphics

enum Spacing {
    /// 4 px — fine-tuning gap (icon/label nudges).
    static let sp1: CGFloat = 4
    /// 8 px — primary rhythm unit (default chip padding, list inset).
    static let sp2: CGFloat = 8
    /// 12 px — between-row gap inside a card.
    static let sp3: CGFloat = 12
    /// 16 px — card padding, button vertical padding.
    static let sp4: CGFloat = 16
    /// 24 px — section gap, card-to-card gap.
    static let sp5: CGFloat = 24
    /// 32 px — page horizontal padding (iPad).
    static let sp6: CGFloat = 32
    /// 48 px — major section break.
    static let sp7: CGFloat = 48
    /// 64 px — hero band height.
    static let sp8: CGFloat = 64
    /// 96 px — full hero / world-rail width.
    static let sp9: CGFloat = 96
}
