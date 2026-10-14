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
    /// NOT unique since the archive became append-only (R-047): a
    /// restored participant has one record per sealed session.
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

extension ArchivedParticipant {
    /// Component-wise (R-055, audit 2026-10-13). The synthesized decode was
    /// all-or-nothing over the snapshot, `[String: LetterProgress]` and
    /// `[RawTrace]`: ONE malformed trace or progress entry — or a field a
    /// later build adds to either type — quarantined the whole child, who
    /// then silently vanished from `all<N>`. Now a bad element costs only
    /// itself and is counted (`StoreDecodeTally`) so the load can say so.
    /// The identity fields stay strict: without them there is no child.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        participantId = try c.decode(UUID.self, forKey: .participantId)
        enrolledAt = try c.decodeIfPresent(Date.self, forKey: .enrolledAt)
        archivedAt = try c.decode(Date.self, forKey: .archivedAt)
        snapshot = try c.decode(DashboardSnapshot.self, forKey: .snapshot)
        let progress = try c.decode(LossyDictionary<LetterProgress>.self, forKey: .progress)
        self.progress = progress.elements
        let traces = try c.decode(LossyArray<RawTrace>.self, forKey: .rawTraces)
        rawTraces = traces.elements
        decoder.storeDecodeTally?.record(progress.droppedCount, of: "progress")
        decoder.storeDecodeTally?.record(traces.droppedCount, of: "rawTraces")
    }
}

@MainActor
protocol ParticipantArchiving {
    /// Seals `record` to durable storage. APPEND-ONLY (audit 2026-10-13,
    /// R-047): a participant sealed twice — training day, then the delayed
    /// session after "Teilnehmer wiederherstellen" — has two records, and
    /// no seal ever replaces or removes an earlier one. Until then the
    /// store was keyed by id and the second seal destroyed the first.
    ///
    /// SYNCHRONOUS AND THROWING (audit 2026-10-13, R-050): when this
    /// returns, the record is on disk and has been read back; when it
    /// throws, nothing about the outgoing child may be wiped. The caller
    /// (`resetForNewParticipant`) wipes the live stores only after a
    /// successful return — the seal used to be an in-memory append plus a
    /// detached write, raced by the synchronous resets that followed it.
    func archive(_ record: ArchivedParticipant) throws
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

/// Why a seal did not happen. Thrown by `archive(_:)`.
enum ParticipantArchiveError: Error, Equatable {
    /// The file was written but did not read back as this child's record.
    case verificationFailed
}

/// JSON-backed implementation: one file per participant under
/// `ParticipantArchive/`, so a corrupt or partially-written file for one
/// child can never cost another child's already-sealed record — the
/// single-shared-file failure mode the other stores accept for CURRENT
/// data (one bad decode zeroes the whole store) is not acceptable for a
/// permanent multi-child archive.
///
/// The write is synchronous on the main actor (R-050): once per child,
/// at the moment the proctor confirms "Nächstes Kind", which is the one
/// place a blocking write is worth its cost. The in-memory array is
/// updated only after the file has been written AND read back, so it
/// never claims a seal the disk does not hold.
final class JSONParticipantArchiveStore: ParticipantArchiving {

    private let directoryURL: URL
    private(set) var archivedParticipants: [ArchivedParticipant]

    /// See `JSONProgressStore.failureCenter`.
    private let failureCenter: PersistenceFailureCenter

    /// How the staged bytes reach the disk. Production writes them as
    /// given; a test injects a writer that corrupts them, which is the only
    /// way to prove the read-back verification in `archive(_:)` is
    /// load-bearing (review 2026-10-14, item 5).
    typealias StagedWriter = (Data, URL) throws -> Void
    private let writeStaged: StagedWriter

    init(directoryURL: URL? = nil,
         failureCenter: PersistenceFailureCenter = .shared,
         writeStaged: @escaping StagedWriter = { try $0.write(to: $1, options: .atomic) }) {
        self.failureCenter = failureCenter
        self.writeStaged = writeStaged
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
        Self.removeStaleStagingFiles(in: self.directoryURL, olderThan: Date())
        self.archivedParticipants = Self.loadAll(from: self.directoryURL, center: failureCenter)
            .sorted { ($0.enrolledAt ?? .distantPast) < ($1.enrolledAt ?? .distantPast) }
    }

