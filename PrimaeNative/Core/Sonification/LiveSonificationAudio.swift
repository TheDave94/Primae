// LiveSonificationAudio.swift
// PrimaeNative
//
// THE ARM SOUND, protocol r17 (2026-11-03; RULINGS L1-L4, the bake-off
// winner, BRIEF-r17-integration). An `AudioControlling` conformer beside
// `AudioEngine`: every arm-sound call the view model, its playback
// controller, the coupling and the demonstrations make (load, play, stop,
// rate, pan, pitch, lifecycle) lands here and drives the live grain engine
// (`LiveSonificationKernel` in an `AVAudioSourceNode`) instead of the r16
// player -> `AVAudioUnitTimePitch` chain.
//
// WHAT STAYS WITH `AudioEngine` (the "host"): the audio session (category,
// activation at launch), the `AVAudioEngine` itself and its main mixer, the
// output route, the measurement tap (`AudioSignalProbe`, on the main mixer, so
// it measures this node too), the init error toast, and the engine pause
// after a background or an interruption. The host's own player is never
// started any more. `AudioEngine.swift` changed by graph wiring only:
// `attachLiveSonificationNode` attaches and connects this node.
//
// WHAT IS RE-DERIVED HERE, mirroring `AudioEngine` flag for flag
// (`shouldResumePlayback`, `appIsForeground`, `interrupted`,
// `interruptionShouldResume`, `interruptionResumeGateRequired`,
// `isFadingOut`) so the r16 semantics hold: a stop fades over
// `fadeOutSeconds` and then discards the loaded sound (a `play()` without a
// load is a no-op, as before); an interruption keeps the loaded sound and the
// resume intent (C2: none when a stop was already fading); `.ended` with
// `.shouldResume` resumes; a lost output (headphones unplugged) stops; a
// background closes the gate and a return re-opens it when it was playing.
// The session-level rules (r16 B1: unplug = interruption; no arm sound while
// a session is blocked or suspended) live in the view model and reach this
// type as `stop()` / `suspendForLifecycle()`, exactly as they reached the
// r16 engine.
//
// DELIBERATE DIFFERENCES from r16 (listed in R17.md):
//   - Every gate-open restarts the sound at its attack; while something
//     still sounds, the new voice crosses over from the old one (equal power,
//     `LiveSonificationKernel.crossfadeSeconds`; LOOPX), not a cut
//     (r16 restarted too, through `player.stop()`, with a hard cut).
//   - A return from the background restarts at the attack (r16 resumed the
//     paused player mid-file).
//   - A route change while the voice is ALREADY sounding does not restart it
//     (r16's `attemptResumePlayback` re-scheduled the file from frame 0).
//   - A reload of the file already loaded does not stop the sound (r16's
//     `loadAudioFile` began with a hard `player.stop()`), and a load cancels
//     a pending stop's bookkeeping, so the fade can no longer discard the file
//     just loaded (the race `PlaybackController.reloadBeforePlay` existed for).
//   - No per-play asynchronous `setActive(true)`: it was a redundant
//     re-activation of an already active session (AudioEngine's own comment).

import AVFoundation
import Foundation
import OSLog

/// The engine-control seam (production: the source node's `AVAudioEngine`;
/// tests: a fake). Lets the state machine be tested on the simulator, where
/// `AVAudioEngine` cannot run.
@MainActor
protocol LiveSonificationOutput: AnyObject {
    var isRunning: Bool { get }
    /// Start the engine if it is not running (session check, synchronous
    /// activation, `start()`), as `AudioEngine.startIfNeeded` does.
    func startIfNeeded()
    /// Constant-power pan of the mono node in the main mixer (the r16 player's pan).
    func setPan(_ pan: Float)
}

@MainActor
final class LiveSonificationAudio: AudioControlling {

    // MARK: Dependencies

