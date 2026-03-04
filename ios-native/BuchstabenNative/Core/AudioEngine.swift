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
    private var interruptionShouldResume = true
    private var interruptionResumeGateRequired = false
    private var pendingLifecyclePauseWorkItem: DispatchWorkItem?

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
        interruptionResumeGateRequired = false
        interruptionShouldResume = true
        attemptResumePlayback()
    }

    func stop() {
        shouldResumePlayback = false
        cancelPendingLifecycleWork()
        player.pause()
        isPlaying = false
    }

    func restart() {
        shouldResumePlayback = true
        interruptionResumeGateRequired = false
        interruptionShouldResume = true
        prepareCurrentTrack()
        attemptResumePlayback()
    }

    func suspendForLifecycle() {
        appIsForeground = false
        cancelPendingLifecycleWork()
        player.pause()
        isPlaying = false
        pendingSafeEnginePause()
    }

    func resumeAfterLifecycle() {
        appIsForeground = true
        attemptResumePlayback()
    }

    func cancelPendingLifecycleWork() {
        pendingLifecyclePauseWorkItem?.cancel()
        pendingLifecyclePauseWorkItem = nil
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
        appIsForeground && !interrupted && shouldResumePlayback && (!interruptionResumeGateRequired || interruptionShouldResume)
    }

    func attemptResumePlayback() {
        startIfNeeded()
        prepareCurrentTrack()

        guard canResumePlayback() else {
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
        cancelPendingLifecycleWork()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isPlaying else { return }
            self.engine.pause()
        }
        pendingLifecyclePauseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func stopAndReset() {
        player.stop()
        engine.stop()
        currentFile = nil
        shouldResumePlayback = false
        appIsForeground = true
        interrupted = false
        interruptionShouldResume = true
        interruptionResumeGateRequired = false
        cancelPendingLifecycleWork()
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
            interruptionResumeGateRequired = true
            interruptionShouldResume = false
            player.pause()
            isPlaying = false
            pendingSafeEnginePause()
        case .ended:
            interrupted = false
            if let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt {
                interruptionShouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            } else {
                interruptionShouldResume = false
            }
            if interruptionShouldResume {
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
            pendingSafeEnginePause()
        case .newDeviceAvailable, .categoryChange, .override, .routeConfigurationChange, .wakeFromSleep, .noSuitableRouteForCategory:
            if appIsForeground && !interrupted {
                attemptResumePlayback()
            }
        default:
            break
        }
    }
}
