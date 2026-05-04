import Foundation

@MainActor
protocol AudioControlling: AnyObject {
    func loadAudioFile(named fileName: String, autoplay: Bool)
    func setAdaptivePlayback(speed: Float, horizontalBias: Float)
    func play()
    func stop()
    func restart()
    func suspendForLifecycle()
    func resumeAfterLifecycle()
    func cancelPendingLifecycleWork()
    /// Non-nil when audio failed to initialise (engine.start error,
    /// audio session category misconfiguration, etc.). The VM surfaces
    /// this as a short German toast at startup so a parent notices
    /// "audio unavailable" instead of silent failure. nil under normal
    /// operation. Every conformer must spell out its initialisation
    /// contract — there is no protocol-level default, so a mock that
    /// omits the property is a compile error rather than a silent
    /// "always healthy" claim.
    var initializationError: String? { get }
}
