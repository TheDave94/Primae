import Foundation

/// All injectable dependencies for TracingViewModel, bundled into one struct.
/// Use `.live` for production, or construct a custom instance in tests.
///
/// The four ex-private controllers (PlaybackController, TransientMessagePresenter,
/// AnimationGuideController, CalibrationStore) are exposed as factories so each
/// VM instance gets its own fresh controller rather than sharing stateful
/// singletons across tests, while still letting test code swap in test-friendly
/// configurations (instant sleepers, shorter debounce timings, etc.).
@MainActor
struct TracingDependencies {
    var audio: AudioControlling
    var progressStore: ProgressStoring
    var haptics: HapticEngineProviding
    /// Difficulty adaptation policy. `nil` lets the VM pick a default
    /// based on `thesisCondition`: `.control` gets a `FixedAdaptationPolicy`
    /// (no live adaptation, so the difficulty manipulation can't confound
    /// the phase-progression IV), and the other arms get a
    /// `MovingAverageAdaptationPolicy`. Tests inject explicit policies
    /// to pin behaviour (review item I-2).
    var adaptationPolicy: (any AdaptationPolicy)?
    var repo: LetterRepository
    var streakStore: StreakStoring
    var dashboardStore: ParentDashboardStoring
    var onboardingStore: OnboardingStoring
    var notificationScheduler: LocalNotificationScheduler
    var syncCoordinator: SyncCoordinator
    var thesisCondition: ThesisCondition
    var schriftArt: SchriftArt
    var letterOrdering: LetterOrderingStrategy
    var enablePaperTransfer: Bool
    /// Whether the parent has enabled the freeform writing mode (default: on).
    /// Controls the visibility of the "Freies Schreiben" entry in the picker bar.
    var enableFreeformMode: Bool
    /// P6 (ROADMAP_V5): play the *phoneme* (sound the letter makes)
    /// instead of the letter *name* when the parent enables it. Default
    /// off; falls back to name audio for letters without phoneme
    /// recordings even when on.
    var enablePhonemeMode: Bool
    /// P1 (ROADMAP): opt-in spaced-retrieval recognition prompt before
    /// every Nth letter selection. Default off — research feature.
    var enableRetrievalPrompts: Bool
    /// CoreML-backed letter recognizer. Default is `CoreMLLetterRecognizer()`;
    /// tests inject `StubLetterRecognizer(result:)` to get deterministic output.
    var letterRecognizer: LetterRecognizerProtocol
    /// German speech-synthesiser used for child-facing verbal feedback
    /// (phase entries, recognition results, celebrations). Default is the
    /// AVSpeechSynthesizer-backed live implementation; tests inject
    /// `NullSpeechSynthesizer()` so utterances never drive real audio.
    var speech: SpeechSynthesizing

    /// Factory for the per-VM playback controller. Receives the audio engine
    /// (so tests can swap a recording stub in via `audio:`) and the
    /// `isPlaying`-changed callback the VM closes over with `[weak self]`.
    /// Override to inject controllers with test-friendly debounce timings or
    /// instant `Sleeper` schedulers. The callback type matches
    /// `PlaybackController.init` exactly — no `@MainActor` annotation —
    /// because the controller calls it from its own `@MainActor` context.
    var makePlaybackController: (AudioControlling, @escaping (Bool) -> Void) -> PlaybackController

    /// Factory for the per-VM transient message presenter. Override with
    /// `{ TransientMessagePresenter(sleep: { _ in }) }` in tests that need
    /// the auto-clear timers to fire deterministically.
    var makeMessagePresenter: () -> TransientMessagePresenter

    /// Factory for the per-VM animation guide controller. Each VM gets its
    /// own so animation Tasks from one test don't leak into the next.
    var makeAnimationGuide: () -> AnimationGuideController

    /// Factory for the per-VM calibration store. Tests that exercise the
    /// calibration overlay can inject a store backed by an in-memory file
    /// or a fake URL so disk I/O is contained.
    var makeCalibrationStore: () -> CalibrationStore

    /// Factory for the per-VM letter scheduler (Ebbinghaus-style spaced
    /// repetition). Tests that exercise specific recommendation outcomes
    /// can inject a scheduler with custom weights or a fixed-letter stub.
    /// Closing the last hidden-singleton hole flagged by the architecture
    /// audit (TracingViewModel previously read LetterScheduler.standard
    /// directly, bypassing this container).
    var makeLetterScheduler: () -> LetterScheduler

