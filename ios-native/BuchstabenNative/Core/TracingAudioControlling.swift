import Foundation

protocol TracingAudioControlling: AnyObject {
    func loadAudioFile(named fileName: String, autoplay: Bool)
    func setAdaptivePlayback(speed: Float, horizontalBias: Float)
    func play()
    func stop()
    func suspendForLifecycle()
    func resumeAfterLifecycle()
}
