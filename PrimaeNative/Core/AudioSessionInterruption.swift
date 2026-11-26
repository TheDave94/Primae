// AudioSessionInterruption.swift
// PrimaeNative
//
// SDK27 (2026-11-24). iOS 27 deprecates `AVAudioSession.interruptionNotification`
// with its `InterruptionType` / `InterruptionOptions` payload, "in favour of
// AVAudioSessionDidBecomeInactiveNotification and
// AVAudioSessionResumptionRecommendationNotification" (iPhoneOS27.2.sdk,
// AVFAudio/AVAudioSessionTypes.h). This type is the one place that reads the
// replacement pair and turns it into the two events the r16 interruption rules
// (B1, C2) are written against, so `AudioEngine` and `LiveSonificationAudio`
// keep their state machines and only change where an event comes from.
//
// The mapping (docs/DECISIONS.md, "SDK27 interruption mapping"):
//   didBecomeInactive, context.source == .system  -> .began
//   didBecomeInactive, context.source == .app     -> nothing (our own
//       `setActive(false)`; the old notification never fired for it, and the
//       app ships no such call: AudioEngine.swift "Intentionally does NOT
//       call setActive(false)")
//   didBecomeInactive, no context                 -> .began (fail safe: the
//       system took the session; silence is the safe reading)
//   resumptionRecommendation, .shouldResume       -> .ended(shouldResume: true)
//   resumptionRecommendation, .shouldNotResume    -> .ended(shouldResume: false)
//   resumptionRecommendation, no context          -> .ended(shouldResume: false)
//       (the old `.ended` without an options key also meant "do not resume")
//
// The decision is a value (`init?(deactivatedBySystem:)`,
// `init(resumptionRecommended:)`) so it is testable without the system
// context objects, which cannot be constructed (`init` is NS_UNAVAILABLE).

import AVFoundation
import Foundation

nonisolated enum AudioSessionInterruption: Equatable, Sendable {
    /// The system deactivated the session: stop, keep the loaded sound and
    /// the resume intent, refuse to resume until told (r16 B1/C2).
    case began
    /// The system's resumption recommendation: resume only when it says so.
    case ended(shouldResume: Bool)

    /// The notifications this type reads.
    static let notificationNames: [Notification.Name] = [
        AVAudioSession.didBecomeInactiveNotification,
        AVAudioSession.resumptionRecommendationNotification,
    ]

    /// A deactivation. `bySystem`: true = the system deactivated the session,
    /// false = the app did, nil = the notification carried no context.
    /// Nil result: not an interruption.
    init?(deactivatedBySystem bySystem: Bool?) {
        guard bySystem ?? true else { return nil }
        self = .began
    }

    /// A resumption recommendation. nil = no context: do not resume.
    init(resumptionRecommended shouldResume: Bool?) {
        self = .ended(shouldResume: shouldResume ?? false)
    }

    /// Read a posted notification. Nil for any other notification, and for a
    /// deactivation the app itself requested.
    init?(_ notification: Notification) {
        switch notification.name {
        case AVAudioSession.didBecomeInactiveNotification:
            let context = notification.userInfo?[AVAudioSession.deactivationContextKey]
                as? AVAudioSession.DeactivationContext
            self.init(deactivatedBySystem: context.map { $0.source == .system })
        case AVAudioSession.resumptionRecommendationNotification:
            let context = notification.userInfo?[AVAudioSession.resumptionContextKey]
                as? AVAudioSession.ResumptionContext
            self.init(resumptionRecommended: context.map { $0.recommendation == .shouldResume })
        default:
            return nil
        }
    }

    /// Observe both notifications on `center` until the returned task is
    /// cancelled or `handle` returns false (its owner is gone). The
    /// notification sequences are created HERE, synchronously on the caller's
    /// main actor, so the observers are registered before this returns: a
    /// notification posted right after the owner's init is not missed
    /// (measured: creating them inside a task missed `AudioEngineTests`'
    /// first post). One loop per name, both ended with the ONE returned task,
    /// so an owner keeps one handle (AudioEngine's observer store and deinit
    /// keep their shape).
    @MainActor
    static func observe(on center: NotificationCenter,
                        _ handle: @escaping @MainActor (AudioSessionInterruption) -> Bool) -> Task<Void, Never> {
        let loops = notificationNames.map { name in
            let sequence = center.notifications(named: name, object: nil)
            return Task { @MainActor in
                for await n in sequence {
                    guard let event = AudioSessionInterruption(n) else { continue }
                    if !handle(event) { return }
                }
            }
        }
        return Task {
            await withTaskCancellationHandler {
                for loop in loops { await loop.value }
            } onCancel: {
                for loop in loops { loop.cancel() }
            }
        }
    }
}
