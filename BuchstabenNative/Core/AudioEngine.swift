@preconcurrency import AVFoundation
import Foundation

@MainActor
public final class AudioEngine: AudioControlling, CustomStringConvertible {
    typealias Interruption = AVAudioSession.InterruptionType
    private nonisolated(unsafe) static var observerStore: [ObjectIdentifier: (interruption: Task<Void, Never>, routeChange: Task<Void, Never>)] = [:]
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private var currentFile: AVAudioFile?

    private var shouldResumePlayback = false
    private var appIsForeground = true
    private var interrupted = false
    private var interruptionShouldResume = true
    private var interruptionResumeGateRequired = false
    private var pendingLifecyclePauseTask: Task<Void, Error>?

    private(set) var isPlaying = false



    #if DEBUG
    var debugInterrupted: Bool { interrupted }
    var debugInterruptionShouldResume: Bool { interruptionShouldResume }
    var debugIsEngineRunning: Bool { engine.isRunning }
    var debugShouldResumePlayback: Bool { shouldResumePlayback }
    var debugAppIsForeground: Bool { appIsForeground }
    var debugInterruptionResumeGateRequired: Bool { interruptionResumeGateRequired }
    #endif

    public init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: engine.mainMixerNode.outputFormat(forBus: 0))
        engine.connect(timePitch, to: engine.mainMixerNode, format: engine.mainMixerNode.outputFormat(forBus: 0))
        player.prepare(withFrameCount: 1024)
        timePitch.rate = 1.0; timePitch.pitch = 0.0

        // Configure AVAudioSession for playback so audio isn't silenced by the
        // mute switch or default ambient category, then attempt initial engine start.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                options: [.interruptSpokenAudioAndMixWithOthers]
            )
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                do {
                    try engine.start()
                } catch {
                    player.stop()
                    print("AudioEngine initial start failed: \(error.localizedDescription)")
                    self.isPlaying = false
                    self.shouldResumePlayback = false
                }
            }
        } catch {
            self.isPlaying = false
            self.shouldResumePlayback = false
            print("AudioEngine session config failed: \(error.localizedDescription)")
        }

        let key = ObjectIdentifier(self)
        let interruptionTask = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification,
                object: nil
            ) {
                guard notification.name == AVAudioSession.interruptionNotification else { continue }
                guard let self else { break }
                let typeValue = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                let optionsValue = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                if let typeValue,
                   let type = Interruption(rawValue: typeValue) {
                    if type == .began {
                        self.isPlaying = false
                        self.handleInterruptionBegan()
                    } else if type == .ended, self.shouldResumePlayback, self.currentFile != nil {
                        if self.canResumePlayback() { self.attemptResumePlayback() }
                    }
                }
                self.handleInterruptionValues(type: typeValue, options: optionsValue)
            }
        }        let routeChangeTask = Task { @MainActor [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification,
                object: nil
            ) {
                guard let self else { return }
                let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                self.handleRouteChangeValue(reason: reasonValue)
            }
        }
        MainActor.assumeIsolated {
            Self.observerStore[key] = (interruption: interruptionTask, routeChange: routeChangeTask)
        }
    }

    nonisolated deinit { Self.removeObservers(for: self) }

    func loadAudioFile(named fileName: String, autoplay: Bool = false) {
        guard let url = resourceURL(for: fileName) else {
            print("Missing audio file: \(fileName)")
            return
        }

        do {
            do {
                player.stop()
                currentFile = try AVAudioFile(forReading: url)
                prepareCurrentTrack()
                guard engine.isRunning else {
                    startIfNeeded()
                    return
                }
            } catch {
                player.stop()
                currentFile = nil
                isPlaying = false
                shouldResumePlayback = false
                print("Failed to load audio file \(fileName): \(error.localizedDescription)")
                return
            }

            shouldResumePlayback = autoplay
            if autoplay {
                attemptResumePlayback()
            } else {
                isPlaying = false
            }
        }
    }

    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        guard speed.isFinite && horizontalBias.isFinite else { return }
        let clampedSpeed = max(0.5, min(2.0, speed))
        if timePitch.rate != clampedSpeed { timePitch.rate = clampedSpeed }
        player.pan = max(-1.0, min(1.0, horizontalBias))
    }

    func play() {
        guard currentFile != nil else { return }
        shouldResumePlayback = true
        interruptionResumeGateRequired = false
        interruptionShouldResume = true
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate session: \(error)")
        }
        if !engine.isRunning {
            startIfNeeded()
        }
        attemptResumePlayback()
    }

    func stop() {
        shouldResumePlayback = false
        isPlaying = false
        interruptionResumeGateRequired = false
        cancelPendingLifecycleWork()
        player.stop()
        currentFile = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("AudioEngine failed to deactivate session: \(error.localizedDescription)")
        }
    }

    func restart() {
        shouldResumePlayback = true
        interruptionResumeGateRequired = false
        interruptionShouldResume = true
        if let file = currentFile { player.stop(); player.scheduleFile(file, at: nil, completionHandler: nil) }
        attemptResumePlayback()
    }

    func suspendForLifecycle() {
        appIsForeground = false
        cancelPendingLifecycleWork()
        self.shouldResumePlayback = self.isPlaying || player.isPlaying
        player.pause()
        isPlaying = false
        pendingSafeEnginePause()
    }

    func resumeAfterLifecycle() {
        guard currentFile != nil else {
            self.shouldResumePlayback = false
            return
        }
        appIsForeground = true
        // Cancel any pending engine-pause task scheduled by suspendForLifecycle
        // before attempting resume. Without this cancellation, the 0.2-second
        // deferred engine.pause() fires after foreground return, stops the engine,
        // and causes testPendingSafeEnginePause_cancelledByResume to fail.
        cancelPendingLifecycleWork()
        // Restart the AVAudioEngine if it was stopped during suspension so the
        // next play() doesn't incur a cold-start latency. This must happen even
        // when shouldResumePlayback is false (no active playback intent) so that
        // the engine stays running and ready — matching the test assertion that
        // engine.isRunning == true after suspend+resume with no pending pause.
        startIfNeeded()
        if let file = currentFile, !player.isPlaying { player.scheduleFile(file, at: nil, completionHandler: nil) }
        if engine.isRunning && currentFile != nil && canResumePlayback() && appIsForeground {
            player.play()
            isPlaying = true
        }
    }
    func cancelPendingLifecycleWork() {
        pendingLifecyclePauseTask?.cancel()
        pendingLifecyclePauseTask = nil
    }
}

