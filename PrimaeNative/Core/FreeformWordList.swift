// FreeformWordList.swift
// PrimaeNative
//
// Curated word list for the freeform "Wort schreiben" sub-mode. Words
// are short, concrete, and familiar to Austrian 1st-graders. Ordered
// easy → hard.

import Foundation

/// A target word offered by the freeform word-writing mode.
struct FreeformWord: Codable, Equatable, Sendable, Hashable {
    /// The word itself, in uppercase.
    let word: String
    /// Integer difficulty: 1 = easy (3-letter names), 2 = medium, 3 = hard.
    let difficulty: Int
}

/// Static catalogue of supported freeform target words.
enum FreeformWordList {

    /// All supported words, pre-sorted easy → hard.
    static let all: [FreeformWord] = [
        // Easy — family names the child already says every day.
        FreeformWord(word: "MAMA", difficulty: 1),
        FreeformWord(word: "PAPA", difficulty: 1),
        FreeformWord(word: "OMA",  difficulty: 1),
        FreeformWord(word: "OPA",  difficulty: 1),
        FreeformWord(word: "BALL", difficulty: 1),
        FreeformWord(word: "HAUS", difficulty: 1),
        FreeformWord(word: "HUND", difficulty: 1),
        FreeformWord(word: "BUCH", difficulty: 1),
        // Medium — 5-letter nouns with common consonant clusters.
        FreeformWord(word: "KATZE",  difficulty: 2),
        FreeformWord(word: "APFEL",  difficulty: 2),
        FreeformWord(word: "BAUM",   difficulty: 2),
        // Hard — 6+ letters or trigraphs (SCH).
        FreeformWord(word: "SCHULE", difficulty: 3),
        FreeformWord(word: "BLUME",  difficulty: 3),
        FreeformWord(word: "SONNE",  difficulty: 3)
    ]

    /// Words filtered by difficulty level.
    static func words(difficulty: Int) -> [FreeformWord] {
        all.filter { $0.difficulty == difficulty }
    }
}
