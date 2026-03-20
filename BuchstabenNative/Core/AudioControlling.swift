import Foundation

@MainActor
public protocol AudioControlling: AnyObject {
    func loadAudioFile(named fileName: String, autoplay: Bool)
    func setAdaptivePlayback(speed: Float, horizontalBias: Float)
    func play()
    func stop()
    func restart()
    func suspendForLifecycle()
    func resumeAfterLifecycle()
    func cancelPendingLifecycleWork()
}

/// No-op AudioControlling for use when AVAudioEngine must not be initialised
/// (e.g. in the XCTest host app process on headless simulators).
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
