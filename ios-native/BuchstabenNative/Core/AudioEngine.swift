import AVFoundation
import Foundation

final class AudioEngine: AudioControlling {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var currentFile: AVAudioFile?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    private var shouldResumePlayback = false
    private var appIsForeground = true
    private var interrupted = false

    private(set) var isPlaying = false

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        installObservers()
        startIfNeeded()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        stopAndReset()
    }

    func loadAudioFile(named fileName: String, autoplay: Bool = false) {
        guard let url = resourceURL(for: fileName) else {
            print("Missing audio file: \(fileName)")
            return
        }

        do {
            currentFile = try AVAudioFile(forReading: url)
            shouldResumePlayback = autoplay
            prepareCurrentTrack()
            if autoplay {
                attemptResumePlayback()
            }
        } catch {
            print("Audio load error: \(error)")
        }
    }

    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        let clampedSpeed = max(0.5, min(2.0, speed))
        timePitch.rate = clampedSpeed * 100.0
        player.pan = max(-1.0, min(1.0, horizontalBias))
    }

    func play() {
        shouldResumePlayback = true
        attemptResumePlayback()
    }

    func stop() {
        shouldResumePlayback = false
        player.pause()
        isPlaying = false
    }

    func restart() {
        shouldResumePlayback = true
        prepareCurrentTrack()
        attemptResumePlayback()
    }

    func suspendForLifecycle() {
        appIsForeground = false
        player.pause()
        isPlaying = false
        pendingSafeEnginePause()
    }

    func resumeAfterLifecycle() {
        appIsForeground = true
        attemptResumePlayback()
    }

    func cancelPendingLifecycleWork() {
        // No-op in baseline engine; used by injected test doubles and lifecycle hardening.
    }
}

private extension AudioEngine {
    func resourceURL(for fileName: String) -> URL? {
        if let direct = Bundle.main.url(forResource: fileName, withExtension: nil) {
            return direct
        }

        let ns = fileName as NSString
        let resource = ns.lastPathComponent
        let subdir = ns.deletingLastPathComponent
        if !subdir.isEmpty,
           let nested = Bundle.main.url(forResource: resource, withExtension: nil, subdirectory: subdir) {
            return nested
        }

        return nil
    }

    func startIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            print("AudioEngine start error: \(error)")
        }
    }

    func canResumePlayback() -> Bool {
        appIsForeground && !interrupted
    }

    func attemptResumePlayback() {
        startIfNeeded()
        prepareCurrentTrack()

        guard shouldResumePlayback, canResumePlayback() else {
            player.pause()
            isPlaying = false
            pendingSafeEnginePause()
            return
        }

        if !player.isPlaying {
            player.play()
        }
        isPlaying = true
    }

    func prepareCurrentTrack() {
        guard let file = currentFile else { return }

        player.stop()
        player.scheduleFile(file, at: nil, completionHandler: nil)
        isPlaying = false
    }

    func pendingSafeEnginePause() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard !self.isPlaying else { return }
            self.engine.pause()
        }
    }

    func stopAndReset() {
        player.stop()
        engine.stop()
        currentFile = nil
        shouldResumePlayback = false
        appIsForeground = true
        interrupted = false
        isPlaying = false
    }

    func installObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    func handleInterruption(_ notification: Notification) {
        guard
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            interrupted = true
            player.pause()
            isPlaying = false
        case .ended:
            interrupted = false
            if let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                attemptResumePlayback()
            }
        @unknown default:
            break
        }
    }

    func handleRouteChange(_ notification: Notification) {
        guard
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        switch reason {
        case .oldDeviceUnavailable:
            player.pause()
            isPlaying = false
            attemptResumePlayback()
        case .newDeviceAvailable, .categoryChange, .override, .routeConfigurationChange, .wakeFromSleep, .noSuitableRouteForCategory:
            attemptResumePlayback()
        default:
            break
        }
    }
}
