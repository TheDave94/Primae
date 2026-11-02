// ExportMembershipTests.swift
//
// Pins for fix lane L9 (2026-11-02, protocol r16):
//   B3  (round-1 DATA-1)     rows are stamped with the enrolment id and the
//                            export selects a child's rows by membership, so
//                            a backwards clock correction loses nothing;
//                            `# droppedPreEnrolmentRows=` counts the rest.
//   B4  (round-1 DATA-8)     an archive file set aside as undecodable is
//                            named in the export (`# setAside=`).
//   B22 (round-2 VERIFY-14)  the export action records a finished free-
//                            writing trial the parent area holds unscored
//                            (`finalizedBy: "export"`).
// Each must go RED when its fix is reverted. No test writes global state.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

private func scratch(_ tag: String) -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("L9-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

/// Phase rows of a combined CSV, per participant block, by the `letter,phase`
/// header (data rows only; the per-arm section has another header).
private func phaseRowCount(_ csv: String) -> Int {
    var inPhase = false
    var n = 0
    for line in csv.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("letter,phase,") { inPhase = true; continue }
        if line.isEmpty || line.hasPrefix("#") { inPhase = false; continue }
        if inPhase { n += 1 }
    }
    return n
}

private func durationRowCount(_ csv: String) -> Int {
    var inSection = false
    var n = 0
    for line in csv.split(separator: "\n", omittingEmptySubsequences: false) {
        if line.hasPrefix("date,recordedAt,") { inSection = true; continue }
        if line.isEmpty || line.hasPrefix("#") { inSection = false; continue }
        if inSection { n += 1 }
    }
    return n
}

private func headerValue(_ csv: String, _ key: String) -> String? {
    csv.split(separator: "\n").first { $0.hasPrefix("# \(key)=") }
        .map { String($0.dropFirst("# \(key)=".count)) }
}

private func row(_ phase: String, at date: Date, enrolment: UUID?, trace: UUID? = nil) -> PhaseSessionRecord {
    var r = PhaseSessionRecord(letter: "F", phase: phase, completed: true, score: 0.8,
                               schedulerPriority: 0, recordedAt: date, rawTraceID: trace, rowId: UUID())
    r.enrolmentId = enrolment
    return r
}

private func duration(at date: Date, enrolment: UUID?) -> SessionDurationRecord {
    SessionDurationRecord(dateString: "2026-10-26", durationSeconds: 30, recordedAt: date,
                          letter: "F", rowId: UUID(), enrolmentId: enrolment)
}

// MARK: - B3

@MainActor
struct EnrolmentMembershipExportTests {

    static let enrolledAt = Date(timeIntervalSince1970: 1_793_000_000)

