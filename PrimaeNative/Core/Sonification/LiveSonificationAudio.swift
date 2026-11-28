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
// `.shouldResume` resumes (from SDK27: a resumption recommendation of
// `.shouldResume`, `AudioSessionInterruption`); a lost output (headphones unplugged) stops; a
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
    /// Start the engine if it is not running and run `then` once it runs
    /// (now, when it already does), as `AudioEngine.startIfNeeded(then:)`
    /// does: SDK27, the start follows a completed ASYNCHRONOUS session
    /// activation (`EngineStartGate`), so a caller passes what must happen
    /// once the engine runs instead of reading `isRunning` right after.
    func startIfNeeded(then: (@MainActor () -> Void)?)
    /// Run a session call that has no asynchronous form OFF the main thread,
    /// ordered with the engine's activations (`EngineStartGate.performSessionWork`).
    func performSessionWork(_ work: @escaping @Sendable () -> Void)
    /// Constant-power pan of the mono node in the main mixer (the r16 player's pan).
    func setPan(_ pan: Float)
}

extension LiveSonificationOutput {
    /// Start without a continuation (a warm start ahead of a later play).
    func startIfNeeded() { startIfNeeded(then: nil) }
}

@MainActor
final class LiveSonificationAudio: AudioControlling {

    // MARK: Dependencies

