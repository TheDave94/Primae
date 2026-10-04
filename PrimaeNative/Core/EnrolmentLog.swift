// EnrolmentLog.swift
// PrimaeNative
//
// A record that a child was ENROLLED, written at the moment of enrolment
// and kept apart from every participant's data (2026-10-04).
//
// WHY A SEPARATE RECORD. `resetForNewParticipant` seals the outgoing
// child to `ParticipantArchive/` only when they did something — the
// phantom-participant fix (#21): a never-used participant used to be
// sealed as a complete, well-formed, zero-row archive, and the combined
// export counted it toward N and every per-arm denominator. The cost of
// that guard was that a child enrolled and then stopped before finishing
// a letter left NO trace at all — no id, no enrolment time, no arm — and
// the per-child safety export that would have kept one was removed in
// #22. Dropouts by arm are exactly what a pilot reports.
//
// So enrolment is logged here, unconditionally, and NEVER as a
// participant: these records are not `ArchivedParticipant`s, never enter
// `allParticipantExportSources`, never count toward `all<N>` or any
// aggregate, and reach the export only as their own trailing block
// (`ParentDashboardExporter.enrolmentBlock`). That is what keeps the
// phantom from coming back through this door.
//
// One file per enrolment under `Enrolments/`, for the same reason the
// participant archive uses one file per child: a corrupt or half-written
// file can then cost only itself.

import Foundation

struct EnrolmentRecord: Codable, Equatable {
    let participantId: UUID
    let enrolledAt: Date?
    /// The arm the child was assigned at enrolment.
    let audioCondition: PilotAudioCondition
    /// `TrainedLetterSubset.rawValue` assigned at enrolment.
    let trainedSubset: String
    /// `StudyProtocol.revision` of the build that enrolled the child.
    let protocolRevision: Int
}

@MainActor
protocol EnrolmentLogging {
    /// Appends `record` durably. Appending the same id again (an
    /// idempotent retry) replaces rather than duplicates.
    func append(_ record: EnrolmentRecord)
    /// Every enrolment on this device, oldest `enrolledAt` first.
    var enrolments: [EnrolmentRecord] { get }
    /// Await every pending background write.
    func flush() async
}

extension EnrolmentLogging {
    func flush() async {}
}

final class JSONEnrolmentLog: EnrolmentLogging {

    private let directoryURL: URL
    private(set) var enrolments: [EnrolmentRecord]
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
                .appendingPathComponent("Enrolments", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
        self.enrolments = Self.loadAll(from: self.directoryURL).sorted(by: Self.oldestFirst)
    }

    func append(_ record: EnrolmentRecord) {
        enrolments.removeAll { $0.participantId == record.participantId }
        enrolments.append(record)
        enrolments.sort(by: Self.oldestFirst)

        guard let data = try? JSONEncoder().encode(record) else {
            storePersistenceLogger.warning(
                "EnrolmentLog encode failed for \(record.participantId.uuidString, privacy: .public) — kept in memory for this session only.")
            return
        }
        let url = directoryURL.appendingPathComponent("\(record.participantId.uuidString).json")
        let previous = pendingSaves[record.participantId]
        previous?.cancel()
        pendingSaves[record.participantId] = Task.detached(priority: .utility) {
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                storePersistenceLogger.error(
                    "EnrolmentLog disk write failed for \(record.participantId.uuidString, privacy: .public) at \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                PersistenceFailureCenter.shared.reportFailure(store: "EnrolmentLog", error: error)
            }
        }
    }

    func flush() async {
        for task in pendingSaves.values { await task.value }
    }

    private static func oldestFirst(_ a: EnrolmentRecord, _ b: EnrolmentRecord) -> Bool {
        (a.enrolledAt ?? .distantPast) < (b.enrolledAt ?? .distantPast)
    }

    private static func loadAll(from directory: URL) -> [EnrolmentRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(EnrolmentRecord.self, from: data)
            }
    }
}
