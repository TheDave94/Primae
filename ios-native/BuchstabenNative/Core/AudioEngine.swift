import AVFoundation
import Foundation

final class AudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var currentFile: AVAudioFile?
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

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

    func loadAudioFile(named fileName: String) {
        guard let url = resourceURL(for: fileName) else {
            print("Missing audio file: \(fileName)")
            return
        }
        do {
            currentFile = try AVAudioFile(forReading: url)
            restart()
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
        guard !isPlaying else { return }
        startIfNeeded()
        if !player.isPlaying {
            player.play()
        }
        isPlaying = true
    }

    func stop() {
        player.pause()
        isPlaying = false
    }

    func restart() {
        guard let file = currentFile else { return }
        player.stop()
        player.scheduleFile(file, at: nil, completionHandler: nil)
        player.play()
        isPlaying = true
    }

    func suspendForLifecycle() {
        stop()
        pendingSafeEnginePause()
    }

    func resumeAfterLifecycle() {
        startIfNeeded()
        guard let file = currentFile else { return }
        if !player.isPlaying {
            player.scheduleFile(file, at: nil, completionHandler: nil)
        }
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
            stop()
        case .ended:
            startIfNeeded()
            if let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume) {
                play()
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

        if reason == .oldDeviceUnavailable {
            stop()
        }
    }
}
