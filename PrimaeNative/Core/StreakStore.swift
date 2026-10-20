import Foundation

// MARK: - Reward events

enum RewardEvent: String, Codable, CaseIterable, Equatable {
    case firstLetter          // completed a letter for the very first time
    case dailyGoalMet         // completed the configured daily practice goal
    case streakDay3           // 3-day streak
    case streakWeek           // 7-day streak
    case streakMonth          // 30-day streak
    case allLettersComplete   // every letter in the alphabet traced at least once
    case perfectAccuracy      // completed a letter with 100% accuracy
    case centuryClub          // 100 total letter completions
}

// MARK: - Streak store protocol

@MainActor
protocol StreakStoring {
    var currentStreak: Int { get }
    var longestStreak: Int { get }
    var totalCompletions: Int { get }
    var completedLetters: Set<String> { get }
    /// Set of `RewardEvent` cases the child has unlocked across all
    /// sessions. Surfaced in the child-facing Fortschritte gallery as
    /// achievement badges; gray-rendered for unearned events.
    var earnedRewards: Set<RewardEvent> { get }
    /// Record a practice session. Returns any newly earned RewardEvents.
    @discardableResult
    func recordSession(date: Date, lettersCompleted: [String], accuracy: Double) -> [RewardEvent]
    /// Same, with whether the daily goal is reached after this session —
    /// the store cannot see the goal, so `.dailyGoalMet` was never awarded
    /// (class two, 2026-09-05). Requirement with a forwarding default so
    /// doubles that implement the base method still conform.
    @discardableResult
    func recordSession(date: Date, lettersCompleted: [String], accuracy: Double,
                       dailyGoalReached: Bool) -> [RewardEvent]
    func reset()
    /// Await any pending background write. See ProgressStoring.flush().
    func flush() async
}

extension StreakStoring {
    func flush() async {}
    /// Default empty set so older conformers that pre-date the badge UI
    /// still compile. Production stores override with the persisted set.
    var earnedRewards: Set<RewardEvent> { [] }
    @discardableResult
    func recordSession(date: Date, lettersCompleted: [String], accuracy: Double,
                       dailyGoalReached: Bool) -> [RewardEvent] {
        recordSession(date: date, lettersCompleted: lettersCompleted, accuracy: accuracy)
    }
}

// MARK: - Persisted model

private struct StreakState: Codable, Equatable {
    var currentStreak: Int = 0
    var longestStreak: Int = 0
    var totalCompletions: Int = 0
    var completedLetters: Set<String> = []
    var earnedRewards: Set<String> = []
    /// Calendar day string "yyyy-MM-dd" of last practice session.
    var lastPracticeDayString: String = ""
    /// Calendar day string of current streak start.
    var streakStartDayString: String = ""
    var schemaVersion: Int? = streakSchemaVersion
}

/// Current on-disk schema for `StreakState`.
private let streakSchemaVersion = 1

// MARK: - JSON-persisted implementation

final class JSONStreakStore: StreakStoring {

    private let fileURL: URL
    private let calendar: Calendar
    private var state: StreakState
    private var pendingSave: Task<Void, Never>?

    /// See `JSONProgressStore.failureCenter` / `.writeRefusal`.
    private let failureCenter: PersistenceFailureCenter
    private(set) var writeRefusal: String?