    @Test("B3: rows a child wrote after a backwards clock correction are all exported, CSV and JSON")
    func clockBackwardsRowsSurvive() throws {
        let id = UUID()
        var snap = DashboardSnapshot()
        // Written under this enrolment, but the clock was put back 1 h.
        for (k, phase) in ["observe", "direct", "guided", "freeWrite"].enumerated() {
            snap.phaseSessionRecords.append(row(phase, at: Self.enrolledAt.addingTimeInterval(-3600 + Double(k) * 30), enrolment: id))
        }
        snap.sessionDurations.append(duration(at: Self.enrolledAt.addingTimeInterval(-3500), enrolment: id))
        let src = ParticipantExportSource(snapshot: snap, participantId: id, progress: [:], rawTraces: [], enrolledAt: Self.enrolledAt)
        let csv = String(decoding: ParentDashboardExporter.combinedDelimitedData(participants: [src], separator: ","), as: UTF8.self)
        #expect(phaseRowCount(csv) == 4, "CSV kept \(phaseRowCount(csv)) of 4 phase rows")
        #expect(durationRowCount(csv) == 1, "CSV kept \(durationRowCount(csv)) of 1 duration row")
        #expect(headerValue(csv, "droppedPreEnrolmentRows") == "0")
        let json = try ParentDashboardExporter.combinedJSONData(participants: [src])
        let obj = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]]).first
        #expect((obj?["phaseSessionRecords"] as? [Any])?.count == 4)
        #expect((obj?["sessionDurations"] as? [Any])?.count == 1)
        #expect(obj?["droppedPreEnrolmentRows"] as? Int == 0)
    }

    @Test("B3: another enrolment's rows and unstamped pre-enrolment rows are dropped and counted; unstamped rows keep the time rule")
    func foreignAndLegacyRows() throws {
        let id = UUID(), other = UUID()
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [
            row("guided", at: Self.enrolledAt.addingTimeInterval(60), enrolment: id),        // kept
            row("guided", at: Self.enrolledAt.addingTimeInterval(120), enrolment: other),    // dropped: other child
            row("guided", at: Self.enrolledAt.addingTimeInterval(-60), enrolment: nil),      // dropped: legacy, before
            row("freeWrite", at: Self.enrolledAt.addingTimeInterval(180), enrolment: nil),   // kept: legacy, after
        ]
        snap.sessionDurations = [
            duration(at: Self.enrolledAt.addingTimeInterval(60), enrolment: id),             // kept
            duration(at: Self.enrolledAt.addingTimeInterval(90), enrolment: other),          // dropped
        ]
        let src = ParticipantExportSource(snapshot: snap, participantId: id, progress: [:], rawTraces: [], enrolledAt: Self.enrolledAt)
        let csv = String(decoding: ParentDashboardExporter.combinedDelimitedData(participants: [src], separator: ","), as: UTF8.self)
        #expect(phaseRowCount(csv) == 2)
        #expect(durationRowCount(csv) == 1)
        #expect(headerValue(csv, "droppedPreEnrolmentRows") == "3")
        let json = try ParentDashboardExporter.combinedJSONData(participants: [src])
        let obj = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]]).first
        #expect((obj?["phaseSessionRecords"] as? [Any])?.count == 2)
        #expect(obj?["droppedPreEnrolmentRows"] as? Int == 3)
    }

    @Test("B3: a raw trace dated before enrolledAt is kept in the JSON when an exported row links to it")
    func linkedTraceSurvives() throws {
        let id = UUID(), traceID = UUID()
        let early = Self.enrolledAt.addingTimeInterval(-3600)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords = [row("freeWrite", at: early, enrolment: id, trace: traceID)]
        let trace = RawTrace(id: traceID, letter: "F", recordedAt: early,
                             points: [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 10)], timestamps: [0, 0.1],
                             forces: [0, 0], strokeStartIndices: [0], canvasSize: CGSize(width: 100, height: 100))
        let src = ParticipantExportSource(snapshot: snap, participantId: id, progress: [:], rawTraces: [trace], enrolledAt: Self.enrolledAt)
        let json = try ParentDashboardExporter.combinedJSONData(participants: [src])
        let obj = try #require(try JSONSerialization.jsonObject(with: json) as? [[String: Any]]).first
        #expect((obj?["rawTraces"] as? [Any])?.count == 1, "the linked trace was dropped while its row was kept")
    }

    @Test("B3: the store stamps each new phase and duration row with the injected enrolment, and the stamp persists")
    func storeStampsRows() throws {
        let dir = scratch("stamp"); defer { try? FileManager.default.removeItem(at: dir) }
        let x = UUID()
        let url = dir.appendingPathComponent("d.json")
        let store = JSONParentDashboardStore(fileURL: url, failureCenter: PersistenceFailureCenter(), enrolmentId: { x })
        store.recordPhaseSession(letter: "F", phase: "guided", completed: true, score: 0.5, schedulerPriority: 0,
                                 condition: .threePhase, assessment: nil, recognition: nil)
        store.recordSession(letter: "F", accuracy: 0.5, durationSeconds: 10, date: Date(), condition: .threePhase)
        #expect(store.snapshot.phaseSessionRecords.first?.enrolmentId == x)
        #expect(store.snapshot.sessionDurations.first?.enrolmentId == x)
        // Round trip through the store file.
        let data = try StoreCoding.encoder().encode(store.snapshot)
        let back = try StoreCoding.decoder().decode(DashboardSnapshot.self, from: data)
        #expect(back.phaseSessionRecords.first?.enrolmentId == x)
        #expect(back.sessionDurations.first?.enrolmentId == x)
        // A store built without a provider stamps nothing (time rule).
        let plain = JSONParentDashboardStore(fileURL: dir.appendingPathComponent("p.json"), failureCenter: PersistenceFailureCenter())
        plain.recordPhaseSession(letter: "F", phase: "guided", completed: true, score: 0.5, schedulerPriority: 0,
                                 condition: .threePhase, assessment: nil, recognition: nil)
        #expect(plain.snapshot.phaseSessionRecords.first?.enrolmentId == nil)
    }

    @Test("B3: rows written before r16 (no enrolmentId key) still decode, with no stamp")
    func legacyRowsDecode() throws {
        let phase = #"{"letter":"A","phase":"guided","completed":true,"score":0.7,"schedulerPriority":0,"recordedAt":0}"#
        let dur = #"{"dateString":"2026-10-26","durationSeconds":12,"condition":"threePhase","recordedAt":0}"#
        let p = try JSONDecoder().decode(PhaseSessionRecord.self, from: Data(phase.utf8))
        let d = try JSONDecoder().decode(SessionDurationRecord.self, from: Data(dur.utf8))
        #expect(p.enrolmentId == nil && d.enrolmentId == nil)
    }
}

// MARK: - B4

@MainActor
struct ArchiveSetAsideExportTests {