    init(
        audio: AudioControlling = AudioEngine(),
        progressStore: ProgressStoring = JSONProgressStore(),
        haptics: HapticEngineProviding = CoreHapticsEngine(),
        adaptationPolicy: (any AdaptationPolicy)? = nil,
        repo: LetterRepository = LetterRepository(),
        streakStore: StreakStoring = JSONStreakStore(),
        dashboardStore: ParentDashboardStoring = JSONParentDashboardStore(),
        onboardingStore: OnboardingStoring = JSONOnboardingStore(),
        notificationScheduler: LocalNotificationScheduler = LocalNotificationScheduler(),
        syncCoordinator: SyncCoordinator? = nil,
        // Pin to `.threePhase` (the full four-phase pedagogical flow) unless the
        // install has explicitly opted into the thesis A/B study via the
        // "Studienteilnahme" toggle in Settings. Without this gate every non-
        // enrolled user had a 2-in-3 chance of being randomly dropped into
        // `.guidedOnly` / `.control`, silently skipping Anschauen + Richtung
        // lernen on every letter. The gate lives on ThesisCondition itself so
        // it's testable without instantiating the full live dependency graph.
        thesisCondition: ThesisCondition = .defaultForInstall,
        schriftArt: SchriftArt = {
            if let raw = UserDefaults.standard.string(forKey: "de.flamingistan.buchstaben.selectedSchriftArt")
                ?? UserDefaults.standard.string(forKey: "selectedSchriftArt") {
                if let art = SchriftArt(rawValue: raw) { return art }
                // Migration: the .schulschrift1995 case was renamed to
                // .schreibschrift when we replaced the Pesendorfer OTF
                // (official Austrian Schulschrift 1995) with the generic
                // Playwrite AT cursive. Map persisted selections forward so
                // existing installs don't silently revert to Druckschrift.
                if raw == "schulschrift1995" { return .schreibschrift }
            }
            return .druckschrift
        }(),
        letterOrdering: LetterOrderingStrategy = {
            if let raw = UserDefaults.standard.string(forKey: "de.flamingistan.buchstaben.letterOrdering"),
               let strategy = LetterOrderingStrategy(rawValue: raw) {
                return strategy
            }
            return .motorSimilarity
        }(),
        enablePaperTransfer: Bool = UserDefaults.standard.bool(
            forKey: "de.flamingistan.buchstaben.enablePaperTransfer"
        ),
        enableFreeformMode: Bool = {
            // Default-on: if the key has never been set, object(forKey:) returns
            // nil and we treat that as "freeform enabled". Parents can opt out
            // via Settings; the stored Bool then becomes authoritative.
            let key = "de.flamingistan.buchstaben.enableFreeformMode"
            if UserDefaults.standard.object(forKey: key) == nil { return true }
            return UserDefaults.standard.bool(forKey: key)
        }(),
        enablePhonemeMode: Bool = UserDefaults.standard.bool(
            forKey: "de.flamingistan.buchstaben.enablePhonemeMode"
        ),
        enableRetrievalPrompts: Bool = UserDefaults.standard.bool(
            forKey: "de.flamingistan.buchstaben.enableRetrievalPrompts"
        ),
        letterRecognizer: LetterRecognizerProtocol = CoreMLLetterRecognizer(),
        speech: SpeechSynthesizing = AVSpeechSpeechSynthesizer(),
        makePlaybackController: @escaping (AudioControlling, @escaping (Bool) -> Void) -> PlaybackController = {
            PlaybackController(audio: $0, onIsPlayingChanged: $1)
        },
        makeMessagePresenter: @escaping () -> TransientMessagePresenter = { TransientMessagePresenter() },
        makeAnimationGuide:   @escaping () -> AnimationGuideController   = { AnimationGuideController() },
        makeCalibrationStore: @escaping () -> CalibrationStore           = { CalibrationStore() },
        makeLetterScheduler:  (() -> LetterScheduler)?                   = nil
    ) {
        self.audio = audio
        self.progressStore = progressStore
        self.haptics = haptics
        self.adaptationPolicy = adaptationPolicy
        self.repo = repo
        self.streakStore = streakStore
        self.dashboardStore = dashboardStore
        self.onboardingStore = onboardingStore
        self.notificationScheduler = notificationScheduler
        // Default: NullSyncService (no-op) until real CloudKit is configured.
        // Swap in a real CloudKitSyncService here when ready.
        if let coordinator = syncCoordinator {
            self.syncCoordinator = coordinator
        } else {
            self.syncCoordinator = SyncCoordinator(
                sync: NullSyncService(),
                progressStore: progressStore,
                streakStore: streakStore
            )
        }
        self.thesisCondition = thesisCondition
        self.schriftArt = schriftArt
        self.letterOrdering = letterOrdering
        self.enablePaperTransfer = enablePaperTransfer
        self.enableFreeformMode = enableFreeformMode
        self.enablePhonemeMode = enablePhonemeMode
        self.enableRetrievalPrompts = enableRetrievalPrompts
        self.letterRecognizer = letterRecognizer
        self.speech = speech
        self.makePlaybackController = makePlaybackController
        self.makeMessagePresenter   = makeMessagePresenter
        self.makeAnimationGuide     = makeAnimationGuide
        self.makeCalibrationStore   = makeCalibrationStore
        // Default scheduler is condition-aware: `.control` gets a
        // fixed-order scheduler so the scheduling effect doesn't
        // confound the phase-progression manipulation (review item
        // W-23). Other conditions get the full Ebbinghaus-weighted
        // scheduler. Tests can still pass an explicit factory.
        if let factory = makeLetterScheduler {
            self.makeLetterScheduler = factory
        } else {
            let condition = thesisCondition
            self.makeLetterScheduler = {
                condition == .control
                    ? LetterScheduler.fixedOrder()
                    : LetterScheduler()
            }
        }
    }

    /// The default production configuration.
    ///
    /// Initialisation contract (review item W-6): this `static let`
    /// reads `UserDefaults` and `ParticipantStore` exactly **once**,
    /// when first accessed (typically at app launch from
    /// `BuchstabenNativeApp.init`). Subsequent settings changes — e.g.
    /// the parent toggling `Schriftart` in `SettingsView` — bypass this
    /// snapshot and write directly to `vm.schriftArt` /
    /// `vm.letterOrdering` on the running VM, so the effective state
    /// stays current without rebuilding the dependency graph. Don't
    /// re-read `live` mid-session expecting fresh `UserDefaults` — it
    /// won't reflect post-launch toggles.
    static let live = TracingDependencies()
}
