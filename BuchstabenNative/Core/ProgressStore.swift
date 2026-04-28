import Foundation

// MARK: - Domain model

/// One recognition reading captured for a letter, retaining everything the
/// thesis-data CSV needs to reconstruct per-session recognition outcomes.
/// Stored alongside the legacy `recognitionAccuracy: [Double]?` so old
/// JSON files keep decoding; new writes populate both fields.
struct RecognitionSample: Codable, Equatable, Sendable {
    /// The letter the model picked for this sample.
    var predictedLetter: String
    /// Calibrated confidence 0–1 of the top prediction.
    var confidence: Double
    /// Whether the prediction matched what the child was supposed to write.
    /// `false` for freeform-letter sessions (no expected letter — we don't
    /// know what they were aiming for).
    var isCorrect: Bool
}

/// Persisted stats for a single letter.
struct LetterProgress: Codable, Equatable {
    var completionCount: Int = 0
    var bestAccuracy: Double = 0.0   // 0.0 – 1.0
    var lastCompletedAt: Date?
    /// Per-phase scores keyed by phase name ('observe', 'guided', 'freeWrite').
    /// nil when recorded before phase-level tracking was introduced.
    var phaseScores: [String: Double]?
    /// Last 5 session writing speeds (checkpoints/second) — tracks automatization.
    /// nil when recorded before speed tracking was introduced.
    var speedTrend: [Double]?
    /// Most recent paper-transfer self-assessment score (1.0 super, 0.5 okay, 0.0 nochmal üben).
    /// nil when paper-transfer mode has not been used for this letter.
    var paperTransferScore: Double?
    /// Variant ID used in the most recent completed session (e.g. "variant").
    /// nil when the standard form was used or no session has been recorded.
    var lastVariantUsed: String?
    /// Last 10 CoreML recognition confidences for this letter (0–1). Populated
    /// when either the freeWrite phase or the freeform-letter mode reports
    /// back from the recognizer. nil before the first successful recognition.
    /// Retained alongside `recognitionSamples` so old JSON files (which only
    /// encoded the confidence array) keep decoding.
    var recognitionAccuracy: [Double]?
    /// Last 10 full recognition readings for this letter. Adds the predicted
    /// letter and whether it matched the expectation — without this the CSV
    /// export had no way to recover those signals from the bare confidence
    /// list and silently emitted constant `recognition_predicted` and
    /// `recognition_correct` columns. nil before the first successful
    /// recognition under the new schema; old installs migrate naturally as
    /// new sessions land.
    var recognitionSamples: [RecognitionSample]?
    /// Count of freeform-mode completions for this letter. nil before the
    /// feature was used. Kept separate from `completionCount` so the parent
    /// dashboard can distinguish guided mastery from exploratory writing.
    var freeformCompletionCount: Int?
}

// MARK: - Protocol (testable seam)

@MainActor
protocol ProgressStoring {
    func progress(for letter: String) -> LetterProgress
    func recordCompletion(for letter: String,
                          accuracy: Double,
                          phaseScores: [String: Double]?,
                          speed: Double?,
                          recognitionResult: RecognitionResult?)
    func recordPaperTransferScore(for letter: String, score: Double)
    func recordVariantUsed(for letter: String, variantID: String?)
    /// Record a freeform-mode recognition result. Does not increment the
    /// guided `completionCount` — freeform usage is tracked separately so
    /// the parent dashboard can distinguish guided mastery from exploration.
    func recordFreeformCompletion(letter: String, result: RecognitionResult)
    /// Append a recognition confidence sample to a letter's rolling history
    /// without incrementing any counters. Used when a guided-mode freeWrite
    /// session's recognizer result lands AFTER the completion record was
    /// already committed — the session counts are already in place, we
    /// just want the confidence data to show up in the dashboard trend.
    func recordRecognitionSample(letter: String, result: RecognitionResult)
    func resetAll()
    var allProgress: [String: LetterProgress] { get }
    /// Current streak: consecutive days with at least one completion.
    var currentStreakDays: Int { get }
    /// Total letters completed across all sessions.
    var totalCompletions: Int { get }
    /// Await any pending background write. Callers that need to guarantee
    /// disk durability (e.g. before process suspension) must invoke this
    /// before the tick ends. Default is no-op for in-memory mocks.
    func flush() async
}

extension ProgressStoring {
    func recordCompletion(for letter: String, accuracy: Double) {
        recordCompletion(for: letter, accuracy: accuracy,
                         phaseScores: nil, speed: nil, recognitionResult: nil)
    }
    func recordCompletion(for letter: String, accuracy: Double, phaseScores: [String: Double]?) {
        recordCompletion(for: letter, accuracy: accuracy,
                         phaseScores: phaseScores, speed: nil, recognitionResult: nil)
    }
    func recordCompletion(for letter: String,
                          accuracy: Double,
                          phaseScores: [String: Double]?,
                          speed: Double?) {
        recordCompletion(for: letter, accuracy: accuracy,
                         phaseScores: phaseScores, speed: speed, recognitionResult: nil)
    }
    func recordPaperTransferScore(for letter: String, score: Double) {}
    func recordVariantUsed(for letter: String, variantID: String?) {}
    func recordFreeformCompletion(letter: String, result: RecognitionResult) {}
    func recordRecognitionSample(letter: String, result: RecognitionResult) {}
    func flush() async {}
}

