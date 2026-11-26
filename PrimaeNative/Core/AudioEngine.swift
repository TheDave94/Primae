import AVFoundation
import Foundation
import OSLog
import Synchronization

@MainActor
public final class AudioEngine: AudioControlling, CustomStringConvertible {

    // MARK: - Observer store (Mutex-protected for nonisolated deinit access)

    private typealias ObserverTasks = (interruption: Task<Void, Never>, routeChange: Task<Void, Never>)
    // `nonisolated` is load-bearing: the nonisolated deinit needs the store outside the main actor
    // (the default isolation). SDK27 (2026-11-24): plain `nonisolated`, not `nonisolated(unsafe)` —
    // `Mutex` is Sendable, so the compiler proves the access safe and the `(unsafe)` escape was
    // unnecessary (its warning was right, not a false positive). The deinit pattern is unchanged.
    private nonisolated static let observerStore = Mutex<[ObjectIdentifier: ObserverTasks]>([:])

    // MARK: - Private state

    private let engine     = AVAudioEngine()
    private let player     = AVAudioPlayerNode()
    private let timePitch  = AVAudioUnitTimePitch()
    private var currentFile: AVAudioFile?
    /// SDK27: the one start path for `engine` (see `EngineStartGate`). The
    /// live voice's source node renders into this engine, so it starts the
    /// engine through this same gate.
    private(set) lazy var startGate = EngineStartGate.production(for: engine, sessionPreparation: sessionPreparation)
    /// Session settings applied in the gate's off-main prepare, before the
    /// configuration and every activation (`SoundEnvelope.makeHostEngine`: the
    /// r17 IO buffer). nil: none.
    private let sessionPreparation: (@Sendable () -> Void)?

    private var shouldResumePlayback          = false
    private var appIsForeground               = true
    private var interrupted                   = false
    private var interruptionShouldResume      = true
    private var interruptionResumeGateRequired = false
    private var pendingLifecyclePauseTask: Task<Void, Error>?