    /// The r16 engine: session, mixer, probe tap, lifecycle engine pause.
    private let host: AudioControlling?
    private let output: LiveSonificationOutput
    let kernel: LiveSonificationKernel
    /// Resolves a file name to a decoded source (production: bundle + decode +
    /// loudness gain; tests: synthetic sources).
    private let resolve: (String) -> SonificationSource?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
                             category: "LiveSonification")

    // MARK: Tunables (as `AudioEngine`)

    var fadeOutSeconds: TimeInterval
    var minPlaybackRate: Float = 0.5
    var maxPlaybackRate: Float = 2.0

    // MARK: State (mirrors AudioEngine)

    private var slots: [String: UInt32] = [:]
    /// Pairs built by the launch prewarm and not yet registered.
    let prewarmed = PrewarmedRenderers()
    /// Renderer pairs this instance had to build on the main actor (a load that beat the prewarm).
    private(set) var mainActorBuilds = 0
    private var sourceCache: [String: SonificationSource] = [:]
    private var nameToKey: [String: String] = [:]
    /// The loaded sound: the r16 engine's `currentFile`.
    private(set) var loadedKey: String?
    private var loadedSlot: UInt32?

    private(set) var isPlaying = false
    private(set) var shouldResumePlayback = false
    private(set) var appIsForeground = true
    private(set) var interrupted = false
    private(set) var interruptionShouldResume = true
    private(set) var interruptionResumeGateRequired = false
    private(set) var isFadingOut = false
    private var fadeTask: Task<Void, Never>?

    private var interruptionTask: Task<Void, Never>?
    private var routeChangeTask: Task<Void, Never>?

    // MARK: Init

    init(host: AudioControlling?,
         output: LiveSonificationOutput,
         kernel: LiveSonificationKernel,
         fadeOutSeconds: TimeInterval,
         observeSession: Bool,
         resolve: @escaping (String) -> SonificationSource?) {
        self.host = host
        self.output = output
        self.kernel = kernel
        self.fadeOutSeconds = fadeOutSeconds
        self.resolve = resolve
        if observeSession { startObservingSession() }
    }

    deinit {
        interruptionTask?.cancel()
        routeChangeTask?.cancel()
    }

    /// The production voice: the r16 engine as host, a source node attached to
    /// its graph, sources from the bundle, renderers prewarmed off-main.
    static func production(host: AudioEngine, fadeOutSeconds: TimeInterval) -> LiveSonificationAudio {
        let kernel = LiveSonificationKernel()
        let node = SourceNodeOutput(kernel: kernel)
        host.attachLiveSonificationNode(node.node, format: node.format)
        #if DEBUG || POPCAP
        PopCapture.armed?.installTap(on: node.node.engine?.mainMixerNode ?? node.node)   // POPCAP
        #endif
        let voice = LiveSonificationAudio(host: host, output: node, kernel: kernel,
                                          fadeOutSeconds: fadeOutSeconds, observeSession: true,
                                          resolve: Self.bundleSource(named:))
        voice.prewarmStudySources()
        return voice
    }

    nonisolated static func bundleURL(named name: String) -> URL? { PrimaeBundle.audioURL(for: name) }

    static func bundleSource(named name: String) -> SonificationSource? {
        guard let url = bundleURL(named: name) else { return nil }
        return SonificationSource.load(url: url, gain: AudioEngine.loudnessGain(forFileAt: url))
    }

    // MARK: Renderer cache

    /// The kernel slot for `source`; built on first use.
    private func slot(for source: SonificationSource) -> UInt32? {
        if let s = slots[source.key] { return s }
        let pair: (TDPSOLA, TDPSOLA)
        if let ready = prewarmed.take(source.key) {
            pair = ready
        } else {
            #if DEBUG || POPCAP
            let t0 = PopCapture.nowNs()
            #endif
            pair = Self.makeRendererPair(source)
            mainActorBuilds += 1
            #if DEBUG || POPCAP
            PopCapture.armed?.event("renderer.build", "key=\(source.key) where=main-on-demand ms=\(Double(PopCapture.nowNs() - t0) / 1e6)")
            #endif
        }
        let s = kernel.register(pair.0, twin: pair.1, gain: source.gain)
        if let s { slots[source.key] = s } else { log.fault("Sonification renderer table full; \(source.key, privacy: .public) not playable") }
        return s
    }

    /// The TDPSOLA renderer for `source` (pure DSP; any thread).
    /// R17D: a source with a recorded onset (`PhonemeOnsets`) loops from its declared attack end.
    nonisolated static func makeRenderer(_ source: SonificationSource) -> TDPSOLA {
        TDPSOLA(source: source.samples, sampleRate: LiveSonificationKernel.sampleRate,
                kind: source.kind, maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                tuning: .default, onset: source.onset)
    }

    /// Two renderers of `source` for one kernel slot (the second is the voice a
    /// restart crosses over to); the twin reuses the first one's analysis.
    nonisolated static func makeRendererPair(_ source: SonificationSource) -> (TDPSOLA, TDPSOLA) {
        let a = makeRenderer(source)
        let b = TDPSOLA(source: source.samples, sampleRate: LiveSonificationKernel.sampleRate, kind: source.kind,
                        maxFramesPerRender: LiveSonificationKernel.chunkFrames, analysis: a.analysis)
        return (a, b)
    }

    private func source(named name: String) -> SonificationSource? {
        if let k = nameToKey[name], let s = sourceCache[k] { return s }
        #if DEBUG || POPCAP
        let t0 = PopCapture.nowNs()
        #endif
        guard let s = resolve(name) else { return nil }
        #if DEBUG || POPCAP
        PopCapture.armed?.event("source.resolve", "file=\(name) ms=\(Double(PopCapture.nowNs() - t0) / 1e6)")
        #endif
        if sourceCache[s.key] == nil { sourceCache[s.key] = s }
        nameToKey[name] = s.key
        return sourceCache[s.key]
    }

    /// Builds the study's arm sounds in the background at
    /// launch, so the first touch on a letter never pays for decoding or
    /// analysis. A load that arrives first builds its own on the main actor;
    /// the background result is then dropped.
    func prewarmStudySources() {
        var urls: [URL] = TrainedLetterSubset.studyLetters.compactMap {
            PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\($0)", name: "\($0)_phoneme1", ext: "wav"))
        }
        if let carrier = SpatialSonification.carrierToneURL() { urls.append(carrier) }
        let gains = urls.map { AudioEngine.loudnessGain(forFileAt: $0) }
        let jobs = Array(zip(urls, gains))
        let store = prewarmed
        Task.detached(priority: .utility) { [weak self] in
            var built: [BuiltRenderer] = []
            for (url, gain) in jobs {
                guard let s = SonificationSource.load(url: url, gain: gain) else { continue }
                #if DEBUG || POPCAP
                let t0 = PopCapture.nowNs()
                #endif
                let pair = Self.makeRendererPair(s)
                store.put(s.key, pair)   // visible to a load at once; `adopt` registers what is left
                #if DEBUG || POPCAP
                PopCapture.armed?.event("renderer.build", "key=\(s.key) where=prewarm ms=\(Double(PopCapture.nowNs() - t0) / 1e6)")
                #endif
                built.append(BuiltRenderer(source: s, renderer: pair.0, twin: pair.1))
            }
            let ready = built
            await self?.adopt(ready)
        }
    }

    /// A renderer built off the main actor, handed over once and never used
    /// there again before registration.
    nonisolated private struct BuiltRenderer: @unchecked Sendable {
        let source: SonificationSource
        let renderer: TDPSOLA
        let twin: TDPSOLA
    }

    private func adopt(_ built: [BuiltRenderer]) {
        for b in built {
            let s = b.source
            if sourceCache[s.key] == nil { sourceCache[s.key] = s }
            guard slots[s.key] == nil, prewarmed.take(s.key) != nil else { continue }
            if let slot = kernel.register(b.renderer, twin: b.twin, gain: s.gain) {
                slots[s.key] = slot
                #if DEBUG || POPCAP
                PopCapture.armed?.event("renderer.adopt", "key=\(s.key) slot=\(slot)")
                #endif
            }
        }
    }

    // MARK: AudioControlling

    var initializationError: String? { host?.initializationError }

    func loadAudioFile(named fileName: String, autoplay: Bool) {
        guard let src = source(named: fileName) else {
            log.warning("Missing audio file: \(fileName, privacy: .public)")
            return
        }
        guard let slot = slot(for: src) else { return }
        // A load ends a pending stop's bookkeeping: the fade keeps sounding
        // out in the kernel, but can no longer discard the file just loaded.
        fadeTask?.cancel(); fadeTask = nil
        isFadingOut = false
        if loadedSlot != slot {
            // A DIFFERENT sound: r16 hard-stopped the player; here the kernel's
            // duck (a 20 ms quarter-cosine; LOOPX), crossed over if a play follows.
            kernel.close(fadeOutFrames: 0)
            isPlaying = false
        }
        loadedKey = src.key
        loadedSlot = slot
        output.startIfNeeded()
        guard output.isRunning else { return }
        shouldResumePlayback = autoplay
        if autoplay { attemptResumePlayback() } else if !kernel.gateRequested { isPlaying = false }
    }

    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        guard speed.isFinite && horizontalBias.isFinite else { return }
        kernel.setRate(max(minPlaybackRate, min(maxPlaybackRate, speed)))
        // The main mixer slews a pan change over ~25 ms itself (measured on the
        // iPad, LOOPX: no step at the buffer edge), so the pan stays the mixer's.
        output.setPan(max(-1, min(1, horizontalBias)))
    }

    func setSpatialPitch(cents: Float) {
        guard cents.isFinite else { return }
        kernel.setPitchCents(max(-1200, min(1200, cents)))
    }

    func play() { play(fadeInSeconds: 0) }

    /// R17D: a sound with a recorded onset starts like a stroke (no fade-in): its onset IS the sound's rise, and
    /// the observe demonstration's 120 ms linear fade took 0.2-4 dB off it (ONSET.md section 5, "Observe"). The
    /// kernel's 8 ms raised-cosine start ramp still applies, as for every stroke. A sound without one (the spatial
    /// carrier) keeps the requested fade.
    func play(fadeInSeconds: TimeInterval) {
        guard let key = loadedKey else { return }
        let fadeInSeconds = sourceCache[key]?.onset == nil ? fadeInSeconds : 0
        fadeTask?.cancel(); fadeTask = nil
        isFadingOut = false
        shouldResumePlayback           = true
        interruptionResumeGateRequired = false
        interruptionShouldResume       = true
        // An explicit play outranks a stale interruption flag (R5, as AudioEngine).
        interrupted                    = false
        output.startIfNeeded()
        attemptResumePlayback(fadeInSeconds: fadeInSeconds)
    }

    /// ENV3 letter-end stop: a raised-cosine fade of `seconds` (zero slope at both ends), then the ordinary stop bookkeeping.
    func stop(fadeOutSeconds seconds: TimeInterval) {
        fadeTask?.cancel(); fadeTask = nil
        guard seconds > 0, isPlaying, output.isRunning else { stop(); return }
        kernel.closeRaisedCosine(frames: Self.frames(seconds))
        isFadingOut = true
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.finishStop()
        }
    }

    func stop() {
        fadeTask?.cancel(); fadeTask = nil
        let needsFade = fadeOutSeconds > 0 && isPlaying && output.isRunning
        guard needsFade else {
            kernel.close(fadeOutFrames: 0)
            finishStop()
            return
        }
        kernel.close(fadeOutFrames: Self.frames(fadeOutSeconds))
        isFadingOut = true
        let duration = fadeOutSeconds
        fadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled, let self else { return }
            self.finishStop()
        }
    }

    private func finishStop(cancelHostLifecycleWork: Bool = true) {
        shouldResumePlayback           = false
        isPlaying                      = false
        interruptionResumeGateRequired = false
        isFadingOut                    = false
        fadeTask = nil
        // As `AudioEngine.finishStop`. Not on an interruption: the host's own
        // observer schedules its engine pause then, and that must stand.
        if cancelHostLifecycleWork { host?.cancelPendingLifecycleWork() }
        loadedKey = nil
        loadedSlot = nil
    }

    func restart() {
        shouldResumePlayback           = true
        interruptionResumeGateRequired = false
        interruptionShouldResume       = true
        attemptResumePlayback()
    }

    func suspendForLifecycle() {
        appIsForeground = false
        host?.cancelPendingLifecycleWork()
        shouldResumePlayback = isPlaying
        kernel.close(fadeOutFrames: 0)
        isPlaying = false
        // The host schedules its engine pause (its player is idle, so it pauses).
        host?.suspendForLifecycle()
    }

    func resumeAfterLifecycle() {
        appIsForeground = true
        host?.resumeAfterLifecycle()
        guard loadedKey != nil else { shouldResumePlayback = false; return }
        output.startIfNeeded()
        if output.isRunning && canResumePlayback(), let slot = loadedSlot {
            kernel.open(slot: slot, fadeInFrames: 0)
            isPlaying = true
        }
    }

    func cancelPendingLifecycleWork() { host?.cancelPendingLifecycleWork() }

    // MARK: Measurement hooks (the host's tap is on the main mixer)

    func emitAudioSignalSummary(label: String) { host?.emitAudioSignalSummary(label: label) }
    func startAudioSignalTicker(intervalSeconds: TimeInterval, label: @escaping @MainActor () -> String) {
        host?.startAudioSignalTicker(intervalSeconds: intervalSeconds, label: label)
    }
    func stopAudioSignalTicker() { host?.stopAudioSignalTicker() }
    var latestAudioSignalSummary: String? { host?.latestAudioSignalSummary }
    var debugAudioStateSummary: String {
        let base = host?.debugAudioStateSummary ?? ""
        return base + " voice=\(isPlaying) loaded=\(loadedKey != nil)"
    }

    // MARK: Resume logic (as AudioEngine)

    func canResumePlayback() -> Bool {
        appIsForeground && !interrupted && shouldResumePlayback
            && (!interruptionResumeGateRequired || interruptionShouldResume)
    }

    private func attemptResumePlayback(fadeInSeconds: TimeInterval = 0) {
        output.startIfNeeded()
        guard output.isRunning, loadedKey != nil, let slot = loadedSlot else { return }
        guard canResumePlayback() else {
            kernel.close(fadeOutFrames: 0)
            isPlaying = false
            return
        }
        kernel.open(slot: slot, fadeInFrames: Self.frames(fadeInSeconds))
        isPlaying = true
    }

    static func frames(_ seconds: TimeInterval) -> UInt32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt32(min(Double(UInt32.max / 2), (seconds * LiveSonificationKernel.sampleRate).rounded()))
    }

    // MARK: Session notifications

    private func startObservingSession() {
        interruptionTask = Task { [weak self] in
            for await n in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                guard let self else { break }
                let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
                let options = (n.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue
                self.handleInterruption(typeRawValue: type, optionsRawValue: options)
            }
        }
        routeChangeTask = Task { [weak self] in
            for await n in NotificationCenter.default.notifications(named: AVAudioSession.routeChangeNotification) {
                guard let self else { break }
                let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                self.handleRouteChange(reasonRawValue: reason)
            }
        }
    }

    /// `AudioEngine`'s interruption observer + `handleInterruptionBegan` +
    /// `handleInterruptionValues`, in that order.
    func handleInterruption(typeRawValue: UInt?, optionsRawValue: UInt?) {
        guard let typeRawValue, let type = AVAudioSession.InterruptionType(rawValue: typeRawValue) else { return }
        switch type {
        case .began:
            // Resume intent read BEFORE any state changes; none when a stop was already fading (C2).
            let intent = isPlaying && !isFadingOut
            let key = loadedKey, slot = loadedSlot
            fadeTask?.cancel(); fadeTask = nil
            kernel.close(fadeOutFrames: 0)
            finishStop(cancelHostLifecycleWork: false)
            loadedKey = key; loadedSlot = slot
            shouldResumePlayback           = intent
            interrupted                    = true
            interruptionResumeGateRequired = true
            interruptionShouldResume       = false
            isPlaying = false
        case .ended:
            interrupted = false
            interruptionShouldResume = optionsRawValue.map {
                AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume)
            } ?? false
            if interruptionShouldResume && loadedKey != nil { attemptResumePlayback() }
        @unknown default:
            break
        }
    }

    /// `AudioEngine.handleRouteChangeValue`, except that a voice already
    /// sounding is not restarted from its attack.
    func handleRouteChange(reasonRawValue: UInt?) {
        // POP2: the preferred IO buffer follows the route (5 ms on speaker/wired, the system default on Bluetooth).
        SoundEnvelope.applyPreferredIOBuffer()
        guard let reasonRawValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRawValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            stop()
        case .newDeviceAvailable, .categoryChange, .override,
             .routeConfigurationChange, .wakeFromSleep, .noSuitableRouteForCategory:
            guard appIsForeground && !interrupted && shouldResumePlayback else { return }
            if isPlaying && kernel.gateRequested { output.startIfNeeded() } else { attemptResumePlayback() }
        default:
            break
        }
    }
}

