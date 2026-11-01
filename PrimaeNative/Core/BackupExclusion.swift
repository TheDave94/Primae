// BackupExclusion.swift
// PrimaeNative
//
// R-061: the thesis (§6.8) says a child's data stays on the iPad and leaves
// only through the proctor's manual export. An iCloud/iTunes backup would be
// a second, unplanned exit. Every per-child JSON store lives under
// `Application Support/PrimaeNative/` (ProgressStore, RawTraceStore,
// ParentDashboardStore, StreakStore, ParticipantArchiveStore, EnrolmentLog,
// OnboardingCoordinator, CalibrationStore, DeliveryEnvironment, LetterCache,
// AudioSignalProbe, and `Exports/` via ExportFileRetention), so flagging that
// ONE directory covers them all: `isExcludedFromBackup` on a directory
// excludes its contents. File-protection classes are deliberately untouched.
//
// `UserDefaults` (the arm override, comparison settings) lives in a plist
// under Library/Preferences and cannot be excluded this way.

import Foundation

nonisolated public enum BackupExclusion {

    /// `<applicationSupport>/PrimaeNative`, the root of all per-child stores.
    public static func dataDirectory(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("PrimaeNative", isDirectory: true)
    }

    /// Creates `directory` if needed and marks it excluded from backup.
    /// Idempotent: safe to call at every launch, and a no-op write when the
    /// flag is already set. Returns whether the directory ends up excluded.
    @discardableResult
    public static func excludeFromBackup(_ directory: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var dir = directory
            if (try? dir.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) == true {
                return true
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try dir.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    /// Launch hook: excludes the live `Application Support/PrimaeNative/`.
    @discardableResult
    public static func excludeLiveDataDirectory() -> Bool {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return false }
        return excludeFromBackup(dataDirectory(applicationSupport: support))
    }
}
