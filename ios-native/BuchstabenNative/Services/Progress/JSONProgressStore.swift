import Foundation

// MARK: - ProgressStoring

protocol ProgressStoring {
func recordCompletion(for letter: String, accuracy: Double)
var completedLettersCount: Int { get }
/// Records whether this completion was at `.precise` tier for the given letter.
/// Returns the updated consecutive-precise count for that letter (currently only "A" is tracked).
func recordPreciseCompletion(letter: String, isPrecise: Bool) -> Int
func hasUnlockedAchievement(_ id: String) -> Bool
func unlockAchievement(_ id: String)
/// Letter with the fewest attempts (un-attempted letters first, alphabetical).
func leastPracticedLetter() -> String?
}

/// Default implementations — all existing conformers remain source-compatible.
extension ProgressStoring {
var completedLettersCount: Int { 0 }
func recordPreciseCompletion(letter: String, isPrecise: Bool) -> Int { 0 }
func hasUnlockedAchievement(_ id: String) -> Bool { false }
func unlockAchievement(_ id: String) {}
func leastPracticedLetter() -> String? { nil }
}

// MARK: - Codable model

private struct LetterRecord: Codable {
var attempts: Int = 0
var totalAccuracy: Double = 0.0

var averageAccuracy: Double {
attempts > 0 ? totalAccuracy / Double(attempts) : 0.0
}
mutating func record(accuracy: Double) { attempts += 1; totalAccuracy += accuracy }
}

private struct PersistentData: Codable {
var letters: [String: LetterRecord] = [:]
var consecutivePreciseA: Int = 0
var unlockedAchievements: Set<String> = []
}

// MARK: - JSONProgressStore

final class JSONProgressStore: ProgressStoring {

private static let alphabet: [String] =
(Unicode.Scalar("A").value...Unicode.Scalar("Z").value)
.compactMap(Unicode.Scalar.init).map(String.init)

private let defaults: UserDefaults
private let storageKey = "buchstaben.progress.v1"

init(defaults: UserDefaults = .standard) { self.defaults = defaults }

// MARK: ProgressStoring

func recordCompletion(for letter: String, accuracy: Double) {
var data = load()
data.letters[letter, default: LetterRecord()].record(accuracy: accuracy)
save(data)
}

var completedLettersCount: Int { load().letters.count }

func recordPreciseCompletion(letter: String, isPrecise: Bool) -> Int {
var data = load()
if letter == "A" {
data.consecutivePreciseA = isPrecise ? data.consecutivePreciseA + 1 : 0
}
save(data)
return data.consecutivePreciseA
}

func hasUnlockedAchievement(_ id: String) -> Bool {
load().unlockedAchievements.contains(id)
}

func unlockAchievement(_ id: String) {
var data = load(); data.unlockedAchievements.insert(id); save(data)
}

func leastPracticedLetter() -> String? {
let data = load()
// Phase 1: completely un-attempted, alphabetical
if let untouched = Self.alphabet.first(where: { data.letters[$0] == nil }) {
return untouched
}
// Phase 2: fewest attempts
return data.letters.min { $0.value.attempts < $1.value.attempts }?.key
}

// MARK: Private

private func load() -> PersistentData {
guard let raw = defaults.data(forKey: storageKey),
let data = try? JSONDecoder().decode(PersistentData.self, from: raw)
else { return PersistentData() }
return data
}

private func save(_ data: PersistentData) {
guard let raw = try? JSONEncoder().encode(data) else { return }
defaults.set(raw, forKey: storageKey)
}
}
