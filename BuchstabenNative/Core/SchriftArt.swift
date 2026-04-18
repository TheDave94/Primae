import Foundation

/// The four standard German school handwriting scripts, varying by Bundesland.
public enum SchriftArt: String, Codable, CaseIterable {
    case druckschrift
    case grundschrift
    case vereinfachteAusgangschrift
    case schulausgangsschrift

    /// OTF resource filename (without extension) for this script.
    public var fontFileName: String {
        switch self {
        case .druckschrift:              return "Primae-Regular"
        case .grundschrift:              return "Grundschrift-Regular"
        case .vereinfachteAusgangschrift: return "VereinfachteAusgangschrift-Regular"
        case .schulausgangsschrift:      return "Schulausgangsschrift-Regular"
        }
    }

    /// German display label shown in the UI.
    public var displayName: String {
        switch self {
        case .druckschrift:              return "Druckschrift"
        case .grundschrift:              return "Grundschrift"
        case .vereinfachteAusgangschrift: return "Vereinfachte Ausgangsschrift"
        case .schulausgangsschrift:      return "Schulausgangsschrift"
        }
    }
}
