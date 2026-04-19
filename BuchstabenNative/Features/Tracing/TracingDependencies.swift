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
    var adaptationPolicy: (any AdaptationPolicy)?
    var repo: LetterRepository
    var streakStore: StreakStoring
    var dashboardStore: ParentDashboardStoring
    var onboardingStore: OnboardingStoring
    var notificationScheduler: LocalNotificationScheduler
    var syncCoordinator: SyncCoordinator
    var thesisCondition: ThesisCondition
    var schriftArt: SchriftArt

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
        thesisCondition: ThesisCondition = ThesisCondition.assign(
            participantId: ParticipantStore.participantId
        ),
        schriftArt: SchriftArt = {
            if let raw = UserDefaults.standard.string(forKey: "de.flamingistan.buchstaben.selectedSchriftArt")
                ?? UserDefaults.standard.string(forKey: "selectedSchriftArt"),
               let art = SchriftArt(rawValue: raw) {
                return art
            }
            return .druckschrift
        }(),
        makePlaybackController: @escaping (AudioControlling, @escaping (Bool) -> Void) -> PlaybackController = {
            PlaybackController(audio: $0, onIsPlayingChanged: $1)
        },
        makeMessagePresenter: @escaping () -> TransientMessagePresenter = { TransientMessagePresenter() },
        makeAnimationGuide:   @escaping () -> AnimationGuideController   = { AnimationGuideController() },
        makeCalibrationStore: @escaping () -> CalibrationStore           = { CalibrationStore() },
        makeLetterScheduler:  @escaping () -> LetterScheduler            = { LetterScheduler() }
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
        self.makePlaybackController = makePlaybackController
        self.makeMessagePresenter   = makeMessagePresenter
        self.makeAnimationGuide     = makeAnimationGuide
        self.makeCalibrationStore   = makeCalibrationStore
        self.makeLetterScheduler    = makeLetterScheduler
    }

    /// The default production configuration.
    static let live = TracingDependencies()
}
