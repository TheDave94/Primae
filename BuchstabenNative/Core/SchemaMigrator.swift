// SchemaMigrator.swift
// BuchstabenNative
//
// D2 (ROADMAP_V5): a thin migration framework so the persistence
// stores have a place to put forward upgrades when their on-disk
// schemas evolve. The W-17 work added `schemaVersion` sentinels to
// `ProgressStore.Store`, `DashboardSnapshot`, and `StreakState`, but
// there was no path from v(N) → v(N+1) — a forward-incompatible
// file just got refused at load and logged. With this framework,
// each store can register a migration block keyed by target version
// and call `SchemaMigrator.migrate` in its load path.
//
// Today, all three stores are at v1 and the framework is a no-op.
// When a store needs to upgrade, add a migration block here:
//
//     let migrations: [Int: SchemaMigrator.Migration] = [
//         2: { data in
//             // Decode as v1 shape, transform, re-encode as v2 shape.
//             return try migrateProgressV1ToV2(data)
//         }
//     ]
//
// The load path then becomes:
//
//     guard let upgraded = SchemaMigrator.migrate(
//         data, from: decoded.schemaVersion ?? 0,
//         to: currentSchemaVersion, migrations: migrations)
//     else { return nil }
//     return try? JSONDecoder().decode(Store.self, from: upgraded)

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