private extension AudioEngine {
    nonisolated static func removeObservers(for object: AnyObject) {
        let key = ObjectIdentifier(object)
        let tasks = observerStore.removeValue(forKey: key)
        tasks?.interruption.cancel()
        tasks?.routeChange.cancel()
    }

    func resourceURL(for fileName: String) -> URL? {
        let bundles: [Bundle] = [.main, .module]
        for bundle in bundles {
            if let url = bundle.url(forResource: fileName, withExtension: nil) {
                return url
            }
        }
        return nil
    }

    func startIfNeeded() {
        guard !engine.isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        let category = session.category
        let canStartForCategory = category == .playback || category == .playAndRecord || category == .multiRoute
        let hasRecordPermission = session.recordPermission == .granted

        guard canStartForCategory || hasRecordPermission else {
            return
        }

        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
        } catch {
            player.stop()
            isPlaying = false
            shouldResumePlayback = false
            print("AudioEngine failed to start: \(error.localizedDescription)")
        }
    }

    func canResumePlayback() -> Bool {
        let result = appIsForeground && !interrupted && shouldResumePlayback && (!interruptionResumeGateRequired || interruptionShouldResume)
        return result
    }

    func attemptResumePlayback() {
        guard engine.isRunning else {
            startIfNeeded()
            return
        }
        // No file loaded — record intent (shouldResumePlayback set by caller) but do not
        // attempt to play. Calling player.play() with nothing scheduled is a no-op at best
        // and raises an AVAudioEngine "not running" assertion at worst (headless CI). The
        // caller's shouldResumePlayback=true is preserved so the engine will start playing
        // once a file is loaded via loadAudioFile(named:autoplay:).
        guard currentFile != nil else { return }
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
        guard let currentFile = currentFile else { return }
        player.stop()
        player.scheduleFile(currentFile, at: nil, completionHandler: nil)
        isPlaying = false
    }

    func pendingSafeEnginePause() {
        cancelPendingLifecycleWork()
        let task = Task { @MainActor [weak self] in
            try await Task.sleep(for: .seconds(0.2))
            guard let self, !Task.isCancelled else { return }
            guard !self.isPlaying else { return }
            self.engine.pause()
        }
        pendingLifecyclePauseTask = task
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

    func handleInterruptionBegan() {
        self.shouldResumePlayback = self.isPlaying
        player.pause()
        self.isPlaying = false
        stop()
    }
    func handleInterruptionValues(type typeValue: UInt?, options optionsValue: UInt?) {
        guard let typeValue else { return }
        switch Interruption(rawValue: typeValue) {
        case .began?:
            interrupted = true
            interruptionResumeGateRequired = true
            interruptionShouldResume = false
            if Thread.isMainThread {
                player.pause()
                isPlaying = false
                pendingSafeEnginePause()
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.player.pause()
                    self.isPlaying = false
                    self.pendingSafeEnginePause()
                }
            }
        case .ended?:
            interrupted = false
            if let optionsValue {
                interruptionShouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
            } else {
                interruptionShouldResume = false
            }
            if interruptionShouldResume {
                attemptResumePlayback()
            }
        case nil:
            return
        @unknown default:
            break
        }
    }
    func handleRouteChangeValue(reason reasonValue: UInt?) {
        guard let reasonValue, let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .oldDeviceUnavailable:
            stop()
        case .newDeviceAvailable, .categoryChange, .override, .routeConfigurationChange, .wakeFromSleep, .noSuitableRouteForCategory:
            if appIsForeground && !interrupted {
                attemptResumePlayback()
            }
        default:
            break
        }
    }
    public nonisolated var description: String { "<AudioEngine>" }

}

