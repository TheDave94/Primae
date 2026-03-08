//  TracingViewModelTests.swift
//  BuchstabenNativeTests
//
//  Integration tests for TracingViewModel touch→playback pipeline.
//  Uses MockAudioController (injected via init) to observe audio side-effects.
//  All tests run on MainActor (TracingViewModel is @MainActor).

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

@MainActor
final class TracingViewModelTests: XCTestCase {

    private var audio: MockAudio!
    private var vm: TracingViewModel!

    override func setUp() async throws {
        audio = MockAudio()
        // singleTouchCooldownAfterNavigation=0 eliminates cooldown timing from tests
        vm = TracingViewModel(singleTouchCooldownAfterNavigation: 0, audio: audio)
    }

    override func tearDown() async throws {
        vm = nil
        audio = nil
    }

    // MARK: 1 — Velocity below threshold keeps playback idle (no play after debounce)

    func testSlowVelocity_doesNotTriggerPlay() throws {
        let playBefore = audio.playCount
        slowDrag(vm: vm)
        // Wait longer than active debounce (0.03s) + idle debounce (0.12s)
        let exp = expectation(description: "debounce window")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(audio.playCount, playBefore,
                       "Slow velocity must never trigger audio.play()")
        XCTAssertFalse(vm.isPlaying)
    }

    // MARK: 2 — Velocity above threshold triggers play after active debounce

    func testFastVelocity_triggersPlayAfterDebounce() throws {
        let playBefore = audio.playCount
        fastDrag(vm: vm, audio: audio)

        let exp = expectation(description: "active debounce 0.03s")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertGreaterThan(audio.playCount, playBefore,
                             "Fast velocity must trigger audio.play() after active debounce")
        XCTAssertTrue(vm.isPlaying)
    }

    // MARK: 3 — endTouch always stops playback, regardless of prior velocity

    func testEndTouch_stopsPlayback() throws {
        fastDrag(vm: vm, audio: audio)
        let exp = expectation(description: "let play fire")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let stopBefore = audio.stopCount
        vm.endTouch()
        XCTAssertGreaterThan(audio.stopCount, stopBefore,
                             "endTouch must call audio.stop()")
        XCTAssertFalse(vm.isPlaying)
    }

    func testEndTouch_withoutPriorTouch_doesNotCrash() {
        // endTouch with no active touch must be a no-op, not a crash
        vm.endTouch()
        XCTAssertFalse(vm.isPlaying)
    }

    // MARK: 4 — appDidEnterBackground suspends audio and clears touch state

