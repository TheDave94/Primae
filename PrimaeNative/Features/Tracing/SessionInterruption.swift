// SessionInterruption.swift
// PrimaeNative
//
// Lifecycle & interruption bookkeeping for a study session (fix batch C,
// audit 2026-10-13). The behaviour lives on `TracingViewModel`; this file
// holds the small value types it keeps.

import Foundation
import os

/// What can suspend a study session (R-005, R-026).
enum SessionInterruption: Hashable {
    /// The scene left `.active` (`.inactive`, then perhaps `.background`).
    case scene
    /// The proctor's parent area covers the child's screen.
    case parentArea
}

/// Interruptions and resumptions, at their (low) frequency.
nonisolated let lifecycleLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
    category: "Lifecycle"
)

/// In-memory interruption bookkeeping for the letter on screen, reset by
/// every `load(letter:)`. Exported per PHASE by fix batch D
/// (`PhaseDeliveryTracker` → `PhaseDelivery`, audit R-020).
struct LifecycleCounters: Equatable {
    /// Times the session was suspended (`beginInterruption` from running)
    /// — an inactive scene or the parent area (batch D).
    var interruptions = 0
    /// Touches the SYSTEM cancelled (edge gesture, Control Center, palm
    /// rejection) — closed as strokes, never taken as a lift (R-024).
    var strokesCancelled = 0
    /// Observe phases restarted from the cue after an interruption (R-006,
    /// D9 default "restart").
    var observeRestarts = 0
    /// Audio output DEVICE changes heard while this letter was on screen
    /// (R-019) — filtered by reason since batch D (`RouteChangeFilter`), so
    /// the engine's own category changes are not counted.
    var routeChanges = 0
    /// The output port type after the most recent route change
    /// (`AVAudioSessionPort` raw value, e.g. "Headphones", "Speaker").
    var outputRoute: String? = nil
}
