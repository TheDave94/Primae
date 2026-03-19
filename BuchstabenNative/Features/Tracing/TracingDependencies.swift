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

    /// The default production configuration.
    static let live = TracingDependencies(
        singleTouchCooldownAfterNavigation: 0.18,
        audio: AudioEngine(),
        progressStore: JSONProgressStore(),
        haptics: CoreHapticsEngine(),
        adaptationPolicy: nil,
        repo: LetterRepository()
    )
}
