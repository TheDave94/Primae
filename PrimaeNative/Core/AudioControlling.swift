import Foundation

@MainActor
protocol AudioControlling: AnyObject {
    func loadAudioFile(named fileName: String, autoplay: Bool)
    func setAdaptivePlayback(speed: Float, horizontalBias: Float)
    /// Spatial-arm pitch drive (pen Y → carrier pitch, in cents relative
    /// to the carrier's authored frequency). Called on the per-tick
    /// coupling path ONLY for `PilotAudioCondition.spatial`; the phoneme
    /// and silent arms never invoke it, so their pitch stays at the
    /// engine default (0 cents). Default implementation is a no-op —
    /// only pitch-capable engines opt in (see AudioEngine+SpatialPitch).
    func setSpatialPitch(cents: Float)
    func play()
    /// Play with a short linear fade-IN, so a demonstration does not start
    /// at full volume (2026-10-02, proctor's device run: "not stop too
    /// abruptly" — the fade-OUT half already existed as `fadeOutSeconds`,
    /// but `play()` restored `player.volume` to full in one step, so every
    /// sound began with a click).
    ///
    /// Default implementation calls `play()` unchanged, so every stub and
    /// test double keeps its current behaviour without opting in.
    func play(fadeInSeconds: TimeInterval)
    func stop()
    func restart()
    func suspendForLifecycle()
    func resumeAfterLifecycle()
    func cancelPendingLifecycleWork()

    // MARK: - Test-only measurement hooks
    //
    // DECLARED AS REQUIREMENTS HERE, NOT EXTENSION-ONLY, and that is
    // load-bearing rather than stylistic. MEASURED 2026-10-02: declared
    // only in the extension below, a probe call on an
    // `AudioControlling`-typed value was statically dispatched to the
    // no-op default, so `AudioEngine`'s real implementation was NEVER
    // reached. The probe compiled, `strings` found it in the shipped
    // framework, and it still wrote nothing on any device run. A silent
    // default then reads as "the code is fine, the audio is quiet" -
    // exactly the conclusion this instrument exists to disprove.
    //
    // Same trap `setSpatialPitch`'s comment below already records; these
    // four repeated it. An extension member is dispatched statically, so a
    // conformer's own implementation is invisible through the existential.
    //
    // Defaults stay in the extension so no test double has to change.
    func emitAudioSignalSummary(label: String)
    /// `label` is a CLOSURE so the phase is read on every tick, not frozen
    /// at the moment the ticker starts.
    ///
    /// MEASURED (2026-10-02): passing a `String` froze the label, so after a
    /// phase transition every window still reported the FIRST phase. A
    /// freeWrite window was logged as `observe`, which made a per-phase
    /// assertion impossible and would have mislabelled the export. The
    /// phase changes underneath a running ticker — that is the whole
    /// reason the ticker exists.
    func startAudioSignalTicker(intervalSeconds: TimeInterval, label: @escaping @MainActor () -> String)
    func stopAudioSignalTicker()
    /// Latest measured `AUDIO-SIGNAL` line; nil before the first window.
    var latestAudioSignalSummary: String? { get }

    /// Non-nil when audio failed to initialise; the VM surfaces this as
    /// a startup toast so silent failure is visible. No protocol default
    /// is provided so conformers must spell out their state explicitly.
    var initializationError: String? { get }
}

extension AudioControlling {
    /// No-op default so non-pitch conformers (test doubles, previews)
    /// satisfy the requirement without change. Declared as a protocol
    /// REQUIREMENT above (not extension-only) so conformers that do
    /// implement it — AudioEngine — are reached via dynamic dispatch.
    func setSpatialPitch(cents: Float) {}

    /// Default fade-IN: just play. Every conformer except AudioEngine
    /// (the only one with a volume ramp to drive) gets this, so adding the
    /// fade did not force a change on a single test double.
    func play(fadeInSeconds: TimeInterval) { play() }

    /// TEST-ONLY: report measured output level for the window just ended,
    /// tagged with `label` (the phase). Default no-op so nothing but the
    /// real engine carries it. This exists because "was there sound" must
    /// be answered by SAMPLES, not by whether `play()` was called.
    func emitAudioSignalSummary(label: String) {}

    /// TEST-ONLY: start emitting a measured summary every `intervalSeconds`
    /// until told to stop.
    ///
    /// Added after MEASURED silence on the device: the transition-only
    /// emission never fired during a 16-second observe phase, because a
    /// phase that does not END has no boundary to report at. The proctor's
    /// complaint was about audio DURING a phase, so the instrument has to
    /// report during one. A ticker also yields a time series rather than
    /// one number per boundary, which is what makes "it went quiet halfway
    /// through" visible.
    ///
    /// `label` is a plain String rather than an autoclosure: it is captured
    /// by the timer, and a non-escaping autoclosure cannot cross into it.
    ///
    /// Extension default: a no-op, so no test double is forced to change.
    func startAudioSignalTicker(intervalSeconds: TimeInterval,
                                label: @escaping @MainActor () -> String) {}
    func stopAudioSignalTicker() {}

    /// Latest measured `AUDIO-SIGNAL` line; nil before the first window.
    var latestAudioSignalSummary: String? { nil }
}
