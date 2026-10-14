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

    /// `onChange(reason, outputLost, outputPortType)`: `reason` is the
    /// notification's `AVAudioSession.RouteChangeReason` raw value (batch
    /// D filters the export's count by it — `RouteChangeFilter`);
    /// `outputLost` is true for `.oldDeviceUnavailable` (headphones
    /// unplugged, Bluetooth gone); `outputPortType` is the new first
    /// output's `AVAudioSession.Port` raw value. Whether this observer or
    /// `AudioEngine`'s hears a notification first is undefined; nothing
    /// may depend on the order.
    init(onChange: @escaping @MainActor (_ reasonRawValue: UInt?, _ outputLost: Bool, _ outputPortType: String?) -> Void) {
        task = Task {
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification, object: nil
            ) {
                let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                let port = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue
                onChange(reasonValue, reason == .oldDeviceUnavailable, port)
            }
        }
    }

    isolated deinit {
        task?.cancel()
    }
}
