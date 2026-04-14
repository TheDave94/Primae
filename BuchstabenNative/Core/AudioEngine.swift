import AVFoundation
import Foundation
import OSLog
import Synchronization

@MainActor
public final class AudioEngine: AudioControlling, CustomStringConvertible {

    // MARK: - Observer store (Mutex-protected for nonisolated deinit access)

    private typealias ObserverTasks = (interruption: Task<Void, Never>, routeChange: Task<Void, Never>)
    // nonisolated(unsafe) is load-bearing: nonisolated deinit needs actor-isolation escape. Xcode warning is a false positive — Mutex<> being Sendable is unrelated.
    private nonisolated(unsafe) static let observerStore = Mutex<[ObjectIdentifier: ObserverTasks]>([:])

    // MARK: - Private state

    private let engine     = AVAudioEngine()
    private let player     = AVAudioPlayerNode()
    private let timePitch  = AVAudioUnitTimePitch()
    private var currentFile: AVAudioFile?

    private var shouldResumePlayback          = false
    private var appIsForeground               = true
    private var interrupted                   = false
    private var interruptionShouldResume      = true
    private var interruptionResumeGateRequired = false
    private var pendingLifecyclePauseTask: Task<Void, Error>?

    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BuchstabenNative",
        category: "AudioEngine"
    )

    private(set) var isPlaying = false

    // MARK: - Debug accessors

    #if DEBUG
    var debugInterrupted:                  Bool { interrupted }
    var debugInterruptionShouldResume:     Bool { interruptionShouldResume }
    var debugIsEngineRunning:              Bool { engine.isRunning }
    var debugShouldResumePlayback:         Bool { shouldResumePlayback }
    var debugAppIsForeground:              Bool { appIsForeground }
    var debugInterruptionResumeGateRequired: Bool { interruptionResumeGateRequired }
    #endif

    // MARK: - Init / deinit

    public init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player,    to: timePitch,              format: engine.mainMixerNode.outputFormat(forBus: 0))
        engine.connect(timePitch, to: engine.mainMixerNode,   format: engine.mainMixerNode.outputFormat(forBus: 0))
        player.prepare(withFrameCount: 1024)
        timePitch.rate = 1.0; timePitch.pitch = 0.0

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback, mode: .default, options: [.interruptSpokenAudioAndMixWithOthers]
            )
            try? AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning {
                do { try engine.start() } catch {
                    player.stop()
                    isPlaying             = false
                    shouldResumePlayback  = false
                    log.error("Initial engine start failed: \(error.localizedDescription)")
                }
            }
        } catch {
            isPlaying            = false
            shouldResumePlayback = false
            log.error("AVAudioSession config failed: \(error.localizedDescription)")
        }

        let key = ObjectIdentifier(self)

        // Tasks inherit @MainActor isolation from init context.
        // [weak self] is still correct — these tasks are long-lived observers.
        let interruptionTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.interruptionNotification, object: nil
            ) {
                guard notification.name == AVAudioSession.interruptionNotification else { continue }
                guard let self else { break }
                let typeValue    = (notification.userInfo?[AVAudioSessionInterruptionTypeKey]    as? NSNumber)?.uintValue
                let optionsValue = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                if let typeValue,
                   let type = AVAudioSession.InterruptionType(rawValue: typeValue) {
                    if type == .began {
                        self.isPlaying = false
                        self.handleInterruptionBegan()
                    } else if type == .ended, self.shouldResumePlayback, self.currentFile != nil {
                        if self.canResumePlayback() { self.attemptResumePlayback() }
                    }
                }
                self.handleInterruptionValues(type: typeValue, options: optionsValue)
            }
        }

        let routeChangeTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification, object: nil
            ) {
                guard let self else { return }
                let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                self.handleRouteChangeValue(reason: reasonValue)
            }
        }

        Self.observerStore.withLock {
            $0[key] = (interruption: interruptionTask, routeChange: routeChangeTask)
        }
    }

    nonisolated deinit { AudioEngine.removeObservers(for: self) }

    // MARK: - AudioControlling

    func loadAudioFile(named fileName: String, autoplay: Bool = false) {
        guard let url = resourceURL(for: fileName) else {
            log.warning("Missing audio file: \(fileName)")
            return
        }
        do {
            player.stop()
            currentFile = try AVAudioFile(forReading: url)
            prepareCurrentTrack()
            guard engine.isRunning else { startIfNeeded(); return }
            shouldResumePlayback = autoplay
            if autoplay { attemptResumePlayback() } else { isPlaying = false }
        } catch {
            player.stop()
            currentFile          = nil
            isPlaying            = false
            shouldResumePlayback = false
            log.error("Failed to load audio file \(fileName): \(error.localizedDescription)")
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
        shouldResumePlayback           = true
        interruptionResumeGateRequired = false
        interruptionShouldResume       = true
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            log.error("Failed to activate audio session: \(error.localizedDescription)")
        }
        if !engine.isRunning { startIfNeeded() }
        attemptResumePlayback()
    }

    func stop() {
        shouldResumePlayback           = false
        isPlaying                      = false
        interruptionResumeGateRequired = false
        cancelPendingLifecycleWork()
        player.reset()
        player.stop()
        currentFile = nil
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            log.error("Stop failed to deactivate session: \(error.localizedDescription)")
        }
    }

    func restart() {
        shouldResumePlayback           = true
        interruptionResumeGateRequired = false
        interruptionShouldResume       = true
        if let file = currentFile { player.stop(); player.scheduleFile(file, at: nil, completionHandler: nil) }
        attemptResumePlayback()
    }

    func suspendForLifecycle() {
        appIsForeground      = false
        cancelPendingLifecycleWork()
        shouldResumePlayback = isPlaying || player.isPlaying
        player.pause()
        isPlaying = false
        pendingSafeEnginePause()
    }

    func resumeAfterLifecycle() {
        guard currentFile != nil else { shouldResumePlayback = false; return }
        appIsForeground = true
        cancelPendingLifecycleWork()
        startIfNeeded()
        if let file = currentFile, !player.isPlaying {
            player.scheduleFile(file, at: nil, completionHandler: nil)
        }
        if engine.isRunning && currentFile != nil && canResumePlayback() && appIsForeground {
            player.play()
            isPlaying = true
        }
    }

    func cancelPendingLifecycleWork() {
        pendingLifecyclePauseTask?.cancel()
        pendingLifecyclePauseTask = nil
    }

    public nonisolated var description: String { "<AudioEngine>" }
}

