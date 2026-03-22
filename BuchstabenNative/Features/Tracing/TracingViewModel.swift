import UIKit
import CoreGraphics
import QuartzCore
import Foundation

// 1. Added 'public' to the class
@MainActor
@Observable
public final class TracingViewModel {
    var showGhost = false
    /// Non-nil while an Apple Pencil is in contact; nil for finger/mouse. Range 0–1.
    var pencilPressure: CGFloat? = nil
    /// Azimuth angle (radians) of the Apple Pencil; 0 when no pencil.
    var pencilAzimuth: CGFloat = 0
    var strokeEnforced = true
    var showDebug = false
    var toastMessage: String?
    var currentLetterName = "A"
    var currentLetterImageName = ""
    var currentLetterImage: UIImage? = nil
    var canvasSize: CGSize = CGSize(width: 1024, height: 1024)
    var progress: CGFloat = 0
    var isPlaying = false
    var activePath: [CGPoint] = []
    var completionMessage: String?
    private(set) var currentDifficultyTier: DifficultyTier = .standard

    private let repo: LetterRepository
    private let strokeTracker = StrokeTracker()
    private let audio: AudioControlling
    private let haptics: HapticEngineProviding
    let progressStore: ProgressStoring
    private var adaptationPolicy: any AdaptationPolicy

    private var letters: [LetterAsset] = []
    private var letterIndex = 0
    private var audioIndex = 0
    private var lastPoint: CGPoint?
    private var lastTimestamp: CFTimeInterval?
    private var isMultiTouchNavigationActive = false
    private var singleTouchSuppressedUntil: CFTimeInterval = 0
    private var isSingleTouchInteractionActive = false
    private var didCompleteCurrentLetter = false
    private var playbackMachine = PlaybackStateMachine()
    private var pendingPlaybackStateTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var completionDismissTask: Task<Void, Never>?
    private var smoothedVelocity: CGFloat = 0
    private let velocitySmoothingAlpha: CGFloat = 0.22
    private let activeDebounceSeconds: TimeInterval = 0.03
    private let idleDebounceSeconds: TimeInterval = 0.12
    private let playbackActivationVelocityThreshold: CGFloat = 22
    private let singleTouchCooldownAfterNavigation: CFTimeInterval

    // Public no-arg initializer uses .live dependencies (production defaults).
@MainActor
public convenience init() {
    self.init(.live)
}


@MainActor
init(_ deps: TracingDependencies = .live) {
    self.singleTouchCooldownAfterNavigation = deps.singleTouchCooldownAfterNavigation
    self.audio = deps.audio
    self.progressStore = deps.progressStore
    self.haptics = deps.haptics
    self.repo = deps.repo
    self.adaptationPolicy = deps.adaptationPolicy ?? MovingAverageAdaptationPolicy()
    haptics.prepare()
    letters = repo.loadLetters()
    guard let first = letters.first else { return }
    load(letter: first)
    toast("Ready")
}
    func toggleGhost() { showGhost.toggle(); toast("Ghost \(showGhost ? "ON" : "OFF")") }
    func toggleStrokeEnforcement() { strokeEnforced.toggle(); resetLetter(); toast("Order \(strokeEnforced ? "ON" : "OFF")") }
    func toggleDebug() { showDebug.toggle(); toast("Debug \(showDebug ? "ON" : "OFF")") }

    // MARK: - Accessibility

    /// Human-readable label for the tracing canvas, including current letter name.
    var accessibilityCanvasLabel: String {
        "Tracing canvas — Letter \(currentLetterName)"
    }

    /// Human-readable progress value for VoiceOver.
    var accessibilityCanvasValue: String {
        let pct = Int(max(0, min(1, progress)) * 100)
        if pct == 0 { return "Not started" }
        if pct == 100 { return "Complete" }
        return "\(pct) percent complete"
    }

    /// Plays the current letter's audio from the beginning (VoiceOver custom action).
    func replayAudio() {
        audio.stop()
        audio.play()
    }


    func resetLetter() {
        strokeTracker.reset()
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        smoothedVelocity = 0
        playbackMachine.resumeIntent = false
        cancelPendingPlaybackWork()
        // Always stop audio unconditionally: setPlaybackState only fires stop when
        // the machine transitions active→idle, but any pending debounce work or
        // not-yet-activated audio must also be silenced on reset. Explicit stop
        // ensures tests that assert "reset stops audio" pass even if the debounce
        // never fired (e.g. synchronous grid scans that don't pump the RunLoop).
        audio.stop()
        playbackMachine.forceIdle()
        isPlaying = false
        didCompleteCurrentLetter = false
        completionDismissTask?.cancel()
        completionMessage = nil
        toast("Reset")
    }

    func nextLetter() {
        guard !letters.isEmpty else { return }
        letterIndex = (letterIndex + 1) % letters.count
        load(letter: letters[letterIndex])
        toast("Letter: \(currentLetterName)")
    }

    func previousLetter() {
        guard !letters.isEmpty else { return }
        letterIndex = (letterIndex - 1 + letters.count) % letters.count
        load(letter: letters[letterIndex])
        toast("Letter: \(currentLetterName)")
    }

