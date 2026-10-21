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

    // Observe sound vs a lost output (protocol r11, RECORD-ONLY: nothing
    // here changes what any arm hears). Only the observe phase writes
    // these; `PhaseDeliveryTracker` exports them on the observe row alone.

    /// Outputs LOST in observe while the arm's dot-tracked observe sound
    /// was playing: the rest of that sound was cut and is not replayed.
    var observeLossesDuringSound = 0
    /// Outputs LOST in observe while no observe sound was playing: the
    /// cue, the gap before the presentation, a held observe, after the
    /// sound was already cut — and, in an arm with no observe sound (the
    /// silent arm, an unclaimed sound), the whole phase.
    var observeLossesWithoutSound = 0
    /// Seconds the observe sound ran, from its play call to its stop (the
    /// phase's end, a load, an interruption), whatever the output did.
    var observeSoundSeconds: Double = 0
    /// Of `observeSoundSeconds`, the seconds before the output was lost.
    var observeSoundDeliveredSeconds: Double = 0
    /// When the observe sound now running started; nil when none runs.
    var observeSoundStartedAt: TimeInterval? = nil
    /// When the running observe sound's current output started carrying
    /// it; nil when none runs or its output was lost.
    var observeSoundDeliveringSince: TimeInterval? = nil

    /// The observe sound started at `now` (one closed first if running).
    mutating func startObserveSound(at now: TimeInterval) {
        endObserveSound(at: now)
        observeSoundStartedAt = now
        observeSoundDeliveringSince = now
    }

    /// The observe sound stopped at `now`. No-op when none runs.
    mutating func endObserveSound(at now: TimeInterval) {
        if let since = observeSoundDeliveringSince {
            observeSoundDeliveredSeconds += max(0, now - since)
        }
        if let start = observeSoundStartedAt {
            observeSoundSeconds += max(0, now - start)
        }
        observeSoundStartedAt = nil
        observeSoundDeliveringSince = nil
    }

    /// The output was lost at `now` in observe: booked as during or
    /// without the sound, and the sound's delivery ends here.
    mutating func observeOutputLost(at now: TimeInterval) {
        if let since = observeSoundDeliveringSince {
            observeLossesDuringSound += 1
            observeSoundDeliveredSeconds += max(0, now - since)
            observeSoundDeliveringSince = nil
        } else {
            observeLossesWithoutSound += 1
        }
    }

    /// These counters as they stand at `now`, a running sound's seconds
    /// included, so a row written while the sound still runs (or a phase
    /// closed before its sound's stop is booked) carries them.
    func settled(at now: TimeInterval) -> LifecycleCounters {
        var copy = self
        copy.endObserveSound(at: now)
        return copy
    }
}
