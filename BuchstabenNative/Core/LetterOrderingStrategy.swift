import Foundation

/// Configurable letter ordering strategies used in teaching practice.
/// Motor similarity grouping (Berninger et al., 2006) teaches letters with
/// similar stroke patterns together; word-building lets children form words early.
enum LetterOrderingStrategy: String, Codable, CaseIterable {
    case motorSimilarity
    case wordBuilding
    case alphabetical

    var displayName: String {
        switch self {
        case .motorSimilarity: return "Motorisch ähnlich"
        case .wordBuilding:    return "Wortbildend"
        case .alphabetical:    return "Alphabetisch"
        }
    }

    func orderedLetters() -> [String] {
        switch self {
        case .motorSimilarity:
            return ["I","L","T","F","E","H","A","K","M","N","V","W","X","Y","Z",
                    "C","O","G","Q","S","U","J","B","D","P","R"]
        case .wordBuilding:
            return ["M","A","L","E","I","O","S","R","N","T","D","U","H","G","K",
                    "W","B","P","F","J","V","C","Q","X","Y","Z"]
        case .alphabetical:
            return (Unicode.Scalar("A").value...Unicode.Scalar("Z").value)
                .compactMap { Unicode.Scalar($0) }
                .map { String($0) }
        }
    }
}