// MARK: - Prewarm hand-over

/// Renderer pairs built off the main actor, published the moment they are
/// built (POPCAP fix, 2026-11-04). The launch prewarm used to hand its results
/// to the main actor in ONE hop after the last build, so a first `load` that
/// arrived while the main actor was busy (measured on the iPad: the first letter
/// loaded 1.8 s after the build finished, before the adopt hop ran) found
/// nothing, built its own pair on the main actor (52 ms for I, 37 ms for the
/// carrier, every run) and the prewarmed pair was then dropped. `slot(for:)` now
/// takes the finished pair from here first.
nonisolated final class PrewarmedRenderers: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: (TDPSOLA, TDPSOLA)] = [:]
    func put(_ key: String, _ pair: (TDPSOLA, TDPSOLA)) { lock.lock(); table[key] = pair; lock.unlock() }
    func take(_ key: String) -> (TDPSOLA, TDPSOLA)? { lock.lock(); defer { lock.unlock() }; return table.removeValue(forKey: key) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return table.count }
}

// MARK: - Production output: the source node

@MainActor
final class SourceNodeOutput: LiveSonificationOutput {
    let node: AVAudioSourceNode
    let format: AVAudioFormat

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
                             category: "LiveSonification")

    init(kernel: LiveSonificationKernel) {
        format = AVAudioFormat(standardFormatWithSampleRate: LiveSonificationKernel.sampleRate, channels: 1)!
        node = Self.makeNode(kernel: kernel, format: format)
    }

    /// Nonisolated so the render block is not main-actor isolated (it runs on
    /// the I/O thread). The kernel is retained for the life of the process.
    nonisolated private static func makeNode(kernel: LiveSonificationKernel,
                                             format: AVAudioFormat) -> AVAudioSourceNode {
        let k = Unmanaged.passRetained(kernel)
        #if DEBUG || POPCAP
        let cap = PopCapture.armed
        #endif
        return AVAudioSourceNode(format: format) { isSilence, ts, frameCount, abl -> OSStatus in
            guard let data = abl.pointee.mBuffers.mData else { return noErr }
            let out = data.assumingMemoryBound(to: Float.self)
            #if DEBUG || POPCAP
            let t0 = mach_absolute_time()
            #endif
            let silent = k._withUnsafeGuaranteedRef { $0.render(into: out, frames: Int(frameCount)) }
            #if DEBUG || POPCAP
            cap?.renderEnd(start: t0, sampleTime: ts.pointee.mSampleTime, ioHostTime: ts.pointee.mHostTime,
                           frames: Int(frameCount), silent: silent, out: out)
            #endif
            isSilence.pointee = ObjCBool(silent)
            return noErr
        }
    }

    var isRunning: Bool { node.engine?.isRunning ?? false }

    func startIfNeeded() {
        guard let engine = node.engine, !engine.isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        let category = session.category
        guard category == .playback || category == .playAndRecord || category == .multiRoute else { return }
        do { try session.setActive(true) } catch {
            log.error("Failed to activate audio session for the live voice: \(error.localizedDescription, privacy: .public)")
        }
        do { try engine.start() } catch {
            log.error("Engine failed to start for the live voice: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setPan(_ pan: Float) { node.pan = pan }
}
