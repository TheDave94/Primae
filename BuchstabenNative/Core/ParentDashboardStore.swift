import Foundation

// MARK: - Data models

struct LetterAccuracyStat: Codable, Equatable {
    let letter: String
    /// Per-session accuracy samples (0–1), chronological order.
    let accuracySamples: [Double]
    var averageAccuracy: Double {
        guard !accuracySamples.isEmpty else { return 0 }
        return accuracySamples.reduce(0, +) / Double(accuracySamples.count)
    }
    var trend: Double {
        // Slope of simple linear regression over last min(10, n) samples.
        let window = Array(accuracySamples.suffix(10))
        guard window.count >= 2 else { return 0 }
        let n = Double(window.count)
        let xs = (0..<window.count).map { Double($0) }
        let xMean = xs.reduce(0, +) / n
        let yMean = window.reduce(0, +) / n
        let numerator = zip(xs, window).reduce(0.0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) }
        let denominator = xs.reduce(0.0) { $0 + ($1 - xMean) * ($1 - xMean) }
        return denominator == 0 ? 0 : numerator / denominator
    }
}

struct SessionDurationRecord: Codable, Equatable {
    /// ISO-8601 date string "yyyy-MM-dd"
    let dateString: String
    /// Duration in seconds.
    let durationSeconds: TimeInterval
    /// Thesis condition active during this session.
    let condition: ThesisCondition

    init(dateString: String, durationSeconds: TimeInterval, condition: ThesisCondition = .threePhase) {
        self.dateString = dateString
        self.durationSeconds = durationSeconds
        self.condition = condition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dateString = try c.decode(String.self, forKey: .dateString)
        durationSeconds = try c.decode(TimeInterval.self, forKey: .durationSeconds)
        condition = (try? c.decode(ThesisCondition.self, forKey: .condition)) ?? .threePhase
    }
}

struct DashboardSnapshot: Codable, Equatable {
    var letterStats: [String: LetterAccuracyStat] = [:]
    var sessionDurations: [SessionDurationRecord] = []
    /// Convenience: top 5 letters by average accuracy descending.
    var topLetters: [LetterAccuracyStat] {
        Array(letterStats.values
            .filter { !$0.accuracySamples.isEmpty }
            .sorted { $0.averageAccuracy > $1.averageAccuracy }
            .prefix(5))
    }
    /// Convenience: letters with accuracy below threshold.
    func lettersBelow(accuracy threshold: Double) -> [LetterAccuracyStat] {
        letterStats.values
            .filter { !$0.accuracySamples.isEmpty && $0.averageAccuracy < threshold }
            .sorted { $0.letter < $1.letter }
    }
    /// Rolling 7-day total practice time in seconds.
    func totalPracticeTime(recentDays: Int = 7, referenceDate: Date = Date(), calendar: Calendar = .current) -> TimeInterval {
        let cutoff = calendar.date(byAdding: .day, value: -recentDays, to: referenceDate)!
        let cutoffString = dayKey(for: cutoff, calendar: calendar)
        return sessionDurations
            .filter { $0.dateString >= cutoffString }
            .reduce(0) { $0 + $1.durationSeconds }
    }
}

// MARK: - Protocol

protocol ParentDashboardStoring {
    var snapshot: DashboardSnapshot { get }
    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval, date: Date, condition: ThesisCondition)
    func reset()
}

// MARK: - JSON-persisted implementation

final class JSONParentDashboardStore: ParentDashboardStoring {

    private let fileURL: URL
    private let calendar: Calendar
    private(set) var snapshot: DashboardSnapshot

    init(fileURL: URL? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
        if let url = fileURL {
            self.fileURL = url
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let dir = support.appendingPathComponent("BuchstabenNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("dashboard.json")
        }
        self.snapshot = Self.load(from: self.fileURL) ?? DashboardSnapshot()
    }

    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval, date: Date, condition: ThesisCondition) {
        let key = letter.uppercased()
        let existing = snapshot.letterStats[key] ?? LetterAccuracyStat(letter: key, accuracySamples: [])
        let updated = LetterAccuracyStat(
            letter: existing.letter,
            accuracySamples: existing.accuracySamples + [accuracy]
        )
        snapshot.letterStats[key] = updated

        if durationSeconds > 0 {
            let day = dayKey(for: date, calendar: calendar)
            snapshot.sessionDurations.append(
                SessionDurationRecord(dateString: day, durationSeconds: durationSeconds, condition: condition)
            )
        }
        persist()
    }

    func reset() {
        snapshot = DashboardSnapshot()
        persist()
    }

    // MARK: Private

    private func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> DashboardSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DashboardSnapshot.self, from: data)
    }
}

// MARK: - Helpers

private func dayKey(for date: Date, calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
}
