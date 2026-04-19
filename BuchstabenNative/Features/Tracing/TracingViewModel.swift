import UIKit
import CoreGraphics
import QuartzCore
import Foundation

@MainActor
@Observable
public final class TracingViewModel {

    // MARK: - Public observable state

    var showGhost           = false
    var showAllLetters      = false
    var pencilPressure: CGFloat? = nil
    var pencilAzimuth: CGFloat   = 0
    var strokeEnforced      = true
    var showDebug           = false
    var schriftArt: SchriftArt = .druckschrift {
        didSet {
            guard oldValue != schriftArt,
                  !letters.isEmpty, letterIndex < letters.count else { return }
            PrimaeLetterRenderer.clearCache()
            currentLetterImage = PrimaeLetterRenderer.render(
                letter: currentLetterName, size: canvasSize, schriftArt: schriftArt)
                ?? PBMLoader.load(named: currentLetterImageName)
            reloadStrokeCheckpoints(for: letters[letterIndex])
        }
    }
    var toastMessage: String?
    var currentLetterName   = "A"
    var currentLetterImageName = ""
    var currentLetterImage: UIImage? = nil
    var canvasSize: CGSize  = CGSize(width: 1024, height: 1024) {
        didSet {
            guard oldValue != canvasSize,
                  !letters.isEmpty, letterIndex < letters.count else { return }
            // Recompute stroke checkpoints now that we know the real canvas dimensions.
            // load(letter:) was called at init with the default 1024×1024 size; the
            // view updates canvasSize to the actual device size on first layout.
            reloadStrokeCheckpoints(for: letters[letterIndex])
            // Also re-render the letter image at the correct canvas size.
            currentLetterImage = PrimaeLetterRenderer.render(
                letter: currentLetterName, size: canvasSize, schriftArt: schriftArt)
                ?? PBMLoader.load(named: currentLetterImageName)
        }
    }
    var progress: CGFloat   = 0
    var isPlaying           = false
    var activePath: [CGPoint] = []
    var completionMessage: String?
    private(set) var currentDifficultyTier: DifficultyTier = .standard

    // MARK: - Learning phase state

    /// Current learning phase (observe / guided / freeWrite).
    var learningPhase: LearningPhase { phaseController.currentPhase }
    /// Per-phase scores for the current letter session.
    var phaseScores: [LearningPhase: CGFloat] { phaseController.phaseScores }
    /// Whether the current letter session (all phases) is complete.
    var isPhaseSessionComplete: Bool { phaseController.isLetterSessionComplete }

    /// Whether stroke-start dots should render in the current phase
    /// (Pearson & Gallagher 1983 GRRM: observe = full scaffold, guided =
    /// partial scaffold with halos, freeWrite = scaffolding withdrawn).
    var showCheckpoints: Bool { phaseController.showCheckpoints }

    /// Whether the ghost guide-line should render because of the current phase.
    /// Composed with the user's `showGhost` toggle in views: phase-driven
    /// scaffolding is always on in observe/guided and always off in freeWrite.
    var showGhostForPhase: Bool {
        switch phaseController.currentPhase {
        case .observe, .guided: return true
        case .freeWrite:        return false
        }
    }

    /// Expose stroke data for calibration overlay (canvas-mapped coordinates).
    var strokeDefinition: LetterStrokes? { strokeTracker.definition }

