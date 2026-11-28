// NOTE: Intentionally uses XCTest — requires real hardware (XCTSkip in setUp), uses expectation/wait. Do not migrate to Swift Testing.
//
// Tests exercise AudioEngine directly via forged AVAudioSession notification userInfo payloads,
// asserting state machine transitions on isPlaying and #if DEBUG accessors.
//
// NOTIFICATION DELIVERY IS ASYNCHRONOUS — READ `postInterruption` BEFORE ADDING A TEST HERE.
// AudioEngine observes via a Swift-concurrency `for await` sequence, which a RunLoop pump does
// NOT service, so `postInterruption`/`postRouteChange` are `async` and MUST be awaited before
// asserting on state they are supposed to change. The note that used to stand here claimed the
// observers were "on .main queue" and that `drainMain()` "is sufficient to flush synchronous
// delivery" — MEASURED WRONG on device 2026-09-20, and the reason several tests in this file
// were reading state from before their own notification landed.

import XCTest
import AVFoundation
@testable import PrimaeNative

final class AudioEngineTests: XCTestCase {

    private var engine: AudioEngine?

    // MARK: - Session setup
    // SDK27 (2026-11-24): no class-level `setCategory` / `setActive(true)` /
    // `setActive(false)` any more. Each was a synchronous session call on the
    // main thread (a runtime "Hang Risk" on iOS 27), and both are now the
    // engine's own job: `AudioEngine.init` configures the category, and every
    // start activates through `startGate`'s asynchronous `activate(options:)`
    // (awaited in `setUp` below).

    // MARK: - Instance setup

    @MainActor override func setUp() async throws {
        // Do NOT call super.setUp(): XCTestCase.setUp() is `async throws` in Swift 6,
        // but calling it via `try await` from @MainActor triggers "sending non-Sendable
        // XCTestCase" and without `try await` triggers "call can throw/is async". The
        // default implementation is a no-op so omitting the super call is safe.
        continueAfterFailure = false
        // Guard: skip on headless CI — AVAudioEngine crashes AudioConverterService in simulator
        #if targetEnvironment(simulator)
        throw XCTSkip("AudioEngine tests require real hardware — skipped in simulator")
        #else
        guard AVAudioSession.sharedInstance().isOtherAudioPlaying || !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty else {
            throw XCTSkip("AVAudioSession has no viable route on this runner")
        }
        #endif
        // setUp is async throws so @MainActor isolation is preserved for this @MainActor class.
        engine = AudioEngine()
        // Ensure AVAudioEngine is in a known running state before any test that checks isRunning.
        // SDK27: init starts it through `startGate` after an ASYNCHRONOUS session activation, so
        // wait for that start here; every test then begins with the engine running, as the
        // synchronous start used to leave it.
        await engine?.startGate.settle()
        engine?.resumeAfterLifecycle()

        // HARDENING (2026-09-21; corrected 2026-10-04 against the device logs).
        //
        // Measured 2026-09-21: this class's interruption-recovery test
        // completes in ~2 s when it passes, but force its assertion to fail
        // with `continueAfterFailure = false` and the whole test host hangs —
        // xcodebuild never returned and had to be killed (rc=137 at a 90 s
        // bound).
        //
        // The teardown block below was added to quiesce the engine however
        // the body exited. IT DOES NOT PREVENT THE WEDGE BY ITSELF — measured
        // on the physical iPad, Debug-Study, 2026-10-01:
        //   - hardening-verify-7: with this block in place, the forced
        //     failure was recorded (`AudioEngineTests.swift:450: … FORCED
        //     FAILURE`) and the run then hung until the 240 s watchdog
        //     killed it; no "Test Case … failed" line was ever printed.
        //   - hardening-verify-8: the same forced failure with
        //     `continueAfterFailure = true` set at the start of the test was
        //     recorded and the test FINISHED — "Executed 1 test, with 1
        //     failure … in 2.386 s". That run's later hang was the UI-test
        //     runner install (a stale runner signed by team XMX37BH48B on the
        //     iPad, "rejecting upgrade"), not this test.
        // Hence `continueAfterFailure = true` at the start of every async
        // interruption test below. This block stays as belt-and-braces; it is
        // not a demonstrated guarantee, and one clean re-run of the forced
        // failure (stale runner removed, unit tests only) would settle it.
        addTeardownBlock { @MainActor [weak self] in
            guard let self else { return }
            // Cancel the pending pause/resume work, then stop playback — so
            // no Task is left holding a reference or mid-await when the
            // engine is freed. `stopAndReset()` (which also halts the
            // underlying AVAudioEngine) is fileprivate to AudioEngine.swift;
            // `stop()` is the accessible equivalent minus that one call, and
            // the engine left running matches the normal tearDown path below.
            self.engine?.cancelPendingLifecycleWork()
            self.engine?.stop()
            self.engine = nil
            // Then let the main actor actually run those cancellations to
            // completion before the host moves on.
            try? await Task.sleep(for: .milliseconds(300))
        }
    }

