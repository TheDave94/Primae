// ExportFileRetentionTests.swift
// PrimaeNativeTests
//
// R-062 (audit 2026-10-13): the research export's tmp/ copy is deleted when
// the share sheet finishes and swept at launch, after the same bytes were
// retained under Application Support/PrimaeNative/Exports/ for devicectl.
// Every test works in its own directory under tmp/; nothing touches the
// real Exports/ directory or the test host's tmp/ root.
//
// Mutation checks (break, confirm RED, restore — read the test count):
//   - retainedCopyHasTheSameBytesAndIsExcludedFromBackup: drop the
//     isExcludedFromBackup resource value in `retain`.
//   - onlyTheNewestRetainedExportsAreKept: skip the prune in `retain`.
//   - defaultRetentionKeepsFive: retainedCount = 50.
//   - justRetainedExportIsNeverPruned: prune without protecting the copy.
//   - pruningIsByModificationDate: sort by name only.
//   - launchSweepDeletesOnlyExportFiles: drop the prefix filter.
//   - sharingExportWritesTheShareFileAndARetainedCopy: skip the
//     `ExportFileRetention.retain` call.
//   - completedShareDeletesOnlyTheTmpCopy: the completion path also
//     deletes the retained copy; or no handler installed.
//   - cancelledShareKeepsTheTmpCopy: ignore `completed`.
//   - liveLocationsAreTheDocumentedRetrievalPath: rename "Exports"; or
//     give ActivitySheet a default other than `.live`.
//   - exportNameTagsIgnoreTheDeviceCalendar: use the device calendar.
//   - shareSheetExcludesLeakyTargetsButNotAirDrop: drop the
//     excludedActivityTypes assignment.

import Testing
import Foundation
import UIKit
@testable import PrimaeNative

@Suite @MainActor struct ExportFileRetentionTests {

    private func scratchDirectory(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("r062-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ text: String, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func participant() -> ParticipantExportSource {
        var snap = DashboardSnapshot()
        snap.phaseSessionRecords.append(PhaseSessionRecord(
            letter: "A", phase: "freeWrite", completed: true, score: 0.5,
            schedulerPriority: 0, recordedAt: Date(timeIntervalSince1970: 1_770_000_100)))
        return ParticipantExportSource(snapshot: snap, participantId: UUID(), progress: [:],
                                       rawTraces: [], enrolledAt: nil)
    }

    @Test("the retained copy carries the same bytes and is excluded from backup")
    func retainedCopyHasTheSameBytesAndIsExcludedFromBackup() throws {
        let tmp = try scratchDirectory("tmp")
        let keep = try scratchDirectory("keep").appendingPathComponent("Exports", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: keep.deletingLastPathComponent())
        }
        let source = try write("letter,phase\nA,freeWrite\n",
                               named: "primae_progress_ALL_2026-10-14_101500_all2.csv", in: tmp)

        let copy = try ExportFileRetention.retain(source, in: keep)

        #expect(copy.deletingLastPathComponent().standardizedFileURL == keep.standardizedFileURL)
        #expect(copy.lastPathComponent == source.lastPathComponent)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
        #expect(try copy.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(try keep.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(FileManager.default.fileExists(atPath: source.path), "retain copies, it does not move")
    }

