import Foundation

/// All injectable dependencies for TracingViewModel, bundled into one struct.
/// Use `.live` for production, or construct a custom instance in tests.
struct TracingDependencies {
    var singleTouchCooldownAfterNavigation: CFTimeInterval = 0.18
    var audio: AudioControlling = AudioEngine()
    var progressStore: ProgressStoring = JSONProgressStore()
    var haptics: HapticEngineProviding = CoreHapticsEngine()
    var adaptationPolicy: (any AdaptationPolicy)? = nil
    var repo: LetterRepository = LetterRepository()

    /// The default production configuration.
    static let live = TracingDependencies()
}

