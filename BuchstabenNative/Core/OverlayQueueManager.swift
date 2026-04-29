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
///
/// The canonical post-freeWrite order — enqueued together so the child
/// always sees them in this sequence, never stacked on top of each other
/// — is: `kpOverlay` → `recognitionBadge` → `paperTransfer` → `celebration`.
/// Each overlay is dismissable by tap (`.dismiss()`); modal-style overlays
/// (paperTransfer, celebration) carry a `nil` defaultDuration so they wait
/// for an explicit dismiss instead of timing out from under the child.
///
/// I-9: `kpOverlay` is terminal in this sequence — it is never shown
/// concurrently with any other overlay. It runs first and auto-advances
/// after its 3 s window; the queue then proceeds to recognitionBadge,
/// paperTransfer, and celebration in order. Nothing else is enqueued
/// while kpOverlay is the active overlay.
enum CanvasOverlay: Equatable, Sendable {
    /// Quick Fréchet-score confirmation chip ("Form 82 %"), 1.5 s.
    /// Currently unused — the inline form/guided feedback cards in
    /// SchuleWorldView render this signal alongside the canvas instead.
    /// Retained on the enum so consumers downstream of the queue can
    /// re-introduce the chip without an enum-shape migration.
    case frechetScore(CGFloat)
    /// Larger KP (Knowledge of Performance) overlay with the reference
    /// path drawn over the child's trace, ~3 s.
    case kpOverlay
    /// CoreML recognition badge when confidence ≥ 0.4, ~3 s.
    case recognitionBadge(RecognitionResult)
    /// Paper-transfer self-assessment modal — show reference letter for 3 s,
    /// hide for 10 s while the child writes on paper, then ask which emoji
    /// fits. Modal: no auto-dismiss, child taps an emoji to advance.
    case paperTransfer(letter: String)
    /// Phase-complete / letter-complete celebration. Modal: no auto-dismiss,
    /// child taps "Weiter" to load the next recommended letter.
    case celebration(stars: Int)
    /// U1 (ROADMAP_V5): newly-unlocked achievement (firstLetter, 7-day
    /// streak, allLetters, etc). Auto-advances after 2.5 s so the queue
    /// keeps flowing into the celebration that follows. The badges in
    /// FortschritteWorldView are the persistent display; this overlay is
    /// the one-time "you just earned this" moment.
    case rewardCelebration(RewardEvent)

    /// Default display duration chosen per overlay type so callers can
    /// enqueue without re-stating the timing at every site. `nil` means
    /// the overlay is modal and only dismisses on an explicit `.dismiss()`
    /// call from the rendering view.
    var defaultDuration: TimeInterval? {
        switch self {
        case .frechetScore:       return 1.5
        case .kpOverlay:          return 3.0
        case .recognitionBadge:   return 3.0
        case .paperTransfer:      return nil   // modal: wait for child
        case .celebration:        return nil   // modal: wait for child
        case .rewardCelebration:  return 2.5
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
    /// `duration == nil` marks a modal overlay — the timer task does not
    /// fire and only an explicit `.dismiss()` advances the queue.
    private var queue: [(overlay: CanvasOverlay, duration: TimeInterval?)] = []

    /// Task driving the auto-advance timer. Cancelled on dismiss or reset
    /// so a manual dismissal doesn't race with the timeout.
    private var advanceTask: Task<Void, Never>?

    /// Injected sleeper for the timed-overlay auto-advance. Defaults to
    /// `realSleeper` (Task.sleep) in production; tests substitute a
    /// deterministic fake so the queue's timing contract can be exercised
    /// without real wall-clock waits.
    private let sleeper: Sleeper

    init(sleeper: @escaping Sleeper = realSleeper) {
        self.sleeper = sleeper
    }

    // MARK: - Public API

    /// Append `overlay` to the queue. If nothing is showing, display
    /// it immediately; otherwise it waits behind whatever's running.
    /// Pass `duration = nil` to use the overlay's default. For modal
    /// overlays (paperTransfer, celebration) the default is also nil,
    /// meaning the queue waits for an explicit `.dismiss()` rather than
    /// timing out — appropriate for a 5-year-old who needs as much time
    /// as the celebration or the paper-write step takes.
    func enqueue(_ overlay: CanvasOverlay, duration: TimeInterval? = nil) {
        let d = duration ?? overlay.defaultDuration
        queue.append((overlay, d))
        if currentOverlay == nil {
            advance()
        }
    }

    /// Slot `overlay` into the queue immediately ahead of the first queued
    /// `.paperTransfer` or `.celebration` (whichever comes first), or append
    /// it if neither is queued. This ensures the canonical post-freeWrite
    /// order `kpOverlay → recognitionBadge → paperTransfer → celebration`
    /// even when CoreML inference finishes after the synchronous teardown
    /// already enqueued kpOverlay, paperTransfer, and celebration (W-25).
    ///
    /// C-4/W-25: also handles the case where paperTransfer or celebration is
    /// *already* the active overlay (CoreML inference arrived very late).
    /// In that case the blocking overlay is pushed back to queue position 0
    /// and the badge becomes the new currentOverlay, then auto-advances.
    func enqueueBeforeCelebration(_ overlay: CanvasOverlay,
                                   duration: TimeInterval? = nil) {
        let d = duration ?? overlay.defaultDuration
        // If a blocking modal (paperTransfer or celebration) is on screen,
        // interrupt it: re-enqueue at front, insert badge ahead of it.
        var isBlocking = false
        if case .paperTransfer = currentOverlay { isBlocking = true }
        if case .celebration   = currentOverlay { isBlocking = true }
        if isBlocking {
            let saved = currentOverlay!
            advanceTask?.cancel()
            advanceTask = nil
            currentOverlay = nil
            queue.insert((saved, saved.defaultDuration), at: 0)
            queue.insert((overlay, d), at: 0)
            advance()
            return
        }
        if let idx = queue.firstIndex(where: { entry in
            if case .paperTransfer = entry.overlay { return true }
            if case .celebration = entry.overlay { return true }
            return false
        }) {
            queue.insert((overlay, d), at: idx)
        } else {
            queue.append((overlay, d))
        }
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
        advanceTask?.cancel()
        // Modal overlays (`duration == nil`) wait for an explicit
        // `.dismiss()` — no timer is armed so the child can take their
        // time on the celebration or the paper-write step. Timed
        // overlays (KP, recognition badge) auto-advance after their
        // window so post-freeWrite feedback flows without manual taps.
        guard let duration = next.duration else {
            advanceTask = nil
            return
        }
        advanceTask = Task { [weak self, sleeper] in
            try? await sleeper(.seconds(duration))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }
}
