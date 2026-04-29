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
            // Invariant: variants are druckschrift-only (review item
            // W-10). Switching script invalidates any previously-shown
            // variant — clearing it here keeps the impossible state
            // `showingVariant && schriftArt != .druckschrift` from
            // ever being observable, regardless of toggle ordering.
            if schriftArt != .druckschrift {
                showingVariant = false
                variantStrokeCache = nil
            }
            currentLetterImage = PrimaeLetterRenderer.render(
                letter: currentLetterName, size: canvasSize, schriftArt: schriftArt)
                ?? PBMLoader.load(named: currentLetterImageName)
            reloadStrokeCheckpoints(for: letters[letterIndex])
            // W-29: reloadStrokeCheckpoints resets the tracker to empty
            // checkpoints; zero the progress bar immediately so it doesn't
            // show the previous font's progress until the next updateTouch.
            progress = 0
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

    /// Active-cell frame in canvas-pixel coordinates, only when the grid
    /// is multi-cell (word mode). Single-cell sessions return `nil` so the
    /// canvas overlays default to full-canvas geometry. Used by overlays
    /// that need to map normalized glyph coordinates (e.g.
    /// DirectPhaseDotsOverlay) into the active cell instead of the whole
    /// canvas — without this they draw in the wrong place for word mode
    /// (W-24 follow-up to C-5: same root cause as the freeWrite scorer
    /// fix, applied to the direct-phase dot renderer).
    var multiCellActiveFrame: CGRect? {
        grid.cells.count > 1 ? grid.activeCell.frame : nil
    }

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
    /// scaffolding is now ON only in observe (the intro animation) so the
    /// child sees stroke direction being demonstrated. In direct / guided
    /// / freeWrite the fat blue ghost lines are off by default and the
    /// child sees only the letter glyph + dots — the user's Hilfslinien
    /// toggle can add them back on demand for struggling sessions.
    var showGhostForPhase: Bool {
        switch phaseController.currentPhase {
        case .observe:                         return true
        case .direct, .guided, .freeWrite:     return false
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
    /// Maximum achievable stars under the active thesis condition.
    /// W-5: guidedOnly/control have 1 active phase so maxStars = 1, not 4.
    var maxStars: Int { phaseController.maxStars }
    /// Phases active under the current thesis condition. I-4: the
    /// `PhaseDotIndicator` HUD uses this so guidedOnly/control don't
    /// render three permanently-empty placeholder dots.
    var activePhases: [LearningPhase] { phaseController.activePhases }

    // MARK: - FreeWrite phase data (forwarded from FreeWritePhaseRecorder)
    //
    // The four buffers, session-timing state, and scoring helpers were
    // extracted into `FreeWritePhaseRecorder` during the W8 God-object
    // cleanup. The VM keeps the same read-only public surface so views
    // and tests don't notice the extraction.

    /// Accumulated canvas-space touch points for free-write scoring.
    var freeWritePoints: [CGPoint] { freeWriteRecorder.points }
    /// CACurrentMediaTime timestamps for each accumulated free-write point.
    var freeWriteTimestamps: [CFTimeInterval] { freeWriteRecorder.timestamps }
    /// Digitiser force at each accumulated free-write point (0 = finger / no data).
    var freeWriteForces: [CGFloat] { freeWriteRecorder.forces }
    /// Checkpoints passed per second in the current guided or freeWrite phase.
    /// Updated on every touch event; reset on phase transition and letter load.
    /// Renamed from `strokesPerSecond` (review item W-25): the figure is
    /// `completedCheckpoints / elapsed`, which is checkpoints/sec, not
    /// strokes/sec. The old name read as "strokes per second" and could
    /// mislead a thesis reader correlating it with motor-rhythm research.
    var checkpointsPerSecond: CGFloat { freeWriteRecorder.checkpointsPerSecond }
    /// Last computed Fréchet distance (for debug overlay).
    var lastFreeWriteDistance: CGFloat { freeWriteRecorder.lastDistance }
    /// Most recent Schreibmotorik four-dimension assessment from the freeWrite phase.
    var lastWritingAssessment: WritingAssessment? { freeWriteRecorder.lastAssessment }
    /// Most recent guided-phase checkpoint-accuracy score (0–1), captured
    /// the moment the child transitions out of Nachspuren. Surfaced by
    /// the Schule world as a verbal "Nachspuren fertig" feedback band.
    var lastGuidedScore: CGFloat? { freeWriteRecorder.lastGuidedScore }
    /// Normalised (0–1) touch path accumulated during the freeWrite phase.
    /// Kept for the KP overlay that shows where the child deviated.
    /// Forwarded from FreeWritePhaseRecorder.
    var freeWritePath: [CGPoint] { freeWriteRecorder.path }
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
    /// P6 (ROADMAP_V5): play the *phoneme* (sound the letter makes —
    /// /a/ as in *Affe*) instead of the letter *name* (/aː/) when the
    /// child taps the audio gesture. Falls back to the name set when
    /// a letter ships no phoneme recordings, so the toggle never
    /// produces silence on letters that haven't been recorded yet.
    /// Persisted in UserDefaults; default off (the canonical name
    /// audio is the established behaviour).
    var enablePhonemeMode: Bool = false {
        didSet {
            UserDefaults.standard.set(enablePhonemeMode,
                forKey: "de.flamingistan.buchstaben.enablePhonemeMode")
            // Reset the audio-variant cursor so a swipe doesn't index
            // out of the new (potentially shorter / longer) population.
            audioIndex = 0
        }
    }

    // MARK: - Recognition + freeform state (forwarded from FreeformController)

    /// Owns every freeform field. The VM keeps the *methods* because they
    /// touch VM-only collaborators (audio, recognizer, speech, stores);
    /// the controller exists to give those fields a single home for
    /// auditing and lifecycle management. Views observe via VM forwarders.
    private let freeform = FreeformController()

    /// Most recent CoreML recognition result (any mode). Cleared on
    /// letter load and phase reset.
    private(set) var lastRecognitionResult: RecognitionResult?

    /// Idempotency gate for in-flight recognition Tasks. Each recognition
    /// dispatch (freeWrite phase teardown, freeform letter, freeform word)
    /// stamps a fresh UUID here; the matching async completion handler
    /// checks equality before applying side effects (lastRecognitionResult,
    /// progress writes, overlay enqueue, speech). State-clearing
    /// transitions — `loadLetter`, `resetForPhaseTransition`,
    /// `clearFreeformCanvas` — set this to nil so any late-arriving
    /// recognition result whose dispatch preceded the clear is silently
    /// dropped instead of writing into the new context.
    ///
    /// Use the named helpers `issueRecognitionToken()` and
    /// `recognitionStillActive(_:)` rather than touching this directly —
    /// they keep the three dispatch / completion sites uniform.
    private var activeRecognitionToken: UUID?

    /// Stamp a fresh recognition token and return it. The caller is
    /// responsible for capturing the returned token in its dispatch
    /// closure and gating the completion handler with
    /// `recognitionStillActive(_:)`. Replaces the previous hand-rolled
    /// `let token = UUID(); self.activeRecognitionToken = token` block
    /// at each of the three recognition entry points.
    private func issueRecognitionToken() -> UUID {
        let token = UUID()
        self.activeRecognitionToken = token
        return token
    }

    /// True if `token` still represents the active recognition session.
    /// Returns false once a state-clearing transition has reset
    /// `activeRecognitionToken` or a newer dispatch has stamped a fresh
    /// token. Use as the first guard inside any recognition Task's
    /// `MainActor.run` completion handler.
    private func recognitionStillActive(_ token: UUID) -> Bool {
        activeRecognitionToken == token
    }

    var writingMode: WritingMode {
        get { freeform.writingMode }
        set { freeform.writingMode = newValue }
    }
    var freeformSubMode: FreeformSubMode {
        get { freeform.freeformSubMode }
        set { freeform.freeformSubMode = newValue }
    }
    var freeformTargetWord: FreeformWord? { freeform.freeformTargetWord }
    var freeformPoints: [CGPoint] { freeform.freeformPoints }
    var freeformStrokeSizes: [Int] { freeform.freeformStrokeSizes }
    var freeformActivePath: [CGPoint] { freeform.freeformActivePath }
    var freeformWordResults: [RecognitionResult] { freeform.freeformWordResults }
    var freeformWordResultSlots: [RecognitionResult?] { freeform.freeformWordResultSlots }
    var freeformRecognitionDelay: TimeInterval {
        get { freeform.freeformRecognitionDelay }
        set { freeform.freeformRecognitionDelay = newValue }
    }
    var isWaitingForRecognition: Bool { freeform.isWaitingForRecognition }
    var isRecognizing: Bool { freeform.isRecognizing }
    var freeformCanvasSize: CGSize { freeform.freeformCanvasSize }
    var hasRecognitionCompleted: Bool { freeform.hasRecognitionCompleted }
    var isRecognitionModelAvailable: Bool? { freeform.isRecognitionModelAvailable }
    /// Form-accuracy score from the last freeform recognition (0–1).
    /// Forwarded from FreeformController.
    var lastFreeformFormScore: CGFloat? { freeform.lastFreeformFormScore }

    /// Serialised canvas overlay scheduler. SchuleWorldView and
    /// TracingCanvasView observe this so no two overlays stack on top of
    /// each other; the canonical post-freeWrite order is
    /// `kpOverlay → recognitionBadge → paperTransfer → celebration`,
    /// driven entirely from this queue (the legacy
    /// `showFreeWriteOverlay` / `showPaperTransfer` booleans were
    /// removed alongside this migration).
    let overlayQueue = OverlayQueueManager()

    // MARK: - Direct phase state

    /// Stroke indices whose start dot has been tapped in the direct phase.
    private(set) var directTappedDots: Set<Int> = []
    /// True while the correct (next expected) dot should pulse to guide after a wrong tap.
    var directPulsingDot: Bool = false
    /// Cancellation handle for the 700 ms timer that clears `directPulsingDot`.
    /// Stored so rapid wrong taps don't accumulate orphaned Tasks (W-28).
    private var directPulsingTask: Task<Void, Never>? = nil
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
    /// Persistent letter-progress store. Private so the VM remains the
    /// only mutator; views consume the read-only `allProgress` /
    /// `progress(for:)` forwarders below (W-5).
    private let progressStore: ProgressStoring

    /// Read-only snapshot of all letter progress. Views bind here instead
    /// of reaching into `progressStore` directly so persistence stays
    /// encapsulated and writes remain VM-mediated.
    var allProgress: [String: LetterProgress] { progressStore.allProgress }

    /// Per-letter progress lookup. Mirrors `ProgressStoring.progress(for:)`.
    func progress(for letter: String) -> LetterProgress {
        progressStore.progress(for: letter)
    }

    /// P7 (ROADMAP_V5): completions that landed today. Drives the
    /// daily-goal pill in `FortschritteWorldView`.
    var completionsToday: Int { progressStore.completionsToday }
    /// P7: parent-configurable daily-completion goal. Persisted in
    /// UserDefaults so a parent can adjust it; default 3 is a low bar
    /// designed to be hit on most weekdays for a 5-year-old.
    var dailyGoal: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: "de.flamingistan.buchstaben.dailyGoal")
            return v > 0 ? v : 3
        }
        set {
            UserDefaults.standard.set(max(1, newValue), forKey: "de.flamingistan.buchstaben.dailyGoal")
        }
    }
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
    /// German speech synthesiser used for child-facing verbal feedback.
    /// Children can't read fluently yet, so every score the dashboard
    /// computes (Klarheit, Form, Tempo, Druck, Rhythmus) goes via TTS
    /// in plain encouraging German rather than visible numbers.
    let speech: SpeechSynthesizing
    /// Owns the freeWrite buffers + session timing + scoring. Lives on
    /// the VM so views can keep reading via the existing forwarders;
    /// extracting it cleared the four-buffer churn out of the VM body.
    private let freeWriteRecorder = FreeWritePhaseRecorder()

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
    /// Wall-clock start of the *current* foreground window for the active
    /// letter. Reset on every `load(letter:)` and on every foreground return
    /// (`appDidBecomeActive`). Cleared on backgrounding so the timer doesn't
    /// keep ticking while the iPad sits idle (D-1: the device only sleeps
    /// after several minutes, so a "4-minute" session would otherwise
    /// silently include the time spent backgrounded).
    private var letterLoadTime: CFTimeInterval?
    /// Accumulated foreground-only practice time across background returns
    /// for the current letter. The reported session duration is
    /// `letterActiveTimeAccumulated + (now − letterLoadTime)`. Resets on
    /// every `load(letter:)`.
    private var letterActiveTimeAccumulated: TimeInterval = 0
    /// Wall-clock `Date` when the current letter was loaded. Used for
    /// T4 (ROADMAP_V5) so the session record can carry wall-clock time
    /// alongside the active-time `durationSeconds`. Distinct from
    /// `letterLoadTime` (CACurrentMediaTime) because we need a stable
    /// timestamp that survives background/foreground cycles.
    private var letterLoadedDate: Date?
    private var isSingleTouchInteractionActive   = false
    private var didCompleteCurrentLetter         = false
    /// Scheduler priority captured at letter selection time (loadRecommendedLetter).
    /// Forwarded to recordPhaseSession so schedulerEffectivenessProxy is non-zero.
    /// C-3: was hardcoded 0, making the Pearson correlation permanently 0.
    private var lastScheduledLetterPriority: Double = 0
    /// W-16: was previously an IUO because `init` needed to capture
    /// `[weak self]` while constructing `PlaybackController`, which under
    /// Swift's two-phase init rules requires every stored property to
    /// have an initial value at the capture site. The fix exposes
    /// `PlaybackController.onIsPlayingChanged` as a mutable `var` so the
    /// controller is constructed with a no-op callback, assigned to
    /// `self.playback`, and the real `[weak self]` callback is wired
    /// AFTER `self` is fully initialised — eliminating the IUO.
    private let playback: PlaybackController
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
        self.enablePhonemeMode      = deps.enablePhonemeMode
        self.letterRecognizer       = deps.letterRecognizer
        self.speech                 = deps.speech
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
        // W-16: build with a no-op callback first so the closure does
        // not capture `self` (which is not yet fully initialised). Once
        // `self.playback` is assigned, every stored `let` is in place
        // and `self` is fully initialised — wire the real `[weak self]`
        // callback at that point. The controller stores
        // `onIsPlayingChanged` as a `var` precisely for this seam.
        let pb = deps.makePlaybackController(deps.audio) { _ in }
        self.playback = pb
        pb.onIsPlayingChanged = { [weak self] in self?.isPlaying = $0 }
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
              let first = activeAudioFiles(for: asset).first else { return }
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
        let files = activeAudioFiles(for: asset)
        guard files.indices.contains(audioIndex) else { return }
        audio.loadAudioFile(named: files[audioIndex], autoplay: true)
    }

    /// P6 (ROADMAP_V5): pick the audio population to play given the
    /// parent's "Lautwert wiedergeben" toggle. When phoneme mode is on
    /// AND the asset ships phoneme recordings, the phoneme set wins.
    /// Otherwise (toggle off, or asset lacks phoneme audio), the
    /// letter-name set is used. This keeps the existing two-finger
    /// swipe variant cycler working — it always cycles within the
    /// active population.
    private func activeAudioFiles(for asset: LetterAsset) -> [String] {
        if enablePhonemeMode, !asset.phonemeAudioFiles.isEmpty {
            return asset.phonemeAudioFiles
        }
        return asset.audioFiles
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
        let files = activeAudioFiles(for: letters[letterIndex])
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
        let files = activeAudioFiles(for: letters[letterIndex])
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
        // Gate on `feedbackIntensity > 0` so freeWrite (which fades all
        // real-time feedback per Schmidt & Lee 2005 Guidance Hypothesis)
        // doesn't fire a stroke-begin haptic. Every other haptic + audio
        // channel already respects this gate; this site was the lone
        // exception (review item W-20 / P-10).
        if feedbackIntensity > 0 { haptics.fire(.strokeBegan) }
        // Reload audio file — stop() in endTouch clears currentFile, so play() would
        // silently fail on subsequent touches without reloading first.
        if letters.indices.contains(letterIndex) {
            let files = activeAudioFiles(for: letters[letterIndex])
            if files.indices.contains(audioIndex) {
                audio.loadAudioFile(named: files[audioIndex], autoplay: false)
            }
        }
    }

    func updateTouch(at p: CGPoint, t: CFTimeInterval, canvasSize: CGSize) {
        guard isSingleTouchInteractionActive      else { return }
        guard let lastPoint                       else { return }

        resyncCanvasSizeIfNeeded(canvasSize)

        let isWithinCanvasBounds =
            p.x >= 0 && p.y >= 0 && p.x <= canvasSize.width && p.y <= canvasSize.height

        let dx       = p.x - lastPoint.x
        let dy       = p.y - lastPoint.y
        let distance = hypot(dx, dy)

        if isWithinCanvasBounds && distance >= minimumTouchMoveDistance {
            activePath.append(p)
            // Accumulate for free-write scoring + KP overlay. The recorder
            // owns the four-buffer state so the VM body doesn't re-derive
            // canvas normalisation per touch.
            if phaseController.currentPhase == .freeWrite {
                freeWriteRecorder.record(point: p,
                                          timestamp: t,
                                          force: pencilPressure ?? 0,
                                          canvasSize: canvasSize)
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

        updateGuidedAndFreeWriteSpeed()

        fireMovementHaptics(prevStrokeIndex: prevStrokeIndex,
                            prevNextCheckpoint: prevNextCheckpoint)

        updateAdaptivePlayback(canvasNormalized: canvasNormalized)

        handleStrokeCompletionIfReached()

        self.lastPoint     = p
        self.lastTimestamp = t
    }

    /// Bring `self.canvasSize` (and the cell layout / checkpoint mapping
    /// that derive from it) back in sync with whatever the touch overlay
    /// is currently reporting. This closes the window where a
    /// rotation/layout update has already fired `canvasSize.didSet` —
    /// reloading checkpoints for the new size — but the touch overlay
    /// coordinator still carries the previous size, causing
    /// normalizedPoint vs. checkpoint coordinate mismatch.
    private func resyncCanvasSizeIfNeeded(_ canvasSize: CGSize) {
        guard canvasSize != self.canvasSize,
              !letters.isEmpty,
              letterIndex < letters.count else { return }
        // Re-flow cell frames with the overlay-reported size BEFORE
        // reloading checkpoints — reload now maps per-cell using each
        // cell's own frame.
        grid.layout(in: canvasSize, schriftArt: schriftArt)
        reloadStrokeCheckpoints(for: letters[letterIndex], usingSize: canvasSize)
    }

    /// Push the live "checkpoints per second" figure into the recorder
    /// while the user is in guided or freeWrite. Stays silent in observe
    /// / direct since those phases have no continuous motion to measure.
    private func updateGuidedAndFreeWriteSpeed() {
        let currentPhase = phaseController.currentPhase
        guard currentPhase == .guided || currentPhase == .freeWrite,
              let def = strokeTracker.definition else { return }
        let completedCPs = def.strokes.enumerated().reduce(0) { acc, item in
            let (idx, stroke) = item
            guard strokeTracker.progress.indices.contains(idx) else { return acc }
            return strokeTracker.progress[idx].complete
                ? acc + stroke.checkpoints.count
                : acc + strokeTracker.progress[idx].nextCheckpoint
        }
        freeWriteRecorder.updateSpeed(completedCheckpoints: completedCPs)
    }

    /// Trigger checkpoint or stroke-completed haptics if the tracker
    /// crossed a boundary on this touch update. Compares the snapshot
    /// taken before `strokeTracker.update(...)` to the post-update state.
    private func fireMovementHaptics(prevStrokeIndex: Int,
                                     prevNextCheckpoint: Int) {
        guard feedbackIntensity > 0 else { return }
        let newStrokeIndex     = strokeTracker.currentStrokeIndex
        let newNextCheckpoint  = strokeTracker.progress.indices.contains(prevStrokeIndex)
            ? strokeTracker.progress[prevStrokeIndex].nextCheckpoint : 0
        guard prevNextCheckpoint != newNextCheckpoint
              || newStrokeIndex != prevStrokeIndex else { return }
        if strokeTracker.progress.indices.contains(prevStrokeIndex)
            && strokeTracker.progress[prevStrokeIndex].complete {
            haptics.fire(.strokeCompleted)
        } else {
            haptics.fire(.checkpointHit)
        }
    }

    /// Map the smoothed velocity + canvas-x to the audio engine's
    /// time-stretch speed and stereo pan, then ask the playback state
    /// machine whether the underlying source should be active or idle.
    private func updateAdaptivePlayback(canvasNormalized: CGPoint) {
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
    }

    /// If the active cell's tracker just completed, advance the grid
    /// cursor to the next cell — or, if the whole sequence is done, kick
    /// off the phase advance. Guards against vacuous completion (empty
    /// stroke definitions, where `isComplete` would be trivially true).
    private func handleStrokeCompletionIfReached() {
        let hasStrokes = (strokeTracker.definition?.strokes.isEmpty == false)
        guard hasStrokes, strokeTracker.isComplete else { return }
        // Snapshot tracker-derived values BEFORE advancing — after the
        // grid moves the cursor, `strokeTracker` aliases the next cell
        // (fresh state, zero progress).
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
            // Stop audio before phase teardown so the child doesn't
            // hear the letter sound bleed into the next phase.
            playback.request(.idle, immediate: true)
            // Route through advanceLearningPhase() so phase transitions
            // always go through one path:
            //   guided     → freeWrite  (phaseController.advance returns true)
            //   guided     → complete   (guidedOnly/control: returns false → celebration)
            //   freeWrite  → complete   (threePhase: returns false → celebration)
            advanceLearningPhase()
        }
    }

    // MARK: - Lifecycle

    public func appDidEnterBackground() async {
        guard playback.appIsForeground else { return }
        playback.appIsForeground = false
        playback.cancelPending()
        endTouch()
        // D-1: stop the session-duration timer so the backgrounded window
        // doesn't get attributed to "active practice". Whatever the child
        // had practised so far is folded into the accumulator and survives
        // the round-trip; the next foreground return restarts the live slice.
        if let start = letterLoadTime {
            letterActiveTimeAccumulated += CACurrentMediaTime() - start
            letterLoadTime = nil
        }
        let cmd = playback.transition(to: .idle)
        playback.apply(cmd)
        if cmd == .none { audio.stop(); isPlaying = false }
        audio.suspendForLifecycle()
        // Halt any in-flight verbal feedback so the synthesised voice
        // doesn't keep talking after the child leaves the app.
        speech.stop()
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
        // D-1: restart the live slice of session-duration tracking so the
        // current foreground window contributes to `duration` again. The
        // pre-background slice is already in `letterActiveTimeAccumulated`.
        if letterLoadTime == nil, !didCompleteCurrentLetter {
            letterLoadTime = CACurrentMediaTime()
        }
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
                freeWriteRecorder.clearAll()
                score = 0
                break
            }
            // Recorder owns scoring — it has the buffers, sessionStart,
            // and canvasSize-normalised points all in one place.
            // C-5: pass the active cell's frame for multi-cell (pencil)
            // layouts so points are normalised to cell-local 0–1 space,
            // matching the reference stroke coordinate system.
            // W-26: word mode (multi-cell) splits the trace by cell so
            // each letter is scored against its own reference, then the
            // four Schreibmotorik dimensions are averaged. The single-
            // cell fall-through preserves the existing finger-mode
            // contract (one tracker definition over the whole canvas).
            if grid.cells.count > 1 {
                let cellRefs = grid.cells.compactMap { cell -> (frame: CGRect, reference: LetterStrokes)? in
                    guard let ref = cell.tracker.definition else { return nil }
                    return (frame: cell.frame, reference: ref)
                }
                if cellRefs.isEmpty {
                    score = freeWriteRecorder.assess(
                        reference: def, canvasSize: canvasSize,
                        cellFrame: grid.activeCell.frame
                    ).overallScore
                } else {
                    score = freeWriteRecorder.assess(
                        cellReferences: cellRefs,
                        canvasSize: canvasSize
                    ).overallScore
                }
            } else {
                score = freeWriteRecorder.assess(
                    reference: def, canvasSize: canvasSize,
                    cellFrame: nil
                ).overallScore
            }
        }

        let wasInFreeWrite = phaseController.currentPhase == .freeWrite
        let wasInGuided = phaseController.currentPhase == .guided

        // Kick the CoreML recognizer off BEFORE the phase advance so it
        // runs in parallel with the Fréchet-based scoring above and the
        // phase-transition side effects below. The result lands on
        // `lastRecognitionResult` when inference finishes; the badge
        // slots into the queue *before* the celebration regardless of
        // how long inference takes — see `enqueueBeforeCelebration`.
        if wasInFreeWrite {
            runRecognizerForFreeWrite()
        }
        if wasInGuided {
            // Capture the guided score before the phase advance so the
            // Schule world can show a verbal feedback band during the
            // transition into freeWrite. Cleared on letter load.
            freeWriteRecorder.lastGuidedScore = score
        }

        // Queue post-freeWrite feedback in canonical order BEFORE we
        // advance the phase controller — `recordPhaseSessionCompletion`
        // (called below for the final phase) enqueues `.celebration`,
        // which we want to come last. The recognition badge enqueue
        // happens asynchronously on the recognizer Task; it slots ahead
        // of the celebration via `enqueueBeforeCelebration`.
        if wasInFreeWrite {
            overlayQueue.enqueue(.kpOverlay)
            if enablePaperTransfer {
                overlayQueue.enqueue(.paperTransfer(letter: currentLetterName))
            }
        }

        if phaseController.advance(score: score) {
            resetForPhaseTransition()
            if phaseController.currentPhase == .observe {
                startGuideAnimation()
            }
            toast(phaseController.currentPhase.displayName)
            // Verbal phase prompt — spoken every transition so a child
            // who can't read the on-screen "Anschauen / Richtung lernen"
            // pill still knows what's happening next.
            speech.speak(ChildSpeechLibrary.phaseEntry(phaseController.currentPhase))
        } else {
            recordPhaseSessionCompletion()
        }
    }

    /// Fire-and-forget recognizer pass for the completed freeWrite phase.
    /// Uses the absolute-canvas-space points already accumulated during
    /// updateTouch so the model sees the same stroke the child drew.
    /// The badge enqueues via `enqueueBeforeCelebration` so it always
    /// lands ahead of the final celebration even when CoreML inference
    /// finishes after the synchronous freeWrite teardown has already
    /// enqueued kpOverlay + paperTransfer + celebration.
    private func runRecognizerForFreeWrite() {
        let pts = freeWritePoints
        let size = canvasSize
        let expected = currentLetterName
        // FreeformController owns the isRecognizing flag — both freeform
        // and freeWrite share the same UI state since only one recognition
        // request is ever in flight at a time.
        freeform.isRecognizing = true
        // Pull the child's prior recognition history for this letter so
        // the calibrator's "practised letter" boost (review item W-21)
        // actually fires. Empty array on first encounter — calibrator
        // skips the boost path until enough samples accumulate.
        let history = (progressStore.progress(for: expected)
                       .recognitionAccuracy ?? [])
                      .map { CGFloat($0) }
        let token = issueRecognitionToken()
        Task { [weak self, letterRecognizer] in
            let result = await letterRecognizer.recognize(
                points: pts, canvasSize: size, expectedLetter: expected,
                historicalFormScores: history)
            guard let self else { return }
            await MainActor.run {
                guard self.recognitionStillActive(token) else { return }
                self.freeform.isRecognizing = false
                self.lastRecognitionResult = result
                // commitCompletion already wrote the guided-mode session
                // record with a nil recognitionResult — by the time the
                // recognizer finishes, the progressStore entry exists but
                // doesn't know about this confidence. Append it now so the
                // dashboard trend reflects actual recognizer readings.
                if let r = result {
                    self.progressStore.recordRecognitionSample(
                        letter: expected, result: r)
                    if r.confidence >= 0.4 {
                        self.overlayQueue.enqueueBeforeCelebration(.recognitionBadge(r))
                        // Verbal mirror of the on-screen badge — same
                        // German wording RecognitionFeedbackView shows,
                        // so a pre-reader hears what they otherwise
                        // could only see. Empty string returns from low-
                        // confidence wrong cases stay silent on purpose.
                        let line = ChildSpeechLibrary.recognition(
                            r, expected: expected)
                        if !line.isEmpty { self.speech.speak(line) }
                    }
                    // P2 (ROADMAP_V5): self-explanation prompt on a
                    // confident-but-wrong recognition. Re-presenting
                    // the canonical reference glyph leverages
                    // Chi 1989's elaborative-processing effect — the
                    // child sees the mismatch and the correct form
                    // back-to-back. Gated on `confidence >= 0.5` so
                    // borderline-noisy predictions don't trigger the
                    // re-animation; gated on `currentLetterName ==
                    // expected` so a fast letter-switch race doesn't
                    // animate the wrong glyph.
                    if !r.isCorrect, r.confidence >= 0.5,
                       self.currentLetterName == expected {
                        self.startGuideAnimation()
                    }
                }
            }
        }
    }

    /// Record the child's paper-transfer self-assessment score and advance
    /// the overlay queue to the next overlay (typically the celebration).
    func submitPaperTransfer(score: Double) {
        progressStore.recordPaperTransferScore(for: currentLetterName, score: score)
        overlayQueue.dismiss()
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
                let files = activeAudioFiles(for: letters[letterIndex])
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
            directPulsingTask?.cancel()
            directPulsingTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(700))
                self.directPulsingDot = false
                self.directPulsingTask = nil
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
        // U6 (ROADMAP_V5): confirmation haptic on the celebration's
        // "Weiter" tap. The rest of the app uses haptics consistently
        // (begin/checkpoint/stroke/letter); this seam was the lone tap
        // that produced no feedback.
        haptics.fire(.letterCompleted)
        let available = visibleLetterNames
        let scored = letterScheduler.prioritized(available: available,
                                                  progress: progressStore.allProgress)
        // C-3: capture priority at selection time so schedulerEffectivenessProxy
        // gets a real non-zero value instead of the hardcoded 0 it was receiving.
        // W-4: reset the overlay queue when no letter is available so the
        // celebration "Weiter" button doesn't leave the child stuck on screen.
        guard let best = scored.first,
              let idx  = letters.firstIndex(where: { $0.name == best.letter }) else {
            overlayQueue.reset()
            return
        }
        lastScheduledLetterPriority = best.priority
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
        activeRecognitionToken = nil
        // Always clear the recorder when a phase transition fires —
        // a stale freeWritePath from a previous freeWrite session must
        // not leak into the next one if the controller lands on a
        // non-freeWrite phase first (e.g. via thesis-condition skips).
        // Then re-arm the timing for the active phase.
        // C-1: clearAll() wipes lastGuidedScore, but advanceLearningPhase() sets
        // it immediately before calling here (guided→freeWrite path). Preserve it
        // so SchuleWorldView's "Nachspuren fertig" feedback card can display.
        let savedGuidedScore = freeWriteRecorder.lastGuidedScore
        freeWriteRecorder.clearAll()
        freeWriteRecorder.lastGuidedScore = savedGuidedScore
        if phaseController.currentPhase == .freeWrite {
            freeWriteRecorder.startSession()
        } else if phaseController.currentPhase == .guided {
            freeWriteRecorder.startGuidedSpeedTracking()
        }
        directTappedDots.removeAll()
        directPulsingTask?.cancel()
        directPulsingTask = nil
        directPulsingDot = false
        directArrowStrokeIndex = nil
        smoothedVelocity = 0
        // W-6: a phase transition can fire mid-stroke (handleStrokeCompletionIfReached
        // is called from updateTouch while a finger is down). If the system interrupts
        // the gesture (incoming call, Control Centre swipe) between that updateTouch
        // and the matching endTouch, isSingleTouchInteractionActive is stranded true
        // and beginTouch's guard rejects all future touches. Reset it here.
        isSingleTouchInteractionActive = false
        playback.resumeIntent = false
        playback.cancelPending()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
    }

    private func recordPhaseSessionCompletion() {
        overlayQueue.enqueue(.celebration(stars: phaseController.starsEarned))
        // Verbal celebration. Stars-tier praise so the child hears
        // approximately how well they did without seeing any percentage.
        speech.speak(ChildSpeechLibrary.praise(starsEarned: phaseController.starsEarned))
        let accuracy = Double(phaseController.overallScore)
        let now = CACurrentMediaTime()
        let liveSlice = letterLoadTime.map { now - $0 } ?? 0
        let duration = letterActiveTimeAccumulated + liveSlice
        let scores: [String: Double] = Dictionary(
            uniqueKeysWithValues: phaseController.phaseScores.map { ($0.key.rawName, Double($0.value)) }
        )
        // D-2: attach the latest recognition reading to the freeWrite row
        // so per-session recognition is recoverable from the CSV. Other
        // phases never produce a freeWrite recognition; pass nil there.
        let freeWriteRecognition: RecognitionSample? = lastRecognitionResult.map { rr in
            RecognitionSample(
                predictedLetter: rr.predictedLetter,
                confidence: Double(rr.confidence),
                isCorrect: rr.isCorrect
            )
        }
        // D-6: capture the input mode in effect for the row so a finger
        // session's pressureControl == 1.0 (no force data) is
        // distinguishable from a low-variance pencil session in the export.
        let device = detector.effectiveKind.rawValue
        for (phase, phaseScore) in scores {
            dashboardStore.recordPhaseSession(
                letter: currentLetterName,
                phase: phase,
                completed: true,
                score: phaseScore,
                schedulerPriority: lastScheduledLetterPriority,
                condition: thesisCondition,
                assessment: phase == "freeWrite" ? lastWritingAssessment : nil,
                recognition: phase == "freeWrite" ? freeWriteRecognition : nil,
                inputDevice: device
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

        let speed: Double? = checkpointsPerSecond > 0 ? Double(checkpointsPerSecond) : nil
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
        let newRewards = streakStore.recordSession(
            date: Date(),
            lettersCompleted: lettersToRecord,
            accuracy: accuracy
        )
        // U1 (ROADMAP_V5): surface freshly-unlocked achievements as a
        // one-time overlay before the celebration the child is already
        // expecting. `enqueueBeforeCelebration` slots each badge ahead
        // of the celebration regardless of where in the queue the
        // celebration currently sits (queued / about to fire / active).
        for event in newRewards {
            overlayQueue.enqueueBeforeCelebration(.rewardCelebration(event))
        }
        // T4: wall-clock duration includes any backgrounded interval and
        // is reconstructed from the load Date stamp; the active-time
        // `duration` parameter excludes it (D-1 accumulator).
        // T7: device tag so the export can split duration by input mode.
        let wallClock = letterLoadedDate.map { Date().timeIntervalSince($0) }
        let device = detector.effectiveKind.rawValue
        dashboardStore.recordSession(letter: dashboardLabel, accuracy: accuracy,
                                      durationSeconds: duration,
                                      wallClockSeconds: wallClock,
                                      date: Date(),
                                      condition: thesisCondition,
                                      inputDevice: device)
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
    /// Achievement events the child has unlocked. Forwarded for the
    /// Fortschritte badge gallery — see HIDDEN_FEATURES_AUDIT C.6:
    /// the data was collected since launch but never surfaced.
    var earnedRewards: Set<RewardEvent> { streakStore.earnedRewards }

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

    /// Test-only deterministic await for the playback debounce window.
    /// Lets integration tests skip the real wall-clock sleep that made
    /// `fastTouch_triggersPlay` flaky on slow CI runners.
    func awaitPlaybackDebounce() async {
        await playback.pendingTransition?.value
    }

    /// Test-only inspection of the D-1 active-time accumulator.
    /// Exposed so the suite can pin the
    /// background-pauses-the-timer / foreground-resumes-it contract
    /// without the integration overhead of a full session-complete
    /// path. nil when a foreground window is currently open.
    var debugLetterLoadTime: CFTimeInterval? { letterLoadTime }
    var debugLetterActiveTimeAccumulated: TimeInterval { letterActiveTimeAccumulated }
    #endif

    // MARK: - Private helpers

    private func load(letter: LetterAsset) {
        phaseController.reset()
        freeWriteRecorder.clearAll()
        showingVariant = false
        variantStrokeCache = nil
        scriptStrokeCache.removeAll(keepingCapacity: true)
        // FreeformController owns lastFreeformFormScore now — clearing the
        // freeform buffers as part of letter load resets it alongside.
        freeform.clearBuffers()
        lastRecognitionResult = nil
        activeRecognitionToken = nil
        overlayQueue.reset()
        directTappedDots.removeAll()
        directPulsingTask?.cancel()
        directPulsingTask = nil
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
        // P3 (ROADMAP_V5): errorless-learning ramp for the first three
        // sessions on a new letter. The MovingAveragePolicy starts at
        // .standard for every letter regardless of whether the child has
        // seen this glyph before; an extra-lenient radius for the first
        // few encounters supports motor-pattern formation without the
        // child experiencing repeated near-miss failure on novel letters
        // (Skinner 1958; Terrace 1963). Falls back to the policy tier
        // from session 4 onward, so adaptation still drives long-term.
        let priorCompletions = progressStore.progress(for: letter.name).completionCount
        if priorCompletions < 3 {
            strokeTracker.radiusMultiplier = max(
                strokeTracker.radiusMultiplier,
                DifficultyTier.easy.radiusMultiplier
            )
        }
        progress                       = 0
        audioIndex                     = 0
        didCompleteCurrentLetter       = false
        letterLoadTime                 = CACurrentMediaTime()
        letterActiveTimeAccumulated    = 0
        letterLoadedDate               = Date()
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
        if phaseController.currentPhase == .freeWrite {
            freeWriteRecorder.startSession()
        } else if phaseController.currentPhase == .guided {
            freeWriteRecorder.startGuidedSpeedTracking()
        }
        if let firstAudio = activeAudioFiles(for: letter).first {
            audio.loadAudioFile(named: firstAudio, autoplay: false)
            playback.request(.idle, immediate: true)
            // Audio plays in response to touches via the playback state machine;
            // no observe-phase auto-play (it would loop silently behind onboarding
            // and start immediately on letter switch without any user action).
        }
        // Speak the initial phase prompt once a fresh letter loads. Phase
        // *transitions* are spoken from `advanceLearningPhase`; this site
        // covers the very first phase a child sees per letter (typically
        // observe, but can be guided when the thesis condition skips
        // observe/direct or when an empty-strokes letter auto-skipped).
        // Empty-strokes letters that vacuously land at .guided also land
        // here, so a child still gets a verbal cue rather than silence.
        speech.speak(ChildSpeechLibrary.phaseEntry(phaseController.currentPhase))
    }

    private func randomAudioVariant() {
        let files = activeAudioFiles(for: letters[letterIndex])
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
        freeform.writingMode = .freeform
        freeform.freeformSubMode = subMode
        clearFreeformCanvas()
        freeform.freeformTargetWord = subMode == .word
            ? FreeformWordList.all.first : nil
        // Halt any in-progress phase audio/animation so freeform is quiet.
        stopGuideAnimation()
        audio.stop()
        playback.forceIdle()
        isPlaying = false
        // Probe the recognizer so the freeform footer can distinguish
        // "still thinking" from "model not available" on first paint.
        // Two-flag idempotency: the value flag (`isRecognitionModelAvailable
        // == nil`) gates *re-probing* once the answer is known, while the
        // in-flight flag (`isProbingModel`) gates a second dispatch during
        // the dispatch→result window — without it, rapid freeform-mode
        // toggles spawn redundant CoreML model loads.
        if freeform.isRecognitionModelAvailable == nil, !freeform.isProbingModel {
            freeform.isProbingModel = true
            Task { [weak self, letterRecognizer] in
                let available = await letterRecognizer.isModelAvailable()
                await MainActor.run {
                    self?.freeform.isRecognitionModelAvailable = available
                    self?.freeform.isProbingModel = false
                }
            }
        }
        toast(subMode == .word ? "Wort schreiben" : "Freies Schreiben")
    }

    /// Return to guided tracing mode. Re-loads the current letter so
    /// phase state and strokes are rebuilt fresh.
    func exitFreeformMode() {
        freeform.writingMode = .guided
        freeform.freeformSubMode = .letter
        freeform.freeformTargetWord = nil
        clearFreeformCanvas()
        if letters.indices.contains(letterIndex) {
            load(letter: letters[letterIndex])
        }
    }

    /// Wipe the freeform drawing buffer without leaving freeform mode.
    /// Used by the "Nochmal" button after a recognition result.
    func clearFreeformCanvas() {
        freeform.clearBuffers()
        lastRecognitionResult = nil
        activeRecognitionToken = nil
    }

    /// Pick the next target word for freeform word mode.
    func selectFreeformWord(_ word: FreeformWord) {
        freeform.freeformTargetWord = word
        freeform.freeformSubMode = .word
        clearFreeformCanvas()
    }

    /// Begin a freeform stroke. Mirrors `beginTouch` but skips all
    /// checkpoint / phase / audio side effects. Cancels any pending
    /// recognition debounce so the recognizer waits for THIS stroke to
    /// finish — critical for multi-stroke letters like A, E, F.
    func beginFreeformTouch(at p: CGPoint) {
        guard writingMode == .freeform else { return }
        freeform.pendingRecognitionTask?.cancel()
        freeform.pendingRecognitionTask = nil
        freeform.isWaitingForRecognition = false
        freeform.freeformActivePath = [p]
    }

    func updateFreeformTouch(at p: CGPoint, canvasSize size: CGSize) {
        guard writingMode == .freeform else { return }
        // Record the freeform canvas dimensions separately — we don't
        // touch `canvasSize` because its didSet rebuilds the guided-mode
        // stroke tracker and fires needless work during a blank-canvas
        // stroke. Recognition uses the size passed into submit.
        freeform.freeformCanvasSize = size
        // Skip microscopic repeats — keeps the buffer from ballooning on
        // a palm rest or a stationary touch.
        if let last = freeform.freeformActivePath.last,
           hypot(p.x - last.x, p.y - last.y) < 1.0 { return }
        freeform.freeformActivePath.append(p)
    }

    /// End a freeform stroke. In letter sub-mode this arms a debounced
    /// recognition call — the child has `freeformRecognitionDelay`
    /// seconds to start the next stroke before the recognizer runs.
    /// Multi-stroke letters (A, E, F, H, K, T, X …) need this window so
    /// they don't get classified after only their first stroke. Word
    /// sub-mode waits for the explicit "Fertig" button regardless.
    func endFreeformTouch() {
        guard writingMode == .freeform else { return }
        if freeform.freeformActivePath.count >= 2 {
            freeform.freeformStrokeSizes.append(freeform.freeformActivePath.count)
            freeform.freeformPoints.append(contentsOf: freeform.freeformActivePath)
        }
        freeform.freeformActivePath.removeAll(keepingCapacity: true)

        if freeform.freeformSubMode == .letter, freeform.freeformPoints.count >= 2 {
            scheduleFreeformLetterRecognition()
        }
    }

    /// Arm a debounced recognition call. Cancels any previously-armed
    /// task first so a rapid stroke sequence only produces ONE
    /// recognition call, fired `freeformRecognitionDelay` seconds after
    /// the most recent pen-lift.
    private func scheduleFreeformLetterRecognition() {
        freeform.pendingRecognitionTask?.cancel()
        freeform.isWaitingForRecognition = true
        let delay = freeform.freeformRecognitionDelay
        freeform.pendingRecognitionTask = Task { [weak self] in
            let nanos = UInt64((delay * 1_000_000_000).rounded())
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled, let self else { return }
            self.freeform.isWaitingForRecognition = false
            self.recognizeFreeformLetter()
        }
    }

    private func recognizeFreeformLetter() {
        let pts = freeform.freeformPoints
        let size = freeform.freeformCanvasSize.width > 0
            ? freeform.freeformCanvasSize : canvasSize
        freeform.isRecognizing = true
        freeform.hasRecognitionCompleted = false
        let token = issueRecognitionToken()
        Task { [weak self, letterRecognizer] in
            let result = await letterRecognizer.recognize(
                points: pts, canvasSize: size, expectedLetter: nil)
            guard let self else { return }
            await MainActor.run {
                guard self.recognitionStillActive(token) else { return }
                self.freeform.isRecognizing = false
                self.freeform.hasRecognitionCompleted = true
                self.lastRecognitionResult = result
                if let result {
                    self.freeform.lastFreeformFormScore = self.freeformFormAccuracy(
                        points: pts, canvasSize: size,
                        predictedLetter: result.predictedLetter)
                    self.recordFreeformCompletion(result: result)
                    // Verbal mirror of the freeform popup's headline so a
                    // child who can't read still hears whether the model
                    // recognised their letter. Empty string returns are
                    // intentional silence (low confidence).
                    // W-30: recognizer was called with expectedLetter: nil,
                    // so result.isCorrect is always false — ChildSpeechLibrary
                    // would never take the positive "Du hast ein X geschrieben!"
                    // branch. In freeform mode the prediction IS the answer
                    // (there is no wrong letter), so synthesise a corrected
                    // result that treats the top prediction as correct.
                    let corrected = RecognitionResult(
                        predictedLetter: result.predictedLetter,
                        confidence: result.confidence,
                        topThree: result.topThree,
                        isCorrect: true)
                    let line = ChildSpeechLibrary.recognition(
                        corrected, expected: result.predictedLetter)
                    if !line.isEmpty { self.speech.speak(line) }
                } else {
                    self.freeform.lastFreeformFormScore = nil
                }
            }
        }
    }

    /// Score how closely the freeform path matches the recognized
    /// letter's reference strokes — using the **currently selected
    /// font's** stroke definition, not the Druckschrift default. A
    /// child practising Schreibschrift draws a curvy A that should be
    /// scored against the cursive reference, and a child practising
    /// Druckschrift the angular one. Returns nil when the letter has
    /// no bundled reference for the active font.
    ///
    /// Delegates the maths to `FreeWriteScorer.formAccuracyShape` —
    /// bounding-box normalisation, per-stroke densification, and
    /// symmetric Hausdorff happen there.
    private func freeformFormAccuracy(points: [CGPoint],
                                      canvasSize: CGSize,
                                      predictedLetter: String) -> CGFloat? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              points.count >= 2,
              let reference = referenceStrokes(forLetterNamed: predictedLetter,
                                               schrift: schriftArt)
        else { return nil }
        return FreeWriteScorer.formAccuracyShape(
            tracedPoints: points,
            reference: reference
        )
    }

    /// Resolve a letter name (e.g. "A", "f", "ß") to the stroke
    /// definition for the given script. Schreibschrift /
    /// Grundschrift / Vereinfachte Ausgangsschrift /
    /// Schulausgangsschrift each ship per-letter `strokes_<id>.json`
    /// in the bundle (loaded via `LetterRepository.loadVariantStrokes`);
    /// Druckschrift uses the primary `LetterAsset.strokes`. Falls back
    /// to Druckschrift if a variant isn't bundled for this letter so
    /// new fonts don't have to ship the full alphabet to be useful.
    private func referenceStrokes(forLetterNamed name: String,
                                   schrift: SchriftArt) -> LetterStrokes? {
        let candidates = [name, name.uppercased(), name.lowercased()]
        if let variantID = schrift.bundleVariantID {
            for candidate in candidates {
                if let variant = repo.loadVariantStrokes(
                    for: candidate, variantID: variantID) {
                    return variant
                }
            }
        }
        // Druckschrift, or variant not bundled for this letter — fall
        // back to the primary strokes.json. Better to score against the
        // print form than to drop the metric entirely.
        for candidate in candidates {
            if let asset = letters.first(where: { $0.name == candidate }) {
                return asset.strokes
            }
        }
        return nil
    }

    /// Submit a finished freeform word. Assigns each completed stroke to
    /// one of `target.word.count` equal-width columns by its x-centroid,
    /// then recognises each column independently. Overlapping handwritten
    /// letter bounding boxes (M bleeds into A) no longer collapse into a
    /// single cluster — each stroke belongs to exactly one bucket even
    /// when the child's writing overlaps. `freeformWordResultSlots` holds
    /// one entry per target letter (nil when the column got no strokes)
    /// so the UI can draw grey placeholder chips for missing letters.
    func submitFreeformWord() {
        guard writingMode == .freeform, freeformSubMode == .word,
              let target = freeform.freeformTargetWord,
              !freeform.freeformPoints.isEmpty else { return }

        let segmentationWidth = freeform.freeformCanvasSize.width > 0
            ? freeform.freeformCanvasSize.width : canvasSize.width
        let targetLetters = Array(target.word)
        let buckets = Self.bucketStrokesByTargetLetter(
            points: freeform.freeformPoints,
            strokeSizes: freeform.freeformStrokeSizes,
            canvasWidth: segmentationWidth,
            letterCount: targetLetters.count
        )
        let size = freeform.freeformCanvasSize.width > 0
            ? freeform.freeformCanvasSize : canvasSize

        freeform.isRecognizing = true
        freeform.hasRecognitionCompleted = false
        // Pre-compute per-letter recognition history on the main actor
        // so the detached Task can look it up without re-entering the
        // VM's isolation. Activates the calibrator boost (review item
        // W-21) for whichever target letters the child has practised.
        let historyByLetter: [String: [CGFloat]] = Dictionary(uniqueKeysWithValues:
            targetLetters.map { ch -> (String, [CGFloat]) in
                let key = String(ch)
                let scores = (progressStore.progress(for: key).recognitionAccuracy ?? [])
                              .map { CGFloat($0) }
                return (key, scores)
            }
        )
        let token = issueRecognitionToken()
        Task { [weak self, letterRecognizer] in
            var slots: [RecognitionResult?] = []
            for i in 0..<targetLetters.count {
                let seg = i < buckets.count ? buckets[i] : []
                guard seg.count >= 2 else { slots.append(nil); continue }
                let expected = String(targetLetters[i])
                let r = await letterRecognizer.recognize(
                    points: seg, canvasSize: size, expectedLetter: expected,
                    historicalFormScores: historyByLetter[expected] ?? [])
                slots.append(r)
            }
            guard let self else { return }
            await MainActor.run {
                guard self.recognitionStillActive(token) else { return }
                self.freeform.isRecognizing = false
                self.freeform.hasRecognitionCompleted = true
                let present = slots.compactMap { $0 }
                self.freeform.freeformWordResultSlots = slots
                self.freeform.freeformWordResults = present
                if let last = present.last {
                    self.lastRecognitionResult = last
                }
                self.recordFreeformWordCompletion(
                    target: target, results: present)
            }
        }
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

    /// Assign every stroke to one of `letterCount` equal-width columns
    /// by the x-coordinate of its centroid. Works even when the child's
    /// handwriting overlaps horizontally — each stroke is a unit and
    /// ends up in exactly one bucket regardless of what the other
    /// strokes do. Returns an array of length `letterCount`; empty
    /// buckets stay empty (caller pads those as missing letters in the
    /// UI). Strokes whose centroid falls outside the canvas clamp to
    /// the nearest bucket rather than being dropped, so a child who
    /// started writing a bit to the right of the visual guides still
    /// gets their strokes accounted for.
    static func bucketStrokesByTargetLetter(
        points: [CGPoint],
        strokeSizes: [Int],
        canvasWidth: CGFloat,
        letterCount: Int
    ) -> [[CGPoint]] {
        guard letterCount > 0, canvasWidth > 0, !strokeSizes.isEmpty else {
            return Array(repeating: [], count: max(letterCount, 0))
        }
        let bucketWidth = canvasWidth / CGFloat(letterCount)
        var buckets: [[CGPoint]] = Array(repeating: [], count: letterCount)
        var cursor = 0
        for strokeLen in strokeSizes {
            let endIdx = min(cursor + strokeLen, points.count)
            guard endIdx > cursor else { cursor = endIdx; continue }
            let strokePoints = Array(points[cursor..<endIdx])
            cursor = endIdx
            let sumX = strokePoints.reduce(0.0) { $0 + $1.x }
            let centroidX = sumX / CGFloat(strokePoints.count)
            let raw = Int((centroidX / bucketWidth).rounded(.down))
            let idx = min(letterCount - 1, max(0, raw))
            buckets[idx].append(contentsOf: strokePoints)
        }
        return buckets
    }
}
