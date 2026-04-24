// FreeformWordList.swift
// BuchstabenNative
//
// Curated word list for the freeform "Wort schreiben" sub-mode. Words
// are short, concrete, and familiar to Austrian 1st-graders (Volksschule
// Woche 1–2 vocabulary). Ordered by increasing difficulty — longer
// words and less-common letters come later.

import Foundation

/// A target word offered by the freeform word-writing mode.
struct FreeformWord: Codable, Equatable, Sendable, Hashable {
    /// The word itself, in uppercase.
    let word: String
    /// Integer difficulty: 1 = easy (3-letter names), 2 = medium, 3 = hard.
    let difficulty: Int
}

/// Static catalogue of supported freeform target words. Keep the list
/// short and child-friendly — 10–15 entries is the thesis sweet spot.
enum FreeformWordList {

    /// All supported words, pre-sorted easy → hard so list UIs can
    /// iterate directly without re-sorting.
    static let all: [FreeformWord] = [
        // Easy — family names the child already says every day.
        FreeformWord(word: "MAMA", difficulty: 1),
        FreeformWord(word: "OMA",  difficulty: 1),
        FreeformWord(word: "OPA",  difficulty: 1),
        FreeformWord(word: "BALL", difficulty: 1),
        FreeformWord(word: "HAUS", difficulty: 1),
        FreeformWord(word: "HUND", difficulty: 1),
        // Medium — 5-letter nouns with common consonant clusters.
        FreeformWord(word: "KATZE",  difficulty: 2),
        FreeformWord(word: "SCHULE", difficulty: 2),
        FreeformWord(word: "APFEL",  difficulty: 2),
        FreeformWord(word: "BAUM",   difficulty: 2),
        // Hard — introduces harder digraphs and less-common letters.
        FreeformWord(word: "FREUND", difficulty: 3),
        FreeformWord(word: "BLUME",  difficulty: 3),
        FreeformWord(word: "SONNE",  difficulty: 3)
    ]

    /// Words filtered by difficulty level.
    static func words(difficulty: Int) -> [FreeformWord] {
        all.filter { $0.difficulty == difficulty }
    }
}
