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
    /// Non-nil when audio failed to initialise; the VM surfaces this as
    /// a startup toast so silent failure is visible. No protocol default
    /// is provided so conformers must spell out their state explicitly.
    var initializationError: String? { get }
}
