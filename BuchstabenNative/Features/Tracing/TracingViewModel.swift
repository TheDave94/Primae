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
    /// When true, the stroke-calibration overlay takes focus and the other
    /// debug panels (audio tuning, letter picker) are hidden so they don't
    /// sit on top of the calibrator's mode / add-stroke / save controls.
    /// Only meaningful while `showDebug` is also true.
    var showCalibration     = false
    /// Convenience gate used by rendering code to drop all learning-phase
    /// overlays (observe-phase modal, start dots, animation guide dot,
    /// direct-phase tap dots, direction arrow) while the calibrator is open
    /// — otherwise the phase UI stacks with the calibrator visualization and
    /// buries the letter.
    var isCalibrating: Bool { showDebug && showCalibration }
    var letterOrdering: LetterOrderingStrategy = .motorSimilarity
    var schriftArt: SchriftArt = .druckschrift {
        didSet {
            guard oldValue != schriftArt,
                  !letters.isEmpty, letterIndex < letters.count else { return }
            scriptStrokeCache.removeAll(keepingCapacity: true)
            PrimaeLetterRenderer.clearCache()
            currentLetterImage = PrimaeLetterRenderer.render(
                letter: currentLetterName, size: canvasSize, schriftArt: schriftArt)
                ?? PBMLoader.load(named: currentLetterImageName)
            reloadStrokeCheckpoints(for: letters[letterIndex])
        }
    }
    /// Forwarded from `TransientMessagePresenter` so existing views keep binding via `vm.toastMessage`.
    var toastMessage: String? { messages.toastMessage }
    var currentLetterName   = "A"
    var currentLetterImageName = ""
    var currentLetterImage: UIImage? = nil
    var canvasSize: CGSize  = CGSize(width: 1024, height: 1024) {
        didSet {
            guard oldValue != canvasSize,
                  !letters.isEmpty, letterIndex < letters.count else { return }
            // Re-layout first so cell frames reflect the new canvas size
            // BEFORE checkpoints reload — reloadStrokeCheckpoints now reads
            // each cell's frame to map strokes into cell-local space.
            grid.layout(in: canvasSize)
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

    /// Read-only view onto the grid's cell list for the canvas renderer.
    /// Length-1 for every single-letter session, so iterating this in the
    /// canvas body produces exactly one pass identical to today's layout.
    var gridCells: [LetterCell] { grid.cells }

    /// Current grid geometry preset. Exposed so the canvas can compute
    /// cell frames from the live Canvas `size` at each draw — this
    /// sidesteps the first-render window where `vm.canvasSize` (fed by
    /// `.onAppear`) hasn't caught up with `geo.size` yet.
    var gridPreset: InputPreset { grid.preset }

    /// Exposed for the debug UI and for unit tests that want to assert
    /// detector state without poking private storage.
    var inputModeDetector: InputModeDetector { detector }

    /// Forwarded from the pencil overlay on every pencil touchesBegan.
    /// Feeds the detector so the first pencil stroke of a session flips
    /// the effective preset to `.pencil`. Does NOT re-apply the grid
    /// preset yet — tracking is still canvas-wide, so auto-promoting
    /// would leave a multi-cell render with touch coords that don't
    /// match any cell's glyph. A later commit introduces cell-aware
    /// tracking alongside the auto-promotion.
    func pencilDidTouchDown() {
        detector.observeTouchBegan(isPencil: true)
    }

    /// Forwarded from the finger overlay on every finger touchesBegan.
    /// Tracks the finger-streak counter used by the detector's
    /// hysteresis to decide when to demote a stale pencil session.
    func fingerDidTouchDown() {
        detector.observeTouchBegan(isPencil: false)
    }

    /// Rebuild the grid's sequence + preset. Called on letter loads and
    /// from the debug override chip.
    ///
    /// In this commit, ONLY the debug `.forcePencil` override flips the
    /// layout to pencil multi-cell. The auto-detected pencil kind is
    /// tracked but not yet acted on — the VM's stroke tracker is still
    /// canvas-wide, so flipping on a real pencil touch would render 4
    /// cells whose glyph positions don't match the tracker's checkpoints,
    /// silently breaking writing. A later commit introduces cell-aware
    /// tracking alongside auto-promotion.
    ///
    /// For finger / auto: length-1 singleLetter sequence, finger preset —
    /// byte-identical to pre-grid behavior. For forcePencil: repetition
    /// sequence across the preset's default cell count (developer preview
    /// of the multi-cell layout; tracking is intentionally broken here).
    func reapplyGridPreset() {
        guard letters.indices.contains(letterIndex) else { return }
        let letter = letters[letterIndex]
        let useForcedPencil = detector.override == .forcePencil
        let preset: InputPreset = useForcedPencil ? .pencil : .finger
        let sequence: TracingSequence = useForcedPencil
            ? .repetition(letter.name, count: preset.cellCount)
            : .singleLetter(letter.name)
        grid.load(sequence: sequence, preset: preset)
        grid.layout(in: canvasSize)
        // Preset changes alter cell frames, which flip the coord space each
        // cell's tracker runs in. The checkpoint-build idempotency cache
        // doesn't include preset state, so force the next reload to rebuild.
        lastCheckpointKey = nil
    }
    var progress: CGFloat   = 0
    var isPlaying           = false
    var activePath: [CGPoint] = []
    /// Forwarded from `TransientMessagePresenter` for views bound via `vm.completionMessage`.
    var completionMessage: String? { messages.completionMessage }
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
    /// scaffolding is always on in observe/direct/guided and always off in freeWrite.
    var showGhostForPhase: Bool {
        switch phaseController.currentPhase {
        case .observe, .direct, .guided: return true
        case .freeWrite:                 return false
        }
    }

    /// Guidance-fading intensity (Schmidt & Lee, 2005): reducing feedback over
    /// time improves motor-learning retention.
    /// observe=1.0, direct=1.0, guided=0.6 (moderate), freeWrite=0.0 (post-hoc only).
    var feedbackIntensity: CGFloat {
        switch phaseController.currentPhase {
        case .observe:   return 1.0
        case .direct:    return 1.0
        case .guided:    return 0.6
        case .freeWrite: return 0.0
        }
    }

    /// Expose stroke data for calibration overlay (canvas-mapped coordinates).
    var strokeDefinition: LetterStrokes? { strokeTracker.definition }

    /// Raw glyph-relative stroke data (0-1 within bounding box) for rendering.
    /// Schreibschrift always takes its strokes from the bundle JSON so the
    /// committed calibrations in Resources/Letters/<x>/strokes_schulschrift.json
    /// are authoritative. Druckschrift still prefers the user-calibrated
    /// Application Support file when one exists — on-device save there works.
    var glyphRelativeStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count else { return nil }
        if showingVariant, let vs = variantStrokeCache { return vs }
        if let ss = activeScriptStrokes { return ss }
        let letter = letters[letterIndex]
        return calibrationStore.strokes(for: letter.name, schriftArt: schriftArt) ?? letter.strokes
    }

    /// Raw glyph-relative strokes from JSON (0-1 within bounding box).
    /// Used by TracingCanvasView to render dots aligned with the ghost at any canvas size.
    var rawGlyphStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count else { return nil }
        if showingVariant, let vs = variantStrokeCache { return vs }
        if let ss = activeScriptStrokes { return ss }
        return letters[letterIndex].strokes
    }

    /// True when the current letter has a registered alternate stroke-order
    /// form usable in the active script. `strokes_variant.json` files carry
    /// Druckschrift-specific coordinates, so in Schreibschrift / future
    /// scripts there's nothing to load until a per-script variant file is
    /// added (e.g. `strokes_schulschrift_variant.json`). Hiding the button
    /// avoids rendering a Druckschrift path on top of a cursive glyph.
    var currentLetterHasVariants: Bool {
        guard !letters.isEmpty, letterIndex < letters.count,
              schriftArt == .druckschrift else { return false }
        return !(letters[letterIndex].variants?.isEmpty ?? true)
    }
    /// Stars earned in current letter session (0-3).
    var starsEarned: Int { phaseController.starsEarned }
    /// Accumulated normalised touch points for free-write scoring.
    private(set) var freeWritePoints: [CGPoint] = []
    /// CACurrentMediaTime timestamps for each accumulated free-write point.
    private(set) var freeWriteTimestamps: [CFTimeInterval] = []
    /// Digitizer force at each accumulated free-write point (0 = finger / no data).
    private(set) var freeWriteForces: [CGFloat] = []
    /// CACurrentMediaTime when the freeWrite phase began. Used for rhythmScore.
    private var freeWriteSessionStart: CFTimeInterval = 0
    /// CACurrentMediaTime when the current guided or freeWrite phase began.
    /// Used to compute writing speed (checkpoints per second).
    private var activePhaseStartTime: CFTimeInterval = 0
    /// Checkpoints passed per second in the current guided or freeWrite phase.
    /// Updated on every touch event; reset on phase transition and letter load.
    private(set) var strokesPerSecond: CGFloat = 0
    /// Last computed Frechet distance (for debug overlay).
    private(set) var lastFreeWriteDistance: CGFloat = 0
    /// Most recent Schreibmotorik four-dimension assessment from the freeWrite phase.
    private(set) var lastWritingAssessment: WritingAssessment? = nil
    /// Normalised (0–1) touch path accumulated during the freeWrite phase.
    /// Kept for the KP overlay that shows where the child deviated.
    private(set) var freeWritePath: [CGPoint] = []
    /// Shows the KP (Knowledge of Performance) overlay after freeWrite completion.
    var showFreeWriteOverlay: Bool = false
    /// Shows the paper-transfer self-assessment overlay after freeWrite, when enabled.
    var showPaperTransfer: Bool = false
    /// Whether the user is currently tracing the variant stroke form.
    var showingVariant: Bool = false
    /// Whether the paper-transfer phase is enabled (thesis setting).
    var enablePaperTransfer: Bool = false {
        didSet {
            UserDefaults.standard.set(enablePaperTransfer,
                forKey: "de.flamingistan.buchstaben.enablePaperTransfer")
        }
    }

    // MARK: - Direct phase state

    /// Stroke indices whose start dot has been tapped in the direct phase.
    private(set) var directTappedDots: Set<Int> = []
    /// True while the correct (next expected) dot should pulse to guide after a wrong tap.
    var directPulsingDot: Bool = false
    /// Index of the stroke whose directional arrow is briefly shown after a correct tap.
    var directArrowStrokeIndex: Int? = nil

    /// Index of the next dot the child must tap in the direct phase.
    var directNextExpectedDotIndex: Int {
        guard let rawStrokes = rawGlyphStrokes else { return 0 }
        for i in rawStrokes.strokes.indices where !directTappedDots.contains(i) { return i }
        return rawStrokes.strokes.count
    }

    // MARK: - Animation guide state (ready for onboarding / demo UI)

    /// Normalized (0–1) point for the animated tracing guide dot.
    /// TracingCanvasView scales this to screen coordinates.
    /// Forwards to AnimationGuideController so views continue to bind via `vm.animationGuidePoint`.
    var animationGuidePoint: CGPoint? { animation.guidePoint }

    // MARK: - Onboarding state (ready for onboarding UI layer)

    /// True once the user has completed onboarding.
    var isOnboardingComplete: Bool = false
    /// Current onboarding step for presenting onboarding UI.
    private(set) var onboardingStep: OnboardingStep = .welcome
    /// Progress through onboarding steps (0–1).
    var onboardingProgress: Double { onboardingCoordinator.progress }

    // MARK: - Private dependencies

    private let repo: LetterRepository
    /// The active cell's stroke tracker. Source-compatible with every
    /// pre-grid use site that read `strokeTracker.X`: for a length-1
    /// sequence the active cell is stable throughout the letter session,
    /// so the returned tracker reference is the same instance from load
    /// to completion. For multi-cell sequences (commit 4 onwards) the
    /// reference shifts when the active cell advances — the tracker is
    /// mutable state owned by the cell, not by the VM.
    private var strokeTracker: StrokeTracker { grid.activeCell.tracker }
    /// Schreibheft grid representation of the current sequence.
    /// Drives the canvas renderer via `gridCells` / `gridPreset`. For the
    /// single-letter flow this is a length-1 sequence with the finger
    /// preset — byte-identical to pre-grid behavior.
    private let grid = SequenceGridController(
        sequence: .singleLetter(""),
        preset: .finger
    )

    /// Finger / pencil detector with hysteresis. Receives every touch-began
    /// event from the overlays; its `effectiveKind` will drive grid preset
    /// promotion from commit 3 onward. Nothing observes it yet in this
    /// commit — detection runs, rendering is unchanged.
    private let detector = InputModeDetector()
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
    private let letterScheduler: LetterScheduler
    private let calibrationStore: CalibrationStore

    // MARK: - Private playback / touch state

    private var letters: [LetterAsset]          = []
    private var letterIndex                      = 0
    private var variantStrokeCache: LetterStrokes? = nil
    /// Per-script bundle stroke cache keyed by (schriftArt). Populated lazily
    /// on first access for each non-Druckschrift script. Invalidated in
    /// `schriftArt.didSet` and on letter load so a switch reloads fresh.
    private var scriptStrokeCache: [SchriftArt: LetterStrokes] = [:]
    private var audioIndex                       = 0
    private var lastPoint: CGPoint?
    private var lastTimestamp: CFTimeInterval?
    private var letterLoadTime: CFTimeInterval?  // for session-duration tracking
    private var isSingleTouchInteractionActive   = false
    private var didCompleteCurrentLetter         = false
    private var playback: PlaybackController!
    private let messages: TransientMessagePresenter
    private let animation: AnimationGuideController
    /// Full-cycle counter for the observe-phase animation. Used to auto-advance
    /// after the second loop completes.
    private var observeCycleCount: Int = 0
    /// Idempotency key for the last reloadStrokeCheckpoints rebuild. Caches the
    /// (letter, size) pair so repeated calls within a rotation safety-net window
    /// or a fast-touch burst don't re-map the same checkpoints over and over.
    /// Reset to nil whenever the source data changes (e.g. user calibration).
    private var lastCheckpointKey: CheckpointBuildKey?
    private var smoothedVelocity: CGFloat        = 0
    /// The three velocity knobs are mutable so the debug audio panel can
    /// tune them live. Defaults are calibrated for iPad-finger writing
    /// at ~50–800 pt/s; see `Self.mapVelocityToSpeed` for the curve they feed.
    private var velocitySmoothingAlpha: CGFloat  = 0.22
    private var playbackActivationVelocityThreshold: CGFloat = 22
    private var minimumTouchMoveDistance: CGFloat    = 1.5

    // MARK: - Init

    @MainActor
    public convenience init() { self.init(.live) }

    @MainActor
    init(_ deps: TracingDependencies = .live) {
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
        self.enablePaperTransfer    = deps.enablePaperTransfer
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
        self.letterOrdering = deps.letterOrdering

        // Build the per-VM controllers from the dependency factories. Doing this
        // here (not at field init) is what lets tests replace any one of them
        // with a test-friendly variant (instant sleeper, shorter debounce, etc.)
        // without having to subclass or poke into the VM's privates.
        self.messages         = deps.makeMessagePresenter()
        self.animation        = deps.makeAnimationGuide()
        self.calibrationStore = deps.makeCalibrationStore()
        self.letterScheduler  = deps.makeLetterScheduler()

        haptics.prepare()
        self.playback = deps.makePlaybackController(deps.audio) { [weak self] in
            self?.isPlaying = $0
        }
        letters = repo.loadLettersFast()
        // Surface a startup audio failure as a brief German toast so a parent
        // notices the device is silent on purpose (not because the child got
        // lost). The toast auto-clears via TransientMessagePresenter's normal
        // 1.3 s timer; nil under healthy operation.
        if let audioError = deps.audio.initializationError {
            messages.show(toast: audioError)
        }
        guard let first = letters.first else { return }
        load(letter: first)
    }

    // MARK: - Toggles

    func toggleGhost()             { showGhost.toggle();         toast("Hilfslinien \(showGhost ? "an" : "aus")") }
    func toggleStrokeEnforcement() { strokeEnforced.toggle();    resetLetter(); toast("Reihenfolge \(strokeEnforced ? "an" : "aus")") }
    func toggleDebug()             { showDebug.toggle();         toast("Debug \(showDebug ? "an" : "aus")") }
    func toggleCalibration()       { showCalibration.toggle();   toast("Kalibrieren \(showCalibration ? "an" : "aus")") }

    /// Switch between the standard and variant stroke form for the current letter.
    /// Only available when the letter has a registered variant (currentLetterHasVariants).
    /// Reloads checkpoints and resets tracing progress; does not affect phase state.
    func toggleVariant() {
        guard currentLetterHasVariants, letters.indices.contains(letterIndex) else { return }
        let letter = letters[letterIndex]
        showingVariant.toggle()
        if showingVariant && variantStrokeCache == nil {
            variantStrokeCache = loadVariantStrokesFromBundle(for: letter)
        }
        lastCheckpointKey = nil
        strokeTracker.reset()
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        reloadStrokeCheckpoints(for: letter)
        toast(showingVariant ? "Variante" : "Standard")
    }

    private func loadVariantStrokesFromBundle(for letter: LetterAsset) -> LetterStrokes? {
        guard let variantID = letter.variants?.first else { return nil }
        return repo.loadVariantStrokes(for: letter.name, variantID: variantID)
    }

    /// Returns the current script's bundle strokes, loading from
    /// `strokes_<variantID>.json` and caching on first access. `nil` when the
    /// active script is Druckschrift (data lives on the LetterAsset itself)
    /// or when no variant file exists for the current letter.
    ///
    /// Driven by `SchriftArt.bundleVariantID`, so adding a new script only
    /// needs an enum case + variantID + bundled JSON — no touch here.
    private var activeScriptStrokes: LetterStrokes? {
        guard !letters.isEmpty, letterIndex < letters.count,
              let variantID = schriftArt.bundleVariantID else { return nil }
        if let cached = scriptStrokeCache[schriftArt] { return cached }
        guard let loaded = repo.loadVariantStrokes(
            for: letters[letterIndex].name, variantID: variantID) else { return nil }
        scriptStrokeCache[schriftArt] = loaded
        return loaded
    }

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
        // Re-load and autoplay the current letter's audio file. The previous
        // shape (`audio.stop(); audio.play()`) was a no-op because stop()
        // nils currentFile and play() guards on it being non-nil — the
        // speaker button silently did nothing.
        guard letters.indices.contains(letterIndex) else { return }
        let files = letters[letterIndex].audioFiles
        guard files.indices.contains(audioIndex) else { return }
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
    }

    // MARK: - Letter navigation

    func resetLetter() {
        strokeTracker.reset()
        progress = 0
        activePath.removeAll(keepingCapacity: true)
        smoothedVelocity = 0
        playback.resumeIntent = false
        playback.cancelPending()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
        didCompleteCurrentLetter = false
        messages.clearCompletionState()
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
        // Autoplay so the long-press UI gesture both switches and previews
        // in one step — no "silent swap" that requires a second tap to hear.
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
        toast("Ton \(audioIndex + 1) von \(files.count): \(soundLabel(for: files[audioIndex]))")
    }

    func previousAudioVariant() {
        guard !letters.isEmpty else { return }
        let files = letters[letterIndex].audioFiles
        guard !files.isEmpty else { return }
        guard files.indices.contains(audioIndex) else { audioIndex = 0; return }
        audioIndex = (audioIndex - 1 + files.count) % files.count
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
        toast("Ton \(audioIndex + 1) von \(files.count): \(soundLabel(for: files[audioIndex]))")
    }

    /// Human-friendly label for a letter sound file — strips the letter
    /// prefix and the `.mp3` extension so toasts read "Ton 4 von 5: Affe"
    /// instead of the raw filename.
    private func soundLabel(for file: String) -> String {
        var label = (file as NSString).deletingPathExtension
        if label.hasPrefix(currentLetterName), label.count > currentLetterName.count {
            label.removeFirst(currentLetterName.count)
        }
        return label.isEmpty ? file : label
    }

    // MARK: - Touch handling

    func beginTouch(at p: CGPoint, t: CFTimeInterval) {
        guard phaseController.isTouchEnabled       else { return }
        guard phaseController.currentPhase != .direct else { return }  // handled by DirectPhaseDotsOverlay
        guard !isSingleTouchInteractionActive     else { return }

        isSingleTouchInteractionActive   = true
        playback.resumeIntent     = true
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
        guard isSingleTouchInteractionActive      else { return }
        guard let lastPoint                       else { return }

        // If the canvas size reported by the touch layer differs from what was used to
        // map checkpoints (self.canvasSize), resync immediately.  This closes the window
        // where a rotation/layout update has already fired canvasSize.didSet — reloading
        // checkpoints for the new size — but the touch overlay coordinator still carries
        // the previous size, causing normalizedPoint vs checkpoint coordinate mismatch.
        if canvasSize != self.canvasSize, !letters.isEmpty, letterIndex < letters.count {
            // Re-flow cell frames with the overlay-reported size BEFORE
            // reloading checkpoints — reload now maps per-cell using each
            // cell's own frame.
            grid.layout(in: canvasSize)
            reloadStrokeCheckpoints(for: letters[letterIndex], usingSize: canvasSize)
        }

        let isWithinCanvasBounds =
            p.x >= 0 && p.y >= 0 && p.x <= canvasSize.width && p.y <= canvasSize.height

        let dx       = p.x - lastPoint.x
        let dy       = p.y - lastPoint.y
        let distance = hypot(dx, dy)

        if isWithinCanvasBounds && distance >= minimumTouchMoveDistance {
            activePath.append(p)
            // Accumulate for free-write scoring and KP overlay
            if phaseController.currentPhase == .freeWrite {
                freeWritePoints.append(p)
                freeWriteTimestamps.append(t)
                freeWriteForces.append(pencilPressure ?? 0)
                freeWritePath.append(CGPoint(x: p.x / max(canvasSize.width, 1),
                                             y: p.y / max(canvasSize.height, 1)))
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

        // Canvas-normalised coords (0–1 over the whole canvas) — used for
        // audio stereo panning so that writing in the right-hand cell of a
        // pencil layout pans right.
        let canvasNormalized = CGPoint(x: p.x / max(canvasSize.width, 1),
                                       y: p.y / max(canvasSize.height, 1))
        // Cell-normalised coords (0–1 over the active cell's frame) — fed
        // to the active cell's stroke tracker, whose checkpoints live in the
        // cell's own 0–1 space. For a length-1 finger sequence the frame
        // equals the whole canvas, so this is identical to canvasNormalized.
        let activeFrame = grid.activeCell.frame
        let normalized: CGPoint
        if activeFrame.width > 0 && activeFrame.height > 0 {
            normalized = CGPoint(
                x: (p.x - activeFrame.minX) / activeFrame.width,
                y: (p.y - activeFrame.minY) / activeFrame.height
            )
        } else {
            normalized = canvasNormalized
        }
        let prevStrokeIndex   = strokeTracker.currentStrokeIndex
        let prevNextCheckpoint = strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        let wasComplete       = strokeTracker.isComplete

        strokeTracker.update(normalizedPoint: normalized)

        let isNowComplete = strokeTracker.isComplete
        if !wasComplete && isNowComplete, feedbackIntensity > 0 { haptics.fire(.letterCompleted) }
        progress = strokeTracker.overallProgress

        let currentPhase = phaseController.currentPhase
        if (currentPhase == .guided || currentPhase == .freeWrite) && activePhaseStartTime > 0 {
            let elapsed = CACurrentMediaTime() - activePhaseStartTime
            if elapsed > 0.1 {
                if let def = strokeTracker.definition {
                    let completedCPs = def.strokes.enumerated().reduce(0) { acc, item in
                        let (idx, stroke) = item
                        guard strokeTracker.progress.indices.contains(idx) else { return acc }
                        return strokeTracker.progress[idx].complete
                            ? acc + stroke.checkpoints.count
                            : acc + strokeTracker.progress[idx].nextCheckpoint
                    }
                    strokesPerSecond = CGFloat(completedCPs) / CGFloat(elapsed)
                }
            }
        }

        let newStrokeIndex     = strokeTracker.currentStrokeIndex
        let newNextCheckpoint  = strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        if (prevNextCheckpoint != newNextCheckpoint || newStrokeIndex != prevStrokeIndex),
           feedbackIntensity > 0 {
            if strokeTracker.progress.indices.contains(prevStrokeIndex)
                && strokeTracker.progress[prevStrokeIndex].complete {
                haptics.fire(.strokeCompleted)
            } else {
                haptics.fire(.checkpointHit)
            }
        }

        let speed        = Self.mapVelocityToSpeed(smoothedVelocity)
        let azimuthBias  = pencilPressure != nil ? cos(pencilAzimuth) * 0.2 : 0
        // Pan follows the absolute x across the whole canvas, not the
        // active cell — so a cell on the right still sounds from the right
        // regardless of cell-local normalisation.
        let hBias        = Float(max(-1.0, min(1.0, (canvasNormalized.x * 2.0 - 1.0) + azimuthBias)))
        audio.setAdaptivePlayback(speed: speed, horizontalBias: hBias)

        let shouldPlayForStroke = strokeTracker.isNearStroke
        let shouldBeActive      = shouldPlayForStroke && smoothedVelocity >= playbackActivationVelocityThreshold
                                  && feedbackIntensity > 0.3
        playback.request(shouldBeActive ? .active : .idle, immediate: shouldBeActive)

        // Guard against vacuous completion: StrokeTracker.isComplete returns true
        // when the letter has no strokes (empty-progress allSatisfy is trivially true).
        let hasStrokes = (strokeTracker.definition?.strokes.isEmpty == false)
        if hasStrokes, strokeTracker.isComplete, !didCompleteCurrentLetter {
            didCompleteCurrentLetter = true
            if feedbackIntensity > 0 { haptics.fire(.letterCompleted) }

            let accuracy = Double(strokeTracker.overallProgress)
            let duration = letterLoadTime.map { CACurrentMediaTime() - $0 } ?? 0
            commitCompletion(letter: currentLetterName,
                             accuracy: accuracy,
                             duration: duration)
            toast("Super gemacht!")
            playback.request(.idle, immediate: true)
        }

        self.lastPoint     = p
        self.lastTimestamp = t
    }

    // MARK: - Lifecycle

    public func appDidEnterBackground() async {
        guard playback.appIsForeground else { return }
        playback.appIsForeground = false
        playback.cancelPending()
        endTouch()
        let cmd = playback.transition(to: .idle)
        playback.apply(cmd)
        if cmd == .none { audio.stop(); isPlaying = false }
        audio.suspendForLifecycle()
        playback.resetPlayIntentClock()
        // Drain pending disk writes before returning so the SwiftUI scene-phase
        // wrapper can hold the iOS suspension grace window open until durability
        // is guaranteed. The prior fire-and-forget `Task { await … }` shape let
        // iOS race the writes to /dev/null on suspension — losing a letter
        // completion that happened seconds before backgrounding.
        await progressStore.flush()
        await streakStore.flush()
        await dashboardStore.flush()
        await onboardingStore.flush()
    }

    public func appDidBecomeActive() {
        playback.appIsForeground = true
        audio.resumeAfterLifecycle()
        if playback.resumeIntent {
            playback.request(playback.state, immediate: true)
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
        playback.resumeIntent   = false
        playback.cancelPending()
        let cmd = playback.transition(to: .idle)
        playback.apply(cmd)
        if cmd == .none { audio.stop(); isPlaying = false }
        playback.forceIdle()
    }

    // MARK: - Completion HUD

    func dismissCompletionHUD() {
        messages.dismissCompletion()
    }

    // MARK: - Animation guide
    // Delegates the guide-dot animation to `AnimationGuideController`.
    // The observe-phase canvas binds to `vm.animationGuidePoint` which forwards
    // to the controller's published point.

    func startGuideAnimation() {
        // Use raw glyph-relative strokes — NOT the canvas-mapped tracker definition.
        // The Canvas maps these to screen coords at render time using normalizedGlyphRect.
        // rawGlyphStrokes (not letters[…].strokes) so the animation dot follows
        // the CURRENT script's stroke set — otherwise Schreibschrift mode plays
        // a Druckschrift path on top of a Playwrite glyph.
        guard !letters.isEmpty, letterIndex < letters.count,
              let rawStrokes = rawGlyphStrokes,
              !rawStrokes.strokes.isEmpty else { return }
        // Auto-advance the observe phase after the second full cycle so a child
        // who can't read "Tippen" isn't stuck waiting for a parent's prompt.
        observeCycleCount = 0
        animation.onCycleComplete = { [weak self] in
            guard let self else { return }
            self.observeCycleCount += 1
            if self.observeCycleCount >= 2,
               self.phaseController.currentPhase == .observe {
                self.completeObservePhase()
            }
        }
        animation.start(strokes: rawStrokes)
    }

    func stopGuideAnimation() {
        animation.stop()
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
        case .direct:
            score = 1.0  // pass/fail
        case .guided:
            score = progress
        case .freeWrite:
            guard let def = strokeTracker.definition else {
                lastWritingAssessment = nil
                score = 0
                break
            }
            let normalised = freeWritePoints.map { pt in
                CGPoint(x: pt.x / max(canvasSize.width, 1),
                        y: pt.y / max(canvasSize.height, 1))
            }
            let assessment = FreeWriteScorer.score(
                tracedPoints: normalised,
                reference: def,
                timestamps: freeWriteTimestamps,
                forces: freeWriteForces,
                sessionStart: freeWriteSessionStart,
                sessionEnd: CACurrentMediaTime()
            )
            lastWritingAssessment = assessment
            score = assessment.overallScore
            lastFreeWriteDistance = FreeWriteScorer.rawDistance(
                tracedPoints: normalised, reference: def)
        }

        let wasInFreeWrite = phaseController.currentPhase == .freeWrite

        if phaseController.advance(score: score) {
            resetForPhaseTransition()
            if phaseController.currentPhase == .observe {
                startGuideAnimation()
            }
            toast(phaseController.currentPhase.displayName)
        } else {
            recordPhaseSessionCompletion()
        }

        if wasInFreeWrite {
            showFreeWriteOverlay = true
            if enablePaperTransfer {
                showPaperTransfer = true
            }
        }
    }

    /// Record the child's paper-transfer self-assessment score and dismiss the overlay.
    func submitPaperTransfer(score: Double) {
        progressStore.recordPaperTransferScore(for: currentLetterName, score: score)
        showPaperTransfer = false
    }

    /// Manually complete observe phase (tap to continue).
    func completeObservePhase() {
        guard phaseController.currentPhase == .observe else { return }
        stopGuideAnimation()
        advanceLearningPhase()
    }

    /// Handle a tap on a numbered start dot in the direct phase.
    /// Correct order tap: plays confirmation audio, shows directional arrow, advances.
    /// Wrong order tap: gentle haptic, pulses the correct dot.
    func tapDirectDot(index: Int) {
        guard phaseController.currentPhase == .direct else { return }
        guard let rawStrokes = rawGlyphStrokes else { return }
        let total = rawStrokes.strokes.count
        guard index < total, !directTappedDots.contains(index) else { return }

        if index == directNextExpectedDotIndex {
            let isFirstTap = directTappedDots.isEmpty
            directTappedDots.insert(index)
            haptics.fire(.checkpointHit)
            // Replay the letter name only on the FIRST correct tap. Every
            // following dot still fires a haptic + directional arrow, but the
            // audio would just retrigger the same "Aaa"/"Emm" and turn into
            // noise — the child already heard it; now they need direction,
            // not another repetition of the name.
            if isFirstTap, letters.indices.contains(letterIndex) {
                let files = letters[letterIndex].audioFiles
                if files.indices.contains(audioIndex) {
                    audio.loadAudioFile(named: files[audioIndex], autoplay: true)
                }
            }
            // Show directional arrow briefly along the stroke path.
            directArrowStrokeIndex = index
            // On the final dot, the old code advanced the phase synchronously,
            // which tore down the direct-phase overlay before the arrow had a
            // chance to render — so the last stroke never got its direction
            // cue. Defer the phase advance until the arrow finishes so the
            // last arrow is shown just like the others.
            let isLastTap = directTappedDots.count >= total
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1.2))
                if self.directArrowStrokeIndex == index {
                    self.directArrowStrokeIndex = nil
                }
                if isLastTap, self.phaseController.currentPhase == .direct {
                    self.haptics.fire(.letterCompleted)
                    self.advanceLearningPhase()
                }
            }
        } else {
            // Wrong dot — gentle haptic, pulse the correct one
            haptics.fire(.offPath)
            directPulsingDot = true
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(700))
                self.directPulsingDot = false
            }
        }
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

    /// Letter names visible based on the showAllLetters toggle, sorted by the active ordering strategy.
    var visibleLetterNames: [String] {
        let pool = showAllLetters
            ? letters.map(\.name)
            : letters.filter { demoBaseLetters.contains($0.baseLetter) }.map(\.name)
        let order = letterOrdering.orderedLetters()
        let rankMap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return pool.sorted { a, b in
            let ra = rankMap[a.uppercased()] ?? Int.max
            let rb = rankMap[b.uppercased()] ?? Int.max
            return ra == rb ? a < b : ra < rb
        }
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
        freeWriteTimestamps.removeAll(keepingCapacity: true)
        freeWriteForces.removeAll(keepingCapacity: true)
        if phaseController.currentPhase == .freeWrite {
            freeWritePath.removeAll(keepingCapacity: true)
            freeWriteSessionStart = CACurrentMediaTime()
        }
        if phaseController.currentPhase == .guided || phaseController.currentPhase == .freeWrite {
            strokesPerSecond = 0
            activePhaseStartTime = CACurrentMediaTime()
        }
        directTappedDots.removeAll()
        directPulsingDot = false
        directArrowStrokeIndex = nil
        smoothedVelocity = 0
        playback.resumeIntent = false
        playback.cancelPending()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
    }

    private func recordPhaseSessionCompletion() {
        let accuracy = Double(phaseController.overallScore)
        let duration = letterLoadTime.map { CACurrentMediaTime() - $0 } ?? 0
        let scores: [String: Double] = Dictionary(
            uniqueKeysWithValues: phaseController.phaseScores.map { ($0.key.rawName, Double($0.value)) }
        )
        for (phase, phaseScore) in scores {
            dashboardStore.recordPhaseSession(
                letter: currentLetterName,
                phase: phase,
                completed: true,
                score: phaseScore,
                schedulerPriority: 0,
                condition: thesisCondition,
                assessment: phase == "freeWrite" ? lastWritingAssessment : nil
            )
        }
        commitCompletion(letter: currentLetterName,
                         accuracy: accuracy,
                         duration: duration,
                         phaseScores: scores)
    }

    /// Shared completion side-effects: durable progress + streak + dashboard
    /// row, background cloud sync, difficulty-tier adaptation, completion HUD.
    /// Both the per-letter stroke-completion path and the multi-phase session
    /// completion path go through here so the side-effect set can never drift
    /// between the two — every store-write addition lands in one place.
    private func commitCompletion(letter: String,
                                  accuracy: Double,
                                  duration: TimeInterval,
                                  phaseScores: [String: Double]? = nil) {
        let speed: Double? = strokesPerSecond > 0 ? Double(strokesPerSecond) : nil
        progressStore.recordCompletion(for: letter, accuracy: accuracy, phaseScores: phaseScores, speed: speed)
        if showingVariant, letters.indices.contains(letterIndex),
           let variantID = letters[letterIndex].variants?.first {
            progressStore.recordVariantUsed(for: letter, variantID: variantID)
        }
        streakStore.recordSession(date: Date(), lettersCompleted: [letter], accuracy: accuracy)
        dashboardStore.recordSession(letter: letter, accuracy: accuracy,
                                      durationSeconds: duration, date: Date(),
                                      condition: thesisCondition)
        Task { [weak self] in try? await self?.syncCoordinator.pushAll() }

        let adaptSample = AdaptationSample(letter: letter,
                                           accuracy: CGFloat(accuracy),
                                           completionTime: duration)
        adaptationPolicy.record(adaptSample)
        currentDifficultyTier         = adaptationPolicy.currentTier
        strokeTracker.radiusMultiplier = currentDifficultyTier.radiusMultiplier

        showCompletionHUD()
    }

    // MARK: - Parent dashboard access

    var dashboardSnapshot: DashboardSnapshot { dashboardStore.snapshot }
    var currentStreak: Int { streakStore.currentStreak }
    var longestStreak: Int { streakStore.longestStreak }

    enum SpeedTrendDirection { case improving, stable, declining }

    /// Aggregate writing-speed trend across all practiced letters.
    /// Returns nil when fewer than two speed samples exist for any letter.
    var writingSpeedTrend: SpeedTrendDirection? {
        let trends = progressStore.allProgress.values
            .compactMap(\.speedTrend)
            .filter { $0.count >= 2 }
        guard !trends.isEmpty else { return nil }
        var totalRelGain = 0.0
        var count = 0
        for trend in trends {
            let half = max(1, trend.count / 2)
            let oldAvg = trend.prefix(half).reduce(0.0, +) / Double(half)
            let newAvg = trend.suffix(trend.count - half).reduce(0.0, +) / Double(trend.count - half)
            guard oldAvg > 0 else { continue }
            totalRelGain += (newAvg - oldAvg) / oldAvg
            count += 1
        }
        guard count > 0 else { return nil }
        let avg = totalRelGain / Double(count)
        if avg > 0.10 { return .improving }
        if avg < -0.10 { return .declining }
        return .stable
    }

    // MARK: - Debug

    #if DEBUG
    var debugActivePathCount: Int { activePath.count }
    /// Raw-name of the participant's assigned A/B condition. Surfaced in the
    /// dashboard's debug-only Forschungsmetriken section so a researcher can
    /// confirm at a glance which arm the device is on.
    var thesisConditionRawName: String { thesisCondition.rawValue }

    // MARK: - Debug audio tuning (forwarders for the DebugAudioPanel sliders)
    //
    // The debug panel binds Sliders to these computed properties; each setter
    // forwards to the underlying controller / engine so changes apply
    // immediately while the child is tracing. Wrapping in #if DEBUG keeps
    // the runtime tuning surface out of release builds entirely.

    /// AudioEngine fade-out duration (s). 0 reverts to abrupt-stop behaviour.
    var tuneFadeOutSeconds: TimeInterval {
        get { (audio as? AudioEngine)?.fadeOutSeconds ?? 0 }
        set { (audio as? AudioEngine)?.fadeOutSeconds = newValue }
    }
    /// PlaybackController idle-debounce window (s) — perceived "finger-lifting" delay.
    var tuneIdleDebounce: TimeInterval {
        get { playback.idleDebounceSeconds }
        set { playback.idleDebounceSeconds = newValue }
    }
    /// PlaybackController active-debounce window (s).
    var tuneActiveDebounce: TimeInterval {
        get { playback.activeDebounceSeconds }
        set { playback.activeDebounceSeconds = newValue }
    }
    /// Coalesce window for rapid play-intents (s).
    var tunePlayIntentDedup: TimeInterval {
        get { playback.playIntentDebounceSeconds }
        set { playback.playIntentDebounceSeconds = newValue }
    }
    /// Min smoothed touch velocity (pt/s) before audio kicks in.
    var tuneVelocityThreshold: CGFloat {
        get { playbackActivationVelocityThreshold }
        set { playbackActivationVelocityThreshold = newValue }
    }
    /// Exponential smoothing factor on touch velocity (0–1).
    var tuneVelocitySmoothing: CGFloat {
        get { velocitySmoothingAlpha }
        set { velocitySmoothingAlpha = newValue }
    }
    /// Min per-event movement (pt). Below this the touch event is ignored.
    var tuneMinMoveDistance: CGFloat {
        get { minimumTouchMoveDistance }
        set { minimumTouchMoveDistance = newValue }
    }
    /// Lower clamp for time-stretch playback rate.
    var tuneMinPlaybackRate: Float {
        get { (audio as? AudioEngine)?.minPlaybackRate ?? 0.5 }
        set { (audio as? AudioEngine)?.minPlaybackRate = newValue }
    }
    /// Upper clamp for time-stretch playback rate.
    var tuneMaxPlaybackRate: Float {
        get { (audio as? AudioEngine)?.maxPlaybackRate ?? 2.0 }
        set { (audio as? AudioEngine)?.maxPlaybackRate = newValue }
    }
    /// Pitch shift in cents (AVAudioUnitTimePitch.pitch). 0 = unshifted.
    var tunePitchCents: Float {
        get { (audio as? AudioEngine)?.pitchCents ?? 0 }
        set { (audio as? AudioEngine)?.pitchCents = newValue }
    }
    #endif

    // MARK: - Private helpers

    private func load(letter: LetterAsset) {
        phaseController.reset()
        freeWritePoints.removeAll(keepingCapacity: true)
        freeWriteTimestamps.removeAll(keepingCapacity: true)
        freeWriteForces.removeAll(keepingCapacity: true)
        freeWriteSessionStart = 0
        activePhaseStartTime = 0
        strokesPerSecond = 0
        freeWritePath.removeAll(keepingCapacity: true)
        showFreeWriteOverlay = false
        showPaperTransfer = false
        showingVariant = false
        variantStrokeCache = nil
        scriptStrokeCache.removeAll(keepingCapacity: true)
        lastFreeWriteDistance = 0
        lastWritingAssessment = nil
        directTappedDots.removeAll()
        directPulsingDot = false
        directArrowStrokeIndex = nil
        showGhost                      = false
        currentLetterName              = letter.name
        currentLetterImageName         = letter.imageName
        currentLetterImage             = PrimaeLetterRenderer.render(letter: letter.name, size: canvasSize, schriftArt: schriftArt) ?? PBMLoader.load(named: letter.imageName)
        // Only point at which the detector can downgrade from .pencil
        // back to .finger — see InputModeDetector for the hysteresis
        // rule. Runs BEFORE reapplyGridPreset so the grid reflects
        // post-reset state.
        detector.resetForSequenceChange()
        // Build the grid BEFORE loading stroke checkpoints: reapplyGridPreset
        // creates fresh LetterCell instances with brand-new StrokeTrackers,
        // and `strokeTracker` is now a computed alias for grid.activeCell.tracker.
        // Loading into the old grid's tracker would be thrown away here.
        reapplyGridPreset()
        reloadStrokeCheckpoints(for: letter)
        progress                       = 0
        audioIndex                     = 0
        didCompleteCurrentLetter       = false
        letterLoadTime                 = CACurrentMediaTime()
        messages.clearCompletionState()
        activePath.removeAll(keepingCapacity: true)
        isSingleTouchInteractionActive = false
        smoothedVelocity               = 0
        playback.resumeIntent   = true
        playback.cancelPending()
        stopGuideAnimation()
        // Auto-start stroke animation in observe phase, or skip phases entirely
        // when the letter has no strokes (lowercase/umlaut placeholders) — there's
        // nothing to demonstrate, and isComplete would otherwise report vacuous success.
        if phaseController.currentPhase == .observe {
            // Use the active script's strokes (rawGlyphStrokes) for both the
            // empty-strokes skip check and the animation payload so
            // Schreibschrift mode animates the Playwrite path, not the
            // Druckschrift skeleton from letter.strokes.
            let observeStrokes = rawGlyphStrokes ?? letter.strokes
            if observeStrokes.strokes.isEmpty {
                phaseController.advance(score: 1.0)  // skip observe
                if phaseController.currentPhase == .direct {
                    phaseController.advance(score: 1.0)  // skip direct (no dots to tap)
                }
            } else {
                animation.startAfterDelay(0.3, strokes: observeStrokes)
            }
        }
        // If we land directly in guided or freeWrite (e.g. after skipping phases or
        // for thesis conditions that omit observe/direct), start the speed clock now.
        if phaseController.currentPhase == .guided || phaseController.currentPhase == .freeWrite {
            activePhaseStartTime = CACurrentMediaTime()
        }
        if let firstAudio = letter.audioFiles.first {
            audio.loadAudioFile(named: firstAudio, autoplay: false)
            playback.request(.idle, immediate: true)
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
        playback.request(.idle, immediate: true)
    }

    private func showCompletionHUD() {
        messages.show(completion: "🎉 \(currentLetterName) geschafft!")
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

    /// Reload stroke checkpoints mapped to canvas-normalised coordinates (0–1).
    /// Pass `usingSize` to override `self.canvasSize` — used by `updateTouch` to
    /// guarantee the mapping size equals the size used to normalise the touch point.
    /// Idempotent: a rebuild with the same (letter, size, schriftArt) as the
    /// prior successful rebuild is skipped, so the rotation safety-net window
    /// in `updateTouch` and repeated `canvasSize.didSet` triggers at the same
    /// dimensions don't burn CPU re-mapping unchanged data. The cache hit is
    /// gated on `strokeTracker.definition != nil` so any path that resets the
    /// tracker (resetLetter, phase transition) automatically misses and rebuilds
    /// without each reset site having to remember to invalidate the key.
    private func reloadStrokeCheckpoints(for letter: LetterAsset, usingSize size: CGSize? = nil) {
        // Stroke coordinates in JSON are glyph-relative (0–1 within bounding box).
        // Map to per-cell-normalised coordinates using each cell's glyph rect,
        // so a multi-cell layout runs each cell's tracker in its own
        // cell-local 0–1 space. For a length-1 finger sequence the single
        // cell's frame equals the whole canvas, so the mapping is identical
        // to the pre-grid canvas-wide checkpoints.
        //
        // Source-of-truth priority: variant (when toggled) → per-script JSON
        // → user calibration → bundle default.
        let effectiveSize = size ?? canvasSize
        let key = CheckpointBuildKey(letter: letter.name, size: effectiveSize, schriftArt: schriftArt, showingVariant: showingVariant)
        if key == lastCheckpointKey, strokeTracker.definition != nil { return }
        let source: LetterStrokes
        if showingVariant, let vs = variantStrokeCache {
            source = vs
        } else if let ss = activeScriptStrokes {
            source = ss
        } else {
            source = calibrationStore.strokes(for: letter.name, schriftArt: schriftArt) ?? letter.strokes
        }
        for cell in grid.cells {
            let cellSize = cell.frame.size
            guard cellSize.width > 0, cellSize.height > 0 else {
                // Pre-layout state (e.g. during init before onAppear) — fall
                // back to the source strokes so the tracker at least has
                // definition loaded; the next layout pass will rebuild.
                cell.tracker.load(source)
                continue
            }
            let strokesForCell: LetterStrokes
            if let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: letter.name, canvasSize: cellSize, schriftArt: schriftArt) {
                let mapped = source.strokes.map { stroke in
                    StrokeDefinition(id: stroke.id, checkpoints: stroke.checkpoints.map { cp in
                        Checkpoint(x: gr.minX + cp.x * gr.width,
                                   y: gr.minY + cp.y * gr.height)
                    })
                }
                strokesForCell = LetterStrokes(letter: source.letter,
                                               checkpointRadius: source.checkpointRadius,
                                               strokes: mapped)
            } else {
                strokesForCell = source
            }
            cell.tracker.load(strokesForCell)
        }
        lastCheckpointKey = key
    }

    /// Persist calibrated glyph-relative checkpoints. Delegates to CalibrationStore
    /// and re-applies the new data to the tracker so the current letter reflects
    /// the calibration immediately without navigating away and back.
    func persistCalibratedStrokes(_ strokes: [[CGPoint]], for letter: String) {
        calibrationStore.persist(strokes, for: letter, schriftArt: schriftArt)
        guard letters.indices.contains(letterIndex) else { return }
        // Calibration replaces the source checkpoint set, so the (letter, size)
        // idempotency cache no longer reflects what's loaded — invalidate it
        // before the rebuild call so the cache check doesn't short-circuit us.
        lastCheckpointKey = nil
        reloadStrokeCheckpoints(for: letters[letterIndex])
    }

    private func toast(_ text: String) {
        messages.show(toast: text)
    }

    /// Idempotency key for `reloadStrokeCheckpoints`. Equal keys mean the cached
    /// strokeTracker contents are still valid for the requested mapping —
    /// (letter changes invalidate via name; rotations via size; font swaps via
    /// schriftArt). Calibration changes invalidate manually since the source
    /// data is not in this key.
    private struct CheckpointBuildKey: Equatable {
        let letter: String
        let size: CGSize
        let schriftArt: SchriftArt
        let showingVariant: Bool
    }
}