    private let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
        category: "AudioEngine"
    )

    private(set) var isPlaying = false

    /// TEST-ONLY output tap. Armed ONLY when the process was launched with
    /// `-audioSignalProbe` (see `AudioSignalProbe`), so it is inert in the
    /// pilot artefact a child holds. It exists because every other audio
    /// assertion in the suite checks that `play()` was CALLED, which is a
    /// statement about intent rather than about the speaker: a failed
    /// engine start, an unresolved file or a muted route all pass those and
    /// leave the child in silence. This measures the samples.
    private let signalProbe = AudioSignalProbe()
    /// Non-nil when init failed to bring the audio stack up — VM toasts this
    /// at startup so a parent notices something is wrong instead of seeing
    /// the child poke a silent device. Stays nil after a healthy init.
    private(set) var initializationError: String? = nil

    /// SDK27: the launch start-up (configuration, activation, first start)
    /// has finished and `initializationError` is final.
    func settleStartup() async { await startGate.settle() }

    // MARK: - Tunable parameters (live-adjustable from the debug audio panel)

    /// Linear fade-out duration applied by `stop()` before the player is
    /// halted and the audio session deactivated. 0 reverts to the legacy
    /// abrupt-stop behaviour. Default ~120 ms keeps the cut from sounding
    /// like a chop without delaying the perceived stop noticeably.
    public var fadeOutSeconds: TimeInterval = 0.12

    /// Lower clamp for the time-stretch playback rate set by
    /// `setAdaptivePlayback(speed:_:)`. Slower than this and the audio
    /// becomes unintelligible muddy artefacts.
    public var minPlaybackRate: Float = 0.5

    /// Upper clamp for the time-stretch playback rate. Faster than this and
    /// the audio sounds like a chipmunk regardless of the AVAudioUnitTimePitch
    /// formant preservation.
    public var maxPlaybackRate: Float = 2.0

    /// Pitch shift applied to the time-stretched audio, in cents
    /// (AVAudioUnitTimePitch.pitch). Default 0 = unshifted.
    public var pitchCents: Float {
        get { timePitch.pitch }
        set { timePitch.pitch = newValue }
    }

    /// In-flight fade-out task. Cancelled (and player.volume restored) by
    /// any subsequent `play()` so a quick re-tap during a fade plays at
    /// full volume instead of resuming mid-ramp.
    private var fadeOutTask: Task<Void, Never>?
    /// True only while a `stop()` fade-out is in flight (`fadeOutTask` also holds the fade-IN ramp).
    private var isFadingOut = false

    /// Per-file loudness gain for `currentFile` (ruling AE-2, 2026-09-06;
    /// computed by AudioEngine+Loudness at load). "Full volume" for the
    /// player is THIS value, not 1.0, so every file plays at one RMS.
    private(set) var loudnessGain: Float = 1.0

    // MARK: - Debug accessors

    #if DEBUG
    var debugInterrupted:                  Bool { interrupted }
    var debugInterruptionShouldResume:     Bool { interruptionShouldResume }
    var debugIsEngineRunning:              Bool { engine.isRunning }
    var debugShouldResumePlayback:         Bool { shouldResumePlayback }
    var debugIsFadingOut:                  Bool { isFadingOut }
    var debugHasCurrentFile:               Bool { currentFile != nil }
    var debugAppIsForeground:              Bool { appIsForeground }
    var debugInterruptionResumeGateRequired: Bool { interruptionResumeGateRequired }
    #endif

    // MARK: - Init / deinit

    public init(sessionPreparation: (@Sendable () -> Void)? = nil) {
        self.sessionPreparation = sessionPreparation
        engine.attach(player)
        engine.attach(timePitch)
        // SDK27: `connectNode` (iOS 27) throws where the deprecated `connect`
        // raised an Objective-C exception. A failure is logged and surfaced as
        // the init toast instead of ending the process.
        do {
            try engine.connectNode(player,    to: timePitch,            format: engine.mainMixerNode.outputFormat(forBus: 0))
            try engine.connectNode(timePitch, to: engine.mainMixerNode, format: engine.mainMixerNode.outputFormat(forBus: 0))
        } catch {
            initializationError = "Audio nicht verfügbar"
            log.error("Audio graph connect failed: \(error.localizedDescription)")
        }
        player.prepare(withFrameCount: 1024)
        timePitch.rate = 1.0; timePitch.pitch = 0.0

        // ARM THE MEASUREMENT TAP HERE, not in `startIfNeeded`.
        //
        // MEASURED 2026-10-16, and it cost a whole diagnosis: `arm(on:)` refuses
        // when `engine.isRunning`, and its only caller was `startIfNeeded`,
        // which itself returns early when the engine is ALREADY running. So any
        // path that started the engine first — a warm-up, a pretest, a resume —
        // left the tap UNINSTALLED, and the probe reported
        // `nonSilent=0 total=0 peak=0.0` over audio the proctor could HEAR.
        // The red `MeasuredAudioUITests` was therefore a false failure caused by
        // its own instrument. Installing at construction is the one point that is
        // always before the first start (`installTap` after a start is the
        // documented crash), so the tap exists for every start path.
        if AudioSignalProbe.isArmedByLaunchArgument {
            signalProbe.arm(on: engine)
        }

        // SDK27 (2026-11-24, seat ruling 1): EVERY start of this engine —
        // this launch start, `startIfNeeded`, and the live voice's
        // `SourceNodeOutput` — goes through `startGate`, which configures the
        // session OFF the main thread and orders the start after iOS 27's
        // asynchronous `activate(options:)` has completed. No session call
        // blocks the main thread, and no synchronous start can overtake the
        // launch activation (measured on the iPad before the gate:
        // `engine.firstStart alreadyRunning=true` in both sound arms). A
        // failed activation is still logged (2026-09-15). A failed
        // configuration or FIRST start still surfaces the init toast; it now
        // lands after `init` returns, and the VM awaits `settleStartup()`
        // before reading it.
        startGate.onPrepareFailure = { [weak self] error in
            guard let self else { return }
            self.isPlaying            = false
            self.shouldResumePlayback = false
            self.initializationError  = "Audio nicht verfügbar"
            self.log.error("AVAudioSession config failed: \(error.localizedDescription)")
        }
        startGate.onStartFailure = { [weak self] _ in
            guard let self else { return }
            self.player.stop()
            self.isPlaying             = false
            self.shouldResumePlayback  = false
            if self.startGate.startCount == 0 {
                self.initializationError = "Ton konnte nicht gestartet werden"
            }
        }
        startGate.whenRunning()

        let key = ObjectIdentifier(self)

        // Tasks inherit @MainActor isolation from init context.
        // [weak self] is still correct — these tasks are long-lived observers.
        //
        // SDK27 (2026-11-24): the events come from iOS 27's didBecomeInactive /
        // resumptionRecommendation pair through `AudioSessionInterruption` (the
        // deprecated interruption notification and its InterruptionType /
        // InterruptionOptions payload are no longer read). One observer per
        // name, both ended with this one task (`AudioSessionInterruption.observe`),
        // so the observer store and `deinit` keep their shape; registered here,
        // synchronously. The branches below are unchanged.
        let interruptionTask = AudioSessionInterruption.observe(on: .default) { [weak self] event in
                    guard let self else { return false }
                    if event == .began {
                        // READ THE RESUME INTENT BEFORE THIS BRANCH CHANGES
                        // ANY STATE, and pass it in explicitly.
                        //
                        // Until 2026-09-20 this line was
                        // `self.isPlaying = false` followed by
                        // `self.handleInterruptionBegan()`, whose first act
                        // was `let savedResumeIntent = isPlaying` — so the
                        // intent was ALWAYS captured as false no matter what
                        // was actually playing. `stop()` →
                        // `finishStop()` then cleared `shouldResumePlayback`
                        // and the function restored the false back over it,
                        // leaving `canResumePlayback()` to refuse and
                        // `attemptResumePlayback()` to take its pause branch.
                        // Playback did not resume after an interruption —
                        // measured on hardware 2026-09-20, and the same
                        // defect the R5-era test comment calls "the
                        // 2026-09-15 regression".
                        //
                        // Passing the intent as a parameter is the fix the
                        // ruling asked for (the ordering, not the symptom):
                        // the dependency is now impossible to re-break
                        // silently by reordering statements above it.
                        // A sound already fading out has been stopped by its caller: no resume intent (C2, AUDIO-2).
                        self.handleInterruptionBegan(resumeIntent: self.isPlaying && !self.isFadingOut)
                    } else if self.shouldResumePlayback, self.currentFile != nil {
                        if self.canResumePlayback() { self.attemptResumePlayback() }
                    }
                    self.handleInterruptionValues(event)
                    return true
        }

        let routeChangeTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(
                named: AVAudioSession.routeChangeNotification, object: nil
            ) {
                guard let self else { return }
                let reasonValue = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                self.handleRouteChangeValue(reason: reasonValue)
            }
        }

        Self.observerStore.withLock {
            $0[key] = (interruption: interruptionTask, routeChange: routeChangeTask)
        }
    }

    nonisolated deinit { AudioEngine.removeObservers(for: self) }

    /// The session configuration every engine needs: `.playback`, `.default`,
    /// `.interruptSpokenAudioAndMixWithOthers`.
    ///
    /// SDK27 (2026-11-24): set only when the session is not already
    /// configured this way. `setCategory` has no asynchronous form, and on the
    /// main thread WHILE the session is active it is a runtime "Hang Risk"
    /// (measured on the iPad: one per engine constructed into an active
    /// session). At a cold launch the session is inactive and unconfigured,
    /// so this still sets it there; an engine built into an identically
    /// configured session has nothing to change. The options compare EQUAL:
    /// `.interruptSpokenAudioAndMixWithOthers` is itself 0x11, i.e. it
    /// carries the `.mixWithOthers` bit (a first version subtracted
    /// `.mixWithOthers` and so never matched; measured on the iPad, the
    /// warning stayed at one per engine).
    nonisolated static func configureSessionIfNeeded(_ session: AVAudioSession = .sharedInstance()) throws {
        let configured = session.category == .playback && session.mode == .default
            && session.categoryOptions == .interruptSpokenAudioAndMixWithOthers
        guard !configured else { return }
        try session.setCategory(.playback, mode: .default, options: [.interruptSpokenAudioAndMixWithOthers])
    }

    /// Test-only: hand the measured output level for the window just ended
    /// to the log, where an XCUI test on a real device can read it. A
    /// no-op unless the probe was launch-armed, so the pilot artefact
    /// never logs this.
    func emitAudioSignalSummary(label: String) {
        guard AudioSignalProbe.isArmedByLaunchArgument else { return }
        signalProbe.emitSummary(label: label)
        signalProbe.reset()
    }

    /// Timer backing `startAudioSignalTicker`. Main-actor because the
    /// engine is, and because `emitSummary` is.
    private var signalTicker: Timer?

    /// TEST-ONLY: see `AudioControlling.startAudioSignalTicker` for why
    /// this exists. A no-op unless launch-armed, so the pilot artefact
    /// never runs a timer.
    func startAudioSignalTicker(intervalSeconds: TimeInterval,
                               label: @escaping @MainActor () -> String) {
        guard AudioSignalProbe.isArmedByLaunchArgument else { return }
        stopAudioSignalTicker()
        // The label closure is read on EVERY tick, so a window is labelled
        // with the phase that was actually running when it closed.
        let tickerLabel = label
        let timer = Timer(timeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emitAudioSignalSummary(label: tickerLabel())

            }
        }
        // `.common` so the ticker keeps running while the child is
        // dragging: RunLoop.commonModes is what keeps a repeating timer
        // alive during scroll tracking, and this measures audio during
        // exactly that kind of interaction.
        RunLoop.main.add(timer, forMode: .common)
        signalTicker = timer
    }

    /// The latest measured `AUDIO-SIGNAL` line, for the XCUI test to read
    /// off the accessibility tree. See `AudioSignalProbe
    /// .latestSummaryLine` for why that is the channel.
    var latestAudioSignalSummary: String? { signalProbe.latestSummaryLine }

    /// TEST-ONLY: the engine's own state for the accessibility readout. A
    /// session that measured nothing and reported no route event left one
    /// question the probe could not answer — whether the engine could run at
    /// all — so the category and running state ride along with it.
    var debugAudioStateSummary: String {
        let cat = AVAudioSession.sharedInstance().category.rawValue
        return "cat=\(cat) run=\(engine.isRunning) playing=\(isPlaying) file=\(currentFile != nil)"
    }

    func stopAudioSignalTicker() {
        signalTicker?.invalidate()
        signalTicker = nil
    }

    /// Protocol r17: the live sonification node (`LiveSonificationAudio`)
    /// renders into THIS graph's main mixer, beside the player, so it shares
    /// the session, the route and the measurement tap. Graph wiring only;
    /// called once, at construction (`SoundEnvelope.makeAudioEngine`).
    func attachLiveSonificationNode(_ node: AVAudioNode, format: AVAudioFormat) {
        engine.attach(node)
        do { try engine.connectNode(node, to: engine.mainMixerNode, format: format) } catch {
            log.error("Live sonification node connect failed: \(error.localizedDescription)")
        }
    }

    // MARK: - AudioControlling

    func loadAudioFile(named fileName: String, autoplay: Bool = false) {
        guard let url = PrimaeBundle.audioURL(for: fileName) else {
            log.warning("Missing audio file: \(fileName)")
            return
        }
        do {
            // A stop() fade still ramping would otherwise run on to finishStop() and wipe
            // THIS load: nil currentFile, stop the player, clear isPlaying (R-072).
            fadeOutTask?.cancel()
            fadeOutTask = nil
            isFadingOut = false
            player.stop()
            currentFile = try AVAudioFile(forReading: url)
            loudnessGain = Self.loudnessGain(forFileAt: url)
            player.volume = loudnessGain
            prepareCurrentTrack()
            // Was `guard engine.isRunning else { startIfNeeded(); return }` —
            // that starts the engine and then unconditionally abandons THIS
            // load: autoplay is never set and attemptResumePlayback() never
            // runs for it, so the file loads and schedules but never
            // actually plays. `engine.isRunning` becomes false via
            // `pendingSafeEnginePause()` (~0.2s after it fires) — reached
            // from backgrounding, from an audio interruption beginning, or
            // from attemptResumePlayback's own "can't resume" branch; NOT
            // from an ordinary gap between two unrelated plays in the
            // foreground (checked directly — those three are the only
            // call sites). So this bites specifically on the next load
            // after a backgrounding/interruption cycle, or a repeat call
            // while resumption was already failing for some other reason
            // — narrower than "every gap," but real, and it silently
            // drops exactly the case a resume is supposed to restore.
            // Matches `play()`'s own `if !engine.isRunning { startIfNeeded() }`
            // below, which does NOT bail out — that's the correct shape
            // already proven elsewhere in this file; `startIfNeeded()`
            // itself still returns early (silently) when the session
            // genuinely can't start, so this doesn't force a play attempt
            // that couldn't have succeeded anyway.
            //
            // SDK27 (2026-11-24): the start is asynchronous now (`startGate`).
            // The intent is recorded at once and the play attempt waits for
            // the start inside `attemptResumePlayback`, so the load is still
            // not abandoned; a cold engine just plays once it runs.
            startIfNeeded()
            shouldResumePlayback = autoplay
            if autoplay { attemptResumePlayback() } else { isPlaying = false }
        } catch {
            player.stop()
            currentFile          = nil
            isPlaying            = false
            shouldResumePlayback = false
            log.error("Failed to load audio file \(fileName): \(error.localizedDescription)")
        }
    }

    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        guard speed.isFinite && horizontalBias.isFinite else { return }
        let clampedSpeed = max(minPlaybackRate, min(maxPlaybackRate, speed))
        if timePitch.rate != clampedSpeed { timePitch.rate = clampedSpeed }
        player.pan = max(-1.0, min(1.0, horizontalBias))
    }

    func play() {
        play(fadeInSeconds: 0)
    }

    /// Fade-IN counterpart to the existing `stop()` ramp (2026-10-02).
    /// Added rather than changing `play()`: the per-touch hot path calls
    /// `play()` on every stroke, and a ramp there would cost a Task per
    /// touch. Only the long demonstration playback asks for a fade, so the
    /// short path is untouched — this file is on the DO-NOT-MODIFY list and
    /// the addition is deliberately additive.
    func play(fadeInSeconds: TimeInterval) {
        guard currentFile != nil else { return }
        // Cancel any in-flight fade-out and restore full volume so a quick
        // re-tap while the previous stop is fading doesn't play at a half
        // volume snapshot mid-ramp.
        fadeOutTask?.cancel()
        fadeOutTask = nil
        isFadingOut = false
        player.volume = fadeInSeconds > 0 ? 0 : loudnessGain
        shouldResumePlayback           = true
        interruptionResumeGateRequired = false
        interruptionShouldResume       = true
        // An explicit play() is the user's intent and outranks a stale
        // interruption flag: iOS does not guarantee an `.ended`
        // notification for every `.began` (an interruption that started
        // while the app was suspended arrives as `.began` on resume with
        // no `.ended`), and `interrupted` was otherwise cleared only by
        // `.ended` — leaving every later play() refused for the rest of
        // the session, both sound arms silent, nothing in the export
        // (audit 2026-09-06, R5).
        interrupted                    = false
        // Was a synchronous `setActive(true)` here (Xcode "AVAudioSession
        // Hang Risk": can block the main thread while the session is
        // active). `play()` is the hot path — it runs on every touch that
        // triggers audio during a session — and by the time it runs the
        // session is virtually always ALREADY active: AudioEngine
        // activates once at init and this file never deactivates it
        // outside a lifecycle suspend (see `stop()`'s doc comment), so
        // this call is a redundant reactivation on every tap, not a real
        // state transition. Safe to fire off-main without waiting: if the
        // engine genuinely isn't running, `attemptResumePlayback()` right
        // below starts it through `startGate`, which orders the start after
        // its OWN completed activation (SDK27) — that ordering guarantee is
        // preserved exactly where it's actually load-bearing, this call
        // just stops being the thing that blocks every ordinary tap for it.
        let sessionLogger = log
        // SDK27: iOS 27's asynchronous `activate(options:)`, awaited for real
        // (the old `try await setActive(true)` awaited a synchronous call).
        Task.detached(priority: .userInitiated) {
            do {
                _ = try await AVAudioSession.sharedInstance().activate(options: [])
            } catch {
                sessionLogger.error("Failed to activate audio session (async): \(error.localizedDescription)")
            }
        }
        attemptResumePlayback()   // starts the engine first when it is not running (SDK27: through startGate)
        // Ramp to full volume only when asked. Reuses the SAME task slot
        // as the fade-out so a stop() arriving mid-fade-in cancels the
        // ramp instead of the two fighting over `player.volume` — the
        // reason the fade-out owns a cancellable slot at all.
        guard fadeInSeconds > 0 else { return }
        let duration = fadeInSeconds
        let target = loudnessGain
        fadeOutTask = Task { [weak self] in
            guard let self else { return }
            let steps = max(4, Int(duration * 60))
            let interval = duration / Double(steps)
            for i in 1...steps {
                if Task.isCancelled { return }
                self.player.volume = target * Float(i) / Float(steps)
                try? await Task.sleep(for: .seconds(interval))
            }
            if Task.isCancelled { return }
            self.player.volume = target
        }
    }

    func stop() {
        // Cancel any prior fade-out so back-to-back stop()s don't pile up
        // ramp tasks competing on player.volume.
        fadeOutTask?.cancel()
        fadeOutTask = nil

        let needsFade = fadeOutSeconds > 0 && isPlaying && engine.isRunning && player.isPlaying
        let startVolume = player.volume

        guard needsFade else {
            finishStop(restoreVolume: startVolume)
            return
        }

        // Linear fade ramp on player.volume → 0, then complete the existing
        // stop sequence. ~60 Hz step rate is smooth without saturating the
        // main actor; minimum 4 steps so very-short fades still ramp.
        let duration = fadeOutSeconds
        isFadingOut = true
        fadeOutTask = Task { [weak self] in
            guard let self else { return }
            let steps = max(4, Int(duration * 60))
            let interval = duration / Double(steps)
            for i in 1...steps {
                if Task.isCancelled { return }
                let progress = Float(i) / Float(steps)
                self.player.volume = startVolume * (1 - progress)
                try? await Task.sleep(for: .seconds(interval))
            }
            if Task.isCancelled { return }
            self.finishStop(restoreVolume: startVolume)
        }
    }

    /// Synchronous tail of `stop()` — runs after the optional fade ramp
    /// completes (or immediately when no fade is needed). Restores
    /// `player.volume` so the next `play()` doesn't start at the faded value.
    ///
    /// Intentionally does NOT call `setActive(false)` on the shared
    /// AVAudioSession. `stop()` fires every time the user lifts a
    /// finger from the canvas (and on phase / letter transitions);
    /// deactivating the shared session at that frequency cut every
    /// in-flight `AVSpeechSynthesizer` utterance short, because the
    /// synth shares this session by default. The session stays
    /// active for AudioEngine's lifetime — `suspendForLifecycle` and
    /// the deinit observer-cleanup handle the genuinely-needed
    /// teardown points (background, interruption, dealloc).
    private func finishStop(restoreVolume: Float) {
        shouldResumePlayback           = false
        isPlaying                      = false
        interruptionResumeGateRequired = false
        isFadingOut                    = false
        cancelPendingLifecycleWork()
        player.reset()
        player.stop()
        // Flush the ~93 ms the time-pitch unit still holds: the volume below is applied after it,
        // so that audio would otherwise play at full level after the fade (C1, AUDIO-1).
        timePitch.reset()
        player.volume = restoreVolume
        currentFile = nil
    }

    func restart() {
        shouldResumePlayback           = true
        interruptionResumeGateRequired = false
        interruptionShouldResume       = true
        if let file = currentFile { player.stop(); player.scheduleFile(file, at: nil, completionHandler: nil) }
        attemptResumePlayback()
    }

    func suspendForLifecycle() {
        appIsForeground      = false
        cancelPendingLifecycleWork()
        shouldResumePlayback = isPlaying || player.isPlaying
        player.pause()
        isPlaying = false
        pendingSafeEnginePause()
    }

    func resumeAfterLifecycle() {
        // DEFECT (2026-09-15): `appIsForeground` used to flip back to true
        // only AFTER this early-return guard. `currentFile` is nil almost
        // always between strokes (finishStop(), the tail of every stop(),
        // nils it), so any scene-phase blip — Control Center, a
        // notification banner, the app switcher, screen lock — that fires
        // suspend/resume while no file is loaded left `appIsForeground`
        // stuck false for the rest of the process: `canResumePlayback()`
        // gates on it, so every later play attempt in both sound arms was
        // silently refused while `isPlaying` kept reading true. Set it
        // unconditionally, before the guard, so a foreground transition is
        // always recorded regardless of what's currently loaded.
        appIsForeground = true
        // Before the guard: with no file loaded the suspend's pending engine pause must die too (C3, AUDIO-6).
        cancelPendingLifecycleWork()
        guard let resumedFile = currentFile else { shouldResumePlayback = false; return }
        // SDK27: the engine starts asynchronously (`startGate`); the resume
        // runs once it is running, for the file loaded NOW (a stop or another
        // load in between ends this resume, as it would have before).
        startIfNeeded { [weak self] in
            guard let self, let file = self.currentFile, file === resumedFile else { return }
            if !self.player.isPlaying {
                self.player.scheduleFile(file, at: nil, completionHandler: nil)
            }
            if self.canResumePlayback() && self.appIsForeground {
                do { try self.player.playAudio(); self.isPlaying = true } catch {   // SDK27: throws where play() raised
                    self.log.error("Player failed to resume: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelPendingLifecycleWork() {
        pendingLifecyclePauseTask?.cancel()
        pendingLifecyclePauseTask = nil
    }

    public nonisolated var description: String { "<AudioEngine>" }
}

// MARK: - Private helpers

private extension AudioEngine {

    nonisolated static func removeObservers(for object: AnyObject) {
        let key   = ObjectIdentifier(object)
        let tasks = observerStore.withLock { $0.removeValue(forKey: key) }
        tasks?.interruption.cancel()
        tasks?.routeChange.cancel()
    }

    /// Starts the engine if it is not running and runs `then` once it runs
    /// (immediately when it already does). The tap is armed in `init` (see
    /// the note there) — arming it here meant it never happened on any path
    /// that started the engine first.
    ///
    /// SDK27 (2026-11-24, seat ruling 1): this was a synchronous
    /// `setActive(true)` then `engine.start()` on the main thread, kept so
    /// because its callers read `engine.isRunning` right after it (the
    /// 2026-09-15 don't-abandon-the-play fix). On iOS 27 that blocking
    /// activation is a runtime "UI unresponsiveness" issue, and at a cold
    /// launch it overtook `init`'s asynchronous activation. The start now
    /// goes through `startGate` (activation completed first, always), and
    /// the 2026-09-15 contract is kept as the continuation: a caller passes
    /// what must happen once the engine runs instead of reading `isRunning`.
    /// A failed configuration or start: `then` is dropped, as
    /// the synchronous version returned without playing. A failed start
    /// resets the player state (`startGate.onStartFailure`, set in `init`).
    func startIfNeeded(then: (@MainActor () -> Void)? = nil) {
        startGate.whenRunning(then)
    }

    func canResumePlayback() -> Bool {
        appIsForeground && !interrupted && shouldResumePlayback
            && (!interruptionResumeGateRequired || interruptionShouldResume)
    }

    func attemptResumePlayback() {
        // Same fix, same reason as loadAudioFile: don't start the engine
        // and then abandon the resume attempt. This is the function that
        // actually calls player.play() (interruption-ended, route-change,
        // resumeAfterLifecycle, and play() itself all funnel through it),
        // so the old shape here was the most consequential copy of the bug.
        // SDK27: the start is asynchronous (`startGate`); the attempt is
        // re-run once the engine runs, reading the state as it is THEN.
        guard engine.isRunning else {
            startIfNeeded { [weak self] in self?.attemptResumePlayback() }
            return
        }
        guard currentFile != nil else { return }
        prepareCurrentTrack()
        guard canResumePlayback() else {
            player.pause()
            isPlaying = false
            pendingSafeEnginePause()
            return
        }
        if !player.isPlaying {
            do { try player.playAudio() } catch {   // SDK27: throws where play() raised
                log.error("Player failed to resume: \(error.localizedDescription)")
                return
            }
        }
        isPlaying = true
    }

    func prepareCurrentTrack() {
        guard let currentFile else { return }
        player.stop()
        scheduleLooping(file: currentFile)
        isPlaying = false
    }

    /// SDK27 (2026-11-24): `.dataRendered`, not `.dataPlayedBack`. Measured
    /// on the iPad (one probe per callback type): a `.dataPlayedBack` file
    /// made the next `player.stop()`, and a schedule onto a stopped engine,
    /// block the main thread on a Default-QoS thread ("[Internal] Thread
    /// running at User-interactive quality-of-service class waiting on a
    /// lower QoS thread"); `.dataRendered` and `.dataConsumed` did not.
    /// `.dataRendered` fires when the file has been rendered, earlier than
    /// `.dataPlayedBack` only by the output latency, so the loop restarts at
    /// the same point within a few milliseconds.
    private func scheduleLooping(file: AVAudioFile) {
        player.scheduleFile(file, at: nil, completionCallbackType: .dataRendered) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.shouldResumePlayback, let f = self.currentFile else { return }
                f.framePosition = 0
                self.scheduleLooping(file: f)
            }
        }
    }

    func pendingSafeEnginePause() {
        cancelPendingLifecycleWork()
        pendingLifecyclePauseTask = Task { [weak self] in
            try await Task.sleep(for: .seconds(0.2))
            guard let self, !Task.isCancelled, !self.isPlaying else { return }
            self.engine.pause()
        }
    }

    func stopAndReset() {
        player.stop()
        engine.stop()
        currentFile                    = nil
        shouldResumePlayback           = false
        appIsForeground                = true
        interrupted                    = false
        interruptionShouldResume       = true
        interruptionResumeGateRequired = false
        cancelPendingLifecycleWork()
        isPlaying = false
    }

    /// - Parameter resumeIntent: whether playback was active immediately
    ///   BEFORE the interruption, captured by the caller before it applies
    ///   any state changes. It cannot be read here: by the time this runs
    ///   the interruption is already being handled. See the caller's
    ///   comment for the defect this parameter exists to make unrepeatable.
    func handleInterruptionBegan(resumeIntent: Bool) {
        let savedResumeIntent = resumeIntent
        // Hold the loaded file across the stop() below, for the same reason
        // and by the same shape as `resumeIntent` above: read BEFORE the
        // state-clearing call, restored after.
        //
        // `stop()` routes to `finishStop()`, which sets `currentFile = nil`.
        // That is right for its other callers — a finger-lift ends playback
        // and the next `play()` loads afresh — but an INTERRUPTION is not
        // the user stopping playback: we intend to resume the same sound,
        // and there must be something left to resume. Measured 2026-09-21:
        // with the file gone, `attemptResumePlayback()` restarted the engine
        // and then bailed at its `currentFile != nil` guard, leaving
        // `isPlaying` false with no pause scheduled, so playback never came
        // back after an interruption (and `play()`'s own `currentFile != nil`
        // guard meant the R5 stale-flag fix could not reach that case
        // either).
        //
        // Deliberately NOT changing `finishStop()` to skip clearing the file
        // under some flag: that is the stale-flag-dependent branching that
        // produced the defect this file was just fixed for. `stop()` and
        // `finishStop()` keep their meaning for every other caller; only what
        // an INTERRUPTION discards changes here.
        let file = currentFile
        player.pause()
        isPlaying = false
        stop()
        currentFile = file
        // Restore resume intent — stop() clears shouldResumePlayback,
        // but we need it preserved so playback resumes after interruption ends.
        shouldResumePlayback = savedResumeIntent
    }

    func handleInterruptionValues(_ event: AudioSessionInterruption) {
        // handleInterruptionValues is always called from the @MainActor observer Task.
        // The Thread.isMainThread guard is removed — we are always on MainActor here.
        switch event {
        case .began:
            interrupted                    = true
            interruptionResumeGateRequired = true
            interruptionShouldResume       = false
            player.pause()
            isPlaying = false
            pendingSafeEnginePause()

        case .ended(let shouldResume):
            interrupted = false
            interruptionShouldResume = shouldResume
            if interruptionShouldResume { attemptResumePlayback() }
        }
    }

    func handleRouteChangeValue(reason reasonValue: UInt?) {
        guard let reasonValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        switch reason {
        case .oldDeviceUnavailable:
            stop()
        case .newDeviceAvailable, .categoryChange, .override,
             .routeConfigurationChange, .wakeFromSleep, .noSuitableRouteForCategory:
            // Only resume if we were actually playing — otherwise attemptResumePlayback
            // falls into its !canResumePlayback() branch and schedules
            // pendingSafeEnginePause(), which pauses the engine 0.2s later.
            // That killed all audio when the user connected AirPods while idle.
            if appIsForeground && !interrupted && shouldResumePlayback { attemptResumePlayback() }
        default:
            break
        }
    }
}
