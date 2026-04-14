import UIKit
import CoreGraphics
import QuartzCore
import Foundation

@MainActor
@Observable
public final class TracingViewModel {

    // MARK: - Public observable state

    var showGhost           = false
    var pencilPressure: CGFloat? = nil
    var pencilAzimuth: CGFloat   = 0
    var strokeEnforced      = true
    var showDebug           = false
    var toastMessage: String?
    var currentLetterName   = "A"
    var currentLetterImageName = ""
    var currentLetterImage: UIImage? = nil
    var canvasSize: CGSize  = CGSize(width: 1024, height: 1024)
    var progress: CGFloat   = 0
    var isPlaying           = false
    var activePath: [CGPoint] = []
    var completionMessage: String?
    private(set) var currentDifficultyTier: DifficultyTier = .standard

    // MARK: - Animation guide state (ready for onboarding / demo UI)

    /// Normalized (0–1) point for the animated tracing guide dot.
    /// TracingCanvasView scales this to screen coordinates.
    private(set) var animationGuidePoint: CGPoint? = nil

    // MARK: - Onboarding state (ready for onboarding UI layer)

    /// True once the user has completed onboarding.
    var isOnboardingComplete: Bool { onboardingStore.hasCompletedOnboarding }
    /// Current onboarding step for presenting onboarding UI.
    private(set) var onboardingStep: OnboardingStep = .welcome
    /// Progress through onboarding steps (0–1).
    var onboardingProgress: Double { onboardingCoordinator.progress }

    // MARK: - Private dependencies

    private let repo: LetterRepository
    private let strokeTracker           = StrokeTracker()
    private let audio: AudioControlling
    private let haptics: HapticEngineProviding
    let progressStore: ProgressStoring
    private let streakStore: StreakStoring
    private let dashboardStore: ParentDashboardStoring
    private let onboardingStore: OnboardingStoring
    private let notificationScheduler: LocalNotificationScheduler
    private let syncCoordinator: SyncCoordinator
    private var adaptationPolicy: any AdaptationPolicy
    private var onboardingCoordinator: OnboardingCoordinator

    // MARK: - Private playback / touch state

    private var letters: [LetterAsset]          = []
    private var letterIndex                      = 0
    private var audioIndex                       = 0
    private var lastPoint: CGPoint?
    private var lastTimestamp: CFTimeInterval?
    private var letterLoadTime: CFTimeInterval?  // for session-duration tracking
    private var isMultiTouchNavigationActive     = false
    private var singleTouchSuppressedUntil: CFTimeInterval = 0
    private var isSingleTouchInteractionActive   = false
    private var didCompleteCurrentLetter         = false
    private var playbackMachine                  = PlaybackStateMachine()
    private var pendingPlaybackStateTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var completionDismissTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?
    private var smoothedVelocity: CGFloat        = 0
    private let velocitySmoothingAlpha: CGFloat  = 0.22
    private let activeDebounceSeconds: TimeInterval  = 0.03
    private let idleDebounceSeconds: TimeInterval    = 0.12
    private let playbackActivationVelocityThreshold: CGFloat = 22
    private let minimumTouchMoveDistance: CGFloat    = 1.5
    private let singleTouchCooldownAfterNavigation: CFTimeInterval

    // MARK: - Init

    @MainActor
    public convenience init() { self.init(.live) }

    @MainActor
    init(_ deps: TracingDependencies = .live) {
        self.singleTouchCooldownAfterNavigation = deps.singleTouchCooldownAfterNavigation
        self.audio                  = deps.audio
        self.progressStore          = deps.progressStore
        self.haptics                = deps.haptics
        self.repo                   = deps.repo
        self.streakStore            = deps.streakStore
        self.dashboardStore         = deps.dashboardStore
        self.onboardingStore        = deps.onboardingStore
        self.notificationScheduler  = deps.notificationScheduler
        self.syncCoordinator        = deps.syncCoordinator
        self.adaptationPolicy       = deps.adaptationPolicy ?? MovingAverageAdaptationPolicy()

        // Resume onboarding from saved step if available
        var coordinator = OnboardingCoordinator()
        if let savedStep = deps.onboardingStore.savedStep {
            coordinator.resume(at: savedStep)
        }
        self.onboardingCoordinator = coordinator
        self.onboardingStep        = coordinator.currentStep

        haptics.prepare()
        letters = repo.loadLetters()
        guard let first = letters.first else { return }
        load(letter: first)
        toast("Ready")
    }

