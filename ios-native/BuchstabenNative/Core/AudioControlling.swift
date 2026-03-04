import Foundation

protocol AudioControlling: AnyObject {
    func loadAudioFile(named fileName: String, autoplay: Bool)
    func setAdaptivePlayback(speed: Float, horizontalBias: Float)
    func play()
    func stop()
    func restart()
    func suspendForLifecycle()
    func resumeAfterLifecycle()
    func cancelPendingLifecycleWork()
}
