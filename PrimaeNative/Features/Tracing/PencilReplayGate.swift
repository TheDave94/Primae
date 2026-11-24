import UIKit

/// U5 (audit R-096): the Apple Pencil gesture -> "replay letter audio"
/// decision, extracted from `PencilAwareCanvasOverlay.Coordinator` so it is
/// plain Swift a test can call (CLAUDE.md, "extract the decisions"). Both
/// delegate callbacks — `didReceiveTap` (double-tap) and `didReceiveSqueeze`
/// — go through `shouldReplay`, so the two gestures cannot diverge.
///
/// Rules, in order:
/// 1. A study session never replays (`TracingViewModel.replayAudio` is a
///    no-op there anyway; ruled 2026-11-24, docs/DECISIONS.md "U5"). An
///    on-demand replay would be extra, child-controlled exposure that
///    differs across children and arms.
/// 2. A squeeze acts only on `.ended`, so one squeeze fires once
///    (`.began` / `.changed` / `.cancelled` do nothing). A tap has no phase.
/// 3. The user's preferred action for that gesture is respected:
///    `.ignore` (gesture switched off in Settings) does nothing, and
///    `.runSystemShortcut` is the system's to run, so the app adds nothing
///    on top of it. Any other preference maps to this app's one Pencil
///    action, the replay.
enum PencilReplayGate {
    enum Gesture {
        case tap
        case squeeze(UIPencilInteraction.Phase)
    }

    static func shouldReplay(_ gesture: Gesture,
                             preferredAction: UIPencilPreferredAction,
                             studyMode: Bool) -> Bool {
        guard !studyMode else { return false }
        if case .squeeze(let phase) = gesture, phase != .ended { return false }
        switch preferredAction {
        case .ignore, .runSystemShortcut: return false
        default: return true
        }
    }

    /// The preferred action the system reports for `gesture`.
    static func preferredAction(for gesture: Gesture) -> UIPencilPreferredAction {
        switch gesture {
        case .tap:     return UIPencilInteraction.preferredTapAction
        case .squeeze: return UIPencilInteraction.preferredSqueezeAction
        }
    }
}

/// U5: one replay per burst, whatever triggered it. Every replay entry
/// (Pencil double-tap, Pencil squeeze, the VoiceOver "Buchstaben-Ton
/// abspielen" action, the retrieval prompt's finger tap) reaches
/// `TracingViewModel.replayAudio`, which admits a replay only if none was
/// admitted within `minimumInterval`. So a squeeze and a finger tap in
/// rapid succession (or a squeeze delivered together with a double-tap)
/// restart the letter audio once, not twice.
struct ReplayDebounce {
    static let minimumInterval: TimeInterval = 0.5
    private(set) var lastAdmittedAt: TimeInterval?

    mutating func admit(now: TimeInterval) -> Bool {
        if let last = lastAdmittedAt, now - last < Self.minimumInterval {
            return false
        }
        lastAdmittedAt = now
        return true
    }
}