    init(fileURL: URL? = nil, calendar: Calendar = .current,
         failureCenter: PersistenceFailureCenter = .shared) {
        self.calendar = calendar
        self.failureCenter = failureCenter
        if let url = fileURL {
            self.fileURL = url
        } else {
            // See ProgressStore.init for the `??` fallback rationale.
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            let dir = support.appendingPathComponent("PrimaeNative", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("streak.json")
        }
        // Missing / unreadable / undecodable / future schema: see
        // `StoreFileQuarantine.load` (R-054, audit 2026-10-13). The old
        // comment here promised "never silently overwritten"; an unreadable
        // or future-schema file was, by the next persist.
        let loaded = StoreFileQuarantine.load(
            self.fileURL, store: "StreakStore", center: failureCenter,
            currentSchemaVersion: streakSchemaVersion,
            schemaVersion: { (state: StreakState) in state.schemaVersion },
            decode: { try StoreCoding.decoder().decode(StreakState.self, from: $0) })
        self.state = loaded.value ?? StreakState()
        self.writeRefusal = loaded.writeRefusal
    }

    var currentStreak: Int { state.currentStreak }
    var longestStreak: Int { state.longestStreak }
    var totalCompletions: Int { state.totalCompletions }
    var completedLetters: Set<String> { state.completedLetters }
    var earnedRewards: Set<RewardEvent> {
        Set(state.earnedRewards.compactMap { RewardEvent(rawValue: $0) })
    }

    @discardableResult
    func recordSession(date: Date, lettersCompleted: [String], accuracy: Double) -> [RewardEvent] {
        recordSession(date: date, lettersCompleted: lettersCompleted, accuracy: accuracy, dailyGoalReached: false)
    }

    func recordSession(date: Date, lettersCompleted: [String], accuracy: Double,
                       dailyGoalReached: Bool) -> [RewardEvent] {
        guard !lettersCompleted.isEmpty else { return [] }

        let dayString = dayKey(for: date)
        var newRewards: [RewardEvent] = []

        // Update streak
        let wasNewDay = dayString != state.lastPracticeDayString
        if wasNewDay {
            let isConsecutive = isConsecutiveDay(after: state.lastPracticeDayString, current: dayString)
            if isConsecutive {
                state.currentStreak += 1
            } else {
                state.currentStreak = 1
                state.streakStartDayString = dayString
            }
            state.longestStreak = max(state.longestStreak, state.currentStreak)
            state.lastPracticeDayString = dayString
        }

        // Route through `LetterProgress.canonicalKey` so `ß` stays
        // in lock-step with the progress and dashboard stores — the
        // `allLettersComplete` check below uses `"ß"` literally.
        let previousLetterCount = state.completedLetters.count
        state.totalCompletions += lettersCompleted.count
        lettersCompleted.forEach { letter in
            state.completedLetters.insert(LetterProgress.canonicalKey(letter))
        }

        // Check rewards
        let newLetterThisSession = previousLetterCount == 0 && !state.completedLetters.isEmpty
        newRewards += checkReward(.firstLetter, condition: newLetterThisSession)
        newRewards += checkReward(.perfectAccuracy, condition: accuracy >= 1.0)
        newRewards += checkReward(.streakDay3, condition: state.currentStreak >= 3)
        newRewards += checkReward(.streakWeek, condition: state.currentStreak >= 7)
        newRewards += checkReward(.streakMonth, condition: state.currentStreak >= 30)
        newRewards += checkReward(.centuryClub, condition: state.totalCompletions >= 100)
        newRewards += checkReward(.dailyGoalMet, condition: dailyGoalReached)
        // allLettersComplete: every supported uppercase letter.
        let allAlphabet = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ".map { String($0) }
            + ["Ä", "Ö", "Ü", "ß"])
        newRewards += checkReward(.allLettersComplete, condition: allAlphabet.isSubset(of: state.completedLetters))

        persist()
        return newRewards
    }

    func reset() {
        state = StreakState()
        persist()
    }

    // MARK: - Private

    private func checkReward(_ reward: RewardEvent, condition: Bool) -> [RewardEvent] {
        guard condition, !state.earnedRewards.contains(reward.rawValue) else { return [] }
        state.earnedRewards.insert(reward.rawValue)
        return [reward]
    }

    private func dayKey(for date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }

    private func isConsecutiveDay(after previous: String, current: String) -> Bool {
        guard !previous.isEmpty else { return false }
        guard let prevDate = parseDay(previous), let currDate = parseDay(current) else { return false }
        let diff = calendar.dateComponents([.day], from: prevDate, to: currDate).day ?? 0
        return diff == 1
    }

    private func parseDay(_ string: String) -> Date? {
        let parts = string.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        return calendar.date(from: comps)
    }

    private func persist() {
        // Encode on main, write off main — see ProgressStore.save().
        guard writeRefusal == nil else {
            storePersistenceLogger.error("StreakStore write refused — the file on disk is kept: \(self.writeRefusal ?? "", privacy: .public)")
            return
        }
        guard let data = StoreCoding.encode(state, store: "StreakStore", center: failureCenter) else { return }
        let url = fileURL
        let center = failureCenter
        // Coalesce + order: see ProgressStore.save() for rationale.
        let previous = pendingSave
        previous?.cancel()
        pendingSave = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                // Loud now (2026-09-14) — see PersistenceFailureCenter.
                storePersistenceLogger.warning(
                    "StreakStore disk write failed at \(url.path, privacy: .private): \((error as NSError).domain, privacy: .public) \((error as NSError).code, privacy: .public) \(error.localizedDescription, privacy: .private)")
                center.reportFailure(store: "StreakStore", error: error)
            }
        }
    }

    /// Await any pending background write. Required before reading the file
    /// from another store instance.
    func flush() async {
        await pendingSave?.value
    }
}
