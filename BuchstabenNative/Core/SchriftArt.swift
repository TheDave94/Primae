import Foundation

/// Handwriting scripts the app can render. `druckschrift` is Primae (print)
/// and `schreibschrift` is Playwrite AT (cursive); the other three are
/// Bundesland-specific German school scripts wired up for the future but
/// not yet bundled as fonts.
public enum SchriftArt: String, Codable, CaseIterable {
    case druckschrift
    case schreibschrift
    case grundschrift
    case vereinfachteAusgangschrift
    case schulausgangsschrift

    /// Font resource filename (without extension) for this script.
    /// PrimaeLetterRenderer probes `.otf` first, then `.ttf`, so either format
    /// can be bundled under this name. Returning the stem keeps the enum
    /// extension-agnostic.
    public var fontFileName: String {
        switch self {
        case .druckschrift:              return "Primae-Regular"
        // Playwrite Österreich (TypeTogether, 2023) — SIL OFL 1.1 licensed
        // variable TTF bundled as Resources/Fonts/PlaywriteAT-Regular.ttf.
        // Implements an Austrian primary-school cursive; not an exact clone
        // of the official Schulschrift 1995, which is why the user-facing
        // label is the generic "Schreibschrift".
        case .schreibschrift:            return "PlaywriteAT-Regular"
        case .grundschrift:              return "Grundschrift-Regular"
        case .vereinfachteAusgangschrift: return "VereinfachteAusgangschrift-Regular"
        case .schulausgangsschrift:      return "Schulausgangsschrift-Regular"
        }
    }

    /// German display label shown in the UI.
    public var displayName: String {
        switch self {
        case .druckschrift:              return "Druckschrift"
        case .schreibschrift:            return "Schreibschrift"
        case .grundschrift:              return "Grundschrift"
        case .vereinfachteAusgangschrift: return "Vereinfachte Ausgangsschrift"
        case .schulausgangsschrift:      return "Schulausgangsschrift"
        }
    }

    /// The `variantID` that `LetterRepository.loadVariantStrokes` uses to
    /// find this script's stroke JSON — e.g. "schulschrift" resolves to
    /// `Letters/<letter>/strokes_schulschrift.json`. `nil` for
    /// `.druckschrift`: its strokes are the primary `strokes.json` carried
    /// by `LetterAsset.strokes`, not a variant file.
    ///
    /// Adding a new script is a three-step move: add an enum case, return
    /// the variantID here, and ship `Resources/Letters/<letter>/strokes_<id>.json`
    /// alongside the font. `TracingViewModel.activeScriptStrokes` picks it
    /// up automatically — no VM changes required.
    public var bundleVariantID: String? {
        switch self {
        case .druckschrift:              return nil
        case .schreibschrift:            return "schulschrift"
        case .grundschrift:              return "grundschrift"
        case .vereinfachteAusgangschrift: return "vereinfachteAusgangschrift"
        case .schulausgangsschrift:      return "schulausgangsschrift"
        }
    }
}
