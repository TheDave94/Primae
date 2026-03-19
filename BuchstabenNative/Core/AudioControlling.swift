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
}

/// A no-op AudioControlling used when the real AVAudioEngine must not be
/// initialised (e.g. headless test runner host process).
public final class NullAudio: AudioControlling {
    public init() {}
    public func loadAudioFile(named: String, autoplay: Bool) {}
    public func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    public func play() {}
    public func stop() {}
    public func restart() {}
    public func suspendForLifecycle() {}
    public func resumeAfterLifecycle() {}
    public func cancelPendingLifecycleWork() {}
}
