import XCTest
import CoreGraphics
import SwiftUI
@testable import BuchstabenNative

final class BuchstabenNativeTests: XCTestCase {
    func testStrokeTrackerProgressionRespectsOrder() {
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

    func testMapVelocityToSpeedIsMonotonicAndBounded() {
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

    func testLetterRepositoryFallsBackFromInvalidJsonToFolderScan() throws {
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

    func testLetterRepositoryFallsBackToSampleWhenNoAssetsExist() {
        let provider = MockResourceProvider(urls: [], byRelativePath: [:])
        let repo = LetterRepository(resources: provider)
        let letters = repo.loadLetters()

        XCTAssertEqual(letters.count, 1)
        XCTAssertEqual(letters[0].name, "A")
        XCTAssertEqual(letters[0].audioFiles, ["A.mp3"])
    }

    func testLetterRepositoryPrefersCleanCuratedAudioForAtoM() throws {
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

    func testGuideRendererSupportsCouncilLetterSet() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 480)
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            XCTAssertNotNil(LetterGuideRenderer.guidePath(for: letter, in: rect), "Expected guide path for \(letter)")
        }
        XCTAssertNotNil(LetterGuideRenderer.guidePath(for: "Z", in: rect), "Fallback guide should exist for non-curated letters")
    }

    func testGuidePathReturnsNilForEmptyRect() {
        XCTAssertNil(LetterGuideRenderer.guidePath(for: "A", in: .zero))
        XCTAssertNil(LetterGuideRenderer.guidePath(for: "A", in: CGRect(x: 0, y: 0, width: 0, height: 10)))
    }

    func testGuideRendererIsCaseInsensitiveForLetterKeys() {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 400)
        let upper = LetterGuideRenderer.guidePath(for: "M", in: rect)
        let lower = LetterGuideRenderer.guidePath(for: "m", in: rect)
        XCTAssertNotNil(upper)
        XCTAssertNotNil(lower)
        XCTAssertEqual(upper?.boundingRect, lower?.boundingRect)
    }

