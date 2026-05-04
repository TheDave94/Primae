import Foundation
import os

/// Disk-write logger used by every JSON-backed store so a
/// `try data.write` failure surfaces in OSLog instead of being
/// silently swallowed. Marked `nonisolated(unsafe)` because `Logger`
/// is Sendable but the module-level `MainActor` default isolation
/// needs an opt-out for use from a detached Task.
nonisolated(unsafe) let storePersistenceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
    category: "StorePersistence"
)

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
    /// Pre-calibration softmax confidence so the thesis can report the
    /// calibrator's effect (raw vs adjusted, decision-flip rate).
    /// Optional for legacy rows written before this field existed.
    var rawConfidence: Double?
    /// Whether the prediction matched what the child was supposed to write.
    /// `false` for freeform-letter sessions (no expected letter — we don't
    /// know what they were aiming for).
    var isCorrect: Bool

    init(predictedLetter: String, confidence: Double,
         rawConfidence: Double? = nil, isCorrect: Bool) {
        self.predictedLetter = predictedLetter
        self.confidence = confidence
        self.rawConfidence = rawConfidence
        self.isCorrect = isCorrect
    }
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
    /// Last 10 full recognition readings — predicted letter +
    /// confidence + whether it matched the expectation. Held alongside
    /// `recognitionAccuracy` so the CSV export can emit the predicted-
    /// letter and correctness columns rather than just confidence.
    /// nil for installs whose first successful recognition predates
    /// this field; new sessions populate it on landing.
    var recognitionSamples: [RecognitionSample]?
    /// Count of freeform-mode completions for this letter. nil before the
    /// feature was used. Kept separate from `completionCount` so the parent
    /// dashboard can distinguish guided mastery from exploratory writing.
    var freeformCompletionCount: Int?
    /// Rolling log of retrieval-practice outcomes. `true` = correct
    /// recognition, `false` = wrong choice. Capped at 10 entries
    /// (latest only). Drives the retrieval-accuracy column in the
    /// thesis CSV alongside form accuracy.
    var retrievalAttempts: [Bool]?
}

extension LetterProgress {
    /// Canonical dictionary key for per-letter persistence. The bare
    /// `letter.uppercased()` rule is wrong for German `ß`: Unicode
    /// canonicalises it to `"SS"`, silently losing the eszett identity.
    /// Every store that keys by letter (`JSONProgressStore`,
    /// `JSONParentDashboardStore`, `JSONStreakStore`) must route through
    /// here so the same child practising `ß` lands consistently across
    /// stores.
    static func canonicalKey(_ letter: String) -> String {
        letter == "ß" ? "ß" : letter.uppercased()
    }
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
    /// Record one retrieval-practice outcome. Capped at 10 entries
    /// (latest only). Default extension is a no-op so mocks that don't
    /// surface this signal stay conforming.
    func recordRetrievalAttempt(letter: String, correct: Bool)
    func resetAll()
    var allProgress: [String: LetterProgress] { get }
    /// Total letters completed across all sessions.
    var totalCompletions: Int { get }
    /// Completions that landed today (calendar day). Drives the daily-
    /// goal pill in `FortschritteWorldView`.
    var completionsToday: Int { get }
    /// Await any pending background write. Callers that need to guarantee
    /// disk durability (e.g. before process suspension) must invoke this
    /// before the tick ends. Default is no-op for in-memory mocks.
    func flush() async
}

extension ProgressStoring {
    var completionsToday: Int { 0 }

