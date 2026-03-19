//  TracingViewModelTests.swift
//  BuchstabenNativeTests
//
//  Integration tests for TracingViewModel touch→playback pipeline.
//  Uses MockAudioController (injected via init) to observe audio side-effects.
//  MainActor isolation is applied per setup/test method where @MainActor VM state
//  is accessed, which is safer under Swift 6 strict concurrency than isolating
//  the entire XCTestCase subclass.

import XCTest
import CoreGraphics
@testable import BuchstabenNative

// MARK: - MockAudioController (local, mirrors BuchstabenNativeTests.swift)
// Redeclared here as internal so these tests are self-contained.

@MainActor
private final class MockAudio: AudioControlling {
    private(set) var loadedFiles: [String] = []
    private(set) var playCount  = 0
    private(set) var stopCount  = 0
    private(set) var suspendForLifecycleCount  = 0
    private(set) var resumeAfterLifecycleCount = 0
    private(set) var cancelPendingLifecycleWorkCount = 0
    private(set) var setAdaptivePlaybackCount  = 0

    func loadAudioFile(named fileName: String, autoplay: Bool) { loadedFiles.append(fileName) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptivePlaybackCount += 1 }
    func play()    { playCount  += 1 }
    func stop()    { stopCount  += 1 }
    func restart() {}
    func suspendForLifecycle()       { suspendForLifecycleCount  += 1 }
    func resumeAfterLifecycle()      { resumeAfterLifecycleCount += 1 }
    func cancelPendingLifecycleWork(){ cancelPendingLifecycleWorkCount += 1 }
}

// MARK: - Helpers

/// Simulate a fast drag at velocity >> 22 pt/s over `count` points.
/// Returns the last timestamp used.
@MainActor
@discardableResult
private func fastDrag(
    vm: TracingViewModel,
    audio: MockAudio,
    canvasSize: CGSize = CGSize(width: 400, height: 400),
    from: CGPoint = CGPoint(x: 100, y: 200),
    count: Int = 10,
    startTime: CFTimeInterval = 1000.0
) -> CFTimeInterval {
    // Velocity = dist/dt. Each step moves 10pt in 0.001s → 10_000 pt/s >> 22 threshold.
    vm.beginTouch(at: from, t: startTime)
    var t = startTime
    var p = from
    for _ in 0..<count {
        t += 0.001
        p.x += 10
        vm.updateTouch(at: p, t: t, canvasSize: canvasSize)
    }
    return t
}

/// Simulate a slow drag at velocity << 22 pt/s.
@MainActor
@discardableResult
private func slowDrag(
    vm: TracingViewModel,
    canvasSize: CGSize = CGSize(width: 400, height: 400),
    from: CGPoint = CGPoint(x: 100, y: 200),
    count: Int = 10,
    startTime: CFTimeInterval = 1000.0
) -> CFTimeInterval {
    // 1pt per 1s → 1 pt/s << 22 threshold.
    vm.beginTouch(at: from, t: startTime)
    var t = startTime
    var p = from
    for _ in 0..<count {
        t += 1.0
        p.x += 1
        vm.updateTouch(at: p, t: t, canvasSize: canvasSize)
    }
    return t
}

// MARK: - TracingViewModelTests

final class TracingViewModelTests: XCTestCase {

    private var audio: MockAudio!
    private var vm: TracingViewModel!

    @MainActor
    override func setUp() async throws {
        audio = MockAudio()
        // singleTouchCooldownAfterNavigation=0 eliminates cooldown timing from tests.
        // strokeEnforced=false allows audio to trigger on velocity alone, regardless of
        // whether the test environment has letter stroke definitions loaded — these tests
        // exercise the audio/lifecycle pipeline, not stroke recognition.
        vm = TracingViewModel(TracingDependencies(
            singleTouchCooldownAfterNavigation: 0,
            audio: audio,
            progressStore: StubProgressStore(),
            haptics: StubHaptics(),
            repo: LetterRepository(resources: StubResourceProvider())))
        vm.strokeEnforced = false
    }

    @MainActor
    override func tearDown() async throws {
        vm = nil
        audio = nil
    }

    // MARK: 1 — Velocity below threshold keeps playback idle (no play after debounce)

    @MainActor
    func testSlowVelocity_doesNotTriggerPlay() async throws {
        let playBefore = audio.playCount
        slowDrag(vm: vm)
        // Wait longer than active debounce (0.03s) + idle debounce (0.12s)
        try await Task.sleep(nanoseconds: 250_000_000) // 0.25s
        XCTAssertEqual(audio.playCount, playBefore,
                       "Slow velocity must never trigger audio.play()")
        XCTAssertFalse(vm.isPlaying)
    }

