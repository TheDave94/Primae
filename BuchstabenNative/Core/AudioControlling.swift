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
    /// Non-nil when audio failed to initialise (engine.start error, audio
    /// session category misconfiguration, etc.). The VM surfaces this as a
    /// short German toast at startup so a parent notices "audio unavailable"
    /// instead of silent failure. nil under normal operation. Default no-op
    /// for in-memory mocks.
    var initializationError: String? { get }
}

// Previously a default implementation returned `nil` here so any
// conformer (production or mock) that omitted the property silently
// reported "no error". Review item W-14 removed that default — every
// conformer now spells out its initialisation contract. Production's
// `AudioEngine` returns the real error from `engine.start()`; test
// stubs declare `nil` explicitly to opt in to the "always healthy"
// behaviour the default used to silently grant.