    func recordRetrievalAttempt(letter: String, correct: Bool) {}

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
    // Optional protocol methods. Defaults crash so a stub that forgot
    // to override one fails loudly in tests instead of silently
    // swallowing thesis-critical data. Production conformers implement
    // all four; test stubs opt in explicitly with no-op overrides
    // where the test isn't asserting that channel.
    func recordPaperTransferScore(for letter: String, score: Double) {
        fatalError("Conformer must override \(#function) — protocol default refuses to silently no-op.")
    }
    func recordVariantUsed(for letter: String, variantID: String?) {
        fatalError("Conformer must override \(#function) — protocol default refuses to silently no-op.")
    }
    func recordFreeformCompletion(letter: String, result: RecognitionResult) {
        fatalError("Conformer must override \(#function) — protocol default refuses to silently no-op.")
    }
    func recordRecognitionSample(letter: String, result: RecognitionResult) {
        fatalError("Conformer must override \(#function) — protocol default refuses to silently no-op.")
    }
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
        /// Persisted schema version. Absent on legacy files (decodes
        /// as `nil`); current writes stamp `currentSchemaVersion` so a
        /// future migration path can branch on the value rather than
        /// silently mis-decoding a forward-incompatible file.
        var schemaVersion: Int? = currentSchemaVersion
    }

    /// Current on-disk schema for `Store`. Bump when adding a field
    /// older builds can't decode safely; gate the migration in
    /// `load(from:)`.
    private static let currentSchemaVersion = 1

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
            let dir = support.appendingPathComponent("PrimaeNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("progress.json")
        }
        self.store = Self.load(from: self.fileURL)
    }

    // MARK: - Caps

    /// Hard ceiling on `completionDates`. The streak query only ever
    /// reads the trailing 30 days, so anything beyond ~1000 entries
    /// is dead weight on disk. Long-running thesis devices that
    /// practise daily for a year would otherwise accumulate 365 × N
    /// records.
    private static let completionDatesCap = 1000

    // MARK: - Canonical key

    /// Normalised dictionary key. Delegates to
    /// `LetterProgress.canonicalKey` so every per-letter store
    /// shares one normalisation rule.
    private static func canonicalKey(_ letter: String) -> String {
        LetterProgress.canonicalKey(letter)
    }

    // MARK: ProgressStoring

    func progress(for letter: String) -> LetterProgress {
        store.letterProgress[Self.canonicalKey(letter)] ?? LetterProgress()
    }

    func recordCompletion(for letter: String,
                          accuracy: Double,
                          phaseScores: [String: Double]?,
                          speed: Double?,
                          recognitionResult: RecognitionResult?) {
        let key = Self.canonicalKey(letter)
        var p = store.letterProgress[key] ?? LetterProgress()
        p.completionCount += 1
        p.bestAccuracy = max(p.bestAccuracy, min(1.0, max(0.0, accuracy)))
        p.lastCompletedAt = Date()
        if let scores = phaseScores { p.phaseScores = scores }
        if let s = speed {
            var trend = p.speedTrend ?? []
            trend.append(s)
            // Keep up to 50 samples — the scheduler's
            // `automatizationBonus` only consults the trend halves
            // (so longer histories don't distort the bonus), but the
            // thesis export needs the full trajectory to plot
            // speed-up curves.
            if trend.count > 50 { trend.removeFirst(trend.count - 50) }
            p.speedTrend = trend
        }
        if let rr = recognitionResult {
            Self.appendRecognition(rr, into: &p)
        }
        store.letterProgress[key] = p
        store.completionDates.append(Date())
        // Cap the rolling completion log — only the last 30 days are
        // ever queried by `currentStreakDays`, but we keep a few hundred
        // for long-window analytics. Bound at the head so the most
        // recent entries always survive.
        if store.completionDates.count > Self.completionDatesCap {
            store.completionDates.removeFirst(
                store.completionDates.count - Self.completionDatesCap
            )
        }
        save()
    }

    func recordFreeformCompletion(letter: String, result: RecognitionResult) {
        let key = Self.canonicalKey(letter)
        var p = store.letterProgress[key] ?? LetterProgress()
        Self.appendRecognition(result, into: &p)
        p.freeformCompletionCount = (p.freeformCompletionCount ?? 0) + 1
        store.letterProgress[key] = p
        save()
    }

    func recordRecognitionSample(letter: String, result: RecognitionResult) {
        let key = Self.canonicalKey(letter)
        var p = store.letterProgress[key] ?? LetterProgress()
        Self.appendRecognition(result, into: &p)
        store.letterProgress[key] = p
        save()
    }

    /// Retrieval-practice outcome (correct ↔ wrong). Capped at 10
    /// entries — the dashboard trend only reads the trailing window so
    /// longer histories are noise.
    func recordRetrievalAttempt(letter: String, correct: Bool) {
        let key = Self.canonicalKey(letter)
        var p = store.letterProgress[key] ?? LetterProgress()
        var attempts = p.retrievalAttempts ?? []
        attempts.append(correct)
        if attempts.count > 10 { attempts.removeFirst(attempts.count - 10) }
        p.retrievalAttempts = attempts
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
            rawConfidence: result.rawConfidence.map { Double($0) },
            isCorrect: result.isCorrect
        ))
        if samples.count > 10 { samples.removeFirst(samples.count - 10) }
        p.recognitionSamples = samples
    }

    func recordPaperTransferScore(for letter: String, score: Double) {
        let key = Self.canonicalKey(letter)
        var p = store.letterProgress[key] ?? LetterProgress()
        p.paperTransferScore = score
        store.letterProgress[key] = p
        save()
    }

    func recordVariantUsed(for letter: String, variantID: String?) {
        let key = Self.canonicalKey(letter)
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

    var totalCompletions: Int {
        store.letterProgress.values.reduce(0) { $0 + $1.completionCount }
    }

    /// Letter completions that landed today. Drives the daily-goal
    /// pill on Fortschritte. Counts entries from `completionDates`
    /// (cap 1000, plenty of headroom for a single day) that fall
    /// within today's calendar day.
    var completionsToday: Int {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return store.completionDates.filter {
            cal.isDate($0, inSameDayAs: today)
        }.count
    }

    // MARK: Persistence

    private static func load(from url: URL) -> Store {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Store.self, from: data)
        else { return Store() }
        // Refuse to read a file written by a future schema we don't
        // understand. Silently dropping unknown fields would clobber
        // them on next save; instead log loudly and fall back to
        // defaults so the unknown file remains intact on disk.
        if let v = decoded.schemaVersion, v > currentSchemaVersion {
            storePersistenceLogger.warning(
                "ProgressStore at \(url.path, privacy: .public) is schema v\(v) but build expects v\(currentSchemaVersion); ignoring on-disk state.")
            return Store()
        }
        return decoded
    }

    private func save() {
        // Encode on main, write off main. Encoding the value-type
        // Store is bounded (completionDates capped at 1000) and
        // main-actor encoding sidesteps Swift 6's strict-concurrency
        // restriction on calling a MainActor-isolated Encodable from
        // a detached Task. The atomic disk write runs off main.
        guard let data = try? JSONEncoder().encode(store) else { return }
        let url = fileURL
        // Coalesce + serialise: each call cancels the prior task and
        // awaits it before writing. The encoded data is already the
        // latest snapshot, so writing only the most recent buffer is
        // equivalent to writing every queued snapshot — and avoids
        // unbounded chain growth under rapid save() bursts. Awaiting
        // the previous task preserves write order on disk.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // The volume might be full or the file corrupt; the
                // in-memory state is still good for the current
                // session, but a parent investigating "the streak
                // reset itself" deserves a log line to point at.
                storePersistenceLogger.warning(
                    "ProgressStore disk write failed at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Await any pending background write. Call before re-opening the file
    /// from another store instance, or before app termination, to avoid
    /// losing writes that haven't been flushed to disk yet.
    public func flush() async {
        await pendingSave?.value
    }
}
