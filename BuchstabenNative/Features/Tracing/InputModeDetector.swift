import Foundation
import Observation

/// Tracks whether the child is currently writing with a pencil or a
/// finger, and exposes the effective `InputPreset.Kind` the grid should
/// use. Implements hysteresis so a single stray finger touch can't
/// demote a pencil session mid-word.
///
/// Promotion: first pencil touch flips the detector to `.pencil`
/// immediately — no delay, so the grid reacts to the first stroke.
///
/// Demotion: only on `resetForSequenceChange()` AND when the last
/// pencil touch was more than `pencilIdleThreshold` ago AND the last
/// `fingerStreakThreshold` touches were all finger. This mirrors the
/// plan's rule — don't steal the pencil preset from a child who just
/// paused mid-word and briefly rested a palm on the screen.
@MainActor
@Observable
final class InputModeDetector {
    enum Override: Equatable {
        case auto
        case forceFinger
        case forcePencil
    }

    private(set) var detectedKind: InputPreset.Kind = .finger
    var override: Override = .auto

    /// Minimum idle duration (no pencil touches) required before a
    /// `.pencil` session can fall back to `.finger`. Long enough that a
    /// child resting mid-word doesn't lose the pencil geometry.
    var pencilIdleThreshold: TimeInterval = 60

    /// How many consecutive finger-only touches must arrive, combined
    /// with idle time, before demoting. A single finger tap doesn't flip.
    var fingerStreakThreshold: Int = 3

    private var lastPencilTouchAt: Date?
    private var consecutiveFingerTouches: Int = 0

    /// Effective preset kind after applying the debug override.
    var effectiveKind: InputPreset.Kind {
        switch override {
        case .auto:         return detectedKind
        case .forceFinger:  return .finger
        case .forcePencil:  return .pencil
        }
    }

    /// Called by the touch overlays on each touch-began event.
    /// `isPencil == true` promotes to `.pencil` immediately.
    func observeTouchBegan(isPencil: Bool, at date: Date = Date()) {
        if isPencil {
            detectedKind = .pencil
            lastPencilTouchAt = date
            consecutiveFingerTouches = 0
        } else {
            consecutiveFingerTouches += 1
        }
    }

    /// Called when a new letter/word/repetition is loaded. Only point
    /// at which the detector may downgrade from `.pencil` back to
    /// `.finger` — keeps the session stable across mid-sequence palm
    /// rests, consistent with the plan's hysteresis rule.
    func resetForSequenceChange(at date: Date = Date()) {
        guard detectedKind == .pencil else { return }
        let idleTooLong = lastPencilTouchAt.map {
            date.timeIntervalSince($0) >= pencilIdleThreshold
        } ?? true
        if idleTooLong && consecutiveFingerTouches >= fingerStreakThreshold {
            detectedKind = .finger
            lastPencilTouchAt = nil
            consecutiveFingerTouches = 0
        }
    }
}
