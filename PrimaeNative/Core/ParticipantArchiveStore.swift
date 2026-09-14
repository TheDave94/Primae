// ParticipantArchiveStore.swift
// PrimaeNative
//
// Sealed, durable copy of one participant's complete on-device record,
// written BEFORE `resetForNewParticipant()` wipes the live stores for
// the next child (2026-09-14). Until this existed, "Neuer Teilnehmer"
// destroyed the outgoing participant's rows unconditionally
// (dashboardStore.reset() / progressStore.resetAll() / streakStore.reset()
// / rawTraceStore.reset()) with no on-device copy surviving except an
// export the proctor might not have completed saving — a data-loss
// defect with no error surfaced, confirmed by driving the reset and
// checking what remained. A kindergarten pilot enrolling several
// children in one sitting, one proctor, one iPad, needs every prior
// child's rows to still be there — and still attributable to the right
// participant — when the end-of-session combined export finally runs.

import Foundation

/// One participant's complete outgoing record, sealed at the moment
/// `resetForNewParticipant()` runs for the NEXT child. Self-contained:
/// everything `ParentDashboardExporter` needs to reproduce that
/// participant's per-row CSV/JSON output stand-alone, without the live
/// stores that produced it.
struct ArchivedParticipant: Codable, Identifiable, Equatable {
    var id: UUID { participantId }
    let participantId: UUID
    let enrolledAt: Date?
    /// Wall-clock instant this record was sealed — i.e. when the NEXT
    /// participant was enrolled. Distinct from `enrolledAt`.
    let archivedAt: Date
    let snapshot: DashboardSnapshot
    let progress: [String: LetterProgress]
    let rawTraces: [RawTrace]
}

@MainActor
protocol ParticipantArchiving {
    /// Seals `record` to durable storage, keyed by `participantId`.
    /// Re-sealing the same id (an idempotent retry) replaces rather than
    /// duplicates.
    func archive(_ record: ArchivedParticipant)
    /// Every sealed participant on this device, oldest `enrolledAt`
    /// first (a nil `enrolledAt` — never-enrolled edge case — sorts
    /// last). Reads the in-memory record, not disk, so a participant
    /// archived a moment ago is visible immediately even if its
    /// background write hasn't landed yet — see `flush()`.
    var archivedParticipants: [ArchivedParticipant] { get }
    /// Await every pending background write. See ProgressStoring.flush().
    func flush() async
}

extension ParticipantArchiving {
    func flush() async {}
}

/// JSON-backed implementation: one file per participant under
/// `ParticipantArchive/`, so a corrupt or partially-written file for one
/// child can never cost another child's already-sealed record — the
/// single-shared-file failure mode the other stores accept for CURRENT
/// data (one bad decode zeroes the whole store) is not acceptable for a
/// permanent multi-child archive. Mirrors `JSONRawTraceStore`'s pattern:
/// the in-memory array is the source of truth for reads, updated
/// synchronously in `archive()`; the detached task only handles disk
/// durability, so `archivedParticipants` is never racing its own write.
final class JSONParticipantArchiveStore: ParticipantArchiving {

    private let directoryURL: URL
    private(set) var archivedParticipants: [ArchivedParticipant]
    private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    init(directoryURL: URL? = nil) {
        if let url = directoryURL {
            self.directoryURL = url
        } else {
            // See ProgressStore.init for the `??` fallback rationale.
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directoryURL = support
                .appendingPathComponent("PrimaeNative", isDirectory: true)
                .appendingPathComponent("ParticipantArchive", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
        self.archivedParticipants = Self.loadAll(from: self.directoryURL)
            .sorted { ($0.enrolledAt ?? .distantPast) < ($1.enrolledAt ?? .distantPast) }
    }

    func archive(_ record: ArchivedParticipant) {
        archivedParticipants.removeAll { $0.participantId == record.participantId }
        archivedParticipants.append(record)
        archivedParticipants.sort { ($0.enrolledAt ?? .distantPast) < ($1.enrolledAt ?? .distantPast) }

        guard let data = try? JSONEncoder().encode(record) else {
            storePersistenceLogger.warning(
                "ParticipantArchiveStore encode failed for \(record.participantId.uuidString, privacy: .public) — kept in memory for this session only, NOT durably sealed to disk.")
            return
        }
        let url = fileURL(for: record.participantId)
        let previous = pendingSaves[record.participantId]
        previous?.cancel()
        pendingSaves[record.participantId] = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                storePersistenceLogger.error(
                    "ParticipantArchiveStore disk write failed for \(record.participantId.uuidString, privacy: .public) at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public) — sealed only in memory this session; do not quit the app before this is retried.")
            }
        }
    }

    func flush() async {
        for task in pendingSaves.values { await task.value }
    }

    // MARK: Private

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private static func loadAll(from directoryURL: URL) -> [ArchivedParticipant] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        var out: [ArchivedParticipant] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            if let record = try? JSONDecoder().decode(ArchivedParticipant.self, from: data) {
                out.append(record)
            } else {
                storePersistenceLogger.error(
                    "ParticipantArchiveStore: \(url.path, privacy: .public) exists but failed to decode — moved aside, excluded from the next export.")
                StoreFileQuarantine.quarantine(url)
            }
        }
        return out
    }
}
