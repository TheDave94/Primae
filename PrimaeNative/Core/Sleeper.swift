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

/// Monotonic "seconds since boot" seam, the companion to `Sleeper` for
/// any loop whose pacing must be measured rather than assumed (audit
/// R-088: a fixed 1/60 s sleep makes the animation's LENGTH a function
/// of device load). Tests inject a fake clock advanced by their fake
/// sleeper, so a simulated slow device is deterministic and instant.
typealias MonotonicClock = @Sendable () -> TimeInterval

/// `nonisolated` for the same reason as `realSleeper`.
nonisolated let realMonotonicClock: MonotonicClock = {
    ProcessInfo.processInfo.systemUptime
}