    // MARK: - Toggles

    func toggleGhost()             { showGhost.toggle();         toast("Ghost \(showGhost ? "ON" : "OFF")") }
    func toggleStrokeEnforcement() { strokeEnforced.toggle();    resetLetter(); toast("Order \(strokeEnforced ? "ON" : "OFF")") }
    func toggleDebug()             { showDebug.toggle();         toast("Debug \(showDebug ? "ON" : "OFF")") }

    // MARK: - Accessibility

    var accessibilityCanvasLabel: String {
        "Tracing canvas — Letter \(currentLetterName)"
    }

    var accessibilityCanvasValue: String {
        let pct = Int(max(0, min(1, progress)) * 100)
        if pct == 0   { return "Not started" }
        if pct == 100 { return "Complete" }
        return "\(pct) percent complete"
    }

    func replayAudio() {
        audio.stop()
        audio.play()
    }

    // MARK: - Letter navigation

    func resetLetter() {
        strokeTracker.reset()
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        smoothedVelocity = 0
        playbackMachine.resumeIntent = false
        cancelPendingPlaybackWork()
        audio.stop()
        playbackMachine.forceIdle()
        isPlaying = false
        didCompleteCurrentLetter = false
        completionDismissTask?.cancel()
        completionMessage = nil
        stopGuideAnimation()
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
        guard files.indices.contains(audioIndex) else { audioIndex = 0; return }
        audioIndex = (audioIndex + 1) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
        toast("Sound \(audioIndex + 1)/\(files.count)")
    }

