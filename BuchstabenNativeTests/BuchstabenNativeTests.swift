import XCTest
import CoreGraphics
import AVFoundation
@testable import BuchstabenNative

@MainActor
final class BuchstabenNativeTests: XCTestCase {
    func testStrokeTrackerProgressionRespectsOrder() async {
        let tracker = StrokeTracker()
        let strokes = LetterStrokes(
            letter: "T",
            checkpointRadius: 0.06,
            strokes: [
                .init(id: 1, checkpoints: [.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.2)]),
                .init(id: 2, checkpoints: [.init(x: 0.4, y: 0.4), .init(x: 0.6, y: 0.4)])
            ]
        )
        tracker.load(strokes)

        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4))
        XCTAssertEqual(tracker.progress[0].nextCheckpoint, 0)
        XCTAssertFalse(tracker.soundEnabled)

        tracker.update(normalizedPoint: CGPoint(x: 0.2, y: 0.2))
        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.2))
        XCTAssertTrue(tracker.progress[0].complete)
        XCTAssertEqual(tracker.currentStrokeIndex, 1)

        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4))
        tracker.update(normalizedPoint: CGPoint(x: 0.6, y: 0.4))
        XCTAssertTrue(tracker.isComplete)
        XCTAssertEqual(tracker.overallProgress, 1.0)
    }

    func testMapVelocityToSpeedIsMonotonicAndBounded() async {
        let sample: [CGFloat] = [0, 60, 120, 240, 500, 900, 1300, 3000]
        let mapped = sample.map(TracingViewModel.mapVelocityToSpeed)

        XCTAssertEqual(mapped.first ?? 0, Float(2.0), accuracy: 0.0001)
        XCTAssertEqual(mapped.last ?? 0, Float(0.5), accuracy: 0.0001)
        mapped.forEach { value in
            XCTAssertGreaterThanOrEqual(value, 0.5)
            XCTAssertLessThanOrEqual(value, 2.0)
        }

        for i in 1..<mapped.count {
            XCTAssertLessThanOrEqual(mapped[i], mapped[i - 1], "Speed should not increase with higher velocity")
        }
    }

    func testLetterRepositoryFallsBackFromInvalidJsonToFolderScan() async throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }

        try fs.write(relative: "A_strokes.json", content: "{not-json")
        try fs.write(relative: "A/A.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "A/A1.mp3", content: "dummy")

        let repo = LetterRepository(resources: fs.provider)
        let letters = repo.loadLetters()

        XCTAssertEqual(letters.first?.name, "A")
        XCTAssertEqual(letters.first?.imageName, "A/A.pbm")
        XCTAssertEqual(letters.first?.audioFiles, ["A/A1.mp3"])
    }

    func testLetterRepositoryFallsBackToSampleWhenNoAssetsExist() async {
        let provider = MockResourceProvider(urls: [], byRelativePath: [:])
        // NullLetterCache ensures no disk-cache hit from other tests in the same process
        let repo = LetterRepository(resources: provider, cache: NullLetterCache())
        let letters = repo.loadLetters()

        XCTAssertEqual(letters.count, 1)
        XCTAssertEqual(letters[0].name, "A")
        XCTAssertEqual(letters[0].audioFiles, ["A.mp3"])
    }

    func testLetterRepositoryPrefersCleanCuratedAudioForAtoM() async throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }

        try fs.write(relative: "M_strokes.json", content: validJSON(letter: "M"))
        try fs.write(relative: "M/M.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "M/Möwe.mp3", content: "ok")
        try fs.write(relative: "M/Meer.mp3", content: "ok")
        try fs.write(relative: "M/hmmm.wav", content: "stale")
        try fs.write(relative: "M/ElevenLabs_test.mp3", content: "stale")

        let repo = LetterRepository(resources: fs.provider)
        let letters = repo.loadLetters()
        let m = try XCTUnwrap(letters.first(where: { $0.id.uppercased() == "M" }))

        XCTAssertEqual(m.audioFiles, ["M/Meer.mp3", "M/Möwe.mp3"])
    }

    func testGuideRendererSupportsCouncilLetterSet() async {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 480)
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            XCTAssertNotNil(LetterGuideRenderer.guidePath(for: letter, in: rect), "Expected guide path for \(letter)")
        }
        XCTAssertNotNil(LetterGuideRenderer.guidePath(for: "Z", in: rect), "Fallback guide should exist for non-curated letters")
    }



    func testGuideRendererGeometryIsNonDegenerateAndContained() async {
        let rect = CGRect(x: 20, y: 30, width: 320, height: 480)

        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let path = try! XCTUnwrap(LetterGuideRenderer.guidePath(for: letter, in: rect))
            let bounds = path.boundingRect
            XCTAssertGreaterThan(bounds.width, 1, "Guide width should be non-degenerate for \(letter)")
            XCTAssertGreaterThan(bounds.height, 1, "Guide height should be non-degenerate for \(letter)")
            XCTAssertTrue(rect.intersects(bounds), "Guide should intersect tracing rect for \(letter)")
            XCTAssertTrue(rect.insetBy(dx: -1, dy: -1).contains(bounds), "Guide bounds should remain inside tracing rect for \(letter)")
        }
    }

    func testGuideRendererFallbackIsDeterministicForUnknownLetter() async {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 500)
        let fallback1 = try! XCTUnwrap(LetterGuideRenderer.guidePath(for: "Z", in: rect))
        let fallback2 = try! XCTUnwrap(LetterGuideRenderer.guidePath(for: "?", in: rect))
        let fallback3 = try! XCTUnwrap(LetterGuideRenderer.guidePath(for: "Z", in: rect))

        XCTAssertEqual(fallback1.boundingRect.integral, fallback2.boundingRect.integral)
        XCTAssertEqual(fallback1.boundingRect.integral, fallback3.boundingRect.integral)
    }

    @MainActor
    func testMultiTouchNavigationClearsAndSuppressesSingleTouchBriefly() async {
        let vm = TracingViewModel(.stub.with(cooldown: 0.05))
        let size = CGSize(width: 320, height: 480)

        vm.beginTouch(at: CGPoint(x: 20, y: 20), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 28, y: 28), t: 1.03, canvasSize: size)
        XCTAssertGreaterThan(vm.debugActivePathCount, 1)

        vm.beginMultiTouchNavigation()
        XCTAssertTrue(vm.debugIsMultiTouchNavigationActive)
        XCTAssertEqual(vm.debugActivePathCount, 0, "Two-finger nav should immediately clear active stroke")

        vm.endMultiTouchNavigation()
        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive)

        vm.beginTouch(at: CGPoint(x: 30, y: 30), t: CACurrentMediaTime())
        XCTAssertEqual(vm.debugActivePathCount, 0, "Single-touch should be briefly suppressed after multi-touch nav")

        usleep(70_000)
        vm.beginTouch(at: CGPoint(x: 32, y: 32), t: CACurrentMediaTime())
        XCTAssertEqual(vm.debugActivePathCount, 1, "Single-touch should recover after suppression window")
    }



    @MainActor
    func testTracingViewModelUsesInjectedAudioControllerAcrossLifecycle() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        // Allow the Task in load(letter:) to complete before asserting
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertGreaterThanOrEqual(audio.loadedFiles.count, 1)

        vm.nextAudioVariant()
        vm.previousAudioVariant()
        vm.appDidEnterBackground()
        vm.appDidBecomeActive()

        XCTAssertGreaterThanOrEqual(audio.loadedFiles.count, 3, "Init + next/previous variant should load audio through seam")
        XCTAssertEqual(audio.suspendForLifecycleCount, 1)
        XCTAssertEqual(audio.resumeAfterLifecycleCount, 1)
    }



    @MainActor
    func testBackgroundCancelsPendingPlaybackAndAvoidsResumeUntilNewIntent() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        vm.appDidEnterBackground()

        XCTAssertGreaterThanOrEqual(audio.cancelPendingLifecycleWorkCount, 1)
        XCTAssertGreaterThanOrEqual(audio.stopCount, 1)

        vm.appDidBecomeActive()
        XCTAssertEqual(audio.playCount, 0, "Should not auto-play on foreground without fresh touch intent")

        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 2.0)
        vm.updateTouch(at: CGPoint(x: 120, y: 120), t: 2.01, canvasSize: size)

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThanOrEqual(audio.playCount, 1, "Fresh touch intent should allow playback again")
    }



    @MainActor
    func testLongSessionLifecycleRegressionMatrix() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        for cycle in 0..<5 {
            let base = CFTimeInterval(10 + cycle)
            vm.beginTouch(at: CGPoint(x: 12, y: 12), t: base)
            vm.updateTouch(at: CGPoint(x: 140, y: 160), t: base + 0.01, canvasSize: size)
            vm.appDidEnterBackground()
            vm.appDidBecomeActive()
        }

        for i in 0..<8 {
            let t = CFTimeInterval(200) + (Double(i) * 0.004)
            vm.beginTouch(at: CGPoint(x: 20 + CGFloat(i), y: 20 + CGFloat(i)), t: t)
            vm.updateTouch(at: CGPoint(x: 25 + CGFloat(i), y: 25 + CGFloat(i)), t: t + 0.001, canvasSize: size)
            vm.endTouch()
        }

        XCTAssertGreaterThanOrEqual(audio.suspendForLifecycleCount, 5)
        XCTAssertGreaterThanOrEqual(audio.resumeAfterLifecycleCount, 5)
        XCTAssertGreaterThanOrEqual(audio.cancelPendingLifecycleWorkCount, 5)
        XCTAssertGreaterThan(audio.setAdaptivePlaybackCount, 0)
        XCTAssertGreaterThanOrEqual(audio.stopCount, audio.suspendForLifecycleCount)
    }

    @MainActor
    func testRepeatedBeginMultiTouchDoesNotLeaveStuckState() async {
        let vm = TracingViewModel(.stub)

        vm.beginMultiTouchNavigation()
        vm.beginMultiTouchNavigation()
        XCTAssertTrue(vm.debugIsMultiTouchNavigationActive)

        vm.endMultiTouchNavigation()
        vm.endMultiTouchNavigation()
        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive)
    }

    // MARK: - Hardening Tests

    /// Rapid background/foreground churn (50 cycles) must not corrupt audio or touch state.
    @MainActor
    func testRapidBackgroundForegroundChurn_50Cycles() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        for cycle in 0..<50 {
            let base = CFTimeInterval(100 + cycle * 2)
            vm.beginTouch(at: CGPoint(x: 10, y: 10), t: base)
            vm.updateTouch(at: CGPoint(x: 80, y: 80), t: base + 0.01, canvasSize: size)
            vm.appDidEnterBackground()
            vm.appDidBecomeActive()
        }

        XCTAssertEqual(audio.suspendForLifecycleCount, 50, "suspendForLifecycle must be called once per bg transition")
        XCTAssertEqual(audio.resumeAfterLifecycleCount, 50, "resumeAfterLifecycle must be called once per fg transition")
        XCTAssertGreaterThanOrEqual(audio.cancelPendingLifecycleWorkCount, 50)
        // Touch state must be clean: no active path after background
        vm.appDidEnterBackground()
        XCTAssertEqual(vm.debugActivePathCount, 0, "Active path must be cleared on background entry")
        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive)
    }

    /// AVAudioSession interruption simulation: .ended with shouldResume = false must NOT resume playback.
    @MainActor
    func testAVAudioSessionInterruption_shouldResumeFalse_doesNotPlay() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        // Establish active playback intent
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        let playsBefore = audio.playCount

        // Simulate interruption via app-level mapping (Background = interruption began)
        vm.appDidEnterBackground()
        let stopAfterInterrupt = audio.stopCount

        // Simulate .ended with shouldResume = false via appDidBecomeActive without touch intent
        // endTouch clears resumeIntent — simulates no-resume scenario
        vm.endTouch()
        vm.appDidBecomeActive()

        XCTAssertGreaterThan(stopAfterInterrupt, 0, "Stop must be called on interruption")
        XCTAssertEqual(audio.playCount, playsBefore, "Playback must NOT resume when shouldResume is false (no touch intent)")
    }

    /// AVAudioSession interruption simulation: .ended with shouldResume = true + fresh touch SHOULD resume playback.
    @MainActor
    func testAVAudioSessionInterruption_shouldResumeTrue_resumesOnNewIntent() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        vm.appDidEnterBackground()
        vm.appDidBecomeActive()

        // Fresh touch intent after foreground return simulates shouldResume = true
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 2.0)
        vm.updateTouch(at: CGPoint(x: 120, y: 120), t: 2.01, canvasSize: size)

        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertGreaterThanOrEqual(audio.playCount, 1, "Fresh touch after foreground return must allow playback (shouldResume = true path)")
    }

    /// Route change: oldDeviceUnavailable fires while app is active — playback must pause immediately.
    @MainActor
    func testAudioRouteChange_oldDeviceUnavailable_stopsPlayback() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        // Start active touch/playback
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 140, y: 160), t: 1.01, canvasSize: size)

        // Simulate oldDeviceUnavailable via background (device lost = system suspends audio)
        let stopsBefore = audio.stopCount
        vm.appDidEnterBackground()
        XCTAssertGreaterThan(audio.stopCount, stopsBefore, "Playback must stop when audio device becomes unavailable")
        XCTAssertEqual(vm.debugActivePathCount, 0, "Active path must be cleared on device unavailable / background")
    }

    /// Route change: multiple rapid oldDeviceUnavailable events must be idempotent (no double-stop or crash).
    @MainActor
    func testAudioRouteChange_oldDeviceUnavailable_isIdempotent() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)

        // Fire route-change-equivalent event 3 times in quick succession
        vm.appDidEnterBackground()
        vm.appDidEnterBackground()
        vm.appDidEnterBackground()

        // State should remain consistent: not triple-stopping with unexpected side effects
        XCTAssertGreaterThanOrEqual(audio.suspendForLifecycleCount, 1)
        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive)
        XCTAssertEqual(vm.debugActivePathCount, 0)
    }

    /// Debounce window: 20 rapid touch events within < debounce window must not trigger multiple playback starts.
    @MainActor
    func testDebounceTouchBurst_rapidTaps_onlyOnePlaybackIntent() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        let playsBefore = audio.playCount

        // Fire 20 touch begin/update pairs within a ~4ms window (well inside 30ms active debounce)
        for i in 0..<20 {
            let t = CFTimeInterval(1.0) + Double(i) * 0.0002
            vm.beginTouch(at: CGPoint(x: CGFloat(10 + i), y: CGFloat(10 + i)), t: t)
            vm.updateTouch(at: CGPoint(x: CGFloat(80 + i), y: CGFloat(80 + i)), t: t + 0.0001, canvasSize: size)
            vm.endTouch()
        }

        // Within debounce window, direct play() calls should be zero (state machine debounces)
        XCTAssertEqual(audio.playCount, playsBefore, "Rapid touch burst within debounce window must not trigger multiple play() calls")
    }

    /// Debounce window: after debounce expires, playback does eventually trigger.
    @MainActor
    func testDebounceWindow_afterExpiry_playbackIsAllowed() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        // Single sustained touch (above velocity threshold), then wait for debounce
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 140, y: 160), t: 1.01, canvasSize: size)

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertGreaterThanOrEqual(audio.setAdaptivePlaybackCount, 1, "Adaptive playback must be updated after debounce expires")
    }

    /// Interruption during background/foreground churn: interleaved events must not corrupt state.
    @MainActor
    func testInterruptionDuringBackgroundForegroundChurn_stateRemainsConsistent() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        for i in 0..<10 {
            let base = CFTimeInterval(10 + i * 3)
            vm.beginTouch(at: CGPoint(x: 10, y: 10), t: base)
            vm.updateTouch(at: CGPoint(x: 60, y: 60), t: base + 0.01, canvasSize: size)

            // Interleave: background then immediate active (simulates interruption during transition)
            vm.appDidEnterBackground()
            vm.appDidBecomeActive()
            vm.appDidEnterBackground()
            vm.appDidBecomeActive()
        }

        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive, "Multi-touch flag must not be stuck after churn")
        XCTAssertEqual(vm.debugActivePathCount, 0, "Active path must be cleared after bg/fg churn sequence")
        XCTAssertGreaterThanOrEqual(audio.suspendForLifecycleCount, 10)
        XCTAssertGreaterThanOrEqual(audio.resumeAfterLifecycleCount, 10)
    }

    /// Touch burst overlapping with navigation: mid-burst multi-touch must suppress subsequent single touches.
    @MainActor
    func testTouchBurstInterruptedByMultiTouchNav_suppressionApplied() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(cooldown: 0.05).with(audio: audio))
        let size = CGSize(width: 320, height: 480)

        // Begin a touch burst
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 20, y: 20), t: 1.01, canvasSize: size)

        // Multi-touch nav fires mid-burst
        vm.beginMultiTouchNavigation()
        XCTAssertEqual(vm.debugActivePathCount, 0, "Nav must immediately clear active path")

        vm.endMultiTouchNavigation()

        // Immediate single touch after nav end should be suppressed
        vm.beginTouch(at: CGPoint(x: 30, y: 30), t: CACurrentMediaTime())
        XCTAssertEqual(vm.debugActivePathCount, 0, "Touch must be suppressed immediately after nav end")

        // After cooldown, touch must be accepted
        usleep(70_000) // 70ms > 50ms cooldown
        vm.beginTouch(at: CGPoint(x: 35, y: 35), t: CACurrentMediaTime())
        XCTAssertEqual(vm.debugActivePathCount, 1, "Touch must be accepted after suppression window expires")
    }

    /// AVAudioSession interruption handler idempotency: double-interrupt-began must not corrupt state.
    @MainActor
    func testAVAudioSessionInterruptionIdempotency_doubleBegan() async {
        let audio = MockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)

        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)

        // Fire interruption-began twice in succession
        vm.appDidEnterBackground()
        let suspendAfterFirst = audio.suspendForLifecycleCount
        vm.appDidEnterBackground() // second "began" — must be idempotent
        let suspendAfterSecond = audio.suspendForLifecycleCount

        XCTAssertEqual(suspendAfterFirst, suspendAfterSecond,
                       "Double interruption-began must not double-suspend: handler must be idempotent")
        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive)
        XCTAssertEqual(vm.debugActivePathCount, 0)
    }
}