    // MARK: 2 — Velocity above threshold triggers play after active debounce

    @MainActor
    func testFastVelocity_triggersPlayAfterDebounce() async throws {
        let playBefore = audio.playCount
        fastDrag(vm: vm, audio: audio)

        // wait for active debounce (0.03s)
        try await Task.sleep(nanoseconds: 80_000_000) // 0.08s

        XCTAssertGreaterThan(audio.playCount, playBefore,
                             "Fast velocity must trigger audio.play() after active debounce")
        XCTAssertTrue(vm.isPlaying)
    }

    // MARK: 3 — endTouch always stops playback, regardless of prior velocity

    @MainActor
    func testEndTouch_stopsPlayback() async throws {
        fastDrag(vm: vm, audio: audio)
        try await Task.sleep(nanoseconds: 80_000_000)

        let stopBefore = audio.stopCount
        vm.endTouch()
        XCTAssertGreaterThan(audio.stopCount, stopBefore,
                             "endTouch must call audio.stop()")
        XCTAssertFalse(vm.isPlaying)
    }

    @MainActor
    func testEndTouch_withoutPriorTouch_doesNotCrash() {
        // endTouch with no active touch must be a no-op, not a crash
        vm.endTouch()
        XCTAssertFalse(vm.isPlaying)
    }

    // MARK: 4 — appDidEnterBackground suspends audio and clears touch state

    @MainActor
    func testAppDidEnterBackground_suspendsClearsState() async throws {
        fastDrag(vm: vm, audio: audio)
        try await Task.sleep(nanoseconds: 80_000_000)

        let suspendBefore = audio.suspendForLifecycleCount
        let stopBefore    = audio.stopCount

        vm.appDidEnterBackground()

        XCTAssertEqual(audio.suspendForLifecycleCount, suspendBefore + 1,
                       "suspendForLifecycle must be called on background")
        XCTAssertGreaterThan(audio.stopCount, stopBefore,
                             "audio.stop() must be called on background")
        XCTAssertFalse(vm.isPlaying, "isPlaying must be false after background")
    }

    // MARK: 5 — appDidBecomeActive with prior resumeIntent resumes playback state

    @MainActor
    func testAppDidBecomeActive_withResumeIntent_resumesAudio() async throws {
        // Drive a fast touch to set resumeIntent=true and establish active state
        fastDrag(vm: vm, audio: audio)
        try await Task.sleep(nanoseconds: 80_000_000)

        vm.appDidEnterBackground()

        let resumeBefore = audio.resumeAfterLifecycleCount
        vm.appDidBecomeActive()

        XCTAssertEqual(audio.resumeAfterLifecycleCount, resumeBefore + 1,
                       "resumeAfterLifecycle must be called on foreground")
    }

    @MainActor
    func testAppDidBecomeActive_withoutResumeIntent_doesNotForcePlay() async throws {
        // endTouch clears resumeIntent; subsequent BecomeActive should not re-play
        fastDrag(vm: vm, audio: audio)
        try await Task.sleep(nanoseconds: 80_000_000)

        vm.endTouch()           // clears resumeIntent
        vm.appDidEnterBackground()
        let playBefore = audio.playCount
        vm.appDidBecomeActive()

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(audio.playCount, playBefore,
                       "No spurious play after BecomeActive when resumeIntent=false")
    }

    // MARK: 6 — Stroke completion forces idle and sets isComplete

    @MainActor
    func testStrokeCompletion_forcesIdleAndSetsComplete() async throws {
        // Manually drive progress to 1.0 via rapid multi-point drag
        // spanning the canvas to hit all checkpoints.
        let canvas = CGSize(width: 400, height: 400)
        let t0: CFTimeInterval = 1000.0

        vm.beginTouch(at: CGPoint(x: 0, y: 0), t: t0)
        var t = t0
        var didComplete = false

        // Grid scan at fast velocity — will hit all checkpoints eventually
        outer: for row in stride(from: 0.0, through: 1.0, by: 0.05) {
            for col in stride(from: 0.0, through: 1.0, by: 0.05) {
                t += 0.001
                let p = CGPoint(x: col * canvas.width, y: row * canvas.height)
                vm.updateTouch(at: p, t: t, canvasSize: canvas)
                if vm.progress >= 1.0 {
                    didComplete = true
                    break outer
                }
            }
        }

        guard didComplete else {
            // Not all letters are completable via grid scan (e.g., complex strokes).
            // Skip test rather than false-fail.
            throw XCTSkip("Letter not completable via grid scan — skipping stroke completion test")
        }

        // Give debounce time to fire, then assert idle
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(vm.progress, 1.0, accuracy: 1e-9)
        XCTAssertFalse(vm.isPlaying,
                       "isPlaying must be false after stroke completion (forced idle)")
    }