    func previousAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        guard files.indices.contains(audioIndex) else { audioIndex = 0; return }
        audioIndex = (audioIndex - 1 + files.count) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
        toast("Sound \(audioIndex + 1)/\(files.count)")
    }

    // MARK: - Multi-touch navigation

    func beginMultiTouchNavigation() {
        guard !isMultiTouchNavigationActive else { return }
        isMultiTouchNavigationActive = true
        endTouch()
    }

    func endMultiTouchNavigation() {
        guard isMultiTouchNavigationActive else { return }
        isMultiTouchNavigationActive = false
        singleTouchSuppressedUntil   = CACurrentMediaTime() + singleTouchCooldownAfterNavigation
    }

    // MARK: - Touch handling

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        guard !isMultiTouchNavigationActive       else { return }
        guard t >= singleTouchSuppressedUntil     else { return }
        guard !isSingleTouchInteractionActive     else { return }

        isSingleTouchInteractionActive   = true
        playbackMachine.resumeIntent     = true
        lastPoint                        = p
        lastTimestamp                    = t
        activePath                       = [p]
        haptics.fire(.strokeBegan)
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        guard !isMultiTouchNavigationActive       else { return }
        guard isSingleTouchInteractionActive      else { return }
        guard let lastPoint                       else { return }

        let isWithinCanvasBounds =
            p.x >= 0 && p.y >= 0 && p.x <= canvasSize.width && p.y <= canvasSize.height

        let dx       = p.x - lastPoint.x
        let dy       = p.y - lastPoint.y
        let distance = hypot(dx, dy)

        if isWithinCanvasBounds && distance >= minimumTouchMoveDistance {
            activePath.append(p)
        }

        if let lastTimestamp {
            let dt       = max(0.001, t - lastTimestamp)
            let velocity = distance / dt
            smoothedVelocity = smoothedVelocity == 0
                ? velocity
                : smoothedVelocity + velocitySmoothingAlpha * (velocity - smoothedVelocity)
        } else {
            self.lastTimestamp = t
        }

        let normalized     = CGPoint(x: p.x / max(canvasSize.width, 1),
                                     y: p.y / max(canvasSize.height, 1))
        let prevStrokeIndex   = strokeTracker.currentStrokeIndex
        let prevNextCheckpoint = strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        let wasComplete       = strokeTracker.isComplete

        strokeTracker.update(normalizedPoint: normalized)

        let isNowComplete = strokeTracker.isComplete
        if !wasComplete && isNowComplete { haptics.fire(.letterCompleted) }
        progress = strokeTracker.overallProgress

        let newStrokeIndex     = strokeTracker.currentStrokeIndex
        let newNextCheckpoint  = strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        if prevNextCheckpoint != newNextCheckpoint || newStrokeIndex != prevStrokeIndex {
            if strokeTracker.progress.indices.contains(prevStrokeIndex)
                && strokeTracker.progress[prevStrokeIndex].complete {
                haptics.fire(.strokeCompleted)
            } else {
                haptics.fire(.checkpointHit)
            }
        }

        let speed        = Self.mapVelocityToSpeed(smoothedVelocity)
        let azimuthBias  = pencilPressure != nil ? cos(pencilAzimuth) * 0.5 : 0
        let hBias        = Float(max(-1.0, min(1.0, dx / 20.0 + azimuthBias)))
        audio.setAdaptivePlayback(speed: speed, horizontalBias: hBias)

        let shouldPlayForStroke = strokeEnforced ? strokeTracker.soundEnabled : true
        let shouldBeActive      = shouldPlayForStroke && smoothedVelocity >= playbackActivationVelocityThreshold
        setPlaybackState(shouldBeActive ? .active : .idle, immediate: false)

        if strokeTracker.isComplete, !didCompleteCurrentLetter {
            didCompleteCurrentLetter = true
            haptics.fire(.letterCompleted)

            let accuracy = Double(strokeTracker.overallProgress)
            let duration = letterLoadTime.map { CACurrentMediaTime() - $0 } ?? 0
            let letter   = currentLetterName

            // — Core progress (existing) —
            progressStore.recordCompletion(for: letter, accuracy: accuracy)

            // — Streak tracking —
            streakStore.recordSession(date: Date(), lettersCompleted: [letter], accuracy: accuracy)

            // — Parent dashboard —
            dashboardStore.recordSession(letter: letter, accuracy: accuracy,
                                          durationSeconds: duration, date: Date())

            // — Background cloud sync —
            Task { [self] in try? await syncCoordinator.pushAll() }

            // — Difficulty adaptation —
            let adaptSample = AdaptationSample(letter: letter,
                                               accuracy: CGFloat(accuracy),
                                               completionTime: duration)
            adaptationPolicy.record(adaptSample)
            currentDifficultyTier                 = adaptationPolicy.currentTier
            strokeTracker.radiusMultiplier        = currentDifficultyTier.radiusMultiplier

            showCompletionHUD()
            toast("Great! Completed")
            setPlaybackState(.idle, immediate: true)
        }

        self.lastPoint     = p
        self.lastTimestamp = t
    }

    // MARK: - Lifecycle

    public func appDidEnterBackground() {
        guard playbackMachine.appIsForeground else { return }
        playbackMachine.appIsForeground = false
        cancelPendingPlaybackWork()
        endTouch()
        let cmd = playbackMachine.transition(to: .idle)
        applyCommand(cmd)
        if cmd == .none { audio.stop(); isPlaying = false }
        audio.suspendForLifecycle()
    }

    public func appDidBecomeActive() {
        playbackMachine.appIsForeground = true
        audio.resumeAfterLifecycle()
        if playbackMachine.resumeIntent {
            setPlaybackState(playbackMachine.state, immediate: true)
        }
        // Refresh daily reminder with current streak
        if isOnboardingComplete {
            notificationScheduler.scheduleDailyReminder(
                currentStreak: streakStore.currentStreak,
                onboardingComplete: true
            )
        }
    }

    func endTouch() {
        isSingleTouchInteractionActive = false
        lastPoint                      = nil
        lastTimestamp                  = nil
        activePath.removeAll(keepingCapacity: true)
        smoothedVelocity               = 0
        pencilPressure                 = nil
        pencilAzimuth                  = 0
        playbackMachine.resumeIntent   = false
        cancelPendingPlaybackWork()
        audio.stop()
        setPlaybackState(.idle, immediate: true)
    }

    // MARK: - Completion HUD

    func dismissCompletionHUD() {
        completionDismissTask?.cancel()
        completionMessage = nil
    }

    // MARK: - Animation guide
    // Drives an animated dot along the letter's stroke path.
    // Call startGuideAnimation() to show the demo; stopGuideAnimation() to cancel.

    func startGuideAnimation() {
        guard let definition = strokeTracker.definition else { return }
        stopGuideAnimation()
        let guide = LetterAnimationGuide.build(from: definition)
        guard !guide.steps.isEmpty else { return }

        animationTask = Task { [self] in
            for step in guide.steps {
                guard !Task.isCancelled else { break }
                animationGuidePoint = step.point
                try? await Task.sleep(for: .seconds(guide.duration(for: step)))
            }
            if !Task.isCancelled { animationGuidePoint = nil }
        }
    }

    func stopGuideAnimation() {
        animationTask?.cancel()
        animationTask        = nil
        animationGuidePoint  = nil
    }

    // MARK: - Onboarding control
    // These methods are called by onboarding UI (future expansion).

    /// Advance to the next onboarding step. Call from onboarding UI buttons.
    func advanceOnboarding() {
        guard onboardingCoordinator.advance() else { return }
        onboardingStep = onboardingCoordinator.currentStep
        if onboardingCoordinator.isComplete {
            onboardingStore.markComplete()
            // Request notification permission and schedule reminder on onboarding completion
            Task { [self] in
                _ = await notificationScheduler.requestPermission()
                notificationScheduler.scheduleDailyReminder(
                    currentStreak: streakStore.currentStreak,
                    onboardingComplete: true
                )
            }
        } else {
            onboardingStore.saveProgress(step: onboardingCoordinator.currentStep)
        }
    }

    /// Skip all onboarding steps immediately.
    func skipOnboarding() {
        onboardingCoordinator.skip()
        onboardingStep = onboardingCoordinator.currentStep
        onboardingStore.markComplete()
    }

    // MARK: - Debug

    #if DEBUG
    var debugIsMultiTouchNavigationActive: Bool { isMultiTouchNavigationActive }
    var debugActivePathCount: Int { activePath.count }
    #endif

    // MARK: - Private helpers

    private func load(letter: LetterAsset) {
        showGhost                      = false
        currentLetterName              = letter.name
        currentLetterImageName         = letter.imageName
        currentLetterImage             = PBMLoader.load(named: letter.imageName) ?? PrimaeLetterRenderer.render(letter: letter.name, size: canvasSize)
        strokeTracker.load(letter.strokes)
        progress                       = 0
        audioIndex                     = 0
        didCompleteCurrentLetter       = false
        letterLoadTime                 = CACurrentMediaTime()
        completionDismissTask?.cancel()
        completionMessage              = nil
        activePath.removeAll(keepingCapacity: true)
        isSingleTouchInteractionActive = false
        smoothedVelocity               = 0
        playbackMachine.resumeIntent   = true
        cancelPendingPlaybackWork()
        stopGuideAnimation()
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

    private func showCompletionHUD() {
        completionDismissTask?.cancel()
        let letter = currentLetterName
        completionMessage = "🎉 \(letter) geschafft!"
        completionDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, !Task.isCancelled else { return }
            if self.completionMessage == "🎉 \(letter) geschafft!" { self.completionMessage = nil }
        }
    }

    static func mapVelocityToSpeed(_ v: CGFloat) -> Float {
        let low: CGFloat = 120, high: CGFloat = 1300
        if v <= low  { return 2.0 }
        if v >= high { return 0.5 }
        return Float(2.0 - 1.5 * ((v - low) / (high - low)))
    }

    private func setPlaybackState(_ target: PlaybackStateMachine.State, immediate: Bool) {
        pendingPlaybackStateTask?.cancel()
        pendingPlaybackStateTask = nil

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
        pendingPlaybackStateTask = Task { [self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            let cmd = playbackMachine.transition(to: target)
            applyCommand(cmd)
        }
    }

    private func cancelPendingPlaybackWork() {
        pendingPlaybackStateTask?.cancel()
        pendingPlaybackStateTask = nil
        audio.cancelPendingLifecycleWork()
    }

    private func applyCommand(_ cmd: PlaybackStateMachine.Command) {
        switch cmd {
        case .play:  audio.play();  isPlaying = true
        case .stop:  audio.stop();  isPlaying = false
        case .none:  break
        }
    }

    private func toast(_ text: String) {
        toastMessage = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
            guard let self, !Task.isCancelled, self.toastMessage == text else { return }
            self.toastMessage = nil
            self.toastTask    = nil
        }
    }
}
