// AudioRouteObserver.swift
// PrimaeNative
//
// Tells the view model about audio route changes (fix batch C, audit
// R-019). `AudioEngine` observes the same notification and stops itself on
// a lost output, but tells nobody; this observer is the view model's own
// ear, so the playback state machine can be reset and the change counted.
// AudioEngine itself is untouched (D7).

import AVFoundation

@MainActor
final class AudioRouteObserver {
    private var task: Task<Void, Never>?

    /// `onChange(reason, outputLost, outputPortType, previousOutputPortType)`:
    /// `reason` is the notification's `AVAudioSession.RouteChangeReason` raw
    /// value (batch D filters the export's count by it — `RouteChangeFilter`);
    /// `outputLost` is true for `.oldDeviceUnavailable` (headphones
    /// unplugged, Bluetooth gone); `outputPortType` is the new first
    /// output's `AVAudioSession.Port` raw value, and `previousOutputPortType`
    /// the first output of the route BEFORE the change
    /// (`AVAudioSessionRouteChangePreviousRouteKey`) — on a loss, the port
    /// that was lost (`RouteRecovery`). Whether this observer or
    /// `AudioEngine`'s hears a notification first is undefined; nothing
    /// may depend on the order.
    init(onChange: @escaping @MainActor (_ reasonRawValue: UInt?, _ outputLost: Bool, _ outputPortType: String?, _ previousOutputPortType: String?) -> Void) {
        task = Task {
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification, object: nil
            ) {
                let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue
                let previous = (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription)?
                    .outputs.first?.portType.rawValue
                onChange(reasonValue, reason == .oldDeviceUnavailable, port, previous)
            }
        }
    }

    isolated deinit {
        task?.cancel()
    }
}

/// When a LOST output counts as BACK (audit 2026-10-18, L-B).
///
/// Only a genuine re-plug of the same output class: the reason is
/// `.newDeviceAvailable` (raw 1) AND the new first output is the port type
/// that was lost. A wake from sleep, a category or configuration change, an
/// override, or a different device arriving (Bluetooth gone, wired headphones
/// plugged) are not the lost output returning. A loss whose port was not
/// reported can never be matched. Raw values, so the rule is testable without
/// a session.
enum RouteRecovery {
    static let newDeviceAvailableRawValue: UInt = 1

    static func isReplug(reasonRawValue: UInt?, newOutputPortType: String?,
                         lostOutputPortType: String?) -> Bool {
        guard reasonRawValue == newDeviceAvailableRawValue,
              let lost = lostOutputPortType else { return false }
        return newOutputPortType == lost
    }
}