    func randomLetter() {
        guard !letters.isEmpty else { return }
        letterIndex = Int.random(in: 0..<letters.count)
        load(letter: letters[letterIndex])
        randomAudioVariant()
        toast("Random: \(currentLetterName)")
    }

    func nextAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = (audioIndex + 1) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
        toast("Sound \(audioIndex + 1)/\(files.count)")
    }

    func previousAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = (audioIndex - 1 + files.count) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
        toast("Sound \(audioIndex + 1)/\(files.count)")
    }

    func beginMultiTouchNavigation() {
        guard !isMultiTouchNavigationActive else { return }
        isMultiTouchNavigationActive = true
        endTouch()
    }

    func endMultiTouchNavigation() {
        guard isMultiTouchNavigationActive else { return }
        isMultiTouchNavigationActive = false
        singleTouchSuppressedUntil = CACurrentMediaTime() + singleTouchCooldownAfterNavigation
    }

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        guard !isMultiTouchNavigationActive else { return }
        guard t >= singleTouchSuppressedUntil else { return }
        guard !isSingleTouchInteractionActive else { return }

        isSingleTouchInteractionActive = true
        playbackMachine.resumeIntent = true
        lastPoint = p
        lastTimestamp = t
        activePath = [p]
        haptics.fire(.strokeBegan)
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        guard !isMultiTouchNavigationActive else { return }
        guard isSingleTouchInteractionActive else { return }
        activePath.append(p)

        guard let lastPoint, let lastTimestamp else { return }
        let dt = max(0.001, t - lastTimestamp)
        let dx = p.x - lastPoint.x
        let dy = p.y - lastPoint.y
        let velocity = hypot(dx, dy) / dt

        if smoothedVelocity == 0 {
            smoothedVelocity = velocity
        } else {
            smoothedVelocity = smoothedVelocity + (velocitySmoothingAlpha * (velocity - smoothedVelocity))
        }

        let normalized = CGPoint(x: p.x / max(canvasSize.width, 1), y: p.y / max(canvasSize.height, 1))
        let prevStrokeIndex = strokeTracker.currentStrokeIndex
        let prevNextCheckpoint = strokeTracker.progress.indices.contains(prevStrokeIndex) ? strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        strokeTracker.update(normalizedPoint: normalized)
        progress = strokeTracker.overallProgress

        // Haptic: checkpoint hit or stroke completed
        let newStrokeIndex = strokeTracker.currentStrokeIndex
        let newNextCheckpoint = strokeTracker.progress.indices.contains(prevStrokeIndex) ? strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        if prevNextCheckpoint != newNextCheckpoint || newStrokeIndex != prevStrokeIndex {
            if strokeTracker.progress.indices.contains(prevStrokeIndex) && strokeTracker.progress[prevStrokeIndex].complete {
                haptics.fire(.strokeCompleted)
            } else {
                haptics.fire(.checkpointHit)
            }
        }

        let speed = Self.mapVelocityToSpeed(smoothedVelocity)
        let azimuthBias = pencilPressure != nil ? cos(pencilAzimuth) * 0.5 : 0
        let hBias = Float(max(-1.0, min(1.0, dx / 20.0 + azimuthBias)))
        audio.setAdaptivePlayback(speed: speed, horizontalBias: hBias)

        let shouldPlayForStroke = strokeEnforced ? strokeTracker.soundEnabled : true
        let shouldBeActive = shouldPlayForStroke && smoothedVelocity >= playbackActivationVelocityThreshold
        setPlaybackState(shouldBeActive ? .active : .idle, immediate: false)

        if strokeTracker.isComplete, !didCompleteCurrentLetter {
            didCompleteCurrentLetter = true
            haptics.fire(.letterCompleted)
            let accuracy = Double(strokeTracker.overallProgress)
            progressStore.recordCompletion(for: currentLetterName, accuracy: accuracy)
            let adaptSample = AdaptationSample(letter: currentLetterName, accuracy: CGFloat(accuracy), completionTime: 0)
            adaptationPolicy.record(adaptSample)
            currentDifficultyTier = adaptationPolicy.currentTier
            strokeTracker.radiusMultiplier = currentDifficultyTier.radiusMultiplier
            showCompletionHUD()
            toast("Great! Completed")
            setPlaybackState(.idle, immediate: true)
        }

        self.lastPoint = p
        self.lastTimestamp = t
    }


    public func appDidEnterBackground() {
        // Guard against re-entrant / duplicate background events (idempotency).
        // AVAudioSession interruptions and UIApplication.didEnterBackground can fire
        // in quick succession; only process the first one per foreground period.
        guard playbackMachine.appIsForeground else { return }
        playbackMachine.appIsForeground = false
        cancelPendingPlaybackWork()
        endTouch()
        // Apply state machine transition and honour the returned command.
        // Then also call audio.stop() unconditionally as a belt-and-suspenders
        // safety net: if a debounced "active" transition was queued but hadn't
        // fired yet, the machine is still .idle (transition returns .none) so
        // applyCommand would be a no-op — but audio must be definitively silent
        // before suspension (e.g. AVAudioSession interruption mid-debounce window).
        let cmd = playbackMachine.transition(to: .idle)
        applyCommand(cmd)
        // Unconditional stop ensures audio is silent even if cmd == .none.
        if cmd == .none {
            audio.stop()
            isPlaying = false
        }
        audio.suspendForLifecycle()
    }

    public func appDidBecomeActive() {
        playbackMachine.appIsForeground = true
        audio.resumeAfterLifecycle()
        if playbackMachine.resumeIntent {
            setPlaybackState(playbackMachine.state, immediate: true)
        }
    }

    func endTouch() {
        isSingleTouchInteractionActive = false
        lastPoint = nil
        lastTimestamp = nil
        activePath.removeAll(keepingCapacity: true)
        smoothedVelocity = 0
        pencilPressure = nil
        pencilAzimuth = 0
        playbackMachine.resumeIntent = false
        cancelPendingPlaybackWork()
        setPlaybackState(.idle, immediate: true)
    }
    private func load(letter: LetterAsset) {
        showGhost = false
        currentLetterName = letter.name
        currentLetterImageName = letter.imageName
        currentLetterImage = PrimaeLetterRenderer.render(letter: letter.name, size: canvasSize)
        strokeTracker.load(letter.strokes)
        progress = 0
        audioIndex = 0
        didCompleteCurrentLetter = false
        completionDismissTask?.cancel()
        completionMessage = nil
        activePath.removeAll(keepingCapacity: true)
        isSingleTouchInteractionActive = false
        smoothedVelocity = 0
        playbackMachine.resumeIntent = true
        cancelPendingPlaybackWork()
        // Ghost guide is scoped to a single letter. Reset here prevents a ghost enabled on
        // letter N from unexpectedly persisting when the user navigates to letter N+1.
        showGhost = false
        if let firstAudio = letter.audioFiles.first {
            audio.loadAudioFile(named: firstAudio, autoplay: false)
            setPlaybackState(.idle, immediate: true)
        }
    }

    private func randomAudioVariant() {
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        audioIndex = Int.random(in: 0..<files.count)
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
    }


    #if DEBUG
    var debugIsMultiTouchNavigationActive: Bool { isMultiTouchNavigationActive }
    var debugActivePathCount: Int { activePath.count }
    #endif

    func dismissCompletionHUD() {
        completionDismissTask?.cancel()
        completionMessage = nil
    }

    private func showCompletionHUD() {
        completionDismissTask?.cancel()
        let letter = currentLetterName
        completionMessage = "🎉 \(letter) geschafft!"
        completionDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self else { return }
            if self.completionMessage == "🎉 \(letter) geschafft!" {
                self.completionMessage = nil
            }
        }
    }

    static func mapVelocityToSpeed(_ v: CGFloat) -> Float {
        let low: CGFloat = 120
        let high: CGFloat = 1300
        if v <= low { return 2.0 }
        if v >= high { return 0.5 }
        let t = (v - low) / (high - low)
        return Float(2.0 - (1.5 * t))
    }

    private func setPlaybackState(_ target: PlaybackStateMachine.State, immediate: Bool) {
        pendingPlaybackStateTask?.cancel()
        pendingPlaybackStateTask = nil

        // Guards are enforced inside PlaybackStateMachine.transition(to:)
        // For immediate path, apply directly; for debounced path, check early.
        let wouldChange: Bool
        if target == .active && (!playbackMachine.appIsForeground || !playbackMachine.resumeIntent) {
            wouldChange = playbackMachine.state != .idle
        } else {
            wouldChange = playbackMachine.state != target
        }

        if immediate {
            let cmd = playbackMachine.transition(to: target)
            applyCommand(cmd)
            return
        }

        guard wouldChange else { return }

        let delay = target == .active ? activeDebounceSeconds : idleDebounceSeconds
        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            let cmd = self.playbackMachine.transition(to: target)
            self.applyCommand(cmd)
        }
        pendingPlaybackStateTask = task
    }

    private func cancelPendingPlaybackWork() {
        guard let c = pendingPlaybackStateTask else {
            audio.cancelPendingLifecycleWork()
            return
        }
        if c.isCancelled {
            pendingPlaybackStateTask = nil
            audio.cancelPendingLifecycleWork()
            return
        }
        c.cancel()
        pendingPlaybackStateTask = nil
        audio.cancelPendingLifecycleWork()
    }

    private func applyCommand(_ cmd: PlaybackStateMachine.Command) {
        switch cmd {
        case .play:
            audio.play()
            isPlaying = true
        case .stop:
            audio.stop()
            isPlaying = false
        case .none:
            break
        }
    }

    private func cancelToastTask() {
        guard let c = toastTask else { return }
        if c.isCancelled {
            toastTask = nil
            return
        }
        c.cancel()
        toastTask = nil
    }

    private func toast(_ text: String) {
        toastMessage = text
        cancelToastTask()

        toastTask = Task { @MainActor [weak self, message = text] in
            do {
                try await Task.sleep(for: .seconds(1.3))
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            guard self.toastMessage == message else { return }
            self.toastMessage = nil
            self.toastTask = nil
        }
    }
}