    func testGhostFallbackPathIsDeterministicForUnknownLetter() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 480)
        let p1 = LetterGuideRenderer.guidePath(for: "Q", in: rect)
        let p2 = LetterGuideRenderer.guidePath(for: "Q", in: rect)
        XCTAssertNotNil(p1)
        XCTAssertNotNil(p2)
        XCTAssertEqual(p1?.boundingRect, p2?.boundingRect)

        let y = LetterGuideRenderer.fallbackCrossbarY(for: "Q")
        let probe = CGPoint(x: rect.width * 0.5, y: rect.height * y)
        let s1 = p1?.strokedPath(.init(lineWidth: 6, lineCap: .round, lineJoin: .round))
        let s2 = p2?.strokedPath(.init(lineWidth: 6, lineCap: .round, lineJoin: .round))
        XCTAssertEqual(s1?.contains(probe), true)
        XCTAssertEqual(s2?.contains(probe), true)
    }


    func testFallbackCrossbarYStaysInExpectedBand() {
        for letter in ["A", "M", "Q", "R", "Z", "Ä"] {
            let y = LetterGuideRenderer.fallbackCrossbarY(for: letter)
            XCTAssertGreaterThanOrEqual(y, 0.42)
            XCTAssertLessThanOrEqual(y, 0.61)
        }
    }

    func testGhostFallbackVariesAcrossDifferentUnknownLetters() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 480)
        let q = LetterGuideRenderer.guidePath(for: "Q", in: rect)
        let r = LetterGuideRenderer.guidePath(for: "R", in: rect)
        XCTAssertNotNil(q)
        XCTAssertNotNil(r)

        let qY = LetterGuideRenderer.fallbackCrossbarY(for: "Q")
        let rY = LetterGuideRenderer.fallbackCrossbarY(for: "R")
        XCTAssertNotEqual(qY, rY)

        let qPath = q?.strokedPath(.init(lineWidth: 6, lineCap: .round, lineJoin: .round))
        let rPath = r?.strokedPath(.init(lineWidth: 6, lineCap: .round, lineJoin: .round))

        let qProbe = CGPoint(x: rect.width * 0.5, y: rect.height * qY)
        let rProbe = CGPoint(x: rect.width * 0.5, y: rect.height * rY)

        XCTAssertEqual(qPath?.contains(qProbe), true)
        XCTAssertEqual(rPath?.contains(rProbe), true)
        XCTAssertNotEqual(qPath?.contains(rProbe), true)
        XCTAssertNotEqual(rPath?.contains(qProbe), true)
    }


    @MainActor
    func testRandomLetterAvoidsImmediateRepeatWhenMultipleLettersExist() throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }

        try fs.write(relative: "A_strokes.json", content: validJSON(letter: "A"))
        try fs.write(relative: "A/A.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "A/A1.mp3", content: "ok")

        try fs.write(relative: "B_strokes.json", content: validJSON(letter: "B"))
        try fs.write(relative: "B/B.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "B/B1.mp3", content: "ok")

        let vm = TracingViewModel(
            repo: LetterRepository(resources: fs.provider),
            audio: FakeAudioEngine(),
            randomIndex: { _ in 0 },
            activeDebounceSeconds: 0,
            idleDebounceSeconds: 0
        )

        XCTAssertEqual(vm.currentLetterName, "A")
        vm.randomLetter()
        XCTAssertEqual(vm.currentLetterName, "B")
    }

    @MainActor
    func testRandomAudioVariantAvoidsImmediateRepeatWhenMultipleFilesExist() throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }

        try fs.write(relative: "A_strokes.json", content: validJSON(letter: "A"))
        try fs.write(relative: "A/A.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "A/A1.mp3", content: "ok")
        try fs.write(relative: "A/A2.mp3", content: "ok")

        let audio = FakeAudioEngine()
        let vm = TracingViewModel(
            repo: LetterRepository(resources: fs.provider),
            audio: audio,
            randomIndex: { _ in 0 },
            activeDebounceSeconds: 0,
            idleDebounceSeconds: 0
        )

        let before = audio.loadedFiles.last
        vm.randomLetter()
        let after = audio.loadedFiles.last

        XCTAssertEqual(vm.currentLetterName, "A")
        XCTAssertEqual(before, "A/A1.mp3")
        XCTAssertEqual(after, "A/A2.mp3")
    }


    func testLetterRepositoryPreferredAudioMatchingHandlesUnicodeNormalization() throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }

        try fs.write(relative: "M_strokes.json", content: validJSON(letter: "M"))
        try fs.write(relative: "M/M.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "M/Möwe.mp3", content: "ok")
        try fs.write(relative: "M/Meer.mp3", content: "ok")

        let repo = LetterRepository(resources: fs.provider)
        let letters = repo.loadLetters()
        let m = try XCTUnwrap(letters.first(where: { $0.id.uppercased() == "M" }))

        XCTAssertEqual(m.audioFiles, ["M/Meer.mp3", "M/Möwe.mp3"])
    }

    @MainActor
    func testSingleTouchSuppressionWindowUsesInjectedClock() {
        let clock = FakeClock(100)
        let audio = FakeAudioEngine()
        let vm = TracingViewModel(
            audio: audio,
            now: { clock.now },
            activeDebounceSeconds: 0,
            idleDebounceSeconds: 0,
            singleTouchCooldownAfterNavigation: 0.05
        )
        let size = CGSize(width: 320, height: 480)

        vm.beginTouch(at: CGPoint(x: 20, y: 20), t: clock.now)
        vm.updateTouch(at: CGPoint(x: 28, y: 28), t: clock.now + 0.03, canvasSize: size)
        XCTAssertGreaterThan(vm.debugActivePathCount, 1)

        vm.beginMultiTouchNavigation()
        XCTAssertTrue(vm.debugIsMultiTouchNavigationActive)
        XCTAssertEqual(vm.debugActivePathCount, 0)

        vm.endMultiTouchNavigation()
        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive)

        vm.beginTouch(at: CGPoint(x: 30, y: 30), t: clock.now)
        XCTAssertEqual(vm.debugActivePathCount, 0)

        clock.advance(by: 0.06)
        vm.beginTouch(at: CGPoint(x: 32, y: 32), t: clock.now)
        XCTAssertEqual(vm.debugActivePathCount, 1)
    }

    @MainActor
    func testRepeatedBeginMultiTouchDoesNotLeaveStuckState() {
        let vm = TracingViewModel(singleTouchCooldownAfterNavigation: 0)

        vm.beginMultiTouchNavigation()
        vm.beginMultiTouchNavigation()
        XCTAssertTrue(vm.debugIsMultiTouchNavigationActive)

        vm.endMultiTouchNavigation()
        vm.endMultiTouchNavigation()
        XCTAssertFalse(vm.debugIsMultiTouchNavigationActive)
    }

    @MainActor
    func testStrokeEnforcementOffAllowsPlaybackActivationDuringMotion() {
        let audio = FakeAudioEngine()
        let vm = TracingViewModel(audio: audio, activeDebounceSeconds: 0, idleDebounceSeconds: 0)
        vm.strokeEnforced = false

        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 140, y: 10), t: 1.06, canvasSize: size)

        XCTAssertTrue(vm.isPlaying)
        XCTAssertGreaterThan(audio.playCalls, 0)
    }

    @MainActor
    func testLifecycleBackgroundStopsPlaybackAndClearsTouchState() {
        let audio = FakeAudioEngine()
        let vm = TracingViewModel(audio: audio, activeDebounceSeconds: 0, idleDebounceSeconds: 0)
        vm.strokeEnforced = false

        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 150, y: 10), t: 1.05, canvasSize: size)
        XCTAssertTrue(vm.isPlaying)
        XCTAssertGreaterThan(vm.debugActivePathCount, 0)

        vm.appDidEnterBackground()

        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(vm.debugActivePathCount, 0)
        XCTAssertGreaterThan(audio.stopCalls, 0)
        XCTAssertEqual(audio.suspendCalls, 1)
    }

    @MainActor
    func testLifecycleResumeDoesNotAutoPlayWithoutNewTouch() {
        let audio = FakeAudioEngine()
        let vm = TracingViewModel(audio: audio, activeDebounceSeconds: 0, idleDebounceSeconds: 0)
        vm.strokeEnforced = false

        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 150, y: 10), t: 1.05, canvasSize: size)
        let playBeforeBackground = audio.playCalls

        vm.appDidEnterBackground()
        vm.appDidBecomeActive()

        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(audio.resumeCalls, 1)
        XCTAssertEqual(audio.playCalls, playBeforeBackground)
    }


    @MainActor
    func testBackgroundCancelsPendingPlaybackActivation() async {
        let audio = FakeAudioEngine()
        let vm = TracingViewModel(audio: audio, activeDebounceSeconds: 0.05, idleDebounceSeconds: 0)
        vm.strokeEnforced = false

        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 150, y: 10), t: 1.02, canvasSize: size)

        vm.appDidEnterBackground()

        try? await Task.sleep(for: .milliseconds(80))

        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(audio.playCalls, 0)
        XCTAssertEqual(audio.suspendCalls, 1)
    }


    @MainActor
    func testDuplicateBackgroundEventsSuspendOnlyOnceUntilActive() {
        let audio = FakeAudioEngine()
        let vm = TracingViewModel(audio: audio, activeDebounceSeconds: 0, idleDebounceSeconds: 0)

        vm.appDidEnterBackground()
        vm.appDidEnterBackground()

        XCTAssertEqual(audio.suspendCalls, 1)

        vm.appDidBecomeActive()
        XCTAssertEqual(audio.resumeCalls, 1)

        vm.appDidEnterBackground()
        XCTAssertEqual(audio.suspendCalls, 2)
    }

    @MainActor
    func testActiveWithoutPriorBackgroundDoesNotResumeAudioEngine() {
        let audio = FakeAudioEngine()
        let vm = TracingViewModel(audio: audio, activeDebounceSeconds: 0, idleDebounceSeconds: 0)

        vm.appDidBecomeActive()

        XCTAssertEqual(audio.resumeCalls, 0)
    }


    @MainActor
    func testRepeatedLifecycleCyclesDoNotLeavePlaybackStuck() {
        let audio = FakeAudioEngine()
        let vm = TracingViewModel(audio: audio, activeDebounceSeconds: 0, idleDebounceSeconds: 0)
        vm.strokeEnforced = false

        let size = CGSize(width: 320, height: 480)
        for i in 0..<150 {
            let t = CFTimeInterval(i) * 0.1
            vm.beginTouch(at: CGPoint(x: 10, y: 10), t: t)
            vm.updateTouch(at: CGPoint(x: 150, y: 10), t: t + 0.04, canvasSize: size)
            vm.appDidEnterBackground()
            vm.appDidBecomeActive()
        }

        XCTAssertFalse(vm.isPlaying)
        XCTAssertEqual(audio.suspendCalls, 150)
        XCTAssertEqual(audio.resumeCalls, 150)
        XCTAssertGreaterThan(audio.stopCalls, 0)
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
    let urls: [URL]
    let byRelativePath: [String: URL]

    func allResourceURLs() -> [URL] { urls }
    func resourceURL(for relativePath: String) -> URL? { byRelativePath[relativePath] }
}

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

private final class FakeAudioEngine: TracingAudioControlling {
    private(set) var loadedFiles: [String] = []
    private(set) var playCalls = 0
    private(set) var stopCalls = 0
    private(set) var suspendCalls = 0
    private(set) var resumeCalls = 0

    func loadAudioFile(named fileName: String, autoplay: Bool) {
        loadedFiles.append(fileName)
    }

    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        // no-op
    }

    func play() { playCalls += 1 }
    func stop() { stopCalls += 1 }
    func suspendForLifecycle() { suspendCalls += 1 }
    func resumeAfterLifecycle() { resumeCalls += 1 }
}

private final class FakeClock {
    var now: CFTimeInterval
    init(_ now: CFTimeInterval) { self.now = now }
    func advance(by delta: CFTimeInterval) { now += delta }
}
