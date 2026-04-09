import Foundation

/// All injectable dependencies for TracingViewModel, bundled into one struct.
/// Use `.live` for production, or construct a custom instance in tests.
@MainActor
struct TracingDependencies {
    var singleTouchCooldownAfterNavigation: CFTimeInterval
    var audio: AudioControlling
    var progressStore: ProgressStoring
    var haptics: HapticEngineProviding
    var adaptationPolicy: (any AdaptationPolicy)?
    var repo: LetterRepository
    var streakStore: StreakStoring

    // Explicit @MainActor init allows @MainActor default values (AudioEngine etc.)
    init(
        singleTouchCooldownAfterNavigation: CFTimeInterval = 0.18,
        audio: AudioControlling = AudioEngine(),
        progressStore: ProgressStoring = JSONProgressStore(),
        haptics: HapticEngineProviding = CoreHapticsEngine(),
        adaptationPolicy: (any AdaptationPolicy)? = nil,
        repo: LetterRepository = LetterRepository(),
        streakStore: StreakStoring = JSONStreakStore()
    ) {
        self.singleTouchCooldownAfterNavigation = singleTouchCooldownAfterNavigation
        self.audio = audio
        self.progressStore = progressStore
        self.haptics = haptics
        self.adaptationPolicy = adaptationPolicy
        self.repo = repo
        self.streakStore = streakStore
    }

    /// The default production configuration.
    static let live = TracingDependencies()
}