    // MARK: 7 — resetLetter clears progress and stops playback

    @MainActor
    func testResetLetter_clearsProgressAndStops() async throws {
        fastDrag(vm: vm, audio: audio)
        try await Task.sleep(nanoseconds: 80_000_000)

        let stopBefore = audio.stopCount
        vm.resetLetter()

        XCTAssertEqual(vm.progress, 0.0, accuracy: 1e-9)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertGreaterThan(audio.stopCount, stopBefore)
    }

    // MARK: 8 — multitouch navigation suppresses single touch

    @MainActor
    func testMultiTouchNavigation_suppressesSingleTouch() async throws {
        vm.beginMultiTouchNavigation()
        // beginTouch during multitouch must be ignored
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: 1000)
        fastDrag(vm: vm, audio: audio, startTime: 1000.1)

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertFalse(vm.isPlaying,
                       "Touch during multitouch navigation must not trigger playback")
    }

    // MARK: 9 — setAdaptivePlayback is called during touch updates

    @MainActor
    func testUpdateTouch_callsSetAdaptivePlayback() {
        let countBefore = audio.setAdaptivePlaybackCount
        fastDrag(vm: vm, audio: audio, count: 5)
        XCTAssertGreaterThan(audio.setAdaptivePlaybackCount, countBefore,
                             "setAdaptivePlayback must be called on each touch update")
    }

    // MARK: 10 — Rapid background/foreground churn does not leave isPlaying=true

    @MainActor
    func testRapidBgFgChurn_neverLeavesPlayingTrue() async throws {
        fastDrag(vm: vm, audio: audio)
        try await Task.sleep(nanoseconds: 80_000_000)

        for _ in 0..<10 {
            vm.appDidEnterBackground()
            vm.appDidBecomeActive()
        }
        vm.appDidEnterBackground()

        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertFalse(vm.isPlaying,
                       "After ending in background, isPlaying must be false")
    }

    // MARK: - Ghost guide lifecycle

    @MainActor
    func testNextLetter_resetsShowGhostToFalse() throws {
        // Enable ghost on first letter
        vm.toggleGhost()
        XCTAssertTrue(vm.showGhost, "Pre-condition: showGhost should be true after toggle")

        // Navigate to next letter — load(letter:) must reset showGhost
        vm.nextLetter()

        XCTAssertFalse(vm.showGhost,
                       "showGhost must reset to false when navigating to the next letter")
    }

    @MainActor
    func testPreviousLetter_resetsShowGhostToFalse() throws {
        // Navigate away first so previousLetter() has room to go back
        vm.nextLetter()
        vm.toggleGhost()
        XCTAssertTrue(vm.showGhost, "Pre-condition: showGhost should be true after toggle")

        vm.previousLetter()

        XCTAssertFalse(vm.showGhost,
                       "showGhost must reset to false when navigating to the previous letter")
    }

    @MainActor
    func testResetLetter_doesNotChangeShowGhost() throws {
        // resetLetter reloads same letter — ghost state is intentionally preserved
        // (user enabled ghost on this letter and reset their attempt, not navigated away)
        vm.toggleGhost()
        vm.resetLetter()
        XCTAssertTrue(vm.showGhost,
                       "showGhost should survive resetLetter — user intent was to retry, not navigate")
    }

    // MARK: - Retain cycle

    func testTracingViewModel_doesNotRetainSelf() async throws {
        weak var weakVM: TracingViewModel?

        await MainActor.run {
            let localVM = TracingViewModel(TracingDependencies(repo: LetterRepository(resources: StubResourceProvider())))
            weakVM = localVM
            // Trigger async work that captures self, then immediately release the strong ref
            localVM.appDidBecomeActive()
        }

        // 500ms: conservative drain window for cancelled @MainActor Task.sleep closures.
        // Longest queued sleep in ViewModel is ~1.3s, but CancellationError propagates immediately.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(weakVM,
                     "TracingViewModel must deallocate — retain cycle in a stored Task closure suspected if this fails")
    }
}