    /// Raw glyph-relative stroke data (0-1 within bounding box) for rendering.
    /// Prefers user-calibrated file in Application Support over bundle strokes.json.
    var glyphRelativeStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count else { return nil }
        let letter = letters[letterIndex]
        return loadCalibratedStrokes(for: letter.name) ?? letter.strokes
    }

    /// Raw glyph-relative strokes from JSON (0-1 within bounding box).
    /// Used by TracingCanvasView to render dots aligned with the ghost at any canvas size.
    var rawGlyphStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count else { return nil }
        return letters[letterIndex].strokes
    }
    /// Stars earned in current letter session (0-3).
    var starsEarned: Int { phaseController.starsEarned }
    /// Accumulated normalised touch points for free-write scoring.
    private(set) var freeWritePoints: [CGPoint] = []
    /// Last computed Frechet distance (for debug overlay).
    private(set) var lastFreeWriteDistance: CGFloat = 0

    // MARK: - Animation guide state (ready for onboarding / demo UI)

    /// Normalized (0–1) point for the animated tracing guide dot.
    /// TracingCanvasView scales this to screen coordinates.
    private(set) var animationGuidePoint: CGPoint? = nil

    // MARK: - Onboarding state (ready for onboarding UI layer)

    /// True once the user has completed onboarding.
    var isOnboardingComplete: Bool = false
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
    private let thesisCondition: ThesisCondition
    private let onboardingStore: OnboardingStoring
    private let notificationScheduler: LocalNotificationScheduler
    private let syncCoordinator: SyncCoordinator
    private var adaptationPolicy: any AdaptationPolicy
    private var onboardingCoordinator: OnboardingCoordinator
    private var phaseController: LearningPhaseController
    private let letterScheduler = LetterScheduler.standard

    // MARK: - Private playback / touch state

    private var letters: [LetterAsset]          = []
    private var letterIndex                      = 0
    private var audioIndex                       = 0
    /// Decoded user-calibrated strokes keyed by letter. Prevents the ghost-render
    /// path from hitting disk + JSON-decode on every frame. Populated lazily on
    /// first read; invalidated on calibration save.
    private var calibratedStrokesCache: [String: LetterStrokes?] = [:]
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
    private var endTouchGraceTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?
    private var animationStartTask: Task<Void, Never>?
    private var smoothedVelocity: CGFloat        = 0
    private let velocitySmoothingAlpha: CGFloat  = 0.22
    private let activeDebounceSeconds: TimeInterval  = 0.03
    private let idleDebounceSeconds: TimeInterval    = 0.12
    private let playbackActivationVelocityThreshold: CGFloat = 22
    private let minimumTouchMoveDistance: CGFloat    = 1.5
    private let singleTouchCooldownAfterNavigation: CFTimeInterval
    // Coalesces rapid tap bursts (begin→update→end in quick succession) into a
    // single audible playback. Without this, each short cycle produces a fresh
    // idle→active transition and a new audio.play() call.
    private var lastPlayIntentWallTime: CFTimeInterval = 0
    private let playIntentDebounceSeconds: CFTimeInterval = 0.1

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
        self.thesisCondition        = deps.thesisCondition
        // Control condition uses fixed difficulty — no moving-average adaptation.
        self.adaptationPolicy       = deps.adaptationPolicy ?? (
            deps.thesisCondition == .control
                ? FixedAdaptationPolicy(currentTier: .standard)
                : MovingAverageAdaptationPolicy()
        )

        // Resume onboarding from saved step if available
        var coordinator = OnboardingCoordinator()
        if let savedStep = deps.onboardingStore.savedStep {
            coordinator.resume(at: savedStep)
        }
        self.onboardingCoordinator = coordinator
        self.onboardingStep        = coordinator.currentStep
        self.isOnboardingComplete  = deps.onboardingStore.hasCompletedOnboarding
        self.phaseController = LearningPhaseController(condition: deps.thesisCondition)
        self.schriftArt = deps.schriftArt

        haptics.prepare()
        letters = repo.loadLettersFast()
        guard let first = letters.first else { return }
        load(letter: first)
    }

    // MARK: - Toggles

    func toggleGhost()             { showGhost.toggle();         toast("Hilfslinien \(showGhost ? "an" : "aus")") }
    func toggleStrokeEnforcement() { strokeEnforced.toggle();    resetLetter(); toast("Reihenfolge \(strokeEnforced ? "an" : "aus")") }
    func toggleDebug()             { showDebug.toggle();         toast("Debug \(showDebug ? "an" : "aus")") }

    // MARK: - Accessibility

    var accessibilityCanvasLabel: String {
        "Schreibfläche — Buchstabe \(currentLetterName)"
    }

    var accessibilityCanvasValue: String {
        let pct = Int(max(0, min(1, progress)) * 100)
        if pct == 0   { return "Nicht begonnen" }
        if pct == 100 { return "Fertig" }
        return "\(pct) Prozent fertig"
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
        endTouchGraceTask?.cancel()
        endTouchGraceTask = nil
        cancelPendingPlaybackWork()
        audio.stop()
        playbackMachine.forceIdle()
        isPlaying = false
        didCompleteCurrentLetter = false
        completionDismissTask?.cancel()
        completionMessage = nil
        stopGuideAnimation()
        toast("Zurückgesetzt")
    }

    func loadLetter(name: String) {
        guard let idx = letters.firstIndex(where: { $0.name == name }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        toast("Buchstabe: \(currentLetterName)")
    }

    var allLetterNames: [String] { letters.map(\.name) }

    func nextLetter() {
        let visible = visibleLetterNames
        guard !visible.isEmpty else { return }
        let currentIdx = visible.firstIndex(of: currentLetterName) ?? -1
        let nextName = visible[(currentIdx + 1) % visible.count]
        guard let idx = letters.firstIndex(where: { $0.name == nextName }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        toast("Buchstabe: \(currentLetterName)")
    }

    func previousLetter() {
        let visible = visibleLetterNames
        guard !visible.isEmpty else { return }
        let currentIdx = visible.firstIndex(of: currentLetterName) ?? 0
        let prevName = visible[(currentIdx - 1 + visible.count) % visible.count]
        guard let idx = letters.firstIndex(where: { $0.name == prevName }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        toast("Buchstabe: \(currentLetterName)")
    }

    func randomLetter() {
        let visible = visibleLetterNames
        guard !visible.isEmpty else { return }
        let randomName = visible[Int.random(in: 0..<visible.count)]
        guard let idx = letters.firstIndex(where: { $0.name == randomName }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        randomAudioVariant()
        toast("Zufall: \(currentLetterName)")
    }

    func nextAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        guard files.indices.contains(audioIndex) else { audioIndex = 0; return }
        audioIndex = (audioIndex + 1) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
        toast("Ton \(audioIndex + 1) von \(files.count)")
    }

    func previousAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        guard files.indices.contains(audioIndex) else { audioIndex = 0; return }
        audioIndex = (audioIndex - 1 + files.count) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: false)
        setPlaybackState(.idle, immediate: true)
        toast("Ton \(audioIndex + 1) von \(files.count)")
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
        guard phaseController.isTouchEnabled       else { return }
        guard !isMultiTouchNavigationActive       else { return }
        guard t >= singleTouchSuppressedUntil     else { return }
        guard !isSingleTouchInteractionActive     else { return }

        isSingleTouchInteractionActive   = true
        playbackMachine.resumeIntent     = true
        endTouchGraceTask?.cancel()
        endTouchGraceTask = nil
        lastPoint                        = p
        lastTimestamp                    = t
        activePath                       = [p]
        haptics.fire(.strokeBegan)
        // Reload audio file — stop() in endTouch clears currentFile, so play() would
        // silently fail on subsequent touches without reloading first.
        if letters.indices.contains(letterIndex) {
            let files = letters[letterIndex].audioFiles
            if files.indices.contains(audioIndex) {
                audio.loadAudioFile(named: files[audioIndex], autoplay: false)
            }
        }
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        guard !isMultiTouchNavigationActive       else { return }
        guard isSingleTouchInteractionActive      else { return }
        guard let lastPoint                       else { return }

        // If the canvas size reported by the touch layer differs from what was used to
        // map checkpoints (self.canvasSize), resync immediately.  This closes the window
        // where a rotation/layout update has already fired canvasSize.didSet — reloading
        // checkpoints for the new size — but the touch overlay coordinator still carries
        // the previous size, causing normalizedPoint vs checkpoint coordinate mismatch.
        if canvasSize != self.canvasSize, !letters.isEmpty, letterIndex < letters.count {
            reloadStrokeCheckpoints(for: letters[letterIndex], usingSize: canvasSize)
        }

        let isWithinCanvasBounds =
            p.x >= 0 && p.y >= 0 && p.x <= canvasSize.width && p.y <= canvasSize.height

        let dx       = p.x - lastPoint.x
        let dy       = p.y - lastPoint.y
        let distance = hypot(dx, dy)

        if isWithinCanvasBounds && distance >= minimumTouchMoveDistance {
            activePath.append(p)
            // Accumulate for free-write scoring
            if phaseController.currentPhase == .freeWrite {
                freeWritePoints.append(p)
            }
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
        let azimuthBias  = pencilPressure != nil ? cos(pencilAzimuth) * 0.2 : 0
        let hBias        = Float(max(-1.0, min(1.0, (normalized.x * 2.0 - 1.0) + azimuthBias)))
        audio.setAdaptivePlayback(speed: speed, horizontalBias: hBias)

        let shouldPlayForStroke = strokeTracker.isNearStroke
        let shouldBeActive      = shouldPlayForStroke && smoothedVelocity >= playbackActivationVelocityThreshold
        setPlaybackState(shouldBeActive ? .active : .idle, immediate: shouldBeActive)

        // Guard against vacuous completion: StrokeTracker.isComplete returns true
        // when the letter has no strokes (empty-progress allSatisfy is trivially true).
        let hasStrokes = (strokeTracker.definition?.strokes.isEmpty == false)
        if hasStrokes, strokeTracker.isComplete, !didCompleteCurrentLetter {
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
                                          durationSeconds: duration, date: Date(),
                                          condition: thesisCondition)

            // — Background cloud sync —
            Task { [weak self] in try? await self?.syncCoordinator.pushAll() }

            // — Difficulty adaptation —
            let adaptSample = AdaptationSample(letter: letter,
                                               accuracy: CGFloat(accuracy),
                                               completionTime: duration)
            adaptationPolicy.record(adaptSample)
            currentDifficultyTier                 = adaptationPolicy.currentTier
            strokeTracker.radiusMultiplier        = currentDifficultyTier.radiusMultiplier

            showCompletionHUD()
            toast("Super gemacht!")
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
        lastPlayIntentWallTime = 0
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
        endTouchGraceTask?.cancel()
        endTouchGraceTask = nil
        let cmd = playbackMachine.transition(to: .idle)
        applyCommand(cmd)
        if cmd == .none { audio.stop(); isPlaying = false }
        playbackMachine.forceIdle()
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
        // Use raw glyph-relative strokes — NOT the canvas-mapped tracker definition.
        // The Canvas maps these to screen coords at render time using normalizedGlyphRect.
        guard !letters.isEmpty, letterIndex < letters.count else { return }
        let rawStrokes = letters[letterIndex].strokes
        guard !rawStrokes.strokes.isEmpty else { return }
        stopGuideAnimation()
        let guide = LetterAnimationGuide.build(from: rawStrokes)
        guard !guide.steps.isEmpty else { return }

        animationTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for step in guide.steps {
                    guard !Task.isCancelled else { break }
                    self.animationGuidePoint = step.point
                    try? await Task.sleep(for: .seconds(guide.duration(for: step)))
                }
                if !Task.isCancelled {
                    self.animationGuidePoint = nil
                    try? await Task.sleep(for: .seconds(0.5))
                }
            }
            self?.animationGuidePoint = nil
        }
    }

    func stopGuideAnimation() {
        animationStartTask?.cancel()
        animationStartTask   = nil
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
            isOnboardingComplete = true
            // Request notification permission and schedule reminder on onboarding completion
            Task { [weak self] in
                guard let self else { return }
                _ = await self.notificationScheduler.requestPermission()
                self.notificationScheduler.scheduleDailyReminder(
                    currentStreak: self.streakStore.currentStreak,
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
        isOnboardingComplete = true
    }

    /// Reset onboarding so the intro flow replays on next launch / app foreground.
    func restartOnboarding() {
        onboardingStore.reset()
        onboardingCoordinator = OnboardingCoordinator()
        onboardingStep = onboardingCoordinator.currentStep
        isOnboardingComplete = false
    }

    // MARK: - Learning phase control

    /// Advance to the next learning phase for the current letter.
    func advanceLearningPhase() {
        let score: CGFloat
        switch phaseController.currentPhase {
        case .observe:
            score = 1.0
        case .guided:
            score = progress
        case .freeWrite:
            guard let def = strokeTracker.definition else { score = 0; break }
            let normalised = freeWritePoints.map { pt in
                CGPoint(x: pt.x / max(canvasSize.width, 1),
                        y: pt.y / max(canvasSize.height, 1))
            }
            score = FreeWriteScorer.score(tracedPoints: normalised, reference: def)
            lastFreeWriteDistance = FreeWriteScorer.rawDistance(
                tracedPoints: normalised, reference: def)
        }

        if phaseController.advance(score: score) {
            resetForPhaseTransition()
            if phaseController.currentPhase == .observe {
                startGuideAnimation()
            }
            toast(phaseController.currentPhase.displayName)
        } else {
            recordPhaseSessionCompletion()
        }
    }

    /// Manually complete observe phase (tap to continue).
    func completeObservePhase() {
        guard phaseController.currentPhase == .observe else { return }
        stopGuideAnimation()
        advanceLearningPhase()
    }

    /// Apply calibrated glyph-relative checkpoints from the debug overlay.
    func applyCalibration(_ strokes: [[CGPoint]]) {
        guard let gr = PrimaeLetterRenderer.normalizedGlyphRect(for: currentLetterName, canvasSize: canvasSize, schriftArt: schriftArt) else { return }
        let defs = strokes.enumerated().map { (i, pts) in
            StrokeDefinition(id: i + 1, checkpoints: pts.map { cp in
                Checkpoint(x: gr.minX + cp.x * gr.width,
                           y: gr.minY + cp.y * gr.height)
            })
        }
        let letterStrokes = LetterStrokes(letter: currentLetterName, checkpointRadius: 0.05, strokes: defs)
        strokeTracker.load(letterStrokes)
    }

    /// Load the letter recommended by spaced repetition.
    func loadRecommendedLetter() {
        let available = visibleLetterNames
        guard let rec = letterScheduler.recommendNext(
            available: available,
            progress: progressStore.allProgress
        ), let idx = letters.firstIndex(where: { $0.name == rec }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        toast("Empfohlen: \(currentLetterName)")
    }

    /// The 7 demo letters for thesis scope.
    private let demoBaseLetters: Set<String> = ["A", "F", "I", "K", "L", "M", "O"]

    /// Letter names visible based on the showAllLetters toggle.
    var visibleLetterNames: [String] {
        if showAllLetters { return letters.map(\.name) }
        return letters.filter { demoBaseLetters.contains($0.baseLetter) }.map(\.name)
    }

    /// Expose stroke definition for canvas rendering.
    /// Current active stroke index.
    var activeStrokeIndex: Int { strokeTracker.currentStrokeIndex }
    /// Check if a stroke is completed.
    func isStrokeCompleted(_ index: Int) -> Bool {
        strokeTracker.progress.indices.contains(index) && strokeTracker.progress[index].complete
    }

    private func resetForPhaseTransition() {
        strokeTracker.reset()
        guard letters.indices.contains(letterIndex) else { return }
        reloadStrokeCheckpoints(for: letters[letterIndex])
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        freeWritePoints.removeAll(keepingCapacity: true)
        smoothedVelocity = 0
        playbackMachine.resumeIntent = false
        endTouchGraceTask?.cancel()
        endTouchGraceTask = nil
        cancelPendingPlaybackWork()
        audio.stop()
        playbackMachine.forceIdle()
        isPlaying = false
    }

    private func recordPhaseSessionCompletion() {
        let accuracy = Double(phaseController.overallScore)
        let duration = letterLoadTime.map { CACurrentMediaTime() - $0 } ?? 0
        let letter = currentLetterName

        let scores: [String: Double] = Dictionary(
            uniqueKeysWithValues: phaseController.phaseScores.map { ($0.key.rawName, Double($0.value)) }
        )
        progressStore.recordCompletion(for: letter, accuracy: accuracy, phaseScores: scores)
        streakStore.recordSession(date: Date(), lettersCompleted: [letter], accuracy: accuracy)
        dashboardStore.recordSession(letter: letter, accuracy: accuracy,
                                      durationSeconds: duration, date: Date(),
                                      condition: thesisCondition)
        Task { [weak self] in try? await self?.syncCoordinator.pushAll() }

        let adaptSample = AdaptationSample(letter: letter,
                                           accuracy: CGFloat(accuracy),
                                           completionTime: duration)
        adaptationPolicy.record(adaptSample)
        currentDifficultyTier = adaptationPolicy.currentTier
        strokeTracker.radiusMultiplier = currentDifficultyTier.radiusMultiplier

        showCompletionHUD()
    }

    // MARK: - Parent dashboard access

    var dashboardSnapshot: DashboardSnapshot { dashboardStore.snapshot }
    var currentStreak: Int { streakStore.currentStreak }
    var longestStreak: Int { streakStore.longestStreak }

    // MARK: - Debug

    #if DEBUG
    var debugIsMultiTouchNavigationActive: Bool { isMultiTouchNavigationActive }
    var debugActivePathCount: Int { activePath.count }
    #endif

    // MARK: - Private helpers

    private func load(letter: LetterAsset) {
        phaseController.reset()
        freeWritePoints.removeAll(keepingCapacity: true)
        lastFreeWriteDistance = 0
        showGhost                      = false
        currentLetterName              = letter.name
        currentLetterImageName         = letter.imageName
        currentLetterImage             = PrimaeLetterRenderer.render(letter: letter.name, size: canvasSize, schriftArt: schriftArt) ?? PBMLoader.load(named: letter.imageName)
        reloadStrokeCheckpoints(for: letter)
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
        // Auto-start stroke animation in observe phase, or skip the phase entirely
        // when the letter has no strokes (lowercase/umlaut placeholders) — there's
        // nothing to demonstrate, and isComplete would otherwise report vacuous success.
        if phaseController.currentPhase == .observe {
            if letter.strokes.strokes.isEmpty {
                phaseController.advance(score: 1.0)
            } else {
                animationStartTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !Task.isCancelled, let self else { return }
                    self.startGuideAnimation()
                }
            }
        }
        if let firstAudio = letter.audioFiles.first {
            audio.loadAudioFile(named: firstAudio, autoplay: false)
            setPlaybackState(.idle, immediate: true)
            // Audio plays in response to touches via the playback state machine;
            // no observe-phase auto-play (it would loop silently behind onboarding
            // and start immediately on letter switch without any user action).
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
        // Map writing velocity to playback rate: slow tracing = slow audio, fast = fast.
        // Range calibrated to iPad finger writing: ~50 pt/s (careful) to ~800 pt/s (quick).
        // Rate 1.0 at ~300 pt/s (normal writing pace).
        let low: CGFloat = 50, high: CGFloat = 800
        if v <= low  { return 0.5 }
        if v >= high { return 2.0 }
        return Float(0.5 + 1.5 * ((v - low) / (high - low)))
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
        pendingPlaybackStateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            let cmd = self.playbackMachine.transition(to: target)
            self.applyCommand(cmd)
        }
    }

    private func cancelPendingPlaybackWork() {
        pendingPlaybackStateTask?.cancel()
        pendingPlaybackStateTask = nil
        audio.cancelPendingLifecycleWork()
    }

    private func applyCommand(_ cmd: PlaybackStateMachine.Command) {
        switch cmd {
        case .play:
            let now = CACurrentMediaTime()
            if now - lastPlayIntentWallTime < playIntentDebounceSeconds {
                isPlaying = true
                return
            }
            lastPlayIntentWallTime = now
            audio.play()
            isPlaying = true
        case .stop:  audio.stop();  isPlaying = false
        case .none:  break
        }
    }

    /// Reload stroke checkpoints mapped to canvas-normalised coordinates (0–1).
    /// Pass `usingSize` to override `self.canvasSize` — used by `updateTouch` to
    /// guarantee the mapping size equals the size used to normalise the touch point.
    private func reloadStrokeCheckpoints(for letter: LetterAsset, usingSize size: CGSize? = nil) {
        // Stroke coordinates in JSON are glyph-relative (0–1 within bounding box).
        // Map to canvas-normalised coordinates using the actual rendered glyph rect.
        // User-calibrated file in Application Support takes priority over bundle strokes.json.
        let effectiveSize = size ?? canvasSize
        let source = loadCalibratedStrokes(for: letter.name) ?? letter.strokes
        let strokesForTracker: LetterStrokes
        if let gr = PrimaeLetterRenderer.normalizedGlyphRect(for: letter.name, canvasSize: effectiveSize, schriftArt: schriftArt) {
            let mapped = source.strokes.map { stroke in
                StrokeDefinition(id: stroke.id, checkpoints: stroke.checkpoints.map { cp in
                    Checkpoint(x: gr.minX + cp.x * gr.width,
                               y: gr.minY + cp.y * gr.height)
                })
            }
            strokesForTracker = LetterStrokes(letter: source.letter,
                                               checkpointRadius: source.checkpointRadius,
                                               strokes: mapped)
        } else {
            strokesForTracker = source
        }
        strokeTracker.load(strokesForTracker)
    }

    private func calibratedStrokesURL(for letter: String) -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BuchstabenNative/CalibratedStrokes/\(letter).json")
    }

    private func loadCalibratedStrokes(for letter: String) -> LetterStrokes? {
        if let cached = calibratedStrokesCache[letter] { return cached }
        guard let url = calibratedStrokesURL(for: letter),
              let data = try? Data(contentsOf: url) else {
            // Memoize the negative result so the per-frame ghost render path
            // doesn't re-hit FileManager. `updateValue(_:forKey:)` is required
            // because `dict[key] = nil` on an Optional-valued dict removes the key.
            calibratedStrokesCache.updateValue(nil, forKey: letter)
            return nil
        }
        let decoded = try? JSONDecoder().decode(LetterStrokes.self, from: data)
        calibratedStrokesCache[letter] = decoded
        return decoded
    }

    /// Persist calibrated glyph-relative checkpoints to Application Support so they
    /// survive app relaunches and take priority over the bundle strokes.json.
    func persistCalibratedStrokes(_ strokes: [[CGPoint]], for letter: String) {
        let defs = strokes.enumerated().compactMap { (i, pts) -> StrokeDefinition? in
            guard !pts.isEmpty else { return nil }
            return StrokeDefinition(id: i + 1, checkpoints: pts.map {
                Checkpoint(x: (($0.x * 1000).rounded() / 1000),
                           y: (($0.y * 1000).rounded() / 1000))
            })
        }
        let ls = LetterStrokes(letter: letter, checkpointRadius: 0.05, strokes: defs)
        guard let url = calibratedStrokesURL(for: letter),
              let data = try? JSONEncoder().encode(ls) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        // Invalidate the calibration cache so the next read picks up the new file.
        calibratedStrokesCache.removeValue(forKey: letter)
        // Apply immediately so the tracker reflects the new calibration without navigation.
        guard letters.indices.contains(letterIndex) else { return }
        reloadStrokeCheckpoints(for: letters[letterIndex])
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