// MARK: - Private helpers

private extension AudioEngine {

    nonisolated static func removeObservers(for object: AnyObject) {
        let key   = ObjectIdentifier(object)
        let tasks = observerStore.withLock { $0.removeValue(forKey: key) }
        tasks?.interruption.cancel()
        tasks?.routeChange.cancel()
    }

    func resourceURL(for fileName: String) -> URL? {
        for bundle in [Bundle.main, Bundle.module] {
            if let url = bundle.url(forResource: fileName, withExtension: nil) { return url }
        }
        return nil
    }

    func startIfNeeded() {
        guard !engine.isRunning else { return }
        let session  = AVAudioSession.sharedInstance()
        let category = session.category
        let canStart = category == .playback || category == .playAndRecord || category == .multiRoute
        guard canStart || AVAudioApplication.shared.recordPermission == .granted else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        do {
            try engine.start()
        } catch {
            player.stop()
            isPlaying            = false
            shouldResumePlayback = false
            log.error("Engine failed to start: \(error.localizedDescription)")
        }
    }

    func canResumePlayback() -> Bool {
        appIsForeground && !interrupted && shouldResumePlayback
            && (!interruptionResumeGateRequired || interruptionShouldResume)
    }

    func attemptResumePlayback() {
        guard engine.isRunning else { startIfNeeded(); return }
        guard currentFile != nil else { return }
        prepareCurrentTrack()
        guard canResumePlayback() else {
            player.pause()
            isPlaying = false
            pendingSafeEnginePause()
            return
        }
        if !player.isPlaying { player.play() }
        isPlaying = true
    }

    func prepareCurrentTrack() {
        guard let currentFile else { return }
        player.stop()
        player.scheduleFile(currentFile, at: nil, completionHandler: nil)
        isPlaying = false
    }

    func pendingSafeEnginePause() {
        cancelPendingLifecycleWork()
        pendingLifecyclePauseTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(0.2))
            guard let self, !Task.isCancelled, !self.isPlaying else { return }
            self.engine.pause()
        }
    }

    func stopAndReset() {
        player.stop()
        engine.stop()
        currentFile                    = nil
        shouldResumePlayback           = false
        appIsForeground                = true
        interrupted                    = false
        interruptionShouldResume       = true
        interruptionResumeGateRequired = false
        cancelPendingLifecycleWork()
        isPlaying = false
    }

    func handleInterruptionBegan() {
        shouldResumePlayback = isPlaying
        player.pause()
        isPlaying = false
        stop()
    }

    func handleInterruptionValues(type typeValue: UInt?, options optionsValue: UInt?) {
        guard let typeValue else { return }
        // handleInterruptionValues is always called from the @MainActor observer Task.
        // The Thread.isMainThread guard is removed — we are always on MainActor here.
        switch AVAudioSession.InterruptionType(rawValue: typeValue) {
        case .began?:
            interrupted                    = true
            interruptionResumeGateRequired = true
            interruptionShouldResume       = false
            player.pause()
            isPlaying = false
            pendingSafeEnginePause()

        case .ended?:
            interrupted = false
            if let optionsValue {
                interruptionShouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    .contains(.shouldResume)
            } else {
                interruptionShouldResume = false
            }
            if interruptionShouldResume { attemptResumePlayback() }

        case nil:
            return
        @unknown default:
            break
        }
    }

    func handleRouteChangeValue(reason reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            stop()
        case .newDeviceAvailable, .categoryChange, .override,
             .routeConfigurationChange, .wakeFromSleep, .noSuitableRouteForCategory:
            if appIsForeground && !interrupted { attemptResumePlayback() }
        default:
            break
        }
    }
}
