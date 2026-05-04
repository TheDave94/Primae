// Sleeper.swift
// PrimaeNative
//
// Shared "wait for a duration" injection seam. Production callers use
// `realSleeper` (= `Task.sleep(for:)`); tests substitute a fake that
// advances instantly so timer-driven flows don't depend on real
// wall-clock waits.

import Foundation

/// Async sleep seam.
typealias Sleeper = @Sendable (Duration) async throws -> Void

/// `nonisolated` so callers in detached Tasks can read it without
/// inheriting the module's MainActor default isolation.
nonisolated let realSleeper: Sleeper = { try await Task.sleep(for: $0) }
