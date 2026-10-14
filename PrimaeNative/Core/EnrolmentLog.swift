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
    /// The session's comparison stamp at enrolment
    /// (`StudyComparisonConfiguration.nonDefaultStamp`; nil = every switch
    /// at its default, the pilot) — R-017, audit 2026-10-13: a zero-row
    /// dropout's configuration was otherwise unknown.
    var comparisonConfiguration: String?
    /// The voice the session speaks with at enrolment (R-021); nil when
    /// none.
    var voiceId: String?
    /// The device and audio state at enrolment (R-020, R-018).
    var environment: EnvironmentStamp?
    /// The binary and launch that enrolled the child (R-020).
    var build: BuildStamp?

    init(participantId: UUID, enrolledAt: Date?, audioCondition: PilotAudioCondition,
         trainedSubset: String, protocolRevision: Int,
         comparisonConfiguration: String? = nil, voiceId: String? = nil,
         environment: EnvironmentStamp? = nil, build: BuildStamp? = nil) {
        self.participantId = participantId
        self.enrolledAt = enrolledAt
        self.audioCondition = audioCondition
        self.trainedSubset = trainedSubset
        self.protocolRevision = protocolRevision
        self.comparisonConfiguration = comparisonConfiguration
        self.voiceId = voiceId
        self.environment = environment
        self.build = build
    }

    /// The five original fields decode strictly, as before; the batch-D
    /// additions lossily, so a file written before them — or one with a
    /// malformed addition — still decodes and keeps its enrolment in the
    /// export.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        participantId = try c.decode(UUID.self, forKey: .participantId)
        enrolledAt = try c.decodeIfPresent(Date.self, forKey: .enrolledAt)
        audioCondition = try c.decode(PilotAudioCondition.self, forKey: .audioCondition)
        trainedSubset = try c.decode(String.self, forKey: .trainedSubset)
        protocolRevision = try c.decode(Int.self, forKey: .protocolRevision)
        comparisonConfiguration = try? c.decode(String.self, forKey: .comparisonConfiguration)
        voiceId = try? c.decode(String.self, forKey: .voiceId)
        environment = try? c.decode(EnvironmentStamp.self, forKey: .environment)
        build = try? c.decode(BuildStamp.self, forKey: .build)
    }
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

    /// See `JSONProgressStore.failureCenter`.
    private let failureCenter: PersistenceFailureCenter

    init(directoryURL: URL? = nil, failureCenter: PersistenceFailureCenter = .shared) {
        self.failureCenter = failureCenter
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
        self.enrolments = Self.loadAll(from: self.directoryURL, center: failureCenter).sorted(by: Self.oldestFirst)
    }

    func append(_ record: EnrolmentRecord) {
        enrolments.removeAll { $0.participantId == record.participantId }
        enrolments.append(record)
        enrolments.sort(by: Self.oldestFirst)

        // An encode failure is a lost enrolment record — reported, not
        // just logged (R-053); kept in memory for this session only.
        guard let data = StoreCoding.encode(record, store: "EnrolmentLog", center: failureCenter) else { return }
        let center = failureCenter
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
                center.reportFailure(store: "EnrolmentLog", error: error)
            }
        }
    }

    func flush() async {
        for task in pendingSaves.values { await task.value }
    }

    private static func oldestFirst(_ a: EnrolmentRecord, _ b: EnrolmentRecord) -> Bool {
        (a.enrolledAt ?? .distantPast) < (b.enrolledAt ?? .distantPast)
    }

    /// An enrolment file that cannot be read or decoded used to be dropped
    /// with no log line and no copy (R-055): that child's enrolment then
    /// vanished from the export's enrolment block. Now it is moved aside
    /// (undecodable) or left in place (unreadable) and reported as a notice.
    private static func loadAll(from directory: URL,
                                center: PersistenceFailureCenter) -> [EnrolmentRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        var out: [EnrolmentRecord] = []
        var setAsideEarlier = 0
        for url in files where url.pathExtension == "json" {
            // See `JSONParticipantArchiveStore.loadAll`: never re-processed,
            // still counted.
            if url.lastPathComponent.contains(StoreFileQuarantine.setAsideMarker) {
                setAsideEarlier += 1
                continue
            }
            switch StoreFileQuarantine.read(url) {
            case .missing:
                continue
            case .unreadable(let error):
                center.reportNotice(store: "EnrolmentLog",
                                    message: "\(url.lastPathComponent) could not be read (\(error.localizedDescription)) — that enrolment is NOT in the export")
            case .data(let data):
                if let record = try? StoreCoding.decoder().decode(EnrolmentRecord.self, from: data) {
                    out.append(record)
                } else {
                    let dest = StoreFileQuarantine.quarantine(url)
                    center.reportNotice(store: "EnrolmentLog",
                                        message: "\(url.lastPathComponent) was undecodable and \(dest.map { "moved aside to \($0.lastPathComponent)" } ?? "could NOT be moved aside") — that enrolment is NOT in the export")
                }
            }
        }
        if setAsideEarlier > 0 {
            center.reportNotice(store: "EnrolmentLog",
                                message: "\(setAsideEarlier) enrolment file(s) set aside earlier (\(StoreFileQuarantine.setAsideMarker)…) — those enrolments are NOT in the export")
        }
        return out
    }
}