    @Test("only the newest retained exports are kept")
    func onlyTheNewestRetainedExportsAreKept() throws {
        let tmp = try scratchDirectory("tmp")
        let keep = try scratchDirectory("keep")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: keep)
        }
        let names = (1...7).map { "primae_progress_ALL_2026-10-0\($0)_120000_all1.csv" }
        for name in names {
            try ExportFileRetention.retain(try write(name, named: name, in: tmp), in: keep, keep: 5)
        }
        let unrelated = try write("x", named: "notes.txt", in: keep)

        let kept = try FileManager.default.contentsOfDirectory(atPath: keep.path)
            .filter { $0.hasPrefix("primae_progress_") }.sorted()
        #expect(kept == Array(names.suffix(5)), "kept: \(kept)")
        #expect(FileManager.default.fileExists(atPath: unrelated.path), "pruning touches exports only")
    }

    @Test("the launch sweep deletes export files and nothing else")
    func launchSweepDeletesOnlyExportFiles() throws {
        let tmp = try scratchDirectory("sweep")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = try write("a", named: "primae_progress_ALL_2026-10-14_101500_all2.json", in: tmp)
        let b = try write("b", named: "primae_progress_2026-10-14_101500_ABCDEF12.csv", in: tmp)
        let other = try write("c", named: "enrolment-export.csv", in: tmp)
        let dir = tmp.appendingPathComponent("primae_progress_folder", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        ExportFileRetention.sweepTemporaryExports(in: tmp)

        #expect(!FileManager.default.fileExists(atPath: a.path))
        #expect(!FileManager.default.fileExists(atPath: b.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: dir.path), "never a recursive delete")
    }

    /// Scratch locations built by the SAME composition the app uses
    /// (`Locations.standard`), so the real wiring is exercised without
    /// touching the test host's Application Support or tmp/ root.
    private func scratchLocations() throws -> (ExportFileRetention.Locations, URL) {
        let root = try scratchDirectory("loc")
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let tmp = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (.standard(applicationSupport: support, temporary: tmp), root)
    }

    @Test("the export action writes the share file and a byte-identical retained copy")
    func sharingExportWritesTheShareFileAndARetainedCopy() throws {
        let (loc, root) = try scratchLocations()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try ParentDashboardExporter.combinedExportForSharing(
            participants: [participant()], format: .csv, locations: loc)

        #expect(url.deletingLastPathComponent().standardizedFileURL
                == loc.temporaryDirectory.standardizedFileURL, "the share sheet gets the tmp/ copy")
        let retained = loc.retainDirectory.appendingPathComponent(url.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: retained.path),
                "the devicectl copy must exist before the tmp/ copy can be deleted")
        #expect(try Data(contentsOf: retained) == Data(contentsOf: url))
    }

    @Test("a COMPLETED share deletes the tmp copy and leaves the retained one")
    func completedShareDeletesOnlyTheTmpCopy() throws {
        let (loc, root) = try scratchLocations()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try ParentDashboardExporter.combinedExportForSharing(
            participants: [participant()], format: .json, locations: loc)
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        ActivitySheet.configure(vc, temporaryExport: url, locations: loc)

        let handler = try #require(vc.completionWithItemsHandler, "no completion handler installed")
        handler(.airDrop, true, nil, nil)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(
            atPath: loc.retainDirectory.appendingPathComponent(url.lastPathComponent).path),
                "the handler must never touch the retained copy")
    }

    @Test("a cancelled share step keeps the tmp copy, so a second choice still has a file")
    func cancelledShareKeepsTheTmpCopy() throws {
        let (loc, root) = try scratchLocations()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try ParentDashboardExporter.combinedExportForSharing(
            participants: [participant()], format: .csv, locations: loc)
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        ActivitySheet.configure(vc, temporaryExport: url, locations: loc)

        let handler = try #require(vc.completionWithItemsHandler)
        handler(.airDrop, false, nil, nil)
        handler(nil, false, nil, nil)

        #expect(FileManager.default.fileExists(atPath: url.path),
                "cancelled: left for the launch sweep")
    }

    @Test("the app's own locations are the standard composition over the real directories")
    func liveLocationsAreTheDocumentedRetrievalPath() throws {
        let fm = FileManager.default
        let support = try #require(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
        let live = ExportFileRetention.Locations.live
        #expect(live == .standard(applicationSupport: support, temporary: fm.temporaryDirectory))
        #expect(live.retainDirectory.path.hasSuffix("/Library/Application Support/PrimaeNative/Exports"),
                "devicectl retrieval path: \(live.retainDirectory.path)")
        // The sheet the parent area presents uses exactly these locations.
        #expect(ActivitySheet(items: [], temporaryExport: nil).locations == live)
    }

    @Test("the default retention keeps exactly five exports")
    func defaultRetentionKeepsFive() throws {
        let tmp = try scratchDirectory("tmp")
        let keep = try scratchDirectory("keep")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: keep)
        }
        for day in 1...7 {
            let name = "primae_progress_ALL_2026-10-0\(day)_120000_all1.csv"
            try ExportFileRetention.retain(try write(name, named: name, in: tmp), in: keep)
        }
        let kept = try FileManager.default.contentsOfDirectory(atPath: keep.path)
        #expect(kept.count == 5, "kept: \(kept.sorted())")
    }

    @Test("the export just retained survives even if its name sorts oldest (non-Gregorian date, clock set back)")
    func justRetainedExportIsNeverPruned() throws {
        // Reviewer's reproduction: five 2026 exports, then one written under
        // a Japanese-calendar device ("0008-10-14"), keep: 5. The five also
        // carry modification dates a day AHEAD (the clock was set back since),
        // so the new export is the oldest by name AND by date: only the
        // protection of the file just written keeps it.
        let tmp = try scratchDirectory("tmp")
        let keep = try scratchDirectory("keep")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: keep)
        }
        let ahead = Date().addingTimeInterval(86_400)
        for day in 1...5 {
            let name = "primae_progress_ALL_2026-10-0\(day)_120000_all1.csv"
            let kept = try ExportFileRetention.retain(try write(name, named: name, in: tmp), in: keep, keep: 5)
            try FileManager.default.setAttributes([.modificationDate: ahead], ofItemAtPath: kept.path)
        }
        let odd = "primae_progress_ALL_0008-10-14_120000_all1.csv"
        let copy = try ExportFileRetention.retain(try write(odd, named: odd, in: tmp), in: keep, keep: 5)

        #expect(FileManager.default.fileExists(atPath: copy.path), "the export just written was deleted")
        #expect(try FileManager.default.contentsOfDirectory(atPath: keep.path).count == 5)
    }

    @Test("pruning removes the OLDEST by modification date, not by name")
    func pruningIsByModificationDate() throws {
        let tmp = try scratchDirectory("tmp")
        let keep = try scratchDirectory("keep")
        defer {
            try? FileManager.default.removeItem(at: tmp)
            try? FileManager.default.removeItem(at: keep)
        }
        // Five retained exports whose names run opposite to their age:
        // "…-09" is the OLDEST file on disk, "…-05" the newest.
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for (age, day) in [9, 8, 7, 6, 5].enumerated() {
            let name = "primae_progress_ALL_2026-10-0\(day)_120000_all1.csv"
            let f = try write(name, named: name, in: keep)
            try FileManager.default.setAttributes(
                [.modificationDate: base.addingTimeInterval(Double(age) * 60)], ofItemAtPath: f.path)
        }
        let new = "primae_progress_ALL_2026-10-04_120000_all1.csv"
        try ExportFileRetention.retain(try write(new, named: new, in: tmp), in: keep, keep: 5)

        let kept = Set(try FileManager.default.contentsOfDirectory(atPath: keep.path))
        #expect(!kept.contains("primae_progress_ALL_2026-10-09_120000_all1.csv"), "oldest on disk must go: \(kept)")
        #expect(kept.contains(new))
        #expect(kept.count == 5)
    }

    @Test("export file names are Gregorian yyyy-MM-dd / HHmmss whatever the device calendar")
    func exportNameTagsIgnoreTheDeviceCalendar() throws {
        let vienna = try #require(TimeZone(identifier: "Europe/Vienna"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = vienna
        let date = try #require(gregorian.date(from: DateComponents(
            year: 2026, month: 10, day: 14, hour: 9, minute: 5, second: 7)))
        for id in [Calendar.Identifier.gregorian, .japanese, .buddhist, .islamicUmmAlQura] {
            var device = Calendar(identifier: id)
            device.timeZone = vienna
            device.locale = Locale(identifier: id == .gregorian ? "de_AT" : "ja_JP")
            #expect(ParentDashboardExporter.dateTag(date, deviceCalendar: device) == "2026-10-14", "\(id)")
            #expect(ParentDashboardExporter.timeTag(date, deviceCalendar: device) == "090507", "\(id)")
        }
    }

    @Test("the share sheet excludes Mail, Messages, Copy and the pointless targets, not AirDrop")
    func shareSheetExcludesLeakyTargetsButNotAirDrop() throws {
        let vc = UIActivityViewController(activityItems: [URL(fileURLWithPath: "/dev/null")],
                                          applicationActivities: nil)
        let (loc, root) = try scratchLocations()
        defer { try? FileManager.default.removeItem(at: root) }
        ActivitySheet.configure(vc, temporaryExport: nil, locations: loc)
        let excluded = Set(vc.excludedActivityTypes ?? [])
        for type in [UIActivity.ActivityType.mail, .message, .copyToPasteboard,
                     .postToFacebook, .saveToCameraRoll, .print, .assignToContact] {
            #expect(excluded.contains(type), "\(type.rawValue) should be excluded")
        }
        #expect(!excluded.contains(.airDrop))
        #expect(vc.completionWithItemsHandler != nil)
    }
}
