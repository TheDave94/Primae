import Foundation

/// The four standard German school handwriting scripts, varying by Bundesland,
/// plus the Austrian Schulschrift 1995 mandated by BMBWF RS 35/2022.
public enum SchriftArt: String, Codable, CaseIterable {
    case druckschrift
    case schulschrift1995
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
        // variable TTF mirrored in BuchstabenNative/Resources/Fonts/ as
        // PlaywriteAT-Regular.ttf. It implements the Austrian primary-school
        // cursive model that corresponds to Schulschrift 1995.
        case .schulschrift1995:          return "PlaywriteAT-Regular"
        case .grundschrift:              return "Grundschrift-Regular"
        case .vereinfachteAusgangschrift: return "VereinfachteAusgangschrift-Regular"
        case .schulausgangsschrift:      return "Schulausgangsschrift-Regular"
        }
    }

    /// German display label shown in the UI.
    public var displayName: String {
        switch self {
        case .druckschrift:              return "Druckschrift"
        case .schulschrift1995:          return "Österreichische Schulschrift 1995"
        case .grundschrift:              return "Grundschrift"
        case .vereinfachteAusgangschrift: return "Vereinfachte Ausgangsschrift"
        case .schulausgangsschrift:      return "Schulausgangsschrift"
        }
    }
}
