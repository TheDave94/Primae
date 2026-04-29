// Fonts.swift
// PrimaeNative — Theme
//
// Primae type ramp + font-family helpers. Wraps the bundled
// "Primae" / "PrimaeText" / "Playwrite AT" families so call sites
// don't have to remember PostScript names. The OTF/TTF files live
// in `Resources/Fonts/` and are loaded via two paths:
//
//   1. `INFOPLIST_KEY_UIAppFonts` in the app target's build
//      settings — covers the case where a host embeds the fonts in
//      the *main* bundle.
//   2. `PrimaeFonts.registerAll()` (see FontRegistration.swift),
//      called from `PrimaeApp.init()` — registers the SPM
//      package's `Bundle.module` fonts with CoreText. This is the
//      load-bearing path because the fonts physically live inside
//      the SPM resource bundle, not the main bundle, and
//      `UIAppFonts` only searches the main bundle.
//
// Type scale mirrors the `--fz-*` CSS vars in
// `design-system/colors_and_type.css`.

import SwiftUI

// MARK: - Sizes

enum FontSize {
    /// 13 pt — caption / metadata.
    static let xs: CGFloat   = 13
    /// 15 pt — small body / dense list.
    static let sm: CGFloat   = 15
    /// 17 pt — base body / default label.
    static let base: CGFloat = 17
    /// 20 pt — emphasised body / button label.
    static let md: CGFloat   = 20
    /// 24 pt — section heading.
    static let lg: CGFloat   = 24
    /// 32 pt — page heading / world title.
    static let xl: CGFloat   = 32
    /// 44 pt — display heading.
    static let xxl: CGFloat  = 44
    /// 64 pt — hero display.
    static let xxxl: CGFloat = 64
    /// 96 pt — splash / celebrate display.
    static let xxxxl: CGFloat = 96
    /// 220 pt — the giant traceable letter on the canvas.
    static let glyph: CGFloat = 220
}

// MARK: - Family helpers

extension Font {
    /// Display family (Primae). Use for large titles, prompts, the
    /// canvas glyph, button labels. Falls back to the system font if
    /// the bundled OTF can't be located at runtime.
    ///
    /// Note: the weight argument selects a *PostScript variant*
    /// (Light / Regular / Semibold / Bold) and the returned Font is
    /// constructed directly with that PostScript name. We deliberately
    /// don't chain `.weight(weight)` — none of the bundled OTFs are
    /// variable fonts, and asking SwiftUI to nudge the weight axis on
    /// a non-variable custom font triggers a SwiftUI bug-report log
    /// ("Unable to update Font Descriptor's weight to Weight(value:
    /// 0.0)") on every render.
    static func display(_ size: CGFloat,
                        weight: Font.Weight = .bold) -> Font {
        Font.custom(primaePostScriptName(for: weight, italic: false), size: size)
    }

    /// Display-cursive (Primae italic) — the cursive-axis variant of
    /// the display family. Reserved for marketing / signature
    /// flourishes; the in-app cursive specimen uses Playwrite AT.
    static func displayCursive(_ size: CGFloat,
                               weight: Font.Weight = .regular) -> Font {
        Font.custom(primaePostScriptName(for: weight, italic: true), size: size)
    }

    /// Body / text family (PrimaeText) — companion text-grade weight
    /// of Primae, optimised for smaller sizes and longer prose.
    static func body(_ size: CGFloat,
                     weight: Font.Weight = .regular) -> Font {
        Font.custom(primaeTextPostScriptName(for: weight, italic: false), size: size)
    }

    /// Austrian school cursive (Playwrite AT) — the *real* cursive
    /// specimen used wherever the app would render Schreibschrift.
    /// Only one weight is bundled.
    static func cursive(_ size: CGFloat) -> Font {
        Font.custom("PlaywriteAT-Regular", size: size)
    }
}

// MARK: - Private — PostScript-name resolution

/// Map a SwiftUI `Font.Weight` to the bundled Primae PostScript name.
/// Falls back to the closest available weight (Light / Regular /
/// Semibold / Bold + Semilight). Italic axis uses the *Cursive*
/// member of the family — the OTFs are named e.g. "Primae-Cursive"
/// for regular-italic.
private func primaePostScriptName(for weight: Font.Weight, italic: Bool) -> String {
    let stem = "Primae"
    let cursive = italic ? "Cursive" : ""
    return weightSuffix(for: weight, stem: stem, cursiveSuffix: cursive)
}

/// Same as above, but for the text-grade companion family.
private func primaeTextPostScriptName(for weight: Font.Weight, italic: Bool) -> String {
    let stem = "PrimaeText"
    let cursive = italic ? "Cursive" : ""
    return weightSuffix(for: weight, stem: stem, cursiveSuffix: cursive)
}

/// PostScript-name builder shared by the two Primae families. The
/// font files are named e.g. `Primae-Light.otf`, `Primae-Cursive.otf`
/// (regular cursive, no weight prefix), `PrimaeText-SemiboldCursive.otf`.
private func weightSuffix(for weight: Font.Weight, stem: String, cursiveSuffix: String) -> String {
    // Map SwiftUI weights onto the five PostScript weights present in
    // the bundle. There's no Medium / Heavy / Black face; round to the
    // nearest available.
    let weightToken: String
    switch weight {
    case .ultraLight, .thin, .light:
        weightToken = "Light"
    case .regular, .medium:
        weightToken = cursiveSuffix.isEmpty ? "Regular" : ""  // "Primae-Cursive"
    case .semibold:
        weightToken = "Semibold"
    case .bold, .heavy, .black:
        weightToken = "Bold"
    default:
        weightToken = "Regular"
    }
    let combined = weightToken + cursiveSuffix
    if combined.isEmpty { return "\(stem)-Regular" }
    return "\(stem)-\(combined)"
}
