import Foundation

// MARK: - Domain model

/// Persisted stats for a single letter.
struct LetterProgress: Codable, Equatable {
    var completionCount: Int = 0
    var bestAccuracy: Double = 0.0   // 0.0 – 1.0
    var lastCompletedAt: Date?
}

// MARK: - Protocol (testable seam)

protocol ProgressStoring {
    func progress(for letter: String) -> LetterProgress
    func recordCompletion(for letter: String, accuracy: Double)
    func resetAll()
    var allProgress: [String: LetterProgress] { get }
    /// Current streak: consecutive days with at least one completion.
    var currentStreakDays: Int { get }
    /// Total letters completed across all sessions.
    var totalCompletions: Int { get }
}

// MARK: - JSON-backed implementation

/// Lightweight JSON progress store backed by a file in the app's
/// Application Support directory. No SwiftData / CoreData dependency —
/// keeps CI fully on Linux-compatible Swift and avoids schema migrations.
public final class JSONProgressStore: ProgressStoring {

    // MARK: Storage

    private let fileURL: URL
    private var store: Store

    private struct Store: Codable {
        var letterProgress: [String: LetterProgress] = [:]
        var completionDates: [Date] = []   // one entry per completion event
    }

    // MARK: Init

    init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let dir = support.appendingPathComponent("BuchstabenNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("progress.json")
        }
        self.store = Self.load(from: self.fileURL)
    }

    // MARK: ProgressStoring

    func progress(for letter: String) -> LetterProgress {
        store.letterProgress[letter.uppercased()] ?? LetterProgress()
    }

    func recordCompletion(for letter: String, accuracy: Double) {
        let key = letter.uppercased()
        var p = store.letterProgress[key] ?? LetterProgress()
        p.completionCount += 1
        p.bestAccuracy = max(p.bestAccuracy, min(1.0, max(0.0, accuracy)))
        p.lastCompletedAt = Date()
        store.letterProgress[key] = p
        store.completionDates.append(Date())
        save()
    }

    func resetAll() {
        store = Store()
        save()
    }

    var allProgress: [String: LetterProgress] {
        store.letterProgress
    }

    var currentStreakDays: Int {
        guard !store.completionDates.isEmpty else { return 0 }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let uniqueDays = Set(store.completionDates.map { cal.startOfDay(for: $0) })
        var streak = 0
        var cursor = today
        while uniqueDays.contains(cursor) {
            streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        // If nothing today, also check if yesterday completed (streak didn't reset yet)
        if streak == 0, let yesterday = cal.date(byAdding: .day, value: -1, to: today) {
            var c = yesterday
            while uniqueDays.contains(c) {
                streak += 1
                guard let prev = cal.date(byAdding: .day, value: -1, to: c) else { break }
                c = prev
            }
        }
        return streak
    }

    var totalCompletions: Int {
        store.letterProgress.values.reduce(0) { $0 + $1.completionCount }
    }

    // MARK: Persistence

    private static func load(from url: URL) -> Store {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Store.self, from: data)
        else { return Store() }
        return decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
