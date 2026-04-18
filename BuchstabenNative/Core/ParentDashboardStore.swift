import Foundation

// MARK: - Data models

struct PhaseSessionRecord: Codable, Equatable {
    let letter: String
    /// LearningPhase.rawName: "observe", "guided", or "freeWrite"
    let phase: String
    let completed: Bool
    /// Phase accuracy score (0–1).
    let score: Double
    /// Spaced-repetition priority assigned when this session was scheduled.
    let schedulerPriority: Double
}

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
    var phaseSessionRecords: [PhaseSessionRecord] = []

    init(letterStats: [String: LetterAccuracyStat] = [:],
         sessionDurations: [SessionDurationRecord] = [],
         phaseSessionRecords: [PhaseSessionRecord] = []) {
        self.letterStats = letterStats
        self.sessionDurations = sessionDurations
        self.phaseSessionRecords = phaseSessionRecords
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        letterStats = try c.decode([String: LetterAccuracyStat].self, forKey: .letterStats)
        sessionDurations = try c.decode([SessionDurationRecord].self, forKey: .sessionDurations)
        // phaseSessionRecords was added after initial release; default to empty for old JSON files.
        phaseSessionRecords = (try? c.decode([PhaseSessionRecord].self, forKey: .phaseSessionRecords)) ?? []
    }

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

    /// Fraction of sessions that completed each phase (keyed by LearningPhase.rawName).
    var phaseCompletionRates: [String: Double] {
        let phases = ["observe", "guided", "freeWrite"]
        var result: [String: Double] = [:]
        for phase in phases {
            let records = phaseSessionRecords.filter { $0.phase == phase }
            guard !records.isEmpty else { continue }
            result[phase] = Double(records.filter { $0.completed }.count) / Double(records.count)
        }
        return result
    }

    /// Mean Fréchet-based score across all completed freeWrite phase sessions.
    var averageFreeWriteScore: Double {
        let scores = phaseSessionRecords
            .filter { $0.phase == "freeWrite" && $0.completed }
            .map { $0.score }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Pearson correlation between scheduler priority and subsequent accuracy improvement.
    /// Positive values indicate the scheduler is correctly prioritising struggling letters.
    var schedulerEffectivenessProxy: Double {
        var pairs: [(priority: Double, delta: Double)] = []
        let letters = Set(phaseSessionRecords.map { $0.letter })
        for letter in letters {
            let records = phaseSessionRecords.filter { $0.letter == letter && $0.completed }
            guard records.count >= 2 else { continue }
            for i in 0..<(records.count - 1) {
                pairs.append((priority: records[i].schedulerPriority,
                               delta: records[i + 1].score - records[i].score))
            }
        }
        guard pairs.count >= 2 else { return 0 }
        let n = Double(pairs.count)
        let xs = pairs.map { $0.priority }
        let ys = pairs.map { $0.delta }
        let xMean = xs.reduce(0, +) / n
        let yMean = ys.reduce(0, +) / n
        let numerator = zip(xs, ys).reduce(0.0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) }
        let xVar = xs.reduce(0.0) { $0 + ($1 - xMean) * ($1 - xMean) }
        let yVar = ys.reduce(0.0) { $0 + ($1 - yMean) * ($1 - yMean) }
        guard xVar > 0, yVar > 0 else { return 0 }
        return numerator / sqrt(xVar * yVar)
    }
}

// MARK: - Protocol

protocol ParentDashboardStoring {
    var snapshot: DashboardSnapshot { get }
    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval, date: Date, condition: ThesisCondition)
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double)
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

    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double) {
        let record = PhaseSessionRecord(
            letter: letter.uppercased(),
            phase: phase,
            completed: completed,
            score: max(0, min(1, score)),
            schedulerPriority: schedulerPriority
        )
        snapshot.phaseSessionRecords.append(record)
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
