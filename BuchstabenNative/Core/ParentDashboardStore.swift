import Foundation

// MARK: - Data models

struct PhaseSessionRecord: Codable, Equatable {
    let letter: String
    /// LearningPhase.rawName: "observe", "direct", "guided", or "freeWrite".
    let phase: String
    let completed: Bool
    /// Phase accuracy score (0–1). For freeWrite equals WritingAssessment.overallScore.
    let score: Double
    /// Spaced-repetition priority assigned when this session was scheduled.
    let schedulerPriority: Double
    /// Thesis A/B condition in effect for this session. Added post-launch so
    /// old records may be missing this field — custom decoder defaults to
    /// .threePhase for pre-migration records.
    let condition: ThesisCondition
    /// Schreibmotorik dimensions (non-nil only for freeWrite sessions).
    let formAccuracy: Double?
    let tempoConsistency: Double?
    let pressureControl: Double?
    let rhythmScore: Double?

    init(letter: String, phase: String, completed: Bool, score: Double,
         schedulerPriority: Double, condition: ThesisCondition = .threePhase,
         assessment: WritingAssessment? = nil) {
        self.letter = letter
        self.phase = phase
        self.completed = completed
        self.score = max(0, min(1, score))
        self.schedulerPriority = schedulerPriority
        self.condition = condition
        self.formAccuracy     = assessment.map { Double($0.formAccuracy) }
        self.tempoConsistency = assessment.map { Double($0.tempoConsistency) }
        self.pressureControl  = assessment.map { Double($0.pressureControl) }
        self.rhythmScore      = assessment.map { Double($0.rhythmScore) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        letter = try c.decode(String.self, forKey: .letter)
        phase = try c.decode(String.self, forKey: .phase)
        completed = try c.decode(Bool.self, forKey: .completed)
        score = try c.decode(Double.self, forKey: .score)
        schedulerPriority = try c.decode(Double.self, forKey: .schedulerPriority)
        condition = (try? c.decode(ThesisCondition.self, forKey: .condition)) ?? .threePhase
        formAccuracy     = try? c.decode(Double.self, forKey: .formAccuracy)
        tempoConsistency = try? c.decode(Double.self, forKey: .tempoConsistency)
        pressureControl  = try? c.decode(Double.self, forKey: .pressureControl)
        rhythmScore      = try? c.decode(Double.self, forKey: .rhythmScore)
    }
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
        guard let cutoff = calendar.date(byAdding: .day, value: -recentDays, to: referenceDate) else { return 0 }
        let cutoffString = dayKey(for: cutoff, calendar: calendar)
        return sessionDurations
            .filter { $0.dateString >= cutoffString }
            .reduce(0) { $0 + $1.durationSeconds }
    }

    /// Fraction of sessions that completed each phase (keyed by LearningPhase.rawName).
    /// Iterates LearningPhase.allCases so every phase — including `direct` —
    /// makes it into the thesis export. Previously hard-coded to three phases,
    /// which silently dropped Richtung-lernen data from every CSV row.
    var phaseCompletionRates: [String: Double] {
        var result: [String: Double] = [:]
        for phase in LearningPhase.allCases.map(\.rawName) {
            let records = phaseSessionRecords.filter { $0.phase == phase }
            guard !records.isEmpty else { continue }
            result[phase] = Double(records.filter { $0.completed }.count) / Double(records.count)
        }
        return result
    }

    /// Mean per-phase score for a single letter, keyed by LearningPhase.rawName.
    /// Returns only phases the child has actually completed at least one
    /// session of — letters never traced beyond observe will return a single
    /// "observe" entry, etc. Used by the per-letter dashboard row to show
    /// which phase a child masters vs which one they get stuck on.
    func phaseScores(for letter: String) -> [String: Double] {
        let key = letter.uppercased()
        let records = phaseSessionRecords.filter { $0.letter.uppercased() == key && $0.completed }
        guard !records.isEmpty else { return [:] }
        var sums: [String: (total: Double, count: Int)] = [:]
        for r in records {
            let prior = sums[r.phase] ?? (0, 0)
            sums[r.phase] = (prior.total + r.score, prior.count + 1)
        }
        return sums.mapValues { $0.total / Double($0.count) }
    }

    /// Daily practice minutes for the most recent `days` days. Missing days
    /// in `sessionDurations` are filled with 0 so the chart x-axis always
    /// shows a continuous timeline. Returns oldest-first so the chart reads
    /// left-to-right as past-to-present.
    func dailyPracticeMinutes(days: Int = 30,
                              referenceDate: Date = Date(),
                              calendar: Calendar = .current) -> [(date: Date, minutes: Double)] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone

        let byKey = Dictionary(grouping: sessionDurations, by: { $0.dateString })
            .mapValues { $0.reduce(0) { $0 + $1.durationSeconds } }