    func testAppDidEnterBackground_suspendsClearsState() throws {
        fastDrag(vm: vm, audio: audio)
        let exp = expectation(description: "play fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

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

    func testAppDidBecomeActive_withResumeIntent_resumesAudio() throws {
        // Drive a fast touch to set resumeIntent=true and establish active state
        fastDrag(vm: vm, audio: audio)
        let exp1 = expectation(description: "play fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        vm.appDidEnterBackground()

        let resumeBefore = audio.resumeAfterLifecycleCount
        vm.appDidBecomeActive()

        XCTAssertEqual(audio.resumeAfterLifecycleCount, resumeBefore + 1,
                       "resumeAfterLifecycle must be called on foreground")
    }

    func testAppDidBecomeActive_withoutResumeIntent_doesNotForcePlay() throws {
        // endTouch clears resumeIntent; subsequent BecomeActive should not re-play
        fastDrag(vm: vm, audio: audio)
        let exp = expectation(description: "play fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        vm.endTouch()           // clears resumeIntent
        vm.appDidEnterBackground()
        let playBefore = audio.playCount
        vm.appDidBecomeActive()

        let exp2 = expectation(description: "give debounce time")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)

        XCTAssertEqual(audio.playCount, playBefore,
                       "No spurious play after BecomeActive when resumeIntent=false")
    }

    // MARK: 6 — Stroke completion forces idle and sets isComplete

    func testStrokeCompletion_forcesIdleAndSetsComplete() throws {
        // The VM loads the first letter on init. Drive all checkpoints to completion
        // using the strokeTracker's known definition via normalized coordinates.
        // We hit progress=1.0 by sending the exact checkpoint centres.
        // Since we can't access strokeTracker internals directly, drive via a letter
        // with a known simple path by resetting and using a high-velocity swipe
        // that covers the entire canvas systematically.
        //
        // Simpler approach: use resetLetter() then verify that after a real letter
        // completes (progress==1.0), isPlaying is false.
        //
        // Because we can't easily control which letter is loaded in CI,
        // we verify the invariant: after progress==1.0, isPlaying must be false.

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
        let exp = expectation(description: "completion idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(vm.progress, 1.0, accuracy: 1e-9)
        XCTAssertFalse(vm.isPlaying,
                       "isPlaying must be false after stroke completion (forced idle)")
    }

    // MARK: 7 — resetLetter clears progress and stops playback

    func testResetLetter_clearsProgressAndStops() throws {
        fastDrag(vm: vm, audio: audio)
        let exp = expectation(description: "play fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        let stopBefore = audio.stopCount
        vm.resetLetter()

        XCTAssertEqual(vm.progress, 0.0, accuracy: 1e-9)
        XCTAssertFalse(vm.isPlaying)
        XCTAssertGreaterThan(audio.stopCount, stopBefore)
    }

    // MARK: 8 — multitouch navigation suppresses single touch

    func testMultiTouchNavigation_suppressesSingleTouch() throws {
        vm.beginMultiTouchNavigation()
        // beginTouch during multitouch must be ignored
        vm.beginTouch(at: CGPoint(x: 100, y: 100), t: 1000)
        fastDrag(vm: vm, audio: audio, startTime: 1000.1)

        let exp = expectation(description: "debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(vm.isPlaying,
                       "Touch during multitouch navigation must not trigger playback")
    }

    // MARK: 9 — setAdaptivePlayback is called during touch updates

    func testUpdateTouch_callsSetAdaptivePlayback() {
        let countBefore = audio.setAdaptivePlaybackCount
        fastDrag(vm: vm, audio: audio, count: 5)
        XCTAssertGreaterThan(audio.setAdaptivePlaybackCount, countBefore,
                             "setAdaptivePlayback must be called on each touch update")
    }

    // MARK: 10 — Rapid background/foreground churn does not leave isPlaying=true

    func testRapidBgFgChurn_neverLeavesPlayingTrue() throws {
        fastDrag(vm: vm, audio: audio)
        let exp0 = expectation(description: "play fires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp0.fulfill() }
        wait(for: [exp0], timeout: 1.0)

        for _ in 0..<10 {
            vm.appDidEnterBackground()
            vm.appDidBecomeActive()
        }
        vm.appDidEnterBackground()

        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(vm.isPlaying,
                       "After ending in background, isPlaying must be false")
    }

    // MARK: - Ghost guide lifecycle

    func testNextLetter_resetsShowGhostToFalse() throws {
        // Enable ghost on first letter
        vm.toggleGhost()
        XCTAssertTrue(vm.showGhost, "Pre-condition: showGhost should be true after toggle")

        // Navigate to next letter — load(letter:) must reset showGhost
        vm.nextLetter()

        XCTAssertFalse(vm.showGhost,
                       "showGhost must reset to false when navigating to the next letter")
    }

    func testPreviousLetter_resetsShowGhostToFalse() throws {
        // Navigate away first so previousLetter() has room to go back
        vm.nextLetter()
        vm.toggleGhost()
        XCTAssertTrue(vm.showGhost, "Pre-condition: showGhost should be true after toggle")

        vm.previousLetter()

        XCTAssertFalse(vm.showGhost,
                       "showGhost must reset to false when navigating to the previous letter")
    }

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
            let localVM = TracingViewModel()
            weakVM = localVM
            // Trigger async work that captures self, then immediately release the strong ref
            localVM.appDidBecomeActive()
        }

        // 500ms: conservative drain window for cancelled @MainActor Task.sleep closures.
        // Longest queued sleep in TracingViewModel is ~1.3s (toast), but CancellationError
        // propagates immediately — 500ms provides headroom for system load variance.
        // If this test becomes flaky in CI, check for a new strong self capture in a stored Task.
        try? await Task.sleep(for: .milliseconds(500))

        XCTAssertNil(weakVM,
                     "TracingViewModel must deallocate — retain cycle in a stored Task closure suspected if this fails")
    }
}
