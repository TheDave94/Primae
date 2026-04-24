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
            grid.layout(in: canvasSize, schriftArt: schriftArt)
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

    /// Index of the currently active cell in the grid. Canvas uses this
    /// to scope active-cell-only scaffolding (direction arrow, animation
    /// guide dot) — other cells render static ghost + dots only.
    var gridActiveCellIndex: Int { grid.activeCellIndex }

    /// Rendered word layout (image + per-character frames). Non-nil only
    /// for `.word` sequences after a successful CoreText layout — the
    /// canvas uses it to blit the whole word as one connected run so
    /// Schreibschrift ligatures aren't cropped per glyph.
    var gridWordRendering: PrimaeLetterRenderer.WordRendering? { grid.wordRendering }

    /// Strokes for the cell at `index`, mapped per its letter. For the
    /// currently-loaded letter (single-letter mode, or first cell of a
    /// word starting with it) this honors the full override chain
    /// (variant / script / calibration). Other cells of a word sequence
    /// fall back to the bundle's default Druckschrift strokes for their
    /// letter — words don't currently support per-letter variants or
    /// calibration. Returns nil if the cell's letter isn't in the
    /// library.
    func gridCellStrokes(at index: Int) -> LetterStrokes? {
        guard index < grid.cells.count else { return nil }
        let cellLetter = grid.cells[index].item.letter
        if cellLetter == currentLetterName {
            return glyphRelativeStrokes
        }
        return letters.first(where: { $0.name == cellLetter })?.strokes
    }

    /// Letter displayed in the cell at `index`, or nil if out of range.
    /// Canvas uses this to render each cell's own glyph in word mode
    /// — repetition mode returns the same letter for every index.
    func gridCellLetter(at index: Int) -> String? {
        guard index < grid.cells.count else { return nil }
        return grid.cells[index].item.letter
    }

    /// Exposed for the debug UI and for unit tests that want to assert
    /// detector state without poking private storage.
    var inputModeDetector: InputModeDetector { detector }

    /// Forwarded from the pencil overlay on every pencil touchesBegan.
    /// Feeds the detector so the first pencil stroke of a session flips
    /// the effective preset to `.pencil`, and re-applies the grid preset
    /// immediately so the layout splits before the stroke completes.
    /// Safe to auto-promote now: commit 4b/4c made tracking cell-aware,
    /// so touches in cell 0 of a newly-split pencil layout still feed
    /// the tracker correctly.
    func pencilDidTouchDown() {
        let priorKind = detector.effectiveKind
        detector.observeTouchBegan(isPencil: true)
        if priorKind != detector.effectiveKind,
           letters.indices.contains(letterIndex) {
            reapplyGridPreset()
            reloadStrokeCheckpoints(for: letters[letterIndex])
        }
    }

    /// Forwarded from the finger overlay on every finger touchesBegan.
    /// Tracks the finger-streak counter used by the detector's
    /// hysteresis to decide when to demote a stale pencil session.
    func fingerDidTouchDown() {
        detector.observeTouchBegan(isPencil: false)
    }

    /// Rebuild the grid's sequence + preset to match the detector's
    /// effective input mode. Called on letter loads, from the debug
    /// override chip, and from the pencil overlay when a real pencil
    /// touch promotes the session.
    ///
    /// - `.finger`: length-1 singleLetter sequence, finger preset —
    ///   byte-identical to pre-grid behavior.
    /// - `.pencil` (auto or forced): repetition sequence broadcasting the
    ///   current letter across the preset's default cell count. Tracking
    ///   is cell-aware as of commit 4b, so writing works in each cell.
    func reapplyGridPreset() {
        guard letters.indices.contains(letterIndex) else { return }
        let letter = letters[letterIndex]
        let usePencil = detector.effectiveKind == .pencil
        let preset: InputPreset = usePencil ? .pencil : .finger
        let sequence: TracingSequence = usePencil
            ? .repetition(letter.name, count: preset.cellCount)
            : .singleLetter(letter.name)
        grid.load(sequence: sequence, preset: preset)
        grid.layout(in: canvasSize, schriftArt: schriftArt)
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
    /// Whether the freeform writing button is exposed in the picker bar.
    /// Parents can disable via Settings; default is enabled.
    var enableFreeformMode: Bool = true {
        didSet {
            UserDefaults.standard.set(enableFreeformMode,
                forKey: "de.flamingistan.buchstaben.enableFreeformMode")
        }
    }

    // MARK: - Recognition + freeform state

    /// Most recent CoreML recognition result. Cleared on letter load and
    /// phase reset. Surfaced by RecognitionFeedbackView after freeWrite
    /// completion or freeform endTouch.
    private(set) var lastRecognitionResult: RecognitionResult?

    /// Whether the app is currently in guided tracing mode (default) or
    /// freeform writing mode. Setting .freeform switches the canvas to a
    /// blank background and routes endTouch through the recognizer.
    var writingMode: WritingMode = .guided
    /// Sub-mode inside freeform (.letter vs .word).
    var freeformSubMode: FreeformSubMode = .letter
    /// Target word when `freeformSubMode == .word`. Nil in letter mode.
    private(set) var freeformTargetWord: FreeformWord?
    /// Canvas-space points the child has drawn in freeform mode, across
    /// multiple strokes. Cleared by `clearFreeformCanvas()` and when the
    /// user returns to guided mode.
    private(set) var freeformPoints: [CGPoint] = []
    /// Per-stroke point counts so segmentation can pick up pen lifts if
    /// needed. Each entry is the count of points appended during one
    /// beginTouch/endTouch cycle in freeform mode.
    private(set) var freeformStrokeSizes: [Int] = []
    /// Active-stroke path within freeform — becomes a green trail on the
    /// canvas. Cleared on endTouch; retained portions move into the
    /// static freeformPoints buffer.
    private(set) var freeformActivePath: [CGPoint] = []
    /// Per-letter recognition results in freeform word mode. Empty in
    /// letter mode or before the first "Fertig" tap.
    private(set) var freeformWordResults: [RecognitionResult] = []
    /// True while the recognizer is running async — UI can show a spinner.
    private(set) var isRecognizing: Bool = false
    /// Size of the freeform blank canvas. Recorded on every updateFreeformTouch
    /// so `recognizeFreeformLetter`/`submitFreeformWord` can pass the right
    /// bounding dimensions to the recognizer without piggy-backing on the
    /// guided-mode `canvasSize`.
    private(set) var freeformCanvasSize: CGSize = .zero
    /// Visibility gate for RecognitionFeedbackView. True after a
    /// successful recognition call until the child taps the badge or the
    /// 4-second auto-dismiss timer fires. Driven off the presence of
    /// `lastRecognitionResult` together with the dismissed flag so the
    /// view re-appears for each fresh result.
    var isRecognitionBadgeDismissed: Bool = false

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
    private let letterRecognizer: LetterRecognizerProtocol

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
        self.enableFreeformMode     = deps.enableFreeformMode
        self.letterRecognizer       = deps.letterRecognizer
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

    /// Autoplay the active cell's letter audio — called on cell advance
    /// in word mode so each letter announces itself as the child moves
    /// through the sequence. Always uses variant 0 (no user-selected
    /// variant for transient cell-advance sounds). Silent when the
    /// active cell's letter has no audio assets in the inventory,
    /// which is acceptable demo behavior per the thesis scope.
    private func autoplayActiveCellLetter() {
        let activeLetter = gridCellLetter(at: gridActiveCellIndex) ?? currentLetterName
        guard let asset = letters.first(where: { $0.name == activeLetter }),
              let first = asset.audioFiles.first else { return }
        audio.loadAudioFile(named: first, autoplay: true)
    }

    func replayAudio() {
        // Re-load and autoplay the ACTIVE cell's letter audio file. For a
        // length-1 single-letter session the active cell's letter equals
        // letters[letterIndex].name, so behavior is identical to today. In
        // word mode, the speaker plays whatever letter the child is on now.
        // Silence is acceptable for letters without audio assets — this is
        // scope-limited demo behavior per the thesis plan.
        let activeLetter = gridCellLetter(at: gridActiveCellIndex)
            ?? currentLetterName
        guard let asset = letters.first(where: { $0.name == activeLetter }) else { return }
        let files = asset.audioFiles
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

    /// Demo word list — Austrian Volksschule 1. Klasse canonical
    /// Woche-1 tracing words, ordered shortest → longest. Every word
    /// composes from letters currently in the bundle (A, F, I, K, L,
    /// M, O, P). See the research note in the commit message: OMA /
    /// OMI / OPA are the standard grandparent trio, MAMA / PAPA the
    /// parent pair, LAMA introduces doubled-letter practice, KILO and
    /// FILM are everyday 4-letter nouns.
    static let demoWordList: [String] = [
        "OMA", "OMI", "OPA", "MAMA", "PAPA", "LAMA", "KILO", "FILM"
    ]

    /// Index into `demoWordList` for the next `cycleWord()` call.
    /// Starts at 0 so the first cycle loads OMA.
    private var wordCycleIndex: Int = 0

    /// Human-readable hint for the debug "Wort:" chip — shows the next
    /// word the chip will load (not the one already loaded).
    var currentWordCycleLabel: String {
        guard !Self.demoWordList.isEmpty else { return "–" }
        return Self.demoWordList[wordCycleIndex % Self.demoWordList.count]
    }

    /// Advance through the demo word list and load the next word.
    /// Debug chip wiring only; the real picker UI comes with the
    /// full "Wörter" tab in a later commit.
    func cycleWord() {
        guard !Self.demoWordList.isEmpty else { return }
        let word = Self.demoWordList[wordCycleIndex % Self.demoWordList.count]
        wordCycleIndex = (wordCycleIndex + 1) % Self.demoWordList.count
        loadWord(word)
    }

    /// Load a word sequence — each character becomes its own cell. Demo
    /// feature for the thesis scope: uppercase-only (lowercase letters
    /// aren't currently in the audio inventory), no per-letter variants
    /// or calibration, no spaced-repetition tracking at the word level.
    /// Completion fires once the last cell's tracker completes.
    ///
    /// Implementation: anchor the VM at the word's first-letter asset so
    /// the existing load / audio / dashboard paths keep working, then
    /// replace the grid's length-1 sequence with the full word and
    /// re-map stroke checkpoints into each cell's 0–1 space.
    func loadWord(_ word: String) {
        let upper = word.uppercased()
        guard !upper.isEmpty, let first = upper.first,
              let idx = letters.firstIndex(where: { $0.name == String(first) }) else { return }
        letterIndex = idx
        load(letter: letters[idx])
        // load() built a length-1 (singleLetter) grid; swap in the word
        // sequence and re-flow cells + strokes to match.
        grid.load(sequence: .word(upper), preset: grid.preset)
        grid.layout(in: canvasSize, schriftArt: schriftArt)
        lastCheckpointKey = nil
        reloadStrokeCheckpoints(for: letters[idx])
        toast("Wort: \(upper)")
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
            grid.layout(in: canvasSize, schriftArt: schriftArt)
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
        // Aggregate across all cells so the progress bar tracks the whole
        // sequence, not just the active cell. For a length-1 sequence this
        // reduces to the active (and only) cell's overallProgress.
        progress = grid.aggregateProgress

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
        if hasStrokes, strokeTracker.isComplete {
            // Snapshot tracker-derived values BEFORE advancing — after the
            // grid moves the cursor, `strokeTracker` aliases the next cell
            // (fresh state, zero progress).
            let accuracy = Double(strokeTracker.overallProgress)
            let completingCellIndex = grid.activeCellIndex
            let sequenceDone = grid.advanceIfCompleted()
            if !sequenceDone {
                // Retain the just-completed cell's ink so it stays on
                // screen — preserves the child's written letter as they
                // move on to the next cell. VM activePath clears so the
                // next cell's tracing starts with a blank slate.
                if grid.cells.indices.contains(completingCellIndex) {
                    grid.cells[completingCellIndex].activePath = activePath
                }
                activePath.removeAll(keepingCapacity: true)
                // Play the next cell's letter audio so the child hears
                // "O → M → A" as they trace through "OMA". Per-cell
                // audio policy per the thesis-plan v1. Silent for letters
                // without an audio asset in the inventory.
                autoplayActiveCellLetter()
            } else if !didCompleteCurrentLetter {
                didCompleteCurrentLetter = true
                if feedbackIntensity > 0 { haptics.fire(.letterCompleted) }

                let duration = letterLoadTime.map { CACurrentMediaTime() - $0 } ?? 0
                commitCompletion(letter: currentLetterName,
                                 accuracy: accuracy,
                                 duration: duration)
                toast("Super gemacht!")
                playback.request(.idle, immediate: true)
            }
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

        // Kick the CoreML recognizer off BEFORE the phase advance so it
        // runs in parallel with the Fréchet-based scoring above and the
        // phase-transition side effects below. Result lands on
        // `lastRecognitionResult` when inference finishes; the UI
        // badge shows up shortly after the KP overlay renders.
        if wasInFreeWrite {
            runRecognizerForFreeWrite()
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

        if wasInFreeWrite {
            showFreeWriteOverlay = true
            if enablePaperTransfer {
                showPaperTransfer = true
            }
        }
    }

    /// Fire-and-forget recognizer pass for the completed freeWrite phase.
    /// Uses the absolute-canvas-space points already accumulated during
    /// updateTouch so the model sees the same stroke the child drew.
    private func runRecognizerForFreeWrite() {
        let pts = freeWritePoints
        let size = canvasSize
        let expected = currentLetterName
        isRecognizing = true
        Task { [weak self, letterRecognizer] in
            let result = await letterRecognizer.recognize(
                points: pts, canvasSize: size, expectedLetter: expected)
            guard let self else { return }
            await MainActor.run {
                self.isRecognizing = false
                self.lastRecognitionResult = result
                self.isRecognitionBadgeDismissed = false
                // commitCompletion already wrote the guided-mode session
                // record with a nil recognitionResult — by the time the
                // recognizer finishes, the progressStore entry exists but
                // doesn't know about this confidence. Append it now so the
                // dashboard trend reflects actual recognizer readings.
                if let r = result {
                    self.progressStore.recordRecognitionSample(
                        letter: expected, result: r)
                }
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
        lastRecognitionResult = nil
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
        // Word sequences fan out per-cell for progress + streak so each
        // letter that appears in a word counts toward its own mastery
        // tracking, while the dashboard + adaptation row uses the word
        // title so thesis analytics can distinguish word sessions from
        // single-letter sessions by the field length. Single-letter and
        // repetition sequences take the pre-word path unchanged.
        let lettersToRecord: [String]
        let dashboardLabel: String
        let isWordSequence: Bool
        if case .word(let word) = grid.sequence.kind {
            lettersToRecord = grid.cells.map(\.item.letter)
            dashboardLabel = word
            isWordSequence = true
        } else {
            lettersToRecord = [letter]
            dashboardLabel = letter
            isWordSequence = false
        }

        let speed: Double? = strokesPerSecond > 0 ? Double(strokesPerSecond) : nil
        // Recognition result lands asynchronously in parallel with phase
        // advance — it's often still nil here. Pass whatever's latched so
        // single-letter guided sessions that finish AFTER the recognizer
        // returns also populate the dashboard's confidence series.
        let rr = lastRecognitionResult
        for l in lettersToRecord {
            progressStore.recordCompletion(for: l, accuracy: accuracy,
                                           phaseScores: phaseScores, speed: speed,
                                           recognitionResult: rr)
        }
        // Variant tracking is single-letter only — loadWord doesn't
        // preserve showingVariant state across word entries.
        if !isWordSequence, showingVariant, letters.indices.contains(letterIndex),
           let variantID = letters[letterIndex].variants?.first {
            progressStore.recordVariantUsed(for: letter, variantID: variantID)
        }
        streakStore.recordSession(date: Date(), lettersCompleted: lettersToRecord, accuracy: accuracy)
        dashboardStore.recordSession(letter: dashboardLabel, accuracy: accuracy,
                                      durationSeconds: duration, date: Date(),
                                      condition: thesisCondition)
        Task { [weak self] in try? await self?.syncCoordinator.pushAll() }

        let adaptSample = AdaptationSample(letter: dashboardLabel,
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
        lastRecognitionResult = nil
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
            let cellLetter = cell.item.letter
            // Per-cell source: the loaded letter keeps its full override
            // chain (variant / script / calibration). Other letters (word
            // mode: the non-first cells) fall back to the bundle's default
            // Druckschrift strokes for that letter. Unknown letters skip.
            let cellSource: LetterStrokes
            if cellLetter == letter.name {
                cellSource = source
            } else if let cellAsset = letters.first(where: { $0.name == cellLetter }) {
                cellSource = cellAsset.strokes
            } else {
                continue
            }
            let cellSize = cell.frame.size
            guard cellSize.width > 0, cellSize.height > 0 else {
                // Pre-layout state (e.g. during init before onAppear) — fall
                // back to the source strokes so the tracker at least has
                // definition loaded; the next layout pass will rebuild.
                cell.tracker.load(cellSource)
                continue
            }
            let strokesForCell: LetterStrokes
            if let gr = PrimaeLetterRenderer.normalizedGlyphRect(
                for: cellLetter, canvasSize: cellSize, schriftArt: schriftArt) {
                let mapped = cellSource.strokes.map { stroke in
                    StrokeDefinition(id: stroke.id, checkpoints: stroke.checkpoints.map { cp in
                        Checkpoint(x: gr.minX + cp.x * gr.width,
                                   y: gr.minY + cp.y * gr.height)
                    })
                }
                strokesForCell = LetterStrokes(letter: cellSource.letter,
                                               checkpointRadius: cellSource.checkpointRadius,
                                               strokes: mapped)
            } else {
                strokesForCell = cellSource
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

    // MARK: - Freeform writing mode

    /// Switch the app into freeform writing. Clears any in-progress guided
    /// state and starts a fresh blank canvas. The reference letter is
    /// whatever the child last tapped in the letter picker — that name
    /// travels with us as the comparison target.
    func enterFreeformMode(subMode: FreeformSubMode = .letter) {
        writingMode = .freeform
        freeformSubMode = subMode
        clearFreeformCanvas()
        if subMode == .word {
            freeformTargetWord = FreeformWordList.all.first
        } else {
            freeformTargetWord = nil
        }
        // Halt any in-progress phase audio/animation so freeform is quiet.
        stopGuideAnimation()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
        toast(subMode == .word ? "Wort schreiben" : "Freies Schreiben")
    }

    /// Return to guided tracing mode. Re-loads the current letter so
    /// phase state and strokes are rebuilt fresh.
    func exitFreeformMode() {
        writingMode = .guided
        freeformSubMode = .letter
        freeformTargetWord = nil
        clearFreeformCanvas()
        if letters.indices.contains(letterIndex) {
            load(letter: letters[letterIndex])
        }
    }

    /// Wipe the freeform drawing buffer without leaving freeform mode.
    /// Used by the "Nochmal" button after a recognition result.
    func clearFreeformCanvas() {
        freeformPoints.removeAll(keepingCapacity: true)
        freeformStrokeSizes.removeAll(keepingCapacity: true)
        freeformActivePath.removeAll(keepingCapacity: true)
        freeformWordResults.removeAll(keepingCapacity: true)
        lastRecognitionResult = nil
    }

    /// Pick the next target word for freeform word mode.
    func selectFreeformWord(_ word: FreeformWord) {
        freeformTargetWord = word
        freeformSubMode = .word
        clearFreeformCanvas()
    }

    /// Begin a freeform stroke. Mirrors `beginTouch` but skips all
    /// checkpoint / phase / audio side effects.
    func beginFreeformTouch(at p: CGPoint) {
        guard writingMode == .freeform else { return }
        freeformActivePath = [p]
    }

    func updateFreeformTouch(at p: CGPoint, canvasSize size: CGSize) {
        guard writingMode == .freeform else { return }
        // Record the freeform canvas dimensions separately — we don't
        // touch `canvasSize` because its didSet rebuilds the guided-mode
        // stroke tracker and fires needless work during a blank-canvas
        // stroke. Recognition uses the size passed into submit.
        freeformCanvasSize = size
        // Skip microscopic repeats — keeps the buffer from ballooning on
        // a palm rest or a stationary touch.
        if let last = freeformActivePath.last,
           hypot(p.x - last.x, p.y - last.y) < 1.0 { return }
        freeformActivePath.append(p)
    }

    /// End a freeform stroke. In letter sub-mode this triggers recognition
    /// immediately (child writes one letter → one result). In word sub-mode
    /// the stroke is retained for the "Fertig" button; recognition waits.
    func endFreeformTouch() {
        guard writingMode == .freeform else { return }
        if freeformActivePath.count >= 2 {
            freeformStrokeSizes.append(freeformActivePath.count)
            freeformPoints.append(contentsOf: freeformActivePath)
        }
        freeformActivePath.removeAll(keepingCapacity: true)

        if freeformSubMode == .letter, freeformPoints.count >= 2 {
            recognizeFreeformLetter()
        }
    }

    private func recognizeFreeformLetter() {
        let pts = freeformPoints
        let size = freeformCanvasSize.width > 0 ? freeformCanvasSize : canvasSize
        isRecognizing = true
        Task { [weak self, letterRecognizer] in
            let result = await letterRecognizer.recognize(
                points: pts, canvasSize: size, expectedLetter: nil)
            guard let self else { return }
            await MainActor.run {
                self.isRecognizing = false
                self.lastRecognitionResult = result
                self.isRecognitionBadgeDismissed = false
                if let result {
                    self.recordFreeformCompletion(result: result)
                }
            }
        }
    }

    /// Submit a finished freeform word. Segments the stroke buffer into
    /// letter regions by horizontal gaps and runs the recognizer on each
    /// segment. Results land in `freeformWordResults` in left-to-right order.
    func submitFreeformWord() {
        guard writingMode == .freeform, freeformSubMode == .word,
              let target = freeformTargetWord,
              !freeformPoints.isEmpty else { return }

        let segmentationWidth = freeformCanvasSize.width > 0
            ? freeformCanvasSize.width : canvasSize.width
        let segments = Self.segmentByHorizontalGaps(
            points: freeformPoints,
            canvasWidth: segmentationWidth
        )
        let targetLetters = Array(target.word)
        let size = freeformCanvasSize.width > 0 ? freeformCanvasSize : canvasSize

        isRecognizing = true
        Task { [weak self, letterRecognizer] in
            var results: [RecognitionResult] = []
            for (i, seg) in segments.enumerated() {
                let expected: String? = i < targetLetters.count
                    ? String(targetLetters[i]) : nil
                if let r = await letterRecognizer.recognize(
                    points: seg, canvasSize: size, expectedLetter: expected) {
                    results.append(r)
                }
            }
            guard let self else { return }
            await MainActor.run {
                self.isRecognizing = false
                self.freeformWordResults = results
                if let last = results.last {
                    self.lastRecognitionResult = last
                    self.isRecognitionBadgeDismissed = false
                }
                self.recordFreeformWordCompletion(
                    target: target, results: results)
            }
        }
    }

    /// Dismiss the recognition badge. Called by the badge's tap gesture
    /// and its 4-second auto-dismiss task.
    func dismissRecognitionBadge() {
        isRecognitionBadgeDismissed = true
    }

    private func recordFreeformCompletion(result: RecognitionResult) {
        // Freeform letter sessions record under the predicted letter so
        // the dashboard tallies what the child actually wrote (not what
        // they were trying to write — the latter is nil in freeform).
        let label = result.predictedLetter.uppercased()
        progressStore.recordFreeformCompletion(letter: label, result: result)
    }

    private func recordFreeformWordCompletion(target: FreeformWord,
                                              results: [RecognitionResult]) {
        for r in results {
            let label = r.predictedLetter.uppercased()
            progressStore.recordFreeformCompletion(letter: label, result: r)
        }
    }

    // MARK: - Segmentation

    /// Split a buffer of points into per-letter clusters using horizontal
    /// gaps wider than `gapFraction` of the canvas width (default 15%).
    /// Simple but effective for 1st-graders writing left-to-right with
    /// visible spaces between glyphs. Sorts the input by x first so the
    /// clusters come out left-to-right regardless of stroke order.
    static func segmentByHorizontalGaps(
        points: [CGPoint],
        canvasWidth: CGFloat,
        gapFraction: CGFloat = 0.15
    ) -> [[CGPoint]] {
        guard !points.isEmpty, canvasWidth > 0 else { return [] }
        let gap = canvasWidth * gapFraction
        let sorted = points.sorted { $0.x < $1.x }
        var clusters: [[CGPoint]] = [[sorted[0]]]
        for p in sorted.dropFirst() {
            guard let current = clusters.last, let lastPoint = current.last else {
                clusters.append([p]); continue
            }
            if p.x - lastPoint.x > gap {
                clusters.append([p])
            } else {
                clusters[clusters.count - 1].append(p)
            }
        }
        return clusters.filter { $0.count >= 2 }
    }
}
