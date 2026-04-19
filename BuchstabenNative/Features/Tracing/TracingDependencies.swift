import Foundation

/// All injectable dependencies for TracingViewModel, bundled into one struct.
/// Use `.live` for production, or construct a custom instance in tests.
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
        }()
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
    }

    /// The default production configuration.
    static let live = TracingDependencies()
}