    /// The r16 engine: session, mixer, probe tap, lifecycle engine pause.
    private let host: AudioControlling?
    private var output: LiveSonificationOutput
    private(set) var kernel: LiveSonificationKernel
    /// Resolves a file name to a decoded source at a rate (production: bundle + decode at the kernel's rate +
    /// loudness gain; tests: synthetic sources).
    private let resolve: (String, Double) -> SonificationSource?
    /// FOLLOWUP-r31: a file name's source cache key without decoding it (production: the bundle URL, symlinks
    /// resolved), so a load can find the source the launch prewarm already decoded off the main thread. Nil: the
    /// voice always resolves (the tests' synthetic sources).
    private let sourceKey: (String) -> String?
    /// r31 (PITCHWIN): the session's output rate, read OFF the main thread (`performSessionWork`, ordered after an
    /// activation) after the launch activation and after every route change. Nil: the voice never re-rates.
    private let outputRate: (@Sendable () -> Double)?
    /// r31: a kernel and output at a new rate, wired into the graph in place of the current ones.
    private let rebuildOutput: ((LiveSonificationOutput, Double) -> (LiveSonificationKernel, LiveSonificationOutput)?)?
    /// How many times the voice re-rated (a test reads it).
    private(set) var rateRebuilds = 0

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
                             category: "LiveSonification")

    // MARK: Tunables (as `AudioEngine`)

    var fadeOutSeconds: TimeInterval
    var minPlaybackRate: Float = 0.5
    var maxPlaybackRate: Float = 2.0

    // MARK: State (mirrors AudioEngine)

    private var slots: [String: UInt32] = [:]
    /// Pairs built by the launch prewarm and not yet registered.
    private(set) var prewarmed = PrewarmedRenderers()
    /// Renderer pairs this instance had to build on the main actor (a load that beat the prewarm). RENDERFREEZE:
    /// zero in production, where a load's own build runs off the main thread (`offMainRendererBuild`).
    private(set) var mainActorBuilds = 0
    /// RENDERFREEZE (2026-11-28): where a load's own renderer build runs (production: `offMainRendererBuild`; the
    /// unit tests' synthetic tones: `inlineRendererBuild`, the same code path run at once) and what it builds.
    /// Up to r32 a load that beat the launch prewarm built its pair ON THE MAIN THREAD: 2.2-6.2 s on the iPad
    /// (Debug-Study), the UI frozen for all of it.
    typealias RendererBuildRunner = @Sendable (@escaping @Sendable () -> Void) -> Void
    typealias RendererPairMaker = @Sendable (SonificationSource) -> (TDPSOLA2, TDPSOLA2)
    private let buildRenderers: RendererBuildRunner
    private let makePair: RendererPairMaker
    /// Keys whose pair a load requested and the voice has not registered yet (one build per key).
    private(set) var awaitingRenderers: Set<String> = []
    /// Whether `key`'s pair is registered in the kernel (read by the device tests).
    func hasRegisteredRenderer(forKey key: String) -> Bool { slots[key] != nil }
    /// The fade-in a play asked for while its renderer was still being built.
    private var pendingFadeInSeconds: TimeInterval = 0
    /// RENDERFREEZE2: callers waiting for a key's pair (`whenRendererReady`), with the file name they asked for (a
    /// re-rate asks again under it).
    private var readyWaiters: [String: (name: String, ready: [@MainActor () -> Void])] = [:]

    nonisolated static let inlineRendererBuild: RendererBuildRunner = { $0() }
    nonisolated static let offMainRendererBuild: RendererBuildRunner = { work in
        Task.detached(priority: .userInitiated) { work() }
    }
    private var sourceCache: [String: SonificationSource] = [:]
    private var nameToKey: [String: String] = [:]
    /// The loaded sound: the r16 engine's `currentFile`.
    private(set) var loadedKey: String?
    /// The file name of the loaded sound (a re-rate reloads it).
    private var loadedName: String?
    private var loadedSlot: UInt32?

    private(set) var isPlaying = false
    private(set) var shouldResumePlayback = false
    private(set) var appIsForeground = true
    private(set) var interrupted = false
    private(set) var interruptionShouldResume = true
    private(set) var interruptionResumeGateRequired = false
    private(set) var isFadingOut = false
    /// FOLLOWUP-r31: a letter switch ended the previous sound with the standing stop fade, and the kernel is still
    /// running it; a `stop()` with nothing playing must not overwrite it with the duck. Cleared by a play and by a
    /// stop's bookkeeping.
    private(set) var switchFadeRunning = false
    private var fadeTask: Task<Void, Never>?

    private var interruptionTask: Task<Void, Never>?
    /// Where the session notifications are observed (`.default`; a test passes
    /// its own so a forged post reaches no other voice in a parallel suite).
    private let notificationCenter: NotificationCenter
    private var routeChangeTask: Task<Void, Never>?
    /// The route's IO buffer (POP2), applied on every route change through
    /// `output.performSessionWork` (off the main thread). A seam for the test
    /// that pins where it runs.
    private let ioBufferWork: @Sendable () -> Void

    // MARK: Init

    init(host: AudioControlling?,
         output: LiveSonificationOutput,
         kernel: LiveSonificationKernel,
         fadeOutSeconds: TimeInterval,
         observeSession: Bool,
         notificationCenter: NotificationCenter = .default,
         ioBufferWork: @escaping @Sendable () -> Void = { SoundEnvelope.applyPreferredIOBuffer() },
         outputRate: (@Sendable () -> Double)? = nil,
         rebuildOutput: ((LiveSonificationOutput, Double) -> (LiveSonificationKernel, LiveSonificationOutput)?)? = nil,
         sourceKey: @escaping (String) -> String? = { _ in nil },
         buildRenderers: @escaping RendererBuildRunner = LiveSonificationAudio.inlineRendererBuild,
         makePair: @escaping RendererPairMaker = { LiveSonificationAudio.makeRendererPair($0) },
         resolve: @escaping (String, Double) -> SonificationSource?) {
        self.buildRenderers = buildRenderers
        self.makePair = makePair
        self.notificationCenter = notificationCenter
        self.ioBufferWork = ioBufferWork
        self.outputRate = outputRate
        self.rebuildOutput = rebuildOutput
        self.host = host
        self.output = output
        self.kernel = kernel
        self.fadeOutSeconds = fadeOutSeconds
        self.resolve = resolve
        self.sourceKey = sourceKey
        if observeSession { startObservingSession() }
    }

    deinit {
        interruptionTask?.cancel()
        routeChangeTask?.cancel()
    }

    /// The production voice: the r16 engine as host, a source node attached to
    /// its graph, sources from the bundle, renderers prewarmed off-main.
    static func production(host: AudioEngine, fadeOutSeconds: TimeInterval,
                           ioBufferWork: @escaping @Sendable () -> Void = { SoundEnvelope.applyPreferredIOBuffer() }) -> LiveSonificationAudio {
        var kernel = LiveSonificationKernel()
        var node = SourceNodeOutput(kernel: kernel, startGate: host.startGate)
        host.attachLiveSonificationNode(node.node, format: node.format)
        // r31 (PITCHWIN): the voice renders at the output hardware's rate, so the mixer and the output unit pass it
        // through and nothing after the renderer converts. The graph's output format is the hardware's (no session
        // call on the main thread); the session's own rate is read back after the launch activation and after
        // every route change (`adoptSessionRate`), and a different rate rebuilds the voice there.
        if let engine = node.node.engine {
            let hw = engine.outputNode.outputFormat(forBus: 0).sampleRate
            if hw > 0 && hw != kernel.sampleRate {
                (kernel, node) = node.replaced(atRate: hw)
            }
        }
        #if DEBUG || POPCAP
        PopCapture.armed?.installTap(on: node.node.engine?.mainMixerNode ?? node.node)   // POPCAP
        #endif
        let voice = LiveSonificationAudio(host: host, output: node, kernel: kernel,
                                          fadeOutSeconds: fadeOutSeconds, observeSession: true,
                                          ioBufferWork: ioBufferWork,
                                          outputRate: { AVAudioSession.sharedInstance().sampleRate },
                                          rebuildOutput: { current, rate in
                                              guard let node = current as? SourceNodeOutput else { return nil }
                                              let (kernel, next) = node.replaced(atRate: rate)
                                              return (kernel, next as LiveSonificationOutput)
                                          },
                                          sourceKey: Self.bundleSourceKey(named:),
                                          buildRenderers: Self.offMainRendererBuild,
                                          resolve: Self.bundleSource(named:sampleRate:))
        voice.prewarmStudySources()
        voice.adoptSessionRate()
        return voice
    }

    nonisolated static func bundleURL(named name: String) -> URL? { PrimaeBundle.audioURL(for: name) }

    /// The cache key `bundleSource` would give `name`'s source, without decoding the file.
    nonisolated static func bundleSourceKey(named name: String) -> String? {
        bundleURL(named: name).map(SonificationSource.cacheKey(for:))
    }

    static func bundleSource(named name: String, sampleRate: Double) -> SonificationSource? {
        guard let url = bundleURL(named: name) else { return nil }
        return SonificationSource.load(url: url, gain: AudioEngine.loudnessGain(forFileAt: url), sampleRate: sampleRate)
    }

    // MARK: Renderer cache

    private enum SlotState { case ready(UInt32), building, unplayable }

    /// The kernel slot for `source` if its renderer pair exists (registered, or built by the prewarm or an
    /// earlier load). RENDERFREEZE: never builds; `.building` means the pair is not there yet and the load
    /// requests it (`requestRenderer`).
    private func slotState(for source: SonificationSource) -> SlotState {
        if let s = slots[source.key] { return .ready(s) }
        guard let pair = prewarmed.take(source.key) else { return .building }
        return register(pair, for: source).map(SlotState.ready) ?? .unplayable
    }

    private func register(_ pair: (TDPSOLA2, TDPSOLA2), for source: SonificationSource) -> UInt32? {
        let s = kernel.register(pair.0, twin: pair.1, gain: source.gain)
        if let s { slots[source.key] = s } else { log.fault("Sonification renderer table full; \(source.key, privacy: .public) not playable") }
        return s
    }

    /// RENDERFREEZE: builds `source`'s pair through `buildRenderers` (production: off the main thread) and
    /// publishes it in `prewarmed`, where the prewarm publishes its own; the first pair published for a key is the
    /// one registered (`PrewarmedRenderers.whenReady`). The prewarm skips a key a load already claimed. A pair
    /// the prewarm already has under way is built here too (it runs at utility QoS, measured 10-20 s per letter on
    /// the iPad under Debug-Study), and the one finished first is taken.
    private func requestRenderer(for source: SonificationSource) {
        let key = source.key
        guard !awaitingRenderers.contains(key) else { return }
        awaitingRenderers.insert(key)
        let store = prewarmed
        store.whenReady(key) { [weak self] in
            Self.onMain { self?.rendererArrived(source, from: store) }
        }
        guard store.claimForLoad(key) else { return }   // already published: `whenReady` has fired
        let make = makePair
        buildRenderers { [weak self] in
            let onMain = Thread.isMainThread
            #if DEBUG || POPCAP
            let t0 = PopCapture.nowNs()
            #endif
            let pair = make(source)
            #if DEBUG || POPCAP
            PopCapture.armed?.event("renderer.build", "key=\(key) where=\(onMain ? "main-on-demand" : "on-demand") ms=\(Double(PopCapture.nowNs() - t0) / 1e6)")
            #endif
            if onMain { MainActor.assumeIsolated { self?.mainActorBuilds += 1 } }
            store.put(key, pair)
        }
    }

    /// A requested pair is published: registered (unless a re-rate replaced the store), and bound to the load that
    /// is still waiting for it, which sounds now if it is meant to (the observe sound starts when ready).
    private func rendererArrived(_ source: SonificationSource, from store: PrewarmedRenderers) {
        guard store === prewarmed, source.sampleRate == kernel.sampleRate else { return }
        awaitingRenderers.remove(source.key)
        let slot: UInt32?
        if let s = slots[source.key] { slot = s } else if let pair = store.take(source.key) { slot = register(pair, for: source) } else { slot = nil }
        // RENDERFREEZE2: after the waiting load is bound (and sounds, if it is meant to), the callers waiting for
        // this renderer run; a full table (no slot) releases them too: the demonstration then runs without a sound.
        defer { readyWaiters.removeValue(forKey: source.key)?.ready.forEach { $0() } }
        guard let slot, loadedKey == source.key, loadedSlot == nil else { return }
        loadedSlot = slot
        #if DEBUG || POPCAP
        PopCapture.armed?.event("renderer.ready", "key=\(source.key) slot=\(slot) resume=\(shouldResumePlayback)")
        #endif
        if canResumePlayback() { attemptResumePlayback(fadeInSeconds: pendingFadeInSeconds) }
    }

    /// RENDERFREEZE2: `ready` runs once `fileName`'s renderer pair is registered: at once when it already is (or the
    /// prewarm has published it), else when the build this requests (`requestRenderer`, off the main thread in
    /// production) is published. An unknown file is ready at once: there is nothing to wait for.
    func whenRendererReady(forFile fileName: String, _ ready: @escaping @MainActor () -> Void) {
        guard let src = source(named: fileName), case .building = slotState(for: src) else { ready(); return }
        readyWaiters[src.key, default: (fileName, [])].ready.append(ready)
        #if DEBUG || POPCAP
        PopCapture.armed?.event("renderer.await", "key=\(src.key)")
        #endif
        requestRenderer(for: src)
    }

    /// RENDERFREEZE2: the launch prewarm builds `fileName`'s pair before the others it has not started (the session's
    /// next letter). Known by name (`sourceKey`), so nothing is decoded here.
    func prioritizeRenderer(forFile fileName: String) {
        guard let key = nameToKey[fileName] ?? sourceKey(fileName), slots[key] == nil else { return }
        prewarmed.prioritize(key)
    }

    /// Runs `body` on the main actor: at once when already on the main thread (the inline build), else in a hop.
    nonisolated private static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { body() } } else { Task { @MainActor in body() } }
    }

    /// The renderer options for a source of `kind` (protocol r31). A phoneme plays through the bake-off winner
    /// "TDPSOLA2-sa" plus the residual level table (`TDPSOLA2Options.production`); the spatial carrier keeps every
    /// option off (`.r27`), which is the r17-r28 TDPSOLA output bit for bit (`TDPSOLA2IdentityTests`,
    /// `ProductionRendererTests`): the spatial arm does not change.
    nonisolated static func rendererOptions(for kind: SourceKind) -> TDPSOLA2Options {
        kind == .carrier ? .r27 : .production
    }

    /// The renderer for `source` (pure DSP; any thread).
    /// R17D: a source with a recorded onset (`PhonemeOnsets`) loops from its declared attack end.
    /// r22: the renderer gets the source's loudness gain, the gain the kernel plays it at, so the recorded onset is
    /// kept under full scale at that gain (`TDPSOLAOnsetCeiling`).
    /// r31: TDPSOLA2 (`rendererOptions(for:)`); r17-r28 built TDPSOLA here.
    nonisolated static func makeRenderer(_ source: SonificationSource) -> TDPSOLA2 {
        TDPSOLA2(source: source.samples, sampleRate: source.sampleRate,
                 kind: source.kind, maxFramesPerRender: LiveSonificationKernel.chunkFrames,
                 tuning: .default, options: rendererOptions(for: source.kind), onset: source.onset,
                 outputGain: source.gain, file: source.fileSource)
    }

    /// Two renderers of `source` for one kernel slot (the second is the voice a
    /// restart crosses over to); the twin reuses the first one's analysis, epochs and level table.
    nonisolated static func makeRendererPair(_ source: SonificationSource) -> (TDPSOLA2, TDPSOLA2) {
        let a = makeRenderer(source)
        return (a, a.twin(source: source.samples))
    }

    private func source(named name: String) -> SonificationSource? {
        if let k = nameToKey[name], let s = sourceCache[k] { return s }
        // FOLLOWUP-r31: the launch prewarm decoded and resampled the study's sources off the main thread; a load
        // takes that source instead of decoding the file again here (measured on the iPad before this: 75 ms on
        // the main thread at the first load of each phoneme letter, inside a letter switch). The same decode, so
        // the same samples: nothing heard changes.
        if let k = sourceKey(name),
           let s = sourceCache[k] ?? prewarmed.source(forKey: k), s.sampleRate == kernel.sampleRate {
            if sourceCache[k] == nil { sourceCache[k] = s }
            nameToKey[name] = k
            #if DEBUG || POPCAP
            PopCapture.armed?.event("source.resolve", "file=\(name) ms=0 prewarmed=1")
            #endif
            return s
        }
        #if DEBUG || POPCAP
        let t0 = PopCapture.nowNs()
        #endif
        guard let s = resolve(name, kernel.sampleRate) else { return nil }
        #if DEBUG || POPCAP
        PopCapture.armed?.event("source.resolve", "file=\(name) ms=\(Double(PopCapture.nowNs() - t0) / 1e6)")
        #endif
        if sourceCache[s.key] == nil { sourceCache[s.key] = s }
        nameToKey[name] = s.key
        return sourceCache[s.key]
    }

    /// Builds the study's arm sounds in the background at
    /// launch, so the first touch on a letter never pays for decoding or
    /// analysis. RENDERFREEZE: every source is decoded first (about 75 ms
    /// each), then the pairs are built; a load that arrives before its pair
    /// builds its own off the main thread, and the prewarm skips that key.
    func prewarmStudySources() {
        var urls: [URL] = TrainedLetterSubset.studyLetters.compactMap {
            PrimaeBundle.resourceURL(firstOf: PrimaeBundle.layouts(dir: "Letters/\($0)", name: "\($0)_phoneme1", ext: "wav"))
        }
        if let carrier = SpatialSonification.carrierToneURL() { urls.append(carrier) }
        let gains = urls.map { AudioEngine.loudnessGain(forFileAt: $0) }
        let jobs = Array(zip(urls, gains))
        let store = prewarmed
        let rate = kernel.sampleRate
        Task.detached(priority: .utility) { [weak self] in
            var built: [BuiltRenderer] = []
            let sources = jobs.compactMap { url, gain in
                SonificationSource.load(url: url, gain: gain, sampleRate: rate).map { s in
                    store.putSource(s)   // FOLLOWUP-r31: a load finds the decoded source at once (no main-thread decode)
                    return s
                }
            }
            // RENDERFREEZE2: the session's next letter first (`prioritizeRenderer`), then the study order.
            var pending = sources
            while !pending.isEmpty {
                let s = pending.remove(at: store.nextPrewarmIndex(pending.map(\.key)))
                guard store.claimForPrewarm(s.key) else { continue }   // RENDERFREEZE: a load is building it
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
        let renderer: TDPSOLA2
        let twin: TDPSOLA2
    }

    private func adopt(_ built: [BuiltRenderer]) {
        for b in built {
            let s = b.source
            guard s.sampleRate == kernel.sampleRate else { continue }   // built before a re-rate: dropped
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
    func settleStartup() async { await host?.settleStartup() }

    func loadAudioFile(named fileName: String, autoplay: Bool) {
        // A load ends a pending stop's bookkeeping: the fade keeps sounding
        // out in the kernel, but can no longer discard the file just loaded.
        // R072FIX: nor may a `stop()` with nothing playing duck it afterwards
        // (the view model stops the observe sound, then loads the next letter).
        if isFadingOut && !kernel.gateRequested { switchFadeRunning = true }
        fadeTask?.cancel(); fadeTask = nil
        isFadingOut = false
        // R072FIX: a DIFFERENT sound is ended BEFORE the new one is resolved and its renderer built. Both run on the
        // main thread, and a renderer the launch prewarm has not built yet took 5.5 s there (Debug-Study, iPad,
        // R-072 capture 2026-11-28), all of it with the old letter still sounding at full level.
        var ended = false
        if let key = nameToKey[fileName] ?? sourceKey(fileName), key != loadedKey {
            endLoadedSoundForSwitch(); ended = true
        }
        guard let src = source(named: fileName) else {
            log.warning("Missing audio file: \(fileName, privacy: .public)")
            return
        }
        // A key known only once resolved (no `sourceKey` for this name): ended here, after the resolve.
        if !ended && src.key != loadedKey { endLoadedSoundForSwitch() }
        // RENDERFREEZE: a renderer not built yet is built off the main thread (`requestRenderer`, after the intent
        // below is recorded); the load binds it, and plays if it is meant to, when it is published.
        let state = slotState(for: src)
        if case .unplayable = state { return }
        loadedKey = src.key
        loadedName = fileName
        if case .ready(let slot) = state { loadedSlot = slot } else { loadedSlot = nil }
        // SDK27: the start is asynchronous (`EngineStartGate`). The intent is
        // recorded now and an autoplay waits for the start inside
        // `attemptResumePlayback`; recording it in a deferred continuation
        // instead would let a load's late `shouldResumePlayback = false`
        // overwrite a `play()` that arrived after it.
        output.startIfNeeded()
        shouldResumePlayback = autoplay
        if autoplay { attemptResumePlayback() } else if !kernel.gateRequested { isPlaying = false }
        if case .building = state { requestRenderer(for: src) }
    }

    /// The loaded sound gives way to a DIFFERENT one (one slot per key, so a different key is a different slot).
    /// FOLLOWUP-r31 (protocol r32): a sound that is playing ends with the standing stop fade (`fadeOutSeconds`,
    /// linear, exactly what `stop()` gives it). Up to r31 the phoneme arm's letter switch took the kernel's 20 ms
    /// duck here, and the `stop()` that follows a switch then found nothing playing. A play right after the load
    /// still crosses over in the kernel (the open overrides the close). Nothing playing (or no fade, or no running
    /// engine): the duck, as before; a fade already running in the kernel ignores it (a closing voice is not
    /// re-closed).
    private func endLoadedSoundForSwitch() {
        if isPlaying && fadeOutSeconds > 0 && output.isRunning {
            kernel.close(fadeOutFrames: frames(fadeOutSeconds))
            switchFadeRunning = true
        } else if !switchFadeRunning {
            kernel.close(fadeOutFrames: 0)
        }
        isPlaying = false
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

    func setStrokeLevel(gainDB: Float) {
        guard gainDB.isFinite else { return }
        kernel.setStrokeLevel(gainDB: gainDB)
    }

    func setStrokeLowpass(cutoffHz: Float) {
        guard cutoffHz.isFinite else { return }
        kernel.setStrokeLowpass(cutoffHz: cutoffHz)
    }

    func setStrokeMute(_ muted: Bool) { kernel.setStrokeMute(muted) }

    func setPressureGain(_ gain: Float) {
        guard gain.isFinite else { return }
        kernel.setPressureGain(gain)
    }

    func setRoughness(_ amount: Float) {
        guard amount.isFinite else { return }
        kernel.setRoughness(amount)
    }

    func setRoughnessTuning(depth: Float, frequencyHz: Float) {
        guard depth.isFinite, frequencyHz.isFinite else { return }
        kernel.setRoughnessTuning(depth: depth, frequencyHz: frequencyHz)
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
        switchFadeRunning = false
        shouldResumePlayback           = true
        interruptionResumeGateRequired = false
        interruptionShouldResume       = true
        // An explicit play outranks a stale interruption flag (R5, as AudioEngine).
        interrupted                    = false
        attemptResumePlayback(fadeInSeconds: fadeInSeconds)   // starts the engine first when it is not running
    }

    /// ENV3 letter-end stop: a raised-cosine fade of `seconds` (zero slope at both ends), then the ordinary stop bookkeeping.
    func stop(fadeOutSeconds seconds: TimeInterval) {
        fadeTask?.cancel(); fadeTask = nil
        guard seconds > 0, isPlaying, output.isRunning else { stop(); return }
        kernel.closeRaisedCosine(frames: frames(seconds))
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
            // A letter switch's fade is already running in the kernel (FOLLOWUP-r31): the gate is closed, so a
            // duck here would only cut that fade short.
            if !(switchFadeRunning && !kernel.gateRequested) { kernel.close(fadeOutFrames: 0) }
            finishStop()
            return
        }
        kernel.close(fadeOutFrames: frames(fadeOutSeconds))
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
        switchFadeRunning              = false
        fadeTask = nil
        // As `AudioEngine.finishStop`. Not on an interruption: the host's own
        // observer schedules its engine pause then, and that must stand.
        if cancelHostLifecycleWork { host?.cancelPendingLifecycleWork() }
        loadedKey = nil
        loadedName = nil
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
        // SDK27: re-opened once the engine runs, with the state as it is then.
        output.startIfNeeded { [weak self] in
            guard let self, self.canResumePlayback(), let slot = self.loadedSlot else { return }
            self.kernel.open(slot: slot, fadeInFrames: 0)
            self.isPlaying = true
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
        // SDK27: a stopped engine starts asynchronously (`EngineStartGate`);
        // the attempt re-runs once it runs, reading the state as it is then.
        guard output.isRunning else {
            output.startIfNeeded { [weak self] in self?.attemptResumePlayback(fadeInSeconds: fadeInSeconds) }
            return
        }
        guard loadedKey != nil, let slot = loadedSlot else {
            pendingFadeInSeconds = fadeInSeconds   // RENDERFREEZE: the renderer is still being built
            return
        }
        guard canResumePlayback() else {
            kernel.close(fadeOutFrames: 0)
            isPlaying = false
            return
        }
        kernel.open(slot: slot, fadeInFrames: frames(fadeInSeconds))
        isPlaying = true
    }

    func frames(_ seconds: TimeInterval) -> UInt32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt32(min(Double(UInt32.max / 2), (seconds * kernel.sampleRate).rounded()))
    }

    // MARK: Output rate (r31, PITCHWIN)

    /// Reads the session's output rate off the main thread, ordered after a pending activation, and re-rates the
    /// voice on the main actor if it differs from the kernel's.
    func adoptSessionRate() {
        guard let outputRate else { return }
        output.performSessionWork { [weak self] in
            let rate = outputRate()
            Task { @MainActor [weak self] in self?.adoptOutputRate(rate) }
        }
    }

    /// Re-rates the voice when the output runs at `rate` and the kernel does not: a new kernel and source node at
    /// `rate` (the controls carried over), every source decoded again at `rate` (the offline resample) and every
    /// renderer rebuilt, the loaded sound reloaded. A sound that was playing is cut, not faded (the route changed
    /// under it; the r16 engine stopped its player too), and resumes if it was meant to.
    func adoptOutputRate(_ rate: Double) {
        guard rate.isFinite, rate > 0, rate != kernel.sampleRate, let rebuildOutput,
              let rebuilt = rebuildOutput(output, rate) else { return }
        let from = kernel.sampleRate
        let name = loadedName
        let resume = shouldResumePlayback
        let waiting = readyWaiters
        readyWaiters = [:]
        kernel.close(fadeOutFrames: 0)
        fadeTask?.cancel(); fadeTask = nil
        isFadingOut = false
        isPlaying = false
        let old = kernel
        (kernel, output) = rebuilt
        kernel.adoptControls(from: old)
        slots = [:]; sourceCache = [:]; nameToKey = [:]; awaitingRenderers = []
        loadedKey = nil; loadedName = nil; loadedSlot = nil
        prewarmed = PrewarmedRenderers()
        rateRebuilds += 1
        log.notice("Sonification re-rated \(from) -> \(rate) Hz")
        #if DEBUG || POPCAP
        PopCapture.armed?.event("voice.rerate", "from=\(from) to=\(rate)")
        #endif
        prewarmStudySources()
        if let name { loadAudioFile(named: name, autoplay: resume) }
        // RENDERFREEZE2: a caller waiting for a renderer of the old rate waits for the new one.
        for w in waiting.values { for ready in w.ready { whenRendererReady(forFile: w.name, ready) } }
    }

    // MARK: Session notifications

    private func startObservingSession() {
        // SDK27: the iOS 27 pair (didBecomeInactive + resumptionRecommendation)
        // replaces the deprecated interruption notification; one observer per
        // name, both under this task so `deinit`'s cancel ends them together.
        let center = notificationCenter
        interruptionTask = AudioSessionInterruption.observe(on: center) { [weak self] event in
            guard let self else { return false }
            self.handleInterruption(event)
            return true
        }
        routeChangeTask = Task { [weak self] in
            for await n in center.notifications(named: AVAudioSession.routeChangeNotification) {
                guard let self else { break }
                let reason = (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                self.handleRouteChange(reasonRawValue: reason)
            }
        }
    }

    /// `AudioEngine`'s interruption observer + `handleInterruptionBegan` +
    /// `handleInterruptionValues`, in that order.
    func handleInterruption(_ event: AudioSessionInterruption) {
        switch event {
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
            #if DEBUG || POPCAP
            PopCapture.armed?.event("voice.interruption", "began intent=\(intent) loaded=\(key != nil)")
            #endif
        case .ended(let shouldResume):
            interrupted = false
            interruptionShouldResume = shouldResume
            if interruptionShouldResume && loadedKey != nil { attemptResumePlayback() }
            #if DEBUG || POPCAP
            PopCapture.armed?.event("voice.interruption", "ended shouldResume=\(shouldResume) playing=\(isPlaying)")
            #endif
        }
    }

    /// `AudioEngine.handleRouteChangeValue`, except that a voice already
    /// sounding is not restarted from its attack.
    func handleRouteChange(reasonRawValue: UInt?) {
        // POP2: the preferred IO buffer follows the route (5 ms on speaker/wired, the system default on Bluetooth).
        // SDK27: off the main thread (the session is active here; on main it is a "Hang Risk"), ordered after a
        // pending activation and ahead of a later one by the host's start gate.
        output.performSessionWork(ioBufferWork)
        // r31: a new route can run at a new rate; read it back after the session work and re-rate if it moved.
        adoptSessionRate()
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
    private var table: [String: (TDPSOLA2, TDPSOLA2)] = [:]
    /// RENDERFREEZE: keys a build was started for (the prewarm's or a load's), keys whose pair was published (the
    /// first one published wins; a later one for the same key is dropped), and the loads waiting for a key.
    private var claimed: Set<String> = []
    private var published: Set<String> = []
    private var waiters: [String: [@Sendable () -> Void]] = [:]
    func put(_ key: String, _ pair: (TDPSOLA2, TDPSOLA2)) {
        lock.lock()
        guard published.insert(key).inserted else { lock.unlock(); return }
        table[key] = pair
        let ready = waiters.removeValue(forKey: key) ?? []
        lock.unlock()
        ready.forEach { $0() }
    }
    /// The prewarm's claim: false when a load (or an earlier prewarm pass) already started this key's build.
    func claimForPrewarm(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return claimed.insert(key).inserted }
    /// A load's claim: false only when the pair is already published (a build under way is not waited for).
    func claimForLoad(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        claimed.insert(key)
        return !published.contains(key)
    }
    /// Calls `ready` once `key`'s pair is published: at once (on this thread) if it already is, else on the
    /// publishing thread.
    func whenReady(_ key: String, _ ready: @escaping @Sendable () -> Void) {
        lock.lock()
        if published.contains(key) { lock.unlock(); ready(); return }
        waiters[key, default: []].append(ready)
        lock.unlock()
    }
    func take(_ key: String) -> (TDPSOLA2, TDPSOLA2)? { lock.lock(); defer { lock.unlock() }; return table.removeValue(forKey: key) }
    /// RENDERFREEZE2: keys the prewarm builds first, most recently asked first (`prioritizeRenderer`).
    private var priority: [String] = []
    func prioritize(_ key: String) {
        lock.lock(); priority.removeAll { $0 == key }; priority.insert(key, at: 0); lock.unlock()
    }
    /// The index in `keys` the prewarm builds next: the most recently prioritised key among them, else the first.
    func nextPrewarmIndex(_ keys: [String]) -> Int {
        lock.lock(); defer { lock.unlock() }
        for k in priority { if let i = keys.firstIndex(of: k) { return i } }
        return 0
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return table.count }
    /// FOLLOWUP-r31: the decoded sources, published as each one is decoded (kept: a source is small and is read
    /// again only on a re-rate, which replaces this store).
    private var sources: [String: SonificationSource] = [:]
    func putSource(_ s: SonificationSource) { lock.lock(); sources[s.key] = s; lock.unlock() }
    func source(forKey key: String) -> SonificationSource? { lock.lock(); defer { lock.unlock() }; return sources[key] }
}

// MARK: - Production output: the source node

@MainActor
final class SourceNodeOutput: LiveSonificationOutput {
    let node: AVAudioSourceNode
    let format: AVAudioFormat

    /// The host engine's start gate: the one start path for the shared engine.
    private let startGate: EngineStartGate

    /// The node's format is the kernel's rate (r31: the output hardware's), mono.
    init(kernel: LiveSonificationKernel, startGate: EngineStartGate) {
        self.startGate = startGate
        format = AVAudioFormat(standardFormatWithSampleRate: kernel.sampleRate, channels: 1)!
        node = Self.makeNode(kernel: kernel, format: format)
    }

    /// r31: a new kernel and node at `rate`, connected to the main mixer in this node's place (same pan); this
    /// node is disconnected and detached. Main actor, off the render path: AVAudioEngine reconnects a mixer input
    /// with the engine running or stopped. The old kernel stays retained (the render block's reference, by design).
    func replaced(atRate rate: Double) -> (LiveSonificationKernel, SourceNodeOutput) {
        let kernel = LiveSonificationKernel(sampleRate: rate)
        let next = SourceNodeOutput(kernel: kernel, startGate: startGate)
        guard let engine = node.engine else { return (kernel, next) }
        let pan = node.pan
        engine.disconnectNodeOutput(node)
        engine.detach(node)
        engine.attach(next.node)
        do { try engine.connectNode(next.node, to: engine.mainMixerNode, format: next.format) } catch {
            Logger(subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative", category: "LiveSonification")
                .error("Live sonification node reconnect failed: \(error.localizedDescription, privacy: .public)")
        }
        next.node.pan = pan
        return (kernel, next)
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

    /// SDK27 (2026-11-24, seat ruling 1): through the host's `EngineStartGate`
    /// (asynchronous activation, then the start), not a synchronous
    /// `setActive(true)` + `engine.start()` here: that blocked the main thread
    /// and, at a cold launch, overtook the host's launch activation.
    func startIfNeeded(then: (@MainActor () -> Void)?) {
        guard node.engine != nil else { return }
        startGate.whenRunning(then)
    }

    func performSessionWork(_ work: @escaping @Sendable () -> Void) { startGate.performSessionWork(work) }

    func setPan(_ pan: Float) { node.pan = pan }
}
