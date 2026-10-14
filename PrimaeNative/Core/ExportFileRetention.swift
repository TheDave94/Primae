// ExportFileRetention.swift
// PrimaeNative
//
// R-062 (audit 2026-10-13, D2-03 / D1-13 / E1-14). The combined research
// export is written to tmp/ for the share sheet. Those files were never
// deleted: every export tap left another full copy of every child's data
// in tmp/ until iOS purged it. They now go away when the share sheet
// finishes and, as a backstop, at the next launch.
//
// The proctor also retrieves exports over USB with `xcrun devicectl device
// copy from` — a path that relied on the tmp/ files persisting. So before
// the tmp/ copy can be deleted, the same bytes are kept under
// Application Support/PrimaeNative/Exports/, excluded from iCloud/Finder
// backup, newest `retainedCount` only.

import Foundation

nonisolated public enum ExportFileRetention {

    /// Every export filename starts with this (`ParentDashboardExporter`).
    static let filenamePrefix = "primae_progress_"

    /// Retained exports kept in `Exports/`; older ones are deleted.
    static let retainedCount = 5

    /// Where the export action writes (tmp/) and keeps (Exports/) its files.
    /// `live` is what the app uses; `standard(applicationSupport:temporary:)`
    /// is the same composition over any base, so a test drives the real
    /// wiring in scratch directories and never touches the app's own.
    nonisolated struct Locations: Sendable, Equatable {
        let temporaryDirectory: URL
        /// `Application Support/PrimaeNative/Exports/`, the devicectl
        /// retrieval point (`--domain-type appDataContainer --source
        /// "Library/Application Support/PrimaeNative/Exports/<file>"`).
        let retainDirectory: URL

        static func standard(applicationSupport: URL, temporary: URL) -> Locations {
            Locations(
                temporaryDirectory: temporary,
                retainDirectory: applicationSupport
                    .appendingPathComponent("PrimaeNative", isDirectory: true)
                    .appendingPathComponent("Exports", isDirectory: true))
        }

        static var live: Locations {
            // Same fallback as the JSON stores (see ProgressStore.init).
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory
            return standard(applicationSupport: support, temporary: fm.temporaryDirectory)
        }
    }

    /// Copies the file at `url` byte for byte into `directory`, marks the
    /// directory and the copy excluded from backup, then deletes all but
    /// the newest `keep` exports there. Returns the copy's URL.
    @discardableResult
    static func retain(_ url: URL, in directory: URL, keep: Int = retainedCount) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var dir = directory
        try dir.setResourceValues(excluded)
        var copy = directory.appendingPathComponent(url.lastPathComponent)
        // Same name = same second and format; the newer bytes win, exactly
        // as the tmp/ write already overwrote them.
        if fm.fileExists(atPath: copy.path) { try fm.removeItem(at: copy) }
        try fm.copyItem(at: url, to: copy)
        try copy.setResourceValues(excluded)
        prune(directory, keep: keep, protecting: copy)
        return copy
    }

    /// Deletes all but the newest `keep` exports in `directory`, where
    /// `protected` (the export just written) always counts as one of them
    /// and is never deleted. Newest by modification date, file name as the
    /// tie-break. Not by name alone: a name's date is the device's calendar
    /// and clock, and a non-Gregorian calendar or a clock set back made the
    /// export just written sort "oldest" and get deleted (review of R-062).
    private static func prune(_ directory: URL, keep: Int, protecting protected: URL) {
        let others = exportFiles(in: directory)
            .filter { $0.lastPathComponent != protected.lastPathComponent }
            .sorted(by: newerFirst)
        for old in others.dropFirst(max(keep - 1, 0)) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    private static func newerFirst(_ a: URL, _ b: URL) -> Bool {
        let da = modificationDate(a), db = modificationDate(b)
        if da != db { return da > db }
        return a.lastPathComponent > b.lastPathComponent
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Regular files directly in `directory` whose name carries the prefix.
    private static func exportFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])) ?? []
        return files.filter { isExportFile($0) }
    }

    private static func isExportFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(filenamePrefix)
            && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    /// Deletes a share-sheet temp export. Only ever deletes a regular file
    /// whose name carries the export prefix.
    static func removeTemporaryExport(_ url: URL) {
        guard isExportFile(url) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Share-sheet completion (R-062): deletes the tmp/ copy of a shared
    /// export, but only when the activity COMPLETED. A cancelled step can
    /// leave the sheet open, and a second choice would then share a file
    /// that is gone; cancelled exports are left to the launch sweep. Only a
    /// file directly in `locations.temporaryDirectory` is ever deleted, so
    /// the retained copy cannot be.
    static func finishSharing(_ url: URL, completed: Bool, locations: Locations) {
        guard completed else { return }
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        guard parent == locations.temporaryDirectory.resolvingSymlinksInPath().path else { return }
        removeTemporaryExport(url)
    }

    /// Launch backstop: deletes every `primae_progress_*` regular file left
    /// directly in `directory` (default tmp/) by an earlier session, e.g.
    /// when the share sheet was dismissed without reporting completion or
    /// the app was killed while it was open.
    public static func sweepTemporaryExports(
        in directory: URL = FileManager.default.temporaryDirectory
    ) {
        for file in exportFiles(in: directory) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
