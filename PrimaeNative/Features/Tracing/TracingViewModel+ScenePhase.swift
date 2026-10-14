// TracingViewModel+ScenePhase.swift
// PrimaeNative
//
// The scene-phase → lifecycle mapping, moved out of `PrimaeApp` so it can
// be tested (fix batch C, audit R-005).

import SwiftUI

extension TracingViewModel {

    /// R-044 (audit 2026-10-13, H1-12): whether the display must stay
    /// awake — a study session with an enrolled child, scene active.
    /// Observe has no touch for 6–14 s and the proctor talks to the child
    /// between letters, so Auto-Lock could otherwise lock the iPad
    /// mid-session (`.inactive`, `.background`, then a passcode while the
    /// child waits). `MainAppView` applies it to
    /// `UIApplication.isIdleTimerDisabled`; outside that window the idle
    /// timer is the system's.
    public var keepsScreenAwake: Bool {
        studyMode && participantEnrolled && sceneIsActive
    }

    /// The scene-phase → lifecycle mapping (R-005). `.inactive` SUSPENDS
    /// the session and records nothing; `.background` additionally
    /// finalises a finished free-writing production and drains the
    /// stores; `.active` resumes. Returns the background flush task so a
    /// test can await it (nil for the synchronous phases).
    @discardableResult
    public func scenePhaseDidChange(to phase: ScenePhase) -> Task<Void, Never>? {
        switch phase {
        case .active:
            appDidBecomeActive()
            return nil
        case .inactive:
            appWillResignActive()
            return nil
        case .background:
            // Under a background-task assertion (R-051): a plain Task does
            // NOT keep a suspending process alive, and the trial the flush
            // protects is the session's last.
            return BackgroundFlushAssertion.protect(named: "Primae store flush",
                                                    using: backgroundTasks) {
                await self.appDidEnterBackground()
            }
        @unknown default:
            appWillResignActive()
            return nil
        }
    }
}
