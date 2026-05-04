// SchemaMigrator.swift
// PrimaeNative
//
// Thin migration framework for the JSON persistence stores. Each
// store registers a migration block keyed by target version and
// calls `migrate` in its load path:
//
//     let migrations: [Int: SchemaMigrator.Migration] = [
//         2: { data in try migrateProgressV1ToV2(data) }
//     ]
//
//     guard let upgraded = SchemaMigrator.migrate(
//         data, from: decoded.schemaVersion ?? 0,
//         to: currentSchemaVersion, migrations: migrations)
//     else { return nil }
//     return try? JSONDecoder().decode(Store.self, from: upgraded)
//
// All three stores currently sit at v1, so the framework is a no-op
// in production. It exists so the upgrade lever is in place when
// the first schema bump lands.

import Foundation

enum SchemaMigrator {
    typealias Migration = (Data) throws -> Data

    /// Apply registered migrations one version step at a time from
    /// `current` to `target`. Returns the migrated data, or `nil` when
    /// any step is missing or its block throws — the caller should then
    /// refuse the file rather than mis-decoding it.
    ///
    /// Returns the input unchanged when `current >= target` (the file is
    /// already at or ahead of the target schema; no migration to do).
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
