// Sleeper.swift
// PrimaeNative
//
// Shared "wait for a duration" injection seam. Production callers
// default to `Task.sleep(for:)`; tests pass in a fake that advances
// instantly (or in deterministic increments) so timer-driven flows
// don't rely on real wall-clock waits.
//
// Two pre-existing local typealiases (TransientMessagePresenter,
// PlaybackController) defined the same shape independently. They keep
// their own definitions to avoid an API break, but new injectable
// timers (OverlayQueueManager, AnimationGuideController, …) reach for
// this shared alias.

import Foundation

/// Async sleep seam. Tests substitute a deterministic implementation
/// (e.g. `{ _ in await Task.yield() }`) so timer-driven tests don't
/// depend on real wall-clock waits.
typealias Sleeper = @Sendable (Duration) async throws -> Void

/// The production sleeper — equivalent to `Task.sleep(for:)`. Used as
/// the default for any initialiser that takes a `Sleeper`. Marked
/// `nonisolated` so callers in detached Tasks can read it without
/// inheriting the module's MainActor default isolation.
nonisolated let realSleeper: Sleeper = { try await Task.sleep(for: $0) }
