import Foundation

/// All injectable dependencies for TracingViewModel, bundled into one struct.
/// Use `.live` for production, or construct a custom instance in tests.
@MainActor
struct TracingDependencies {
    var singleTouchCooldownAfterNavigation: CFTimeInterval
    var activeDebounceSeconds: TimeInterval
    var idleDebounceSeconds: TimeInterval
    var audio: AudioControlling
    var progressStore: ProgressStoring
    var haptics: HapticEngineProviding
    var adaptationPolicy: (any AdaptationPolicy)?
    var repo: LetterRepository

    // Explicit @MainActor init allows @MainActor default values (AudioEngine etc.)
    init(
        singleTouchCooldownAfterNavigation: CFTimeInterval = 0.18,
        activeDebounceSeconds: TimeInterval = 0.03,
        idleDebounceSeconds: TimeInterval = 0.12,
        audio: AudioControlling = AudioEngine(),
        progressStore: ProgressStoring = JSONProgressStore(),
        haptics: HapticEngineProviding = CoreHapticsEngine(),
        adaptationPolicy: (any AdaptationPolicy)? = nil,
        repo: LetterRepository = LetterRepository()
    ) {
        self.singleTouchCooldownAfterNavigation = singleTouchCooldownAfterNavigation
        self.activeDebounceSeconds = activeDebounceSeconds
        self.idleDebounceSeconds = idleDebounceSeconds
        self.audio = audio
        self.progressStore = progressStore
        self.haptics = haptics
        self.adaptationPolicy = adaptationPolicy
        self.repo = repo
    }

    /// The default production configuration.
    static let live = TracingDependencies()
}
