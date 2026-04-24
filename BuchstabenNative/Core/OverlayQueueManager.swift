// OverlayQueueManager.swift
// BuchstabenNative
//
// Serialises canvas overlays so the child never sees stacked
// feedback (Fréchet badge + KP diagram + recognition chip +
// celebration all at once). Each overlay runs for its own duration,
// then the queue auto-advances. While the queue is empty, the canvas
// returns to interactive state.
//
// The actual rendering still lives in the existing overlay views —
// this manager only arbitrates visibility and order.

import CoreGraphics
import Foundation

/// Content of a single queued canvas overlay. Extend as new temporal
/// feedback moments are added; the manager itself doesn't care about
/// payload shape, only about ordering + dismissal.
enum CanvasOverlay: Equatable, Sendable {
    /// Quick Fréchet-score confirmation chip ("Form 82 %"), 1.5 s.
    case frechetScore(CGFloat)
    /// Larger KP (Knowledge of Performance) overlay with the reference
    /// path drawn over the child's trace, ~3 s.
    case kpOverlay
    /// CoreML recognition badge when confidence ≥ 0.4, ~3 s.
    case recognitionBadge(RecognitionResult)
    /// Phase-complete / letter-complete celebration, ~2 s.
    case celebration(stars: Int)

    /// Default display duration chosen per overlay type so callers can
    /// enqueue without re-stating the timing at every site.
    var defaultDuration: TimeInterval {
        switch self {
        case .frechetScore:       return 1.5
        case .kpOverlay:          return 3.0
        case .recognitionBadge:   return 3.0
        case .celebration:        return 2.0
        }
    }
}

/// Per-VM overlay scheduler. Observable so SwiftUI views can bind
/// directly to `currentOverlay` and animate on change.
@MainActor
@Observable
final class OverlayQueueManager {

    // MARK: - State

    /// Overlay currently on screen, or nil when the queue is drained
    /// and the canvas is back to interactive.
    private(set) var currentOverlay: CanvasOverlay?

    /// FIFO queue of waiting overlays. Public via `pendingCount` only.
    private var queue: [(overlay: CanvasOverlay, duration: TimeInterval)] = []

    /// Task driving the auto-advance timer. Cancelled on dismiss or reset
    /// so a manual dismissal doesn't race with the timeout.
    private var advanceTask: Task<Void, Never>?

    // MARK: - Public API

    /// Append `overlay` to the queue. If nothing is showing, display
    /// it immediately; otherwise it waits behind whatever's running.
    /// Pass `duration = nil` to use the overlay's default.
    func enqueue(_ overlay: CanvasOverlay, duration: TimeInterval? = nil) {
        let d = duration ?? overlay.defaultDuration
        queue.append((overlay, d))
        if currentOverlay == nil {
            advance()
        }
    }

    /// Dismiss the current overlay early (e.g. child tapped through).
    /// Advances to the next in queue, or idles if the queue is empty.
    func dismiss() {
        advanceTask?.cancel()
        advanceTask = nil
        advance()
    }

    /// Clear the queue and any active overlay. Call on letter change
    /// or phase reset so stale feedback can't bleed across sessions.
    func reset() {
        advanceTask?.cancel()
        advanceTask = nil
        queue.removeAll(keepingCapacity: true)
        currentOverlay = nil
    }

    /// How many overlays are waiting behind the current one.
    var pendingCount: Int { queue.count }

    // MARK: - Internals

    private func advance() {
        if queue.isEmpty {
            currentOverlay = nil
            return
        }
        let next = queue.removeFirst()
        currentOverlay = next.overlay
        advanceTask = Task { [weak self] in
            let nanos = UInt64((next.duration * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }
}