    @MainActor override func tearDown() async throws {
        // Cancel any pending debounce work before nil-ing engine to avoid DispatchWorkItem
        // firing after tearDown on a deallocated engine.
        engine?.cancelPendingLifecycleWork()
        engine = nil
        // Do NOT call super.tearDown() — same reason as setUp() above.
    }

    // MARK: - Direct methods: stop() / play() / restart()
    #if DEBUG

    // D1 (audit AUDIO-6): the stop / route / suspend tests below used to run
    // against an engine that never played, so `isPlaying == false` held
    // whether or not the code under test did anything (three mutations of
    // stop(), route loss and suspend all survived). Each now STARTS REAL
    // PLAYBACK first and asserts it as a precondition.
    @MainActor private func startRealPlayback(_ engine: AudioEngine) {
        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertTrue(engine.isPlaying, "precondition: playback started")
    }

    @MainActor func testStop_setsIsPlayingFalse() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        startRealPlayback(engine)
        engine.stop()
        await awaitObserverDelivery()   // past the fade-out ramp
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback)
    }

    @MainActor func testStop_isIdempotent() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        startRealPlayback(engine)
        engine.stop()
        engine.stop()
        await awaitObserverDelivery()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback)
    }

    /// R-072: a load that arrives while a `stop()` fade-out is still ramping
    /// must survive the fade's completion. The fade task used to run on to
    /// `finishStop()`, which nils `currentFile`, stops the player and clears
    /// `isPlaying` — silently wiping the newer `loadAudioFile(autoplay: true)`.
    @MainActor func testLoadDuringStopFade_isNotWipedByFadeCompletion() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        startRealPlayback(engine)
        engine.stop()
        XCTAssertTrue(engine.debugIsFadingOut, "precondition: stop() started a fade-out")
        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertTrue(engine.isPlaying, "precondition: the new load started playback")
        XCTAssertFalse(engine.debugIsFadingOut, "a new load ends the stale fade-out")
        // Well past the 0.12 s ramp: a surviving fade task would have run finishStop() by now.
        try await Task.sleep(for: .seconds(Double(engine.fadeOutSeconds) + 0.4))
        XCTAssertTrue(engine.isPlaying, "the stale fade's finishStop() wiped the new load")
        XCTAssertTrue(engine.debugShouldResumePlayback)
        XCTAssertTrue(engine.debugHasCurrentFile, "the stale fade's finishStop() nilled the new file")
    }

    /// `play()` opens with `guard currentFile != nil else { return }`: with no
    /// file it is a no-op. (This test used to assert the opposite and was
    /// stale since that guard went in.)
    @MainActor func testPlay_withNoFile_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.play()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback,
                       "play() with no loaded file must be a no-op and set no resume intent")
    }

    @MainActor func testRestart_withNoFile_doesNotCrashAndSetsShouldResume() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // restart() is a distinct code path: clears gate flags, calls prepareCurrentTrack, attemptResumePlayback
        engine.restart()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(engine.debugShouldResumePlayback,
                      "restart() must set shouldResumePlayback=true")
        XCTAssertFalse(engine.debugInterruptionResumeGateRequired,
                       "restart() must clear interruptionResumeGateRequired")
    }

    // MARK: - loadAudioFile edge cases

    @MainActor func testLoadAudioFile_missingFile_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: "nonexistent_totally_fake_file_xyz.mp3", autoplay: false)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback)
    }

    /// AE-2: the loaded file's gain reaches the engine (the carrier is the
    /// target, so unity); a missing file leaves the previous gain alone.
    #endif
    @MainActor func testLoadAudioFile_setsLoudnessGain() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: false)
        XCTAssertEqual(engine.loudnessGain, 1.0, accuracy: 0.02,
                       "the carrier defines the loudness target and must play at unity")
    }

    @MainActor func testLoadAudioFile_missingFile_autoplayTrue_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // autoplay=true with missing file must not crash or corrupt state
        engine.loadAudioFile(named: "nonexistent_totally_fake_file_xyz.mp3", autoplay: true)
        XCTAssertFalse(engine.isPlaying)
        // shouldResumePlayback is only set inside the do-block after successful file open,
        // so missing file leaves it unchanged from prior state.
    }

    // MARK: - Interruption: .began
    #if DEBUG

    @MainActor func testInterruptionBegan_stopsPlayback() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        await postInterruption(type: .began)
        XCTAssertFalse(engine.isPlaying, "isPlaying must be false after interruption began")
        XCTAssertTrue(engine.debugInterrupted, "interrupted flag must be set")
        XCTAssertFalse(engine.debugInterruptionShouldResume,
                       "interruptionShouldResume must be false after .began")
        XCTAssertTrue(engine.debugInterruptionResumeGateRequired,
                      "interruptionResumeGateRequired must be set after .began")
    }

    /// R5 (audit 2026-09-06): iOS does not guarantee an `.ended` for every
    /// `.began`. A `play()` after an un-ended `.began` is the user's intent
    /// and must clear `interrupted`; otherwise every later play() in the
    /// session is refused and both sound arms go silent with no trace.
    ///
    /// A FILE MUST BE LOADED FIRST, and this test never did — which is why it
    /// failed on hardware the first time it was ever run (2026-09-21). `play()`
    /// opens with `guard currentFile != nil else { return }`, so with no file
    /// it returns before reaching the very line this test exists to check,
    /// and `interrupted` is left set. The fix it guards was correct the whole
    /// time; the test was asserting a consequence of a code path it never
    /// entered. Loading the carrier puts it on the path the child's own touch
    /// takes.
    @MainActor func testPlayAfterBeganWithoutEnded_clearsInterrupted() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertTrue(engine.isPlaying, "precondition: playback started")

        await postInterruption(type: .began)
        XCTAssertTrue(engine.debugInterrupted, "precondition: .began sets interrupted")
        engine.play()
        XCTAssertFalse(engine.debugInterrupted,
                       "play() must clear a stale interrupted flag (no .ended arrived)")
        XCTAssertTrue(engine.debugShouldResumePlayback)
        XCTAssertFalse(engine.debugInterruptionResumeGateRequired)
    }

    @MainActor func testInterruptionBegan_isIdempotent() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        await postInterruption(type: .began)
        let interruptedAfterFirst = engine.debugInterrupted
        await postInterruption(type: .began)
        XCTAssertEqual(engine.debugInterrupted, interruptedAfterFirst,
                       "Double .began must not corrupt interrupted flag")
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - Interruption: .ended

    @MainActor func testInterruptionEnded_shouldResumeFalse_remainsPaused() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        await postInterruption(type: .began)
        await postInterruption(type: .ended, shouldResume: false)
        XCTAssertFalse(engine.isPlaying, "Must stay paused when shouldResume=false")
        XCTAssertFalse(engine.debugInterrupted, "interrupted flag must clear on .ended")
        XCTAssertFalse(engine.debugInterruptionShouldResume,
                       "interruptionShouldResume must be false")
    }

    @MainActor func testInterruptionEnded_shouldResumeTrue_setsFlag() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        await postInterruption(type: .began)
        await postInterruption(type: .ended, shouldResume: true)
        // Even without a loaded file, the flag must reflect the system's intent
        XCTAssertFalse(engine.debugInterrupted, "interrupted must clear on .ended")
        XCTAssertTrue(engine.debugInterruptionShouldResume,
                      "interruptionShouldResume must be true when OS signals .shouldResume")
    }

    @MainActor func testInterruptionEnded_withoutPrecedingBegan_isHarmless() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        await postInterruption(type: .ended, shouldResume: true)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugInterrupted)
    }

    @MainActor func testInterruptionEnded_missingOptionKey_defaultsToNoResume() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // SDK27: a resumption recommendation with NO context object — the
        // iOS 27 counterpart of the old `.ended` without an options key.
        XCTAssertTrue(ForgedSessionNotifications.post(ForgedSessionNotifications.resumption(nil)))
        // The observer is a `for await` sequence: a run-loop pump cannot
        // deliver it (see `postInterruption`), so await it.
        await awaitObserverDelivery()
        XCTAssertFalse(engine.debugInterruptionShouldResume,
                       "Missing option key must default to shouldResume=false")
    }

    // MARK: - Route Change
    #endif

    @MainActor func testRouteChange_oldDeviceUnavailable_stopsPlayback() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertTrue(engine.isPlaying, "precondition: playback started")
        await postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertFalse(engine.isPlaying, "oldDeviceUnavailable must stop playback")
    }

    @MainActor func testRouteChange_oldDeviceUnavailable_isIdempotent() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertTrue(engine.isPlaying, "precondition: playback started")
        await postRouteChange(reason: .oldDeviceUnavailable)
        await postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertFalse(engine.isPlaying)
    }

    @MainActor func testRouteChange_newDeviceAvailable_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        await postRouteChange(reason: .newDeviceAvailable)
        XCTAssertFalse(engine.isPlaying) // no file; no shouldResume intent
    }

    @MainActor func testRouteChange_categoryChange_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        await postRouteChange(reason: .categoryChange)
        XCTAssertFalse(engine.isPlaying)
    }

    @MainActor func testRouteChange_wakeFromSleep_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        await postRouteChange(reason: .wakeFromSleep)
        XCTAssertFalse(engine.isPlaying)
    }

    @MainActor func testRouteChange_malformedUserInfo_isHarmless() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertTrue(engine.isPlaying, "precondition: playback started")
        // Missing reason key — guard in handleRouteChange must absorb this silently
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [:]
        )
        await awaitObserverDelivery()
        XCTAssertTrue(engine.isPlaying, "a malformed route change must not disturb playback")
    }

    // MARK: - Lifecycle
    #if DEBUG

    @MainActor func testSuspendForLifecycle_stopsPlayback() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        startRealPlayback(engine)
        engine.suspendForLifecycle()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugAppIsForeground)
    }

    @MainActor func testSuspendForLifecycle_isIdempotent() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        startRealPlayback(engine)
        engine.suspendForLifecycle()
        engine.suspendForLifecycle()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugAppIsForeground)
    }

    @MainActor func testResumeAfterLifecycle_setsAppIsForeground() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.resumeAfterLifecycle()
        XCTAssertTrue(engine.debugAppIsForeground)
    }

    // MARK: - appIsForeground stuck-false regression (2026-09-15)
    //
    // `resumeAfterLifecycle()` used to set `appIsForeground = true` AFTER
    // `guard currentFile != nil else { ...; return }`. `currentFile` is nil
    // almost always between strokes (finishStop() nils it on every stop()),
    // so a scene-phase blip with nothing loaded — Control Center, a
    // notification banner, the app switcher, screen lock — left
    // `appIsForeground` stuck false for the rest of the process:
    // `canResumePlayback()` gates on it, so every later play attempt in
    // both sound arms was silently refused. This test drives exactly that
    // sequence: suspend/resume with no file loaded, then load a file with
    // autoplay and confirm it actually plays, not just that the flag reads
    // true in isolation.

    @MainActor func testResumeAfterLifecycle_withNoFileLoaded_clearsStuckForegroundFlag() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // Precondition: no file loaded, matching the between-strokes state
        // that made this reachable in practice.
        engine.suspendForLifecycle()
        engine.resumeAfterLifecycle()
        XCTAssertTrue(engine.debugAppIsForeground,
                      "resumeAfterLifecycle() must clear appIsForeground even when currentFile is nil")

        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertTrue(engine.isPlaying,
                      "a play attempt after a no-file lifecycle blip must not be silently refused " +
                      "by a stuck appIsForeground=false — the 2026-09-15 regression")
    }
    #endif

    @MainActor func testSuspendThenResume_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.resumeAfterLifecycle()
        XCTAssertFalse(engine.isPlaying) // no file loaded
    }

    @MainActor func testCancelPendingLifecycleWork_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.cancelPendingLifecycleWork()
        engine.cancelPendingLifecycleWork()
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - pendingSafeEnginePause debounce
    //
    // These tests use a strong local reference (not [weak self]) to prevent tearDown
    // from nil-ing `engine` before the async closure asserts, which would cause
    // vacuous passes via nil-coalescing.
    #if DEBUG

    @MainActor func testPendingSafeEnginePause_firesAfterDelay() async throws {
        let localEngine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        localEngine.suspendForLifecycle()

        let exp = expectation(description: "AVAudioEngine pauses after 0.2s debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            XCTAssertFalse(localEngine.debugIsEngineRunning,
                           "AVAudioEngine must be paused after pendingSafeEnginePause fires")
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)
    }

    /// Pins FIXPLAN C3 (audit AUDIO-6): `resumeAfterLifecycle()` must cancel
    /// pending lifecycle work BEFORE its `guard currentFile != nil`, so a
    /// suspend/resume blip with no file loaded (the normal between-strokes
    /// state) does not pause the engine 0.2 s later.
    @MainActor func testPendingSafeEnginePause_cancelledByResume() async throws {
        let localEngine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        localEngine.suspendForLifecycle()
        // Immediately resume — DispatchWorkItem must be cancelled before it fires
        localEngine.resumeAfterLifecycle()

        let exp = expectation(description: "AVAudioEngine stays running when pause was cancelled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // Note: isRunning reflects whether the engine is started, not whether audio is playing.
            // After resume with no file, startIfNeeded() starts the engine so isRunning == true.
            XCTAssertTrue(localEngine.debugIsEngineRunning,
                          "AVAudioEngine must not be paused when resume cancelled the pending pause work item")
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.5)
    }

    // MARK: - SDK27: every engine start follows the asynchronous activation (seat ruling 1)
    //
    // Measured on the iPad before `EngineStartGate`: at a cold launch the
    // first sound reached a SYNCHRONOUS `setActive(true)` + `engine.start()`
    // before init's asynchronous activation had returned (capture
    // `engine.firstStart alreadyRunning=true`, both sound arms), and that
    // main-thread activation was Xcode's "UI unresponsiveness" issue. These
    // two drive a fresh engine (cold) and a fresh live voice on the real
    // graph: the start must NOT have happened synchronously, and the play
    // must still happen once the gate has activated and started — one
    // activation, one start, however many requests joined it.

    @MainActor func testColdEngine_loadAutoplay_startsOnlyAfterActivation_thenPlays() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let cold = AudioEngine()
        cold.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertFalse(cold.debugIsEngineRunning,
                       "the engine started synchronously, ahead of the asynchronous activation (the SDK27 race)")
        XCTAssertFalse(cold.isPlaying, "nothing can be playing before the engine runs")
        XCTAssertTrue(cold.startGate.isStarting, "the load must have joined the activation in flight")
        await cold.startGate.settle()
        XCTAssertTrue(cold.debugIsEngineRunning, "the gate must start the engine after the activation")
        XCTAssertTrue(cold.isPlaying, "the autoplay load must play once the engine runs (the 2026-09-15 contract)")
        XCTAssertEqual(cold.startGate.activationCount, 1, "init's start and the load's must share ONE activation")
        XCTAssertEqual(cold.startGate.startCount, 1)
        cold.stop()
    }

    @MainActor func testColdLiveVoice_loadAutoplay_startsOnlyAfterActivation_thenSounds() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let host = AudioEngine()
        let voice = LiveSonificationAudio.production(host: host, fadeOutSeconds: SoundEnvelope.fadeOutSeconds)
        voice.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertFalse(host.debugIsEngineRunning,
                       "the live voice started the shared engine synchronously, ahead of the activation (the SDK27 race)")
        XCTAssertFalse(voice.isPlaying, "the voice cannot sound before the engine runs")
        await host.startGate.settle()
        XCTAssertTrue(host.debugIsEngineRunning)
        // RENDERFREEZE (2026-11-28): the carrier's renderer is built off the main thread (0.63 s on the iPad when
        // the launch prewarm has not built it), so the autoplay sounds once the engine runs AND the renderer is
        // registered. Bounded at 60 s (Debug-Study, -Onone).
        for _ in 0..<1200 where !voice.awaitingRenderers.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(voice.awaitingRenderers.isEmpty, "the carrier's renderer was never registered")
        XCTAssertTrue(voice.isPlaying, "the autoplay load must sound once the engine runs and the renderer is ready")
        XCTAssertEqual(host.startGate.activationCount, 1, "the host's launch start and the voice's must share ONE activation")
        XCTAssertEqual(host.startGate.startCount, 1)
        voice.stop()
    }

    // MARK: - Resuming after the engine paused (2026-09-15 regression)
    //
    // `attemptResumePlayback()` (and `loadAudioFile()`, same shape, same
    // fix, not independently testable here — see below) had
    // `guard engine.isRunning else { startIfNeeded(); return }`. That
    // restarts AVAudioEngine and then UNCONDITIONALLY ABANDONS the call
    // that triggered it: player.play() never runs for it. The engine
    // comes back up, but nothing plays.
    //
    // `engine.isRunning` goes false via `pendingSafeEnginePause()`
    // (already covered by `testPendingSafeEnginePause_firesAfterDelay`
    // above), reachable from `fileprivate` code only through real
    // triggers — backgrounding, or an audio interruption. Interruption
    // recovery is the one this test drives, via the same
    // `postInterruption` helper the rest of this suite already uses,
    // because it's fully reachable through `internal` API and is the
    // best-precedented real scenario for "engine paused, then asked to
    // resume." `loadAudioFile`'s copy of the same bug isn't independently
    // driven by a test — every accessible way to pause the engine also
    // sets either `interrupted` or `appIsForeground` false, both of
    // which gate `canResumePlayback()` regardless of this fix, so it
    // can't be isolated from `attemptResumePlayback`'s own gating without
    // reaching into `fileprivate` state. Fixed by code-identical
    // reasoning and symmetry with the tested function, not blind.

    @MainActor func testAttemptResumePlayback_afterInterruptionPausesEngine_actuallyResumes() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: SpatialSonification.carrierToneFile, autoplay: true)
        XCTAssertTrue(engine.isPlaying, "precondition: playback started")

        await postInterruption(type: .began)
        // handleInterruptionValues' .began case schedules the same
        // pendingSafeEnginePause() idle-pause used everywhere else in
        // this file; wait past its 0.2s debounce so the engine is
        // actually paused, not mid-debounce, before ending the
        // interruption.
        let pausedExp = expectation(description: "AVAudioEngine pauses during the interruption")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { pausedExp.fulfill() }
        await fulfillment(of: [pausedExp], timeout: 1.0)
        XCTAssertFalse(engine.debugIsEngineRunning, "precondition: the engine must actually be paused")

        await postInterruption(type: .ended, shouldResume: true)
        // SDK27: the restart follows an asynchronous activation (`startGate`).
        await engine.startGate.settle()

        XCTAssertTrue(engine.debugIsEngineRunning,
                      "ending the interruption must restart the paused engine")
        // The three terms canResumePlayback() needs, asserted individually
        // so a failure names WHICH one is wrong instead of collapsing into
        // one opaque "did not resume" at the end.
        XCTAssertFalse(engine.debugInterrupted,
                       ".ended must clear `interrupted` — otherwise canResumePlayback() refuses")
        XCTAssertTrue(engine.debugAppIsForeground,
                      "`appIsForeground` must be true for any resume; suspendForLifecycle is the " +
                      "only thing that clears it, and this test never calls it")
        XCTAssertTrue(engine.debugShouldResumePlayback,
                      "the resume intent must have SURVIVED the interruption — if this is false, " +
                      "the .began path captured isPlaying after it was already zeroed (the " +
                      "ordering defect fixed 2026-09-20), and canResumePlayback() will refuse")
        XCTAssertTrue(engine.debugInterruptionShouldResume,
                      "the .ended option .shouldResume must have been parsed out of the forged " +
                      "userInfo — canResumePlayback()'s last term needs it while the resume gate " +
                      "is still required")
        // Re-read after a further settle. attemptResumePlayback's refusal
        // branch calls pendingSafeEnginePause(), which pauses the engine
        // 0.2 s later — so an engine that was running at the assertion
        // above and has stopped now is the signature of THAT branch having
        // run, i.e. canResumePlayback() was false at the moment it was
        // evaluated even though every term reads true by now.
        let settle = expectation(description: "past pendingSafeEnginePause's 0.2 s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        await fulfillment(of: [settle], timeout: 2.0)
        XCTAssertTrue(engine.debugIsEngineRunning,
                      "the engine must STILL be running half a second later — if it stopped, " +
                      "attemptResumePlayback took its pendingSafeEnginePause() refusal branch")

        XCTAssertTrue(engine.isPlaying,
                      "ending the interruption must actually resume playback, not just restart the " +
                      "engine and abandon attemptResumePlayback's own resume intent — this is the " +
                      "2026-09-15 regression")
    }

    // MARK: - setAdaptivePlayback clamping
    #endif

    @MainActor func testSetAdaptivePlayback_clampsBelowMinSpeed_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // min valid speed is 0.5; values below must be clamped, not crash
        engine.setAdaptivePlayback(speed: 0.1, horizontalBias: 0)
    }

    @MainActor func testSetAdaptivePlayback_clampsAboveMaxSpeed_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // max valid speed is 2.0; values above must be clamped, not crash
        engine.setAdaptivePlayback(speed: 9.9, horizontalBias: 0)
    }

    @MainActor func testSetAdaptivePlayback_clampsBias_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // pan range is -1.0...1.0
        engine.setAdaptivePlayback(speed: 1.0, horizontalBias: -5.0)
        engine.setAdaptivePlayback(speed: 1.0, horizontalBias: 5.0)
    }

    // MARK: - Interleaved / overlap scenarios
    #if DEBUG

    @MainActor func testInterruptionDuringBackground_stateIsConsistent() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        await postInterruption(type: .began)
        XCTAssertTrue(engine.debugInterrupted)
        XCTAssertFalse(engine.debugAppIsForeground)
        await postInterruption(type: .ended, shouldResume: true)
        engine.resumeAfterLifecycle()
        XCTAssertFalse(engine.debugInterrupted)
        XCTAssertTrue(engine.debugAppIsForeground)
    }

    @MainActor func testRouteChangeDuringInterruption_doesNotCorruptState() async throws {
        continueAfterFailure = true   // see the HARDENING note in setUp
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        await postInterruption(type: .began)
        await postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertTrue(engine.debugInterrupted, "interrupted must remain set after route change during interruption")
        XCTAssertFalse(engine.isPlaying)
        await postInterruption(type: .ended, shouldResume: true)
        XCTAssertFalse(engine.debugInterrupted)
        XCTAssertTrue(engine.debugInterruptionShouldResume)
    }

    @MainActor func testRapidSuspendResumeCycle_completesWithinTimeout() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // Wrap in expectation with explicit timeout so a deadlock surfaces as a fast failure
        // rather than hanging the CI job indefinitely.
        let exp = expectation(description: "20 rapid suspend/resume cycles complete without deadlock")
        DispatchQueue.main.async {
            for _ in 0..<20 {
                engine.suspendForLifecycle()
                engine.resumeAfterLifecycle()
            }
            XCTAssertTrue(engine.debugAppIsForeground)
            XCTAssertFalse(engine.isPlaying)
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 2.0)
    }

    // MARK: - deinit: observer removal and retain cycle
    #endif

    @MainActor func testDeinit_removesObserversAndDoesNotCrash() async {
        // autoreleasepool forces immediate ARC release — without it the test runner's own
        // pool may keep localEngine alive past XCTAssertNil, giving a false failure.
        weak var weakRef: AudioEngine?
        autoreleasepool {
            let localEngine = AudioEngine()
            weakRef = localEngine
            // localEngine goes out of scope and is released here
        }
        XCTAssertNil(weakRef,
                     "AudioEngine must deallocate — retain cycle in observer closure suspected if this fails")
        // Post notifications after deinit — must not crash (observers must have been removed)
        await postInterruption(type: .began)
        await postRouteChange(reason: .oldDeviceUnavailable)
        // Reaching here = no EXC_BAD_ACCESS from dangling observer
    }

    // MARK: - AE-1: rate must not move pitch (driven offline through the same unit type)

    /// Ruling AE-1 (2026-09-06): the child's stroke velocity drives the
    /// playback rate; the spatial arm's pitch encodes vertical position.
    /// The engine drives BOTH through one `AVAudioUnitTimePitch`
    /// (pitch-preserving time-stretch + an independent cents shift). This
    /// test DRIVES that unit offline: a 440 Hz triangle rendered at rate
    /// 0.5, 1.0 and 2.0 must stay at 440 Hz, and ±1200 cents must give
    /// 880 / 220 Hz — while the same graph with an `AVAudioUnitVarispeed`
    /// (what "playback-rate pitching" would be) is driven to the failure:
    /// rate 2.0 → 880 Hz. Hardware suite: the simulator skips the engine.
    @MainActor func testTimePitchRate_doesNotMovePitch_varispeedDoes() throws {
        func dominantHz(_ node: AVAudioUnit, configure: (AVAudioUnit) -> Void) throws -> Double {
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
            engine.attach(player); engine.attach(node)
            try engine.connectNode(player, to: node, format: format)
            try engine.connectNode(node, to: engine.mainMixerNode, format: format)
            configure(node)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            // 2 s of 440 Hz triangle, looped like the carrier.
            let frames = AVAudioFrameCount(88_200)
            let src = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            src.frameLength = frames
            let p = src.floatChannelData![0]
            for i in 0..<Int(frames) {
                let phase = (Double(i) * 440.0 / 44_100).truncatingRemainder(dividingBy: 1)
                p[i] = Float(4 * abs(phase - 0.5) - 1) * 0.5
            }
            try engine.start()
            player.scheduleBuffer(src, at: nil, options: .loops)
            try player.playAudio()
            let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                       frameCapacity: engine.manualRenderingMaximumFrameCount)!
            var samples: [Float] = []
            // Skip the unit's warm-up, then keep 1.5 s.
            var rendered = 0
            while rendered < 44_100 * 3 {
                let status = try engine.renderOffline(4096, to: out)
                guard status == .success else { break }
                let q = out.floatChannelData![0]
                if rendered >= 44_100 { samples.append(contentsOf: UnsafeBufferPointer(start: q, count: Int(out.frameLength))) }
                rendered += Int(out.frameLength)
            }
            engine.stop()
            XCTAssertGreaterThan(samples.count, 44_100, "offline render produced too little audio")
            // Fundamental by positive-going zero crossings.
            var crossings = 0
            for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 { crossings += 1 }
            return Double(crossings) / (Double(samples.count) / 44_100)
        }
        // Time-pitch: rate does not move pitch.
        for rate: Float in [0.5, 1.0, 2.0] {
            let hz = try dominantHz(AVAudioUnitTimePitch()) { ($0 as! AVAudioUnitTimePitch).rate = rate }
            XCTAssertEqual(hz, 440, accuracy: 15, "AVAudioUnitTimePitch at rate \(rate) moved the pitch to \(hz) Hz")
        }
        // Time-pitch: cents move pitch, independently of rate.
        let up = try dominantHz(AVAudioUnitTimePitch()) { let t = $0 as! AVAudioUnitTimePitch; t.rate = 2.0; t.pitch = 1200 }
        XCTAssertEqual(up, 880, accuracy: 30, "+1200 cents at rate 2.0 should be 880 Hz, got \(up)")
        let down = try dominantHz(AVAudioUnitTimePitch()) { let t = $0 as! AVAudioUnitTimePitch; t.rate = 0.5; t.pitch = -1200 }
        XCTAssertEqual(down, 220, accuracy: 15, "−1200 cents at rate 0.5 should be 220 Hz, got \(down)")
        // The failure the ruling describes, driven: varispeed at rate 2.0 doubles the pitch.
        let vari = try dominantHz(AVAudioUnitVarispeed()) { ($0 as! AVAudioUnitVarispeed).rate = 2.0 }
        XCTAssertEqual(vari, 880, accuracy: 30, "varispeed at rate 2.0 is the confound: expected 880 Hz, got \(vari)")
    }

    // MARK: - Helpers

    /// How long to let the engine's asynchronous observers run before a test
    /// reads state a posted notification is supposed to have changed.
    /// Measured sufficient 2026-09-20 (the diagnostic read the PROCESSED
    /// `.ended` state after this wait, and stale state before it).
    private static let observerSettleSeconds: Double = 0.4

    /// Post an AVAudioSession interruption notification with forged userInfo,
    /// and WAIT until `AudioEngine` has actually processed it.
    ///
    /// **WHY THIS IS `async` — AND WHY YOU MUST `await` IT.**
    ///
    /// `AudioEngine` does NOT observe these notifications through an
    /// observer registered on the main run loop. It observes them through a
    /// Swift-concurrency sequence —
    /// `for await notification in NotificationCenter.default.notifications(…)`
    /// (`AudioEngine.swift:139`) — and **`RunLoop.main.run(until:)` does not
    /// service that sequence.** Pumping the run loop cannot deliver it.
    ///
    /// This was measured on hardware 2026-09-20, and it is the reason an
    /// entire class of assertions in this file was worthless: immediately
    /// after posting `.began` the engine's flags were still
    /// `.began`-unprocessed, and immediately after posting `.ended` they
    /// were the `.began` signature. Every test that posted a notification
    /// here and then asserted on the result was reading state from BEFORE
    /// the notification landed — including tests that appeared to pass.
    /// The old `drainMain()` fallback below cannot fix it, and the header
    /// comment that claimed those observers are "on .main queue" was wrong.
    ///
    /// **THIS IS THE STANDARD PATTERN FOR THIS FILE: post, `await`
    /// delivery, then assert.** Do not assert on a forged notification
    /// without awaiting it.
    ///
    /// object: nil matches AudioEngine's observer registration (object: nil = any sender).
    ///
    /// SDK27 (2026-11-24): posts iOS 27's pair with genuine context objects
    /// (`ForgedSessionNotifications`) — `.began` is a system deactivation,
    /// `.ended` a resumption recommendation — since `AudioEngine` no longer
    /// reads the deprecated interruption notification.
    enum InterruptionPhase { case began, ended }
    @MainActor private func postInterruption(type: InterruptionPhase,
                                  shouldResume: Bool = false) async {
        let posted = ForgedSessionNotifications.post(
            ForgedSessionNotifications.interruption(began: type == .began, shouldResume: shouldResume))
        XCTAssertTrue(posted, "could not build the iOS 27 session context for the forged notification")
        await awaitObserverDelivery()
    }

    /// Post an AVAudioSession route change notification with forged userInfo.
    /// Same `async` contract and the same reason as `postInterruption` — the
    /// route-change observer is also a `for await` sequence
    /// (`AudioEngine.swift:160`).
    @MainActor private func postRouteChange(reason: AVAudioSession.RouteChangeReason) async {
        let userInfo: [AnyHashable: Any] = [
            AVAudioSessionRouteChangeReasonKey: reason.rawValue
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: userInfo
        )
        await awaitObserverDelivery()
    }

    /// Suspend until the engine's async observers have had a chance to run.
    /// See `postInterruption` for why a RunLoop pump cannot substitute.
    @MainActor private func awaitObserverDelivery() async {
        let delivered = expectation(description: "async observers processed the notification")
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.observerSettleSeconds) {
            delivered.fulfill()
        }
        await fulfillment(of: [delivered], timeout: 2.0)
    }

    /// Pumps the main RunLoop for 0.05 s.
    ///
    /// **It does NOT deliver `AudioEngine`'s notification observers** —
    /// they are Swift-concurrency sequences, not run-loop observers
    /// (measured 2026-09-20; see `postInterruption`). Retained only for the
    /// few synchronous main-queue hops elsewhere in this file. Never use it
    /// to wait for a posted notification.
    @MainActor private func drainMain() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