// MARK: - JSON-backed implementation

/// Lightweight JSON progress store backed by a file in the app's
/// Application Support directory. No SwiftData / CoreData dependency —
/// keeps CI fully on Linux-compatible Swift and avoids schema migrations.
public final class JSONProgressStore: ProgressStoring {

    // MARK: Storage

    private let fileURL: URL
    private var store: Store
    /// Serialised chain of background disk writes. Lets `save()` return
    /// immediately (no MainActor hitch at letter completion) while still
    /// guaranteeing write order. Tests call `await flush()` to wait for
    /// all pending writes before re-opening the file.
    private var pendingSave: Task<Void, Never>?

    private struct Store: Codable {
        var letterProgress: [String: LetterProgress] = [:]
        var completionDates: [Date] = []   // one entry per completion event
    }

    // MARK: Init

    public init(fileURL: URL? = nil) {
        if let url = fileURL {
            self.fileURL = url
        } else {
            // iOS sandbox guarantees this URL exists; the `??` keeps a sandbox
            // edge case from crashing the app on launch — we'd lose persistence
            // across launches in that case but keep the session alive.
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
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

    func recordCompletion(for letter: String,
                          accuracy: Double,
                          phaseScores: [String: Double]?,
                          speed: Double?,
                          recognitionResult: RecognitionResult?) {
        let key = letter.uppercased()
        var p = store.letterProgress[key] ?? LetterProgress()
        p.completionCount += 1
        p.bestAccuracy = max(p.bestAccuracy, min(1.0, max(0.0, accuracy)))
        p.lastCompletedAt = Date()
        if let scores = phaseScores { p.phaseScores = scores }
        if let s = speed {
            var trend = p.speedTrend ?? []
            trend.append(s)
            if trend.count > 5 { trend.removeFirst(trend.count - 5) }
            p.speedTrend = trend
        }
        if let rr = recognitionResult {
            Self.appendRecognition(rr, into: &p)
        }
        store.letterProgress[key] = p
        store.completionDates.append(Date())
        save()
    }

    func recordFreeformCompletion(letter: String, result: RecognitionResult) {
        let key = letter.uppercased()
        var p = store.letterProgress[key] ?? LetterProgress()
        Self.appendRecognition(result, into: &p)
        p.freeformCompletionCount = (p.freeformCompletionCount ?? 0) + 1
        store.letterProgress[key] = p
        save()
    }

    func recordRecognitionSample(letter: String, result: RecognitionResult) {
        let key = letter.uppercased()
        var p = store.letterProgress[key] ?? LetterProgress()
        Self.appendRecognition(result, into: &p)
        store.letterProgress[key] = p
        save()
    }

    /// Append a recognition reading to a LetterProgress' rolling history.
    /// Maintains both the legacy `recognitionAccuracy` confidence list and
    /// the richer `recognitionSamples` list capped at 10 entries each.
    /// Centralised so the three record* paths can't drift on the cap or
    /// on which fields they write.
    private static func appendRecognition(_ result: RecognitionResult,
                                          into p: inout LetterProgress) {
        var acc = p.recognitionAccuracy ?? []
        acc.append(Double(result.confidence))
        if acc.count > 10 { acc.removeFirst(acc.count - 10) }
        p.recognitionAccuracy = acc

        var samples = p.recognitionSamples ?? []
        samples.append(RecognitionSample(
            predictedLetter: result.predictedLetter,
            confidence: Double(result.confidence),
            isCorrect: result.isCorrect
        ))
        if samples.count > 10 { samples.removeFirst(samples.count - 10) }
        p.recognitionSamples = samples
    }

    func recordPaperTransferScore(for letter: String, score: Double) {
        let key = letter.uppercased()
        var p = store.letterProgress[key] ?? LetterProgress()
        p.paperTransferScore = score
        store.letterProgress[key] = p
        save()
    }

    func recordVariantUsed(for letter: String, variantID: String?) {
        let key = letter.uppercased()
        var p = store.letterProgress[key] ?? LetterProgress()
        p.lastVariantUsed = variantID
        store.letterProgress[key] = p
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
        let url = fileURL
        // Coalesce: cancel any prior pending task. Since in-memory state is
        // already up-to-date and `data` is a full snapshot of the current store,
        // writing only the latest snapshot is equivalent to writing N
        // back-to-back snapshots. This avoids unbounded chain growth + N×
        // Data retention under rapid save() bursts.
        //
        // Ordering: await the previous task before writing so two in-flight
        // writes can't race and leave an older snapshot on disk.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Await any pending background write. Call before re-opening the file
    /// from another store instance, or before app termination, to avoid
    /// losing writes that haven't been flushed to disk yet.
    public func flush() async {
        await pendingSave?.value
    }
}
