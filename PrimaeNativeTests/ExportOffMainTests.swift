// ExportOffMainTests.swift
// R-086. At 40 children the combined JSON export held the main actor for
// 8.3 s on the iPad (`ExportScaleMeasurementTests`), freezing the export
// screen. The proctor's export now runs through
// `ParentDashboardExporter.combinedExportForSharingOffMain`: the content is
// fixed on the main actor, the JSON encode and the file writes run in a
// detached task. These tests pin the two things that change must not get
// wrong: the bytes are the synchronous path's, and the slow half really
// does not need the main actor.

import Foundation
import Testing
@testable import PrimaeNative

@MainActor
@Suite(.serialized)
struct ExportOffMainTests {

    private func scratchLocations(_ label: String) throws -> (ExportFileRetention.Locations, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("r086-\(label)-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (.standard(applicationSupport: support, temporary: tmp), root)
    }

    /// `primae_progress_ALL_<date>_<time>_all<N>.<ext>` without the
    /// `<date>_<time>` part, which depends on the second each call ran in.
    private func nameWithoutTimestamp(_ url: URL) -> String {
        let parts = url.lastPathComponent.components(separatedBy: "_")
        return (parts.prefix(3) + parts.suffix(1)).joined(separator: "_")
    }

    @Test("the off-main export writes the synchronous export's bytes, in every format")
    func offMainExportIsByteIdenticalToTheSynchronousOne() async throws {
        let participants = GoldenExportFixture.participants()
        let enrolments = GoldenExportFixture.enrolments()
        let lost = ArchiveSetAside(fileName: "\(GoldenExportFixture.p3.uuidString)-lost.json")
        for format in [DashboardExportFormat.csv, .tsv, .json] {
            let (syncLoc, syncRoot) = try scratchLocations("sync")
            let (asyncLoc, asyncRoot) = try scratchLocations("async")
            defer {
                try? FileManager.default.removeItem(at: syncRoot)
                try? FileManager.default.removeItem(at: asyncRoot)
            }
            let syncURL = try ParentDashboardExporter.combinedExportForSharing(
                participants: participants, enrolments: enrolments, setAside: [lost],
                format: format, locations: syncLoc)
            let asyncURL = try await ParentDashboardExporter.combinedExportForSharingOffMain(
                participants: participants, enrolments: enrolments, setAside: [lost],
                format: format, locations: asyncLoc)

            let syncBytes = try Data(contentsOf: syncURL)
            let asyncBytes = try Data(contentsOf: asyncURL)
            #expect(!syncBytes.isEmpty, "\(format): the synchronous export wrote nothing")
            #expect(asyncBytes == syncBytes, "\(format): off-main bytes differ from the synchronous export")
            #expect(nameWithoutTimestamp(asyncURL) == nameWithoutTimestamp(syncURL),
                    "\(format): \(asyncURL.lastPathComponent) vs \(syncURL.lastPathComponent)")
            #expect(asyncURL.lastPathComponent.hasPrefix("primae_progress_ALL_"))
            #expect(asyncURL.deletingLastPathComponent().standardizedFileURL
                    == asyncLoc.temporaryDirectory.standardizedFileURL, "\(format): the share copy is in tmp/")
            let retained = asyncLoc.retainDirectory.appendingPathComponent(asyncURL.lastPathComponent)
            #expect(try Data(contentsOf: retained) == asyncBytes, "\(format): retained copy differs")
        }
    }

    @Test("the JSON encode and both file writes finish while the main actor is blocked")
    func encodeAndWriteDoNotNeedTheMainActor() async throws {
        let (loc, root) = try scratchLocations("blocked")
        defer { try? FileManager.default.removeItem(at: root) }
        let participants = GoldenExportFixture.participants()

        let export = Task { @MainActor in
            try await ParentDashboardExporter.combinedExportForSharingOffMain(
                participants: participants, format: .json, locations: loc)
        }
        // The main executor is FIFO: the export task was enqueued first, so
        // its main-actor part (the content) has run when this resumes.
        await Task.yield()

        // Block the main actor and wait for the retained copy, the last
        // thing the export writes. Work that needs the main actor cannot
        // run until this loop ends, so the file can only appear if the
        // encode and the writes run elsewhere. The bound is a liveness
        // limit for the failing case, not a performance threshold.
        let deadline = Date().addingTimeInterval(30)
        var retainedWhileBlocked = false
        while Date() < deadline {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: loc.retainDirectory.path)) ?? []
            if names.contains(where: { $0.hasSuffix(".json") }) { retainedWhileBlocked = true; break }
            usleep(10_000)
        }
        #expect(retainedWhileBlocked, "the export did not finish while the main actor was blocked")

        let url = try await export.value
        #expect(try Data(contentsOf: url) == ParentDashboardExporter.combinedJSONData(participants: participants))
    }
}