    func archive(_ record: ArchivedParticipant) throws {
        let url = newFileURL(for: record)
        // Written under a name the loader ignores (`loadAll` reads only
        // `.json`), verified there, and only then moved to its final name.
        // `moveItem` refuses an existing destination, so this can never
        // overwrite a seal; a record that fails verification never becomes
        // visible, and its leftover `.sealing` file is inert.
        let staging = url.appendingPathExtension("sealing")
        do {
            // StoreCoding (R-053): a non-finite value is written as "NaN"
            // instead of throwing. With the plain coder one NaN anywhere in
            // the child's record made every seal throw, so "Nächstes Kind"
            // was refused for the rest of the session.
            let data = try StoreCoding.encoder().encode(record)
            try writeStaged(data, staging)
            // Read it back: the seal counts only once the disk holds THIS
            // child's record with every row, not merely once a write call
            // returned. The read-back uses the loader's own lossy decode
            // (R-055), so it must also have dropped nothing.
            let tally = StoreDecodeTally()
            let readBack = try StoreCoding.decoder(tally: tally).decode(
                ArchivedParticipant.self, from: Data(contentsOf: staging))
            guard tally.dropped.isEmpty,
                  readBack.participantId == record.participantId,
                  readBack.snapshot.phaseSessionRecords.count == record.snapshot.phaseSessionRecords.count,
                  readBack.snapshot.sessionDurations.count == record.snapshot.sessionDurations.count,
                  readBack.progress.count == record.progress.count,
                  readBack.rawTraces.count == record.rawTraces.count
            else { throw ParticipantArchiveError.verificationFailed }
            try FileManager.default.moveItem(at: staging, to: url)
        } catch {
            // A staged file that failed verification (or whose move failed)
            // is removed here; only a crash mid-seal can leave one behind.
            try? FileManager.default.removeItem(at: staging)
            // A NOTICE, not a failure: the caller keeps the live stores, so
            // nothing is lost — the child is still on the device, un-wiped.
            // `reportFailure` would hard-stop the live child's session for a
            // write that cost nothing.
            failureCenter.reportNotice(
                store: "ParticipantArchiveStore",
                message: "seal of \(record.participantId.uuidString) failed (\(error.localizedDescription)) — NOT sealed; that child stays live, nothing was wiped")
            storePersistenceLogger.error(
                "ParticipantArchiveStore seal failed for \(record.participantId.uuidString, privacy: .public) at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public) — NOT sealed; the live stores are kept.")
            throw error
        }
        archivedParticipants.append(record)
        archivedParticipants.sort { ($0.enrolledAt ?? .distantPast) < ($1.enrolledAt ?? .distantPast) }
    }

    // MARK: Private

    /// A file name no existing seal uses: `<uuid>_<archivedAt ms>.json`,
    /// suffixed `-2`, `-3`, … if that is taken. Never an existing file, so
    /// a write here can only ever ADD a seal. Files sealed before this
    /// change are named `<uuid>.json`; `loadAll` reads every `.json` in
    /// the directory, so they load exactly as before.
    private func newFileURL(for record: ArchivedParticipant) -> URL {
        let stem = "\(record.participantId.uuidString)_\(Int64((record.archivedAt.timeIntervalSince1970 * 1000).rounded()))"
        var url = directoryURL.appendingPathComponent("\(stem).json")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directoryURL.appendingPathComponent("\(stem)-\(n).json")
            n += 1
        }
        return url
    }

    /// A `.json.sealing` file left behind is a seal that never finished:
    /// the process died between the staged write and the rename (a seal
    /// the read-back refused removes its own staging file). `loadAll`
    /// already ignores it, so it is inert but accumulates. Removed at
    /// launch, ONE file at a time (never a
    /// directory), and only when ALL of these hold: a regular file, a name
    /// ending in `.json.sealing`, and last modified before this launch — so
    /// a real seal (`.json`) and anything else in the directory are never
    /// touched, and neither is a staging file a concurrent seal could still
    /// be writing.
    private static func removeStaleStagingFiles(in directoryURL: URL, olderThan launch: Date) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? fm.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: keys
        ) else { return }
        for url in urls where url.lastPathComponent.hasSuffix(".json.sealing") {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < launch
            else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// One file per child; every file is read on its own, so one that
    /// cannot be read or decoded never hides the others. Each such file is
    /// reported to the failure center as a notice (R-055) — it is a child
    /// MISSING from the next combined export, which the proctor must know
    /// before handing the export over.
    private static func loadAll(from directoryURL: URL,
                                center: PersistenceFailureCenter) -> [ArchivedParticipant] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL, includingPropertiesForKeys: nil)) ?? []
        var out: [ArchivedParticipant] = []
        var setAsideEarlier = 0
        for url in files where url.pathExtension == "json" {
            // Already set aside on an earlier launch: not re-read, not
            // moved again — but still counted below, so the proctor sees
            // the missing child on every launch, not only the first.
            if url.lastPathComponent.contains(StoreFileQuarantine.setAsideMarker) {
                setAsideEarlier += 1
                continue
            }
            let data: Data
            switch StoreFileQuarantine.read(url) {
            case .missing: continue
            case .unreadable(let error):
                center.reportNotice(store: "ParticipantArchiveStore",
                                    message: "\(url.lastPathComponent) could not be read (\(error.localizedDescription)) — that child is NOT in the export")
                continue
            case .data(let bytes): data = bytes
            }
            let tally = StoreDecodeTally()
            if let record = try? StoreCoding.decoder(tally: tally).decode(ArchivedParticipant.self, from: data) {
                out.append(record)
                if !tally.dropped.isEmpty {
                    center.reportNotice(store: "ParticipantArchiveStore",
                                        message: "\(url.lastPathComponent): dropped undecodable \(tally.dropped.joined(separator: ", ")); the rest of that child loaded")
                }
            } else {
                storePersistenceLogger.error(
                    "ParticipantArchiveStore: \(url.path, privacy: .public) exists but failed to decode — moved aside, excluded from the next export.")
                let dest = StoreFileQuarantine.quarantine(url)
                center.reportNotice(store: "ParticipantArchiveStore",
                                    message: "\(url.lastPathComponent) was undecodable and \(dest.map { "moved aside to \($0.lastPathComponent)" } ?? "could NOT be moved aside") — that child is NOT in the export")
            }
        }
        if setAsideEarlier > 0 {
            center.reportNotice(store: "ParticipantArchiveStore",
                                message: "\(setAsideEarlier) archive file(s) set aside earlier (\(StoreFileQuarantine.setAsideMarker)…) — those children are NOT in the export")
        }
        return out
    }
}
