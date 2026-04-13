// NOTE: Intentionally uses XCTest — requires real hardware (XCTSkip in setUp), uses expectation/wait. Do not migrate to Swift Testing.
// AudioEngineTests.swift
// BuchstabenNativeTests
//
// Requires Xcode 13+ for XCTSkip in setUp to behave correctly (marks skip, not failure).
//
// Tests exercise AudioEngine directly via forged AVAudioSession notification userInfo payloads,
// asserting state machine transitions on isPlaying and #if DEBUG accessors.
// Observers in AudioEngine are registered with object: nil on .main queue; tests run on main
// thread by default so drainMain() (RunLoop.main.run) is sufficient to flush synchronous delivery.

import XCTest
import AVFoundation
@testable import BuchstabenNative

@MainActor
final class AudioEngineTests: XCTestCase {

    // Swift 6: @MainActor class inherits @MainActor isolation on all initialisers,
    // conflicting with XCTestCase's nonisolated designated initialisers.
    nonisolated override init() { super.init() }
    nonisolated override init(selector: Selector) { super.init(selector: selector) }

    private var engine: AudioEngine?

    // MARK: - Class-level session setup
    // Activate once per suite to avoid interrupting the shared session on every test setUp.

    nonisolated override class func setUp() {
        super.setUp()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // XCTSkip is not available at class level; individual tests will skip via instance setUp.
            print("AudioEngineTests: AVAudioSession.setActive failed at class setUp: \(error)")
        }
    }

    nonisolated override class func tearDown() {
        try? AVAudioSession.sharedInstance().setActive(false)
        super.tearDown()
    }

    // MARK: - Instance setup

    override func setUp() async throws {
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
        // resumeAfterLifecycle() calls startIfNeeded() which starts the engine if not yet running.
        engine?.resumeAfterLifecycle()
    }

    override func tearDown() async throws {
        // Cancel any pending debounce work before nil-ing engine to avoid DispatchWorkItem
        // firing after tearDown on a deallocated engine.
        engine?.cancelPendingLifecycleWork()
        engine = nil
        // Do NOT call super.tearDown() — same reason as setUp() above.
    }

    // MARK: - Direct methods: stop() / play() / restart()

    func testStop_setsIsPlayingFalse() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.stop()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback)
    }

    func testStop_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.stop()
        engine.stop()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback)
    }

    func testPlay_withNoFile_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.play()
        // No file loaded — isPlaying stays false, but shouldResumePlayback must be set
        XCTAssertFalse(engine.isPlaying)
        XCTAssertTrue(engine.debugShouldResumePlayback,
                      "play() must set shouldResumePlayback=true even without a loaded file")
    }

    func testRestart_withNoFile_doesNotCrashAndSetsShouldResume() async throws {
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

    func testLoadAudioFile_missingFile_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.loadAudioFile(named: "nonexistent_totally_fake_file_xyz.mp3", autoplay: false)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugShouldResumePlayback)
    }

    func testLoadAudioFile_missingFile_autoplayTrue_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // autoplay=true with missing file must not crash or corrupt state
        engine.loadAudioFile(named: "nonexistent_totally_fake_file_xyz.mp3", autoplay: true)
        XCTAssertFalse(engine.isPlaying)
        // shouldResumePlayback is only set inside the do-block after successful file open,
        // so missing file leaves it unchanged from prior state.
    }

    // MARK: - Interruption: .began

    func testInterruptionBegan_stopsPlayback() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        XCTAssertFalse(engine.isPlaying, "isPlaying must be false after interruption began")
        XCTAssertTrue(engine.debugInterrupted, "interrupted flag must be set")
        XCTAssertFalse(engine.debugInterruptionShouldResume,
                       "interruptionShouldResume must be false after .began")
        XCTAssertTrue(engine.debugInterruptionResumeGateRequired,
                      "interruptionResumeGateRequired must be set after .began")
    }

    func testInterruptionBegan_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        let interruptedAfterFirst = engine.debugInterrupted
        postInterruption(type: .began)
        XCTAssertEqual(engine.debugInterrupted, interruptedAfterFirst,
                       "Double .began must not corrupt interrupted flag")
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - Interruption: .ended

    func testInterruptionEnded_shouldResumeFalse_remainsPaused() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        postInterruption(type: .ended, shouldResume: false)
        XCTAssertFalse(engine.isPlaying, "Must stay paused when shouldResume=false")
        XCTAssertFalse(engine.debugInterrupted, "interrupted flag must clear on .ended")
        XCTAssertFalse(engine.debugInterruptionShouldResume,
                       "interruptionShouldResume must be false")
    }

    func testInterruptionEnded_shouldResumeTrue_setsFlag() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        postInterruption(type: .ended, shouldResume: true)
        // Even without a loaded file, the flag must reflect the system's intent
        XCTAssertFalse(engine.debugInterrupted, "interrupted must clear on .ended")
        XCTAssertTrue(engine.debugInterruptionShouldResume,
                      "interruptionShouldResume must be true when OS signals .shouldResume")
    }

    func testInterruptionEnded_withoutPrecedingBegan_isHarmless() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .ended, shouldResume: true)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugInterrupted)
    }

    func testInterruptionEnded_missingOptionKey_defaultsToNoResume() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // Post .ended with no option key — edge case from older OS versions
        let userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue
            // Deliberately omitting AVAudioSessionInterruptionOptionKey
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: userInfo
        )
        drainMain()
        XCTAssertFalse(engine.debugInterruptionShouldResume,
                       "Missing option key must default to shouldResume=false")
    }

    // MARK: - Route Change

    func testRouteChange_oldDeviceUnavailable_stopsPlayback() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertFalse(engine.isPlaying, "oldDeviceUnavailable must stop playback")
    }

    func testRouteChange_oldDeviceUnavailable_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .oldDeviceUnavailable)
        postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertFalse(engine.isPlaying)
    }

    func testRouteChange_newDeviceAvailable_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .newDeviceAvailable)
        XCTAssertFalse(engine.isPlaying) // no file; no shouldResume intent
    }

    func testRouteChange_categoryChange_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .categoryChange)
        XCTAssertFalse(engine.isPlaying)
    }

    func testRouteChange_wakeFromSleep_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postRouteChange(reason: .wakeFromSleep)
        XCTAssertFalse(engine.isPlaying)
    }

    func testRouteChange_malformedUserInfo_isHarmless() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // Missing reason key — guard in handleRouteChange must absorb this silently
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: [:]
        )
        drainMain()
        XCTAssertFalse(engine.isPlaying)
    }

    // MARK: - Lifecycle

    func testSuspendForLifecycle_stopsPlayback() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugAppIsForeground)
    }

    func testSuspendForLifecycle_isIdempotent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.suspendForLifecycle()
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.debugAppIsForeground)
    }

    func testResumeAfterLifecycle_setsAppIsForeground() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.resumeAfterLifecycle()
        XCTAssertTrue(engine.debugAppIsForeground)
    }

    func testSuspendThenResume_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        engine.resumeAfterLifecycle()
        XCTAssertFalse(engine.isPlaying) // no file loaded
    }

    func testCancelPendingLifecycleWork_isIdempotent() async throws {
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

    func testPendingSafeEnginePause_firesAfterDelay() async throws {
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

    func testPendingSafeEnginePause_cancelledByResume() async throws {
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

    // MARK: - setAdaptivePlayback clamping

    func testSetAdaptivePlayback_clampsBelowMinSpeed_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // min valid speed is 0.5; values below must be clamped, not crash
        engine.setAdaptivePlayback(speed: 0.1, horizontalBias: 0)
    }

    func testSetAdaptivePlayback_clampsAboveMaxSpeed_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // max valid speed is 2.0; values above must be clamped, not crash
        engine.setAdaptivePlayback(speed: 9.9, horizontalBias: 0)
    }

    func testSetAdaptivePlayback_clampsBias_doesNotCrash() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        // pan range is -1.0...1.0
        engine.setAdaptivePlayback(speed: 1.0, horizontalBias: -5.0)
        engine.setAdaptivePlayback(speed: 1.0, horizontalBias: 5.0)
    }

    // MARK: - Interleaved / overlap scenarios

    func testInterruptionDuringBackground_stateIsConsistent() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        engine.suspendForLifecycle()
        postInterruption(type: .began)
        XCTAssertTrue(engine.debugInterrupted)
        XCTAssertFalse(engine.debugAppIsForeground)
        postInterruption(type: .ended, shouldResume: true)
        engine.resumeAfterLifecycle()
        XCTAssertFalse(engine.debugInterrupted)
        XCTAssertTrue(engine.debugAppIsForeground)
    }

    func testRouteChangeDuringInterruption_doesNotCorruptState() async throws {
        let engine = try XCTUnwrap(self.engine, "AudioEngine must be initialized")
        postInterruption(type: .began)
        postRouteChange(reason: .oldDeviceUnavailable)
        XCTAssertTrue(engine.debugInterrupted, "interrupted must remain set after route change during interruption")
        XCTAssertFalse(engine.isPlaying)
        postInterruption(type: .ended, shouldResume: true)
        XCTAssertFalse(engine.debugInterrupted)
        XCTAssertTrue(engine.debugInterruptionShouldResume)
    }

    func testRapidSuspendResumeCycle_completesWithinTimeout() async throws {
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

    func testDeinit_removesObserversAndDoesNotCrash() async {
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
        postInterruption(type: .began)
        postRouteChange(reason: .oldDeviceUnavailable)
        // Reaching here = no EXC_BAD_ACCESS from dangling observer
    }

    // MARK: - Helpers

    /// Post an AVAudioSession interruption notification with forged userInfo.
    /// object: nil matches AudioEngine's observer registration which uses object: nil (any sender).
    private func postInterruption(type: AVAudioSession.InterruptionType,
                                  shouldResume: Bool = false) {
        var userInfo: [AnyHashable: Any] = [
            AVAudioSessionInterruptionTypeKey: type.rawValue
        ]
        if type == .ended {
            let options: AVAudioSession.InterruptionOptions = shouldResume ? [.shouldResume] : []
            userInfo[AVAudioSessionInterruptionOptionKey] = options.rawValue
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: nil,
            userInfo: userInfo
        )
        drainMain()
    }

    /// Post an AVAudioSession route change notification with forged userInfo.
    private func postRouteChange(reason: AVAudioSession.RouteChangeReason) {
        let userInfo: [AnyHashable: Any] = [
            AVAudioSessionRouteChangeReasonKey: reason.rawValue
        ]
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: nil,
            userInfo: userInfo
        )
        drainMain()
    }

    /// Drain the main RunLoop long enough for .main-queue observers to fire synchronously.
    /// Observers in AudioEngine are registered on .main queue; XCTest runs test methods on the
    /// main thread, so RunLoop.main.run(until:) is the correct and sufficient drain mechanism.
    private func drainMain() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
}
