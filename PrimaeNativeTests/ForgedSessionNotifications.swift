// ForgedSessionNotifications.swift
// PrimaeNativeTests: SDK27 (2026-11-24)
//
// Posts iOS 27's didBecomeInactive / resumptionRecommendation notifications
// with GENUINE context objects, so a test drives the production observers
// through the same `as? AVAudioSession.DeactivationContext` /
// `ResumptionContext` casts a system post goes through.
//
// The contexts are "created by the system" (`init` NS_UNAVAILABLE), so they
// are made here through the Objective-C runtime: `alloc` without `init`, then
// the backing ivar set by key-value coding. Before any KVC write the ivar is
// looked up with `class_copyIvarList`; if the SDK ever stores the value some
// other way, `make` returns nil (and the caller records an Issue / fails)
// instead of raising NSUndefinedKeyException and taking the process down.

import Foundation
import AVFoundation
import ObjectiveC

enum ForgedSessionNotifications {

    /// An instance of `cls` with the Int ivar behind `key` set to `value`,
    /// read back through the public getter; nil if the ivar is not there.
    static func make(_ cls: AnyClass, key: String, value: Int) -> NSObject? {
        var count: UInt32 = 0
        guard let ivars = class_copyIvarList(cls, &count) else { return nil }
        defer { free(ivars) }
        let names = (0..<Int(count)).compactMap { ivar_getName(ivars[$0]).map { String(cString: $0) } }
        guard names.contains("_\(key)") || names.contains(key) else { return nil }
        guard let made = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.takeRetainedValue() as? NSObject
        else { return nil }
        made.setValue(value, forKey: key)
        guard (made.value(forKey: key) as? Int) == value else { return nil }
        return made
    }

    static func deactivationContext(source: AVAudioSession.DeactivationSource) -> AVAudioSession.DeactivationContext? {
        make(AVAudioSession.DeactivationContext.self, key: "source", value: source.rawValue)
            as? AVAudioSession.DeactivationContext
    }

    static func resumptionContext(_ r: AVAudioSession.ResumptionRecommendation) -> AVAudioSession.ResumptionContext? {
        make(AVAudioSession.ResumptionContext.self, key: "recommendation", value: r.rawValue)
            as? AVAudioSession.ResumptionContext
    }

    /// The notification a system interruption's begin posts. `source: nil`
    /// posts it without a context. Nil when the context could not be made.
    static func inactive(source: AVAudioSession.DeactivationSource?) -> Notification? {
        var info: [AnyHashable: Any] = [:]
        if let source {
            guard let c = deactivationContext(source: source) else { return nil }
            info[AVAudioSession.deactivationContextKey] = c
        }
        return Notification(name: AVAudioSession.didBecomeInactiveNotification, object: nil, userInfo: info)
    }

    /// The notification an interruption's end posts. `nil` posts it without a context.
    static func resumption(_ r: AVAudioSession.ResumptionRecommendation?) -> Notification? {
        var info: [AnyHashable: Any] = [:]
        if let r {
            guard let c = resumptionContext(r) else { return nil }
            info[AVAudioSession.resumptionContextKey] = c
        }
        return Notification(name: AVAudioSession.resumptionRecommendationNotification, object: nil, userInfo: info)
    }

    /// Post `n`; false (nothing posted) when it is nil.
    @discardableResult
    static func post(_ n: Notification?, to center: NotificationCenter = .default) -> Bool {
        guard let n else { return false }
        center.post(n)
        return true
    }

    /// Began = a system deactivation; ended = a resumption recommendation.
    static func interruption(began: Bool, shouldResume: Bool = false) -> Notification? {
        began ? inactive(source: .system) : resumption(shouldResume ? .shouldResume : .shouldNotResume)
    }
}