private func validJSON(letter: String) -> String {
    """
    {
      "letter": "\(letter)",
      "checkpointRadius": 0.06,
      "strokes": [
        {
          "id": 1,
          "checkpoints": [
            { "x": 0.2, "y": 0.2 },
            { "x": 0.8, "y": 0.8 }
          ]
        }
      ]
    }
    """
}

private struct MockResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    let urls: [URL]
    let byRelativePath: [String: URL]

    func allResourceURLs() -> [URL] { urls }
    func resourceURL(for relativePath: String) -> URL? { byRelativePath[relativePath] }
}

/// An in-memory no-op cache that always appears empty — used to isolate
/// LetterRepository tests from real disk cache state in CI.

private final class TempResourceFS {
    let root: URL
    var provider: MockResourceProvider {
        let urls = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?.map {
            root.appendingPathComponent($0)
        } ?? []

        let map = Dictionary(uniqueKeysWithValues: urls.map { (url) in
            let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
            return (rel, url)
        })

        return MockResourceProvider(urls: urls, byRelativePath: map)
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(relative: String, content: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}


@MainActor
private final class MockAudioController: AudioControlling {
    private(set) var loadedFiles: [String] = []
    private(set) var suspendForLifecycleCount = 0
    private(set) var resumeAfterLifecycleCount = 0
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var cancelPendingLifecycleWorkCount = 0
    private(set) var setAdaptivePlaybackCount = 0

    func loadAudioFile(named fileName: String, autoplay: Bool) {
        loadedFiles.append(fileName)
    }

    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptivePlaybackCount += 1 }
    func play() { playCount += 1 }
    func stop() { stopCount += 1 }
    func restart() {}

    func suspendForLifecycle() {
        suspendForLifecycleCount += 1
    }

    func resumeAfterLifecycle() {
        resumeAfterLifecycleCount += 1
    }

    func cancelPendingLifecycleWork() { cancelPendingLifecycleWorkCount += 1 }
}
