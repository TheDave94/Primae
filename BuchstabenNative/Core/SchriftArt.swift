import Foundation

/// The four standard German school handwriting scripts, varying by Bundesland,
/// plus the Austrian Schulschrift 1995 mandated by BMBWF RS 35/2022.
public enum SchriftArt: String, Codable, CaseIterable {
    case druckschrift
    case schulschrift1995
    case grundschrift
    case vereinfachteAusgangschrift
    case schulausgangsschrift

    /// OTF resource filename (without extension) for this script.
    public var fontFileName: String {
        switch self {
        case .druckschrift:              return "Primae-Regular"
        // Pesendorfer 2020 OpenType version — place Schulschrift1995-Regular.otf in
        // Resources/Fonts/ after obtaining the educational-use licence from BMBWF/Pesendorfer.
        case .schulschrift1995:          return "Schulschrift1995-Regular"
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