    @Test("B4: a child whose archive file is corrupt is named in the export as set aside, on this launch and later ones")
    func corruptArchiveIsNamed() throws {
        let dir = scratch("arch"); defer { try? FileManager.default.removeItem(at: dir) }
        let arch = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: PersistenceFailureCenter())
        let x = UUID(), t = Date(timeIntervalSince1970: 1_793_000_000)
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(letter: "F", phase: "freeWrite", completed: true, score: 0.6,
                                                           schedulerPriority: 0, recordedAt: t.addingTimeInterval(60)))
        try arch.archive(ArchivedParticipant(participantId: x, enrolledAt: t, archivedAt: t.addingTimeInterval(900),
                                             snapshot: snap, progress: [:], rawTraces: []))
        #expect(arch.setAsideArchiveFiles.isEmpty)
        let file = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        let bytes = try Data(contentsOf: file)
        try bytes.prefix(bytes.count / 2).write(to: file)   // truncated
        for launch in 1...2 {   // set aside now, then "earlier"
            let reloaded = JSONParticipantArchiveStore(directoryURL: dir, failureCenter: PersistenceFailureCenter())
            #expect(reloaded.archivedParticipants.isEmpty)
            let aside = try #require(reloaded.setAsideArchiveFiles.first, "launch \(launch): nothing listed as set aside")
            #expect(aside.participantId == x)
            #expect(aside.fileName.contains(StoreFileQuarantine.setAsideMarker))
            let enrol = [EnrolmentRecord(participantId: x, enrolledAt: t, audioCondition: .phoneme,
                                         trainedSubset: "AFI", protocolRevision: 15)]
            let csv = String(decoding: ParentDashboardExporter.combinedDelimitedData(
                participants: [], enrolments: enrol, setAside: reloaded.setAsideArchiveFiles, separator: ","), as: UTF8.self)
            #expect(csv.hasPrefix("# setAside=\(aside.fileName) participantId=\(x.uuidString)\n"),
                    "launch \(launch): \(csv.prefix(120))")
        }
    }

    @Test("B4: no set-aside file, no line; a file name without an id gives an empty id")
    func cleanExportAndUnnamedFile() {
        let src = ParticipantExportSource(snapshot: DashboardSnapshot(), participantId: UUID(), progress: [:], rawTraces: [], enrolledAt: nil)
        let csv = String(decoding: ParentDashboardExporter.combinedDelimitedData(participants: [src], separator: ","), as: UTF8.self)
        #expect(csv.hasPrefix("# participantId="))
        #expect(!csv.contains("# setAside="))
        let odd = ArchiveSetAside(fileName: "notes.undecodable-1.json")
        #expect(odd.participantId == nil)
        #expect(ParentDashboardExporter.setAsideLine(odd) == "# setAside=notes.undecodable-1.json participantId=")
    }
}

// MARK: - B22

/// An archive that reports one set-aside file, for the export-action test.
private final class SetAsideArchive: ParticipantArchiving {
    let archivedParticipants: [ArchivedParticipant] = []
    let setAsideArchiveFiles: [ArchiveSetAside]
    init(_ files: [ArchiveSetAside]) { setAsideArchiveFiles = files }
    func archive(_ record: ArchivedParticipant) {}
}

@MainActor
@Suite(.serialized)
struct ExportFinalizesHeldTrialTests {

    @Test("B22: exporting while the parent area holds a finished freeWrite records it first (finalizedBy export) and names set-aside files")
    func exportRecordsHeldTrial() throws {
        let dir = scratch("b22"); defer { try? FileManager.default.removeItem(at: dir) }
        let dash = JSONParentDashboardStore(fileURL: dir.appendingPathComponent("d.json"), failureCenter: PersistenceFailureCenter())
        let lost = ArchiveSetAside(fileName: "\(UUID().uuidString)_1.undecodable-2.json")
        let rig = LifecycleRig(arm: .phoneme) { deps in
            deps.dashboardStore = dash
            deps.participantArchive = SetAsideArchive([lost])
        }
        let vm = rig.vm
        vm.loadLetter(name: "A")
        vm.phaseController.resume(at: .freeWrite)
        var t: CFTimeInterval = 1000; var p = CGPoint(x: 50, y: 200)
        vm.beginTouch(at: p, t: t)
        for _ in 0..<12 { t += 0.01; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: rig.canvas) }
        vm.endTouch()                 // the 2.0 s quiet window is pending
        vm.parentAreaDidOpen()        // the proctor opens the parent area: window held
        #expect(!dash.snapshot.phaseSessionRecords.contains { $0.phase == "freeWrite" }, "precondition: no freeWrite row yet")

        let support = dir.appendingPathComponent("Application Support", isDirectory: true)
        let tmp = dir.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = try vm.makeResearchExport(format: .csv, locations: .standard(applicationSupport: support, temporary: tmp))

        let rows = dash.snapshot.phaseSessionRecords.filter { $0.phase == "freeWrite" }
        #expect(rows.count == 1, "the held trial has \(rows.count) freeWrite rows")
        #expect(rows.first?.finalizedBy == RowFinalization.export.rawValue)
        #expect(rows.first?.completed == true)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# setAside=\(lost.fileName) participantId=\(lost.participantId!.uuidString)"))
        // Nothing left to finalise: a second export records nothing more.
        #expect(vm.finalizeHeldTrialForExport() == false)
        vm.parentAreaDidClose()
        #expect(dash.snapshot.phaseSessionRecords.filter { $0.phase == "freeWrite" }.count == 1)
    }
}
