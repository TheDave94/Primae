import Foundation
#if canImport(CloudKit)
import CloudKit
#endif

// MARK: - Sync state

enum SyncState: Equatable {
    case idle
    case syncing
    case error(String)
}

// MARK: - Sync record types

enum SyncRecordType: String {
    case progress = "ProgressRecord"
    case streak   = "StreakRecord"
}

// MARK: - Protocol (async/throws — Swift 6.3)

protocol CloudSyncService: AnyObject, Sendable {
    var syncState: SyncState { get }
    /// Upload local data. Throws on network or CloudKit failure.
    func push(recordType: SyncRecordType, payload: [String: Any]) async throws
    /// Fetch latest record. Returns empty dict when no record exists yet.
    func fetch(recordType: SyncRecordType) async throws -> [String: Any]
}

// MARK: - Null (test / pre-CloudKit) implementation

final class NullSyncService: CloudSyncService, @unchecked Sendable {
    private(set) var syncState: SyncState = .idle
    private(set) var pushedRecords: [(SyncRecordType, [String: Any])] = []
    private var storedRecords: [SyncRecordType: [String: Any]] = [:]

    /// Inject a record to be returned by fetch (for tests).
    func seedRecord(type: SyncRecordType, payload: [String: Any]) {
        storedRecords[type] = payload
    }

    /// Set to simulate a network/auth failure on next push or fetch.
    var simulateError: Error? = nil

    func push(recordType: SyncRecordType, payload: [String: Any]) async throws {
        if let error = simulateError {
            syncState = .error(error.localizedDescription)
            throw error
        }
        syncState = .syncing
        pushedRecords.append((recordType, payload))
        storedRecords[recordType] = payload
        syncState = .idle
    }

    func fetch(recordType: SyncRecordType) async throws -> [String: Any] {
        if let error = simulateError {
            syncState = .error(error.localizedDescription)
            throw error
        }
        syncState = .syncing
        let result = storedRecords[recordType] ?? [:]
        syncState = .idle
        return result
    }

    func reset() {
        syncState = .idle
        pushedRecords = []
        storedRecords = [:]
        simulateError = nil
    }
}

// MARK: - SyncCoordinator

/// Coordinates sync between local stores and CloudKit.
/// Uses last-write-wins merge: remote timestamp beats local if newer.
@MainActor
final class SyncCoordinator {

    private let sync: any CloudSyncService
    private let progressStore: ProgressStoring
    private let streakStore: StreakStoring
    private(set) var lastSyncDate: Date?

    init(sync: any CloudSyncService, progressStore: ProgressStoring, streakStore: StreakStoring) {
        self.sync = sync
        self.progressStore = progressStore
        self.streakStore = streakStore
    }

    var syncState: SyncState { sync.syncState }

    /// Push all local state to CloudKit. Throws on first failure.
    func pushAll() async throws {
        try await sync.push(recordType: .progress, payload: buildProgressPayload())
        try await sync.push(recordType: .streak,   payload: buildStreakPayload())
        lastSyncDate = Date()
    }

    // MARK: Private

    private func buildProgressPayload() -> [String: Any] {
        let entries = progressStore.allProgress
        let mapped = entries.map { k, v in
            ["letter": k, "completions": v.completionCount, "bestAccuracy": v.bestAccuracy]
        }
        return [
            "entries":   mapped,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
    }

    private func buildStreakPayload() -> [String: Any] {
        [
            "currentStreak":    streakStore.currentStreak,
            "longestStreak":    streakStore.longestStreak,
            "totalCompletions": streakStore.totalCompletions,
            "timestamp":        ISO8601DateFormatter().string(from: Date())
        ]
    }
}
