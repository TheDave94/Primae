// SchemaMigrator.swift
// PrimaeNative
//
// Thin migration framework for the JSON persistence stores. Stores
// register a migration block keyed by target version and call
// `migrate` in their load path. All three stores sit at v1 today, so
// the framework is a no-op until the first schema bump lands.

import Foundation

enum SchemaMigrator {
    typealias Migration = (Data) throws -> Data

    /// Apply registered migrations one version at a time from
    /// `current` to `target`. Returns nil when a step is missing or
    /// throws — caller should refuse the file rather than mis-decode.
    /// Input passes through unchanged when `current >= target`.
    static func migrate(
        _ data: Data,
        from current: Int,
        to target: Int,
        migrations: [Int: Migration]
    ) -> Data? {
        guard current < target else { return data }
        var working = data
        for v in (current + 1)...target {
            guard let migration = migrations[v] else {
                storePersistenceLogger.warning(
                    "SchemaMigrator: no migration registered for v\(v); refusing legacy v\(current) file.")
                return nil
            }
            do {
                working = try migration(working)
            } catch {
                storePersistenceLogger.warning(
                    "SchemaMigrator: migration v\(v) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        return working
    }
}
