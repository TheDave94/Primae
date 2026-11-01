// BackupExclusionTests.swift
// PrimaeNativeTests
//
// R-061. Works in a scratch directory under tmp/; never the real container.
//
// Mutation checks (break, confirm RED, read the test count):
//   - excludesTheDirectoryAndCreatesItWhenMissing: drop setResourceValues.
//   - isIdempotent: make the second call throw/return false.
//   - dataDirectoryIsTheOneEveryStoreUses: rename the "PrimaeNative" component.

import Testing
import Foundation
@testable import PrimaeNative

@Suite struct BackupExclusionTests {

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("r061-\(UUID().uuidString)", isDirectory: true)
    }

    private func isExcluded(_ url: URL) -> Bool? {
        try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    @Test func excludesTheDirectoryAndCreatesItWhenMissing() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = BackupExclusion.dataDirectory(applicationSupport: root)
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        #expect(BackupExclusion.excludeFromBackup(dir))

        #expect(FileManager.default.fileExists(atPath: dir.path))
        #expect(isExcluded(dir) == true)
    }

    @Test func isIdempotent() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = BackupExclusion.dataDirectory(applicationSupport: root)
        let file = dir.appendingPathComponent("progress.json")

        #expect(BackupExclusion.excludeFromBackup(dir))
        try Data("x".utf8).write(to: file)
        #expect(BackupExclusion.excludeFromBackup(dir))

        #expect(isExcluded(dir) == true)
        #expect(try Data(contentsOf: file) == Data("x".utf8), "existing data is untouched")
    }

    @Test func dataDirectoryIsTheOneEveryStoreUses() {
        let support = URL(fileURLWithPath: "/x/Library/Application Support", isDirectory: true)
        #expect(BackupExclusion.dataDirectory(applicationSupport: support).path
                == "/x/Library/Application Support/PrimaeNative")
    }
}
