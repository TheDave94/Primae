@preconcurrency import AVFoundation
import Foundation

@MainActor
public final class AudioEngine: @unchecked Sendable, AudioControlling, CustomStringConvertible {
    private nonisolated(unsafe) static var observerStore: [ObjectIdentifier: (interruption: NSObjectProtocol?, routeChange: NSObjectProtocol?)] = [:]
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
        // Configure AVAudioSession for playback so audio isn't silenced by the
        // mute switch or default ambient category.
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioEngine: AVAudioSession setup error: \(error)")
        }
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: nil)
        engine.connect(timePitch, to: engine.mainMixerNode, format: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
        interruptionObserver = nil

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in self?.handleRouteChangeValue(reason: reasonValue) }
        }

        Self.observerStore[ObjectIdentifier(self)] = (interruption: interruptionObserver, routeChange: routeChangeObserver)
        startIfNeeded()
    }

    deinit {
        Self.removeObservers(for: self)
    }

    func loadAudioFile(named fileName: String, autoplay: Bool = false) {
        guard let url = resourceURL(for: fileName) else {
            print("Missing audio file: \(fileName) [stack: \(Thread.callStackSymbols.prefix(4))]")
            return
        }

        do {
            do {
                currentFile = try AVAudioFile(forReading: url)
                guard engine.isRunning else {
                    startIfNeeded()
                    return
                }
                prepareCurrentTrack()
            } catch {
                player.stop()
                currentFile = nil
                isPlaying = false
                print("Audio load error: \(error)")
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
        let clampedSpeed = max(0.5, min(2.0, speed))
        timePitch.rate = clampedSpeed
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
        if canResumePlayback() {
            prepareCurrentTrack()
            if !player.isPlaying {
                player.play()
            }
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
        let observers = observerStore.removeValue(forKey: key)
        if let obs = observers?.interruption {
            NotificationCenter.default.removeObserver(obs)
        }
        if let obs = observers?.routeChange {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func resourceURL(for fileName: String) -> URL? {
        // Search Bundle.main first (Xcode app target puts resources there via Copy Bundle Resources),
        // then Bundle.module (Swift PM resource bundle). FileManager path construction is most
        // reliable for subdirectory assets on device.
        let bundles: [Bundle] = [.main, .module]
        let ns = fileName as NSString
        let resource = ns.lastPathComponent
        let subdir = ns.deletingLastPathComponent

        for bundle in bundles {
            // FileManager path -- works for both flat and subdirectory paths
            if let root = bundle.resourceURL {
                let candidate = root.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
            // Bundle API subdirectory lookup
            if !subdir.isEmpty,
               let url = bundle.url(forResource: resource, withExtension: nil, subdirectory: subdir) {
                return url
            }
            // Bundle API flat lookup
            if let url = bundle.url(forResource: fileName, withExtension: nil) { return url }
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

        do {
            try engine.start()
        } catch {
            print("AudioEngine start error: \(error)")
        }    }

    func canResumePlayback() -> Bool {
        let result = appIsForeground && !interrupted && shouldResumePlayback && (!interruptionResumeGateRequired || interruptionShouldResume)
        return result
    }

    func attemptResumePlayback() {
        startIfNeeded()
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

    func installObservers() {
        // Both observers use queue: .main, so the closure body already runs on the
        // main thread. Calling handlers directly (no Task, no MainActor.assumeIsolated)
        // avoids sending the non-Sendable notification/userInfo across an isolation
        // boundary, which is the Swift 6 data-race error at the call site.
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            if let typeValue,
               AVAudioSession.InterruptionType(rawValue: typeValue) == .began {
                self?.isPlaying = false
            }
            Task { @MainActor [weak self] in self?.handleInterruptionValues(type: typeValue, options: optionsValue) }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in self?.handleRouteChangeValue(reason: reasonValue) }
        }

        Self.observerStore[ObjectIdentifier(self)] = (interruption: interruptionObserver, routeChange: routeChangeObserver)
    }

    @objc func handleInterruption(_ notification: Notification) {
        let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
        if let typeValue,
           AVAudioSession.InterruptionType(rawValue: typeValue) == .began {
            isPlaying = false
        }
        handleInterruptionValues(type: typeValue, options: optionsValue)
    }

    func handleInterruptionValues(type typeValue: UInt?, options optionsValue: UInt?) {
        guard let typeValue else { return }
        switch AVAudioSession.InterruptionType(rawValue: typeValue) {
        case .began?:
            interrupted = true
            interruptionResumeGateRequired = true
            interruptionShouldResume = false
            player.pause()
            isPlaying = false
            pendingSafeEnginePause()
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
    public nonisolated var description: String { "<AudioEngine>" }

}