        var out: [(date: Date, minutes: Double)] = []
        for offset in (0..<days).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: referenceDate) else { continue }
            let key = formatter.string(from: day)
            let minutes = (byKey[key] ?? 0) / 60.0
            out.append((date: day, minutes: minutes))
        }
        return out
    }

    /// Mean overall score across all completed freeWrite phase sessions.
    var averageFreeWriteScore: Double {
        let scores = phaseSessionRecords
            .filter { $0.phase == "freeWrite" && $0.completed }
            .map { $0.score }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / Double(scores.count)
    }

    /// Average of each Schreibmotorik dimension across completed freeWrite sessions
    /// that have dimension data. Returns nil when no such sessions exist yet.
    var averageWritingDimensions: (form: Double, tempo: Double, pressure: Double, rhythm: Double)? {
        let records = phaseSessionRecords
            .filter { $0.phase == "freeWrite" && $0.completed && $0.formAccuracy != nil }
        guard !records.isEmpty else { return nil }
        let count = Double(records.count)
        return (
            form:     records.compactMap(\.formAccuracy).reduce(0, +)     / count,
            tempo:    records.compactMap(\.tempoConsistency).reduce(0, +) / count,
            pressure: records.compactMap(\.pressureControl).reduce(0, +)  / count,
            rhythm:   records.compactMap(\.rhythmScore).reduce(0, +)      / count
        )
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

@MainActor
protocol ParentDashboardStoring {
    var snapshot: DashboardSnapshot { get }
    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval, date: Date, condition: ThesisCondition)
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, assessment: WritingAssessment?)
    func reset()
    /// Await any pending background write. See ProgressStoring.flush().
    func flush() async
}

extension ParentDashboardStoring {
    /// Backward-compatible overload for call sites that don't supply an assessment.
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition) {
        recordPhaseSession(letter: letter, phase: phase, completed: completed, score: score,
                           schedulerPriority: schedulerPriority, condition: condition, assessment: nil)
    }
    func flush() async {}
}

// MARK: - JSON-persisted implementation

final class JSONParentDashboardStore: ParentDashboardStoring {

    private let fileURL: URL
    private let calendar: Calendar
    private(set) var snapshot: DashboardSnapshot
    private var pendingSave: Task<Void, Never>?

    init(fileURL: URL? = nil, calendar: Calendar = .current) {
        self.calendar = calendar
        if let url = fileURL {
            self.fileURL = url
        } else {
            // See ProgressStore.init for the `??` fallback rationale.
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("BuchstabenNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("dashboard.json")
        }
        self.snapshot = Self.load(from: self.fileURL) ?? DashboardSnapshot()
    }

    /// Hard ceiling on per-letter accuracy samples. The trend regression
    /// only looks at the trailing 10, so anything beyond ~200 samples is
    /// noise — capping there keeps the dashboard JSON file from growing
    /// unbounded on long-running thesis devices while still preserving
    /// enough history for a generous trailing-window analysis.
    private static let accuracySamplesCap = 200

    /// Hard ceiling on phase-session records. The dashboard summaries
    /// (phaseCompletionRates, schedulerEffectivenessProxy, recent table
    /// in ResearchDashboardView) all work over recent windows, never
    /// scan the full history. Long-running thesis devices were
    /// previously accumulating one record per phase × ~5 letters per
    /// session × multiple sessions per day — fine for a year, but
    /// unbounded growth on a multi-year deployment.
    private static let phaseSessionRecordsCap = 2000

    /// Hard ceiling on per-day session durations. PracticeTrendChart
    /// renders the last 30 days at most; 1000 entries gives roughly
    /// three years of headroom for the trailing-window export.
    private static let sessionDurationsCap = 1000

    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval, date: Date, condition: ThesisCondition) {
        let key = letter.uppercased()
        let existing = snapshot.letterStats[key] ?? LetterAccuracyStat(letter: key, accuracySamples: [])
        var samples = existing.accuracySamples
        samples.append(accuracy)
        if samples.count > Self.accuracySamplesCap {
            samples.removeFirst(samples.count - Self.accuracySamplesCap)
        }
        let updated = LetterAccuracyStat(
            letter: existing.letter,
            accuracySamples: samples
        )
        snapshot.letterStats[key] = updated

        if durationSeconds > 0 {
            let day = dayKey(for: date, calendar: calendar)
            snapshot.sessionDurations.append(
                SessionDurationRecord(dateString: day, durationSeconds: durationSeconds, condition: condition)
            )
            if snapshot.sessionDurations.count > Self.sessionDurationsCap {
                snapshot.sessionDurations.removeFirst(
                    snapshot.sessionDurations.count - Self.sessionDurationsCap
                )
            }
        }
        persist()
    }

    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, assessment: WritingAssessment?) {
        let record = PhaseSessionRecord(
            letter: letter.uppercased(),
            phase: phase,
            completed: completed,
            score: score,
            schedulerPriority: schedulerPriority,
            condition: condition,
            assessment: assessment
        )
        snapshot.phaseSessionRecords.append(record)
        if snapshot.phaseSessionRecords.count > Self.phaseSessionRecordsCap {
            snapshot.phaseSessionRecords.removeFirst(
                snapshot.phaseSessionRecords.count - Self.phaseSessionRecordsCap
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
        // Encode off main: snapshot the value-type DashboardSnapshot on
        // the actor, then encode + write inside the detached Task.
        let snapshotCopy = snapshot
        let url = fileURL
        // Coalesce + order: see ProgressStore.save() for rationale.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshotCopy) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Await any pending background write. Required before reading the file
    /// from another store instance.
    func flush() async {
        await pendingSave?.value
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
