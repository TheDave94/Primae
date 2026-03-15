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

// MARK: - Protocol

protocol CloudSyncService: AnyObject {
    var syncState: SyncState { get }
    /// Upload local data to CloudKit. Calls completion with success/failure.
    func push(recordType: SyncRecordType, payload: [String: Any], completion: @escaping (Result<Void, Error>) -> Void)
    /// Fetch latest record from CloudKit for a given type.
    func fetch(recordType: SyncRecordType, completion: @escaping (Result<[String: Any], Error>) -> Void)
}

// MARK: - Null (test/simulator) implementation

final class NullSyncService: CloudSyncService {
    private(set) var syncState: SyncState = .idle
    private(set) var pushedRecords: [(SyncRecordType, [String: Any])] = []
    private var storedRecords: [SyncRecordType: [String: Any]] = [:]

    /// Inject a record to be returned by fetch (for tests).
    func seedRecord(type: SyncRecordType, payload: [String: Any]) {
        storedRecords[type] = payload
    }

    /// Simulate an error on next push/fetch (for resilience tests).
    var simulateError: Error? = nil

    func push(recordType: SyncRecordType, payload: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        if let error = simulateError {
            syncState = .error(error.localizedDescription)
            completion(.failure(error))
            return
        }
        syncState = .syncing
        pushedRecords.append((recordType, payload))
        storedRecords[recordType] = payload
        syncState = .idle
        completion(.success(()))
    }

    func fetch(recordType: SyncRecordType, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        if let error = simulateError {
            syncState = .error(error.localizedDescription)
            completion(.failure(error))
            return
        }
        syncState = .syncing
        let result = storedRecords[recordType] ?? [:]
        syncState = .idle
        completion(.success(result))
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
final class SyncCoordinator {

    private let sync: CloudSyncService
    private let progressStore: ProgressStoring
    private let streakStore: StreakStoring
    private(set) var lastSyncDate: Date?

    init(sync: CloudSyncService, progressStore: ProgressStoring, streakStore: StreakStoring) {
        self.sync = sync
        self.progressStore = progressStore
        self.streakStore = streakStore
    }

    var syncState: SyncState { sync.syncState }

    /// Push all local state to CloudKit.
    func pushAll(completion: @escaping (Result<Void, Error>) -> Void) {
        let progressPayload = buildProgressPayload()
        sync.push(recordType: .progress, payload: progressPayload) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success:
                let streakPayload = self.buildStreakPayload()
                self.sync.push(recordType: .streak, payload: streakPayload) { [weak self] r in
                    if case .success = r { self?.lastSyncDate = Date() }
                    completion(r)
                }
            }
        }
    }

    // MARK: Private

    private func buildProgressPayload() -> [String: Any] {
        let entries = progressStore.allProgress
        let mapped = entries.map { k, v in ["letter": k, "completions": v.completionCount, "bestAccuracy": v.bestAccuracy] }
        return ["entries": mapped,
                "timestamp": ISO8601DateFormatter().string(from: Date())]
    }

    private func buildStreakPayload() -> [String: Any] {
        ["currentStreak": streakStore.currentStreak,
         "longestStreak": streakStore.longestStreak,
         "totalCompletions": streakStore.totalCompletions,
         "timestamp": ISO8601DateFormatter().string(from: Date())]
    }
}
