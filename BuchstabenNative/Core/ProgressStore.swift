import Foundation
import os

/// Disk-write logger used by every JSON-backed store so a `try data.write`
/// failure is no longer silently swallowed (review item W-18). Marked
/// `nonisolated(unsafe)` because `Logger` is Sendable but the
/// module-level `MainActor` default isolation needs an opt-out for use
/// from a detached Task.
nonisolated(unsafe) let storePersistenceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "BuchstabenNative",
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

extension LetterProgress {
    /// Canonical dictionary key for any per-letter persistence. The bare
    /// `letter.uppercased()` rule is wrong for the German `ß`: Unicode
    /// canonicalises it to `"SS"`, which silently loses the eszett's
    /// identity and routes its progress into a non-existent `SS` slot.
    /// Every store that keys by letter — `JSONProgressStore`,
    /// `JSONParentDashboardStore`, `JSONStreakStore` — must use this so
    /// the same child practising `ß` is reflected consistently across
    /// stores (review item W-3).
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
    func resetAll()
    var allProgress: [String: LetterProgress] { get }
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
    // Optional protocol methods. Default implementations crash so a stub
    // that forgot to override one fails loudly in tests instead of
    // silently swallowing thesis-critical data (review item W-13/P-3).
    // Production conformers (`JSONProgressStore`) implement all four;
    // test stubs (`StubProgressStore`) opt in explicitly with no-op
    // overrides where the test isn't asserting that channel.
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
        /// W-17: persisted schema version. Absent from pre-W-17 files
        /// (decodes as `nil`); current writes stamp `currentSchemaVersion`
        /// so a future migration path can branch on the value instead of
        /// silently mis-decoding a forward-incompatible file.
        var schemaVersion: Int? = currentSchemaVersion
    }

    /// Current on-disk schema for `Store`. Bump when adding a field that
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
            let dir = support.appendingPathComponent("BuchstabenNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("progress.json")
        }
        self.store = Self.load(from: self.fileURL)
    }

    // MARK: - Caps

    /// Hard ceiling on `completionDates`. The streak query reads at
    /// most the trailing 30 days of entries, so anything beyond ~1000
    /// is dead weight on disk. Long-running thesis devices that practise
    /// daily for a year would otherwise accumulate 365+ records per
    /// year × N completions per session.
    private static let completionDatesCap = 1000

    // MARK: - Canonical key

    /// Normalised dictionary key used by every per-letter store entry.
    /// Delegates to `LetterProgress.canonicalKey` so all stores share
    /// one normalisation rule (review item W-3).
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
            // D-4: keep the full automatisation trajectory (up to 50
            // samples) instead of clipping to 5. The scheduler's
            // `automatizationBonus` only reads the trend halves so
            // longer histories don't distort the bonus, but the thesis
            // export needs the full trajectory to plot speed-up curves.
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

    // MARK: Persistence

    private static func load(from url: URL) -> Store {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(Store.self, from: data)
        else { return Store() }
        // W-17: refuse to read a file written by a future schema we
        // don't understand — silently dropping unknown fields would
        // overwrite the file on next save and lose data the newer
        // build wrote. Returning a fresh `Store()` here is also wrong
        // (would clobber the future file); we log and bail back to
        // the cached in-memory state by returning a marker the caller
        // can treat as "skip this load". For now we fail loudly with
        // a logger warning and fall back to defaults — mirrors the
        // existing decode-failure path so behaviour stays predictable
        // until a real migration ladder lands.
        if let v = decoded.schemaVersion, v > currentSchemaVersion {
            storePersistenceLogger.warning(
                "ProgressStore at \(url.path, privacy: .public) is schema v\(v) but build expects v\(currentSchemaVersion); ignoring on-disk state.")
            return Store()
        }
        return decoded
    }

    private func save() {
        // Encode on main, write off main. Encoding the value-type Store is
        // bounded (completionDates capped at 1000) and main-actor encoding
        // sidesteps the Swift 6 strict-concurrency restriction on calling a
        // MainActor-isolated Encodable conformance from a nonisolated
        // detached Task. The atomic disk write — the heavier I/O — still
        // runs off main on the cooperative pool.
        guard let data = try? JSONEncoder().encode(store) else { return }
        let url = fileURL
        // Coalesce: cancel any prior pending task. Since the encoded data is
        // already a full copy of the current store, writing only the latest
        // snapshot is equivalent to writing N back-to-back snapshots. This
        // avoids unbounded chain growth + N× Data retention under rapid
        // save() bursts.
        //
        // Ordering: await the previous task before writing so two in-flight
        // writes can't race and leave an older snapshot on disk.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // Surfacing instead of silently dropping (review item W-18).
                // The on-disk file might be corrupt or the volume full;
                // either way the in-memory state is still good for the
                // current session, but a parent investigating "the streak
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
