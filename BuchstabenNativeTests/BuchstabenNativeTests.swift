//  BuchstabenNativeTests.swift
//  BuchstabenNativeTests

import Testing
import Foundation
import CoreGraphics
import QuartzCore
import AVFoundation
@testable import BuchstabenNative

@Suite(.serialized) @MainActor struct BuchstabenNativeTests {

    @Test func strokeTrackerProgressionRespectsOrder() {
        let tracker = StrokeTracker()
        let strokes = LetterStrokes(letter: "T", checkpointRadius: 0.06, strokes: [
            .init(id: 1, checkpoints: [.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.2)]),
            .init(id: 2, checkpoints: [.init(x: 0.4, y: 0.4), .init(x: 0.6, y: 0.4)])
        ])
        tracker.load(strokes)
        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4))
        #expect(tracker.progress[0].nextCheckpoint == 0)
        #expect(!tracker.soundEnabled)
        tracker.update(normalizedPoint: CGPoint(x: 0.2, y: 0.2))
        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.2))
        #expect(tracker.progress[0].complete)
        #expect(tracker.currentStrokeIndex == 1)
        tracker.update(normalizedPoint: CGPoint(x: 0.4, y: 0.4))
        tracker.update(normalizedPoint: CGPoint(x: 0.6, y: 0.4))
        #expect(tracker.isComplete)
        #expect(tracker.overallProgress == 1.0)
    }

    @Test func mapVelocityToSpeedIsMonotonicAndBounded() {
        let sample: [CGFloat] = [0, 60, 120, 240, 500, 900, 1300, 3000]
        let mapped = sample.map(TracingViewModel.mapVelocityToSpeed)
        #expect(abs((mapped.first ?? 0) - Float(0.5)) < 0.0001)
        #expect(abs((mapped.last ?? 0) - Float(2.0)) < 0.0001)
        mapped.forEach { #expect($0 >= 0.5); #expect($0 <= 2.0) }
        for i in 1..<mapped.count { #expect(mapped[i] >= mapped[i-1]) }
    }

    @Test func letterRepositoryFallsBackFromInvalidJsonToFolderScan() throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }
        try fs.write(relative: "A_strokes.json", content: "{not-json")
        try fs.write(relative: "A/A.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "A/A1.mp3", content: "dummy")
        let repo = LetterRepository(resources: fs.provider)
        let letters = repo.loadLetters()
        #expect(letters.first?.name == "A")
        #expect(letters.first?.imageName == "A/A.pbm")
        #expect(letters.first?.audioFiles == ["A/A1.mp3"])
    }

    @Test func letterRepositoryFallsBackToSampleWhenNoAssetsExist() {
        let repo = LetterRepository(resources: LocalMockResourceProvider(urls: [], byRelativePath: [:]), cache: NullLetterCache())
        let letters = repo.loadLetters()
        #expect(letters.count == 1)
        #expect(letters[0].name == "A")
        #expect(letters[0].audioFiles == ["A.mp3"])
    }

    @Test func letterRepositoryPrefersCleanCuratedAudioForAtoM() throws {
        let fs = try TempResourceFS()
        defer { fs.cleanup() }
        try fs.write(relative: "M_strokes.json", content: validJSON(letter: "M"))
        try fs.write(relative: "M/M.pbm", content: "P1\n1 1\n0")
        try fs.write(relative: "M/Möwe.mp3", content: "ok")
        try fs.write(relative: "M/Meer.mp3", content: "ok")
        try fs.write(relative: "M/hmmm.wav", content: "stale")
        try fs.write(relative: "M/ElevenLabs_test.mp3", content: "stale")
        let repo = LetterRepository(resources: fs.provider)
        let m = try #require(repo.loadLetters().first(where: { $0.id.uppercased() == "M" }))
        #expect(m.audioFiles == ["M/Meer.mp3", "M/Möwe.mp3"])
    }

    @Test func guideRendererSupportsCouncilLetterSet() {
        let rect = CGRect(x: 0, y: 0, width: 320, height: 480)
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            #expect(LetterGuideRenderer.guidePath(for: letter, in: rect) != nil)
        }
        #expect(LetterGuideRenderer.guidePath(for: "Z", in: rect) != nil)
    }

    @Test func guideRendererGeometryIsNonDegenerateAndContained() throws {
        let rect = CGRect(x: 20, y: 30, width: 320, height: 480)
        for letter in ["A", "F", "I", "K", "L", "M", "O"] {
            let path = try #require(LetterGuideRenderer.guidePath(for: letter, in: rect))
            let bounds = path.boundingRect
            #expect(bounds.width > 1); #expect(bounds.height > 1)
            #expect(rect.intersects(bounds))
            #expect(rect.insetBy(dx: -1, dy: -1).contains(bounds))
        }
    }

    @Test func guideRendererFallbackIsDeterministicForUnknownLetter() throws {
        let rect = CGRect(x: 0, y: 0, width: 300, height: 500)
        let f1 = try #require(LetterGuideRenderer.guidePath(for: "Z", in: rect))
        let f2 = try #require(LetterGuideRenderer.guidePath(for: "?", in: rect))
        let f3 = try #require(LetterGuideRenderer.guidePath(for: "Z", in: rect))
        #expect(f1.boundingRect.integral == f2.boundingRect.integral)
        #expect(f1.boundingRect.integral == f3.boundingRect.integral)
    }

    @Test func multiTouchNavigationClearsAndSuppressesSingleTouchBriefly() {
        let vm = TracingViewModel(.stub.with(cooldown: 0.05))
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 20, y: 20), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 28, y: 28), t: 1.03, canvasSize: size)
        #expect(vm.debugActivePathCount > 1)
        vm.beginMultiTouchNavigation()
        #expect(vm.debugIsMultiTouchNavigationActive)
        #expect(vm.debugActivePathCount == 0)
        vm.endMultiTouchNavigation()
        #expect(!vm.debugIsMultiTouchNavigationActive)
        vm.beginTouch(at: CGPoint(x: 30, y: 30), t: CACurrentMediaTime())
        #expect(vm.debugActivePathCount == 0)
        usleep(70_000)
        vm.beginTouch(at: CGPoint(x: 32, y: 32), t: CACurrentMediaTime())
        #expect(vm.debugActivePathCount == 1)
    }

    @Test func tracingViewModelUsesInjectedAudioControllerAcrossLifecycle() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        #expect(audio.loadedFiles.count >= 1)
        vm.nextAudioVariant(); vm.previousAudioVariant()
        vm.appDidEnterBackground(); vm.appDidBecomeActive()
        #expect(audio.loadedFiles.count >= 3)
        #expect(audio.suspendForLifecycleCount == 1)
        #expect(audio.resumeAfterLifecycleCount == 1)
    }

    @Test func backgroundCancelsPendingPlaybackAndAvoidsResumeUntilNewIntent() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        vm.appDidEnterBackground()
        #expect(audio.cancelPendingLifecycleWorkCount >= 1)
        #expect(audio.stopCount >= 1)
        vm.appDidBecomeActive()
        #expect(audio.playCount == 0)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 2.0)
        vm.updateTouch(at: CGPoint(x: 120, y: 120), t: 2.01, canvasSize: size)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(audio.playCount >= 1)
    }

    @Test func longSessionLifecycleRegressionMatrix() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        for cycle in 0..<5 {
            let base = CFTimeInterval(10 + cycle)
            vm.beginTouch(at: CGPoint(x: 12, y: 12), t: base)
            vm.updateTouch(at: CGPoint(x: 140, y: 160), t: base + 0.01, canvasSize: size)
            vm.appDidEnterBackground(); vm.appDidBecomeActive()
        }
        for i in 0..<8 {
            let t = CFTimeInterval(200) + (Double(i) * 0.004)
            vm.beginTouch(at: CGPoint(x: 20 + CGFloat(i), y: 20 + CGFloat(i)), t: t)
            vm.updateTouch(at: CGPoint(x: 25 + CGFloat(i), y: 25 + CGFloat(i)), t: t + 0.001, canvasSize: size)
            vm.endTouch()
        }
        #expect(audio.suspendForLifecycleCount >= 5)
        #expect(audio.resumeAfterLifecycleCount >= 5)
        #expect(audio.cancelPendingLifecycleWorkCount >= 5)
        #expect(audio.setAdaptivePlaybackCount > 0)
        #expect(audio.stopCount >= audio.suspendForLifecycleCount)
    }

    @Test func repeatedBeginMultiTouchDoesNotLeaveStuckState() {
        let vm = TracingViewModel(.stub)
        vm.beginMultiTouchNavigation(); vm.beginMultiTouchNavigation()
        #expect(vm.debugIsMultiTouchNavigationActive)
        vm.endMultiTouchNavigation(); vm.endMultiTouchNavigation()
        #expect(!vm.debugIsMultiTouchNavigationActive)
    }

    @Test func rapidBackgroundForegroundChurn_50Cycles() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        for cycle in 0..<50 {
            let base = CFTimeInterval(100 + cycle * 2)
            vm.beginTouch(at: CGPoint(x: 10, y: 10), t: base)
            vm.updateTouch(at: CGPoint(x: 80, y: 80), t: base + 0.01, canvasSize: size)
            vm.appDidEnterBackground(); vm.appDidBecomeActive()
        }
        #expect(audio.suspendForLifecycleCount == 50)
        #expect(audio.resumeAfterLifecycleCount == 50)
        #expect(audio.cancelPendingLifecycleWorkCount >= 50)
        vm.appDidEnterBackground()
        #expect(vm.debugActivePathCount == 0)
        #expect(!vm.debugIsMultiTouchNavigationActive)
    }

    @Test func avAudioSessionInterruption_shouldResumeFalse_doesNotPlay() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        let playsBefore = audio.playCount
        vm.appDidEnterBackground()
        let stopAfterInterrupt = audio.stopCount
        vm.endTouch(); vm.appDidBecomeActive()
        #expect(stopAfterInterrupt > 0)
        #expect(audio.playCount == playsBefore)
    }

    @Test func avAudioSessionInterruption_shouldResumeTrue_resumesOnNewIntent() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        vm.appDidEnterBackground(); vm.appDidBecomeActive()
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 2.0)
        vm.updateTouch(at: CGPoint(x: 120, y: 120), t: 2.01, canvasSize: size)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(audio.playCount >= 1)
    }

    @Test func audioRouteChange_oldDeviceUnavailable_stopsPlayback() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 140, y: 160), t: 1.01, canvasSize: size)
        let stopsBefore = audio.stopCount
        vm.appDidEnterBackground()
        #expect(audio.stopCount > stopsBefore)
        #expect(vm.debugActivePathCount == 0)
    }

    @Test func audioRouteChange_oldDeviceUnavailable_isIdempotent() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        vm.appDidEnterBackground(); vm.appDidEnterBackground(); vm.appDidEnterBackground()
        #expect(audio.suspendForLifecycleCount >= 1)
        #expect(!vm.debugIsMultiTouchNavigationActive)
        #expect(vm.debugActivePathCount == 0)
    }

    @Test func debounceTouchBurst_rapidTaps_onlyOnePlaybackIntent() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        let playsBefore = audio.playCount
        for i in 0..<20 {
            let t = CFTimeInterval(1.0) + Double(i) * 0.0002
            vm.beginTouch(at: CGPoint(x: CGFloat(10+i), y: CGFloat(10+i)), t: t)
            vm.updateTouch(at: CGPoint(x: CGFloat(80+i), y: CGFloat(80+i)), t: t+0.0001, canvasSize: size)
            vm.endTouch()
        }
        #expect(audio.playCount == playsBefore)
    }

    @Test func debounceWindow_afterExpiry_playbackIsAllowed() async {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 140, y: 160), t: 1.01, canvasSize: size)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(audio.setAdaptivePlaybackCount >= 1)
    }

    @Test func interruptionDuringBgFgChurn_stateRemainsConsistent() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        for i in 0..<10 {
            let base = CFTimeInterval(10 + i * 3)
            vm.beginTouch(at: CGPoint(x: 10, y: 10), t: base)
            vm.updateTouch(at: CGPoint(x: 60, y: 60), t: base + 0.01, canvasSize: size)
            vm.appDidEnterBackground(); vm.appDidBecomeActive()
            vm.appDidEnterBackground(); vm.appDidBecomeActive()
        }
        #expect(!vm.debugIsMultiTouchNavigationActive)
        #expect(vm.debugActivePathCount == 0)
        #expect(audio.suspendForLifecycleCount >= 10)
        #expect(audio.resumeAfterLifecycleCount >= 10)
    }

    @Test func touchBurstInterruptedByMultiTouchNav_suppressionApplied() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(cooldown: 0.05).with(audio: audio))
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 20, y: 20), t: 1.01, canvasSize: size)
        vm.beginMultiTouchNavigation()
        #expect(vm.debugActivePathCount == 0)
        vm.endMultiTouchNavigation()
        vm.beginTouch(at: CGPoint(x: 30, y: 30), t: CACurrentMediaTime())
        #expect(vm.debugActivePathCount == 0)
        usleep(70_000)
        vm.beginTouch(at: CGPoint(x: 35, y: 35), t: CACurrentMediaTime())
        #expect(vm.debugActivePathCount == 1)
    }

    @Test func avAudioSessionInterruptionIdempotency_doubleBegan() {
        let audio = LocalMockAudioController()
        let vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
        let size = CGSize(width: 320, height: 480)
        vm.beginTouch(at: CGPoint(x: 10, y: 10), t: 1.0)
        vm.updateTouch(at: CGPoint(x: 80, y: 80), t: 1.01, canvasSize: size)
        vm.appDidEnterBackground()
        let suspendAfterFirst = audio.suspendForLifecycleCount
        vm.appDidEnterBackground()
        #expect(audio.suspendForLifecycleCount == suspendAfterFirst)
        #expect(!vm.debugIsMultiTouchNavigationActive)
        #expect(vm.debugActivePathCount == 0)
    }
}

// MARK: - Private helpers

private func validJSON(letter: String) -> String {
    """
    {"letter":"\(letter)","checkpointRadius":0.06,"strokes":[{"id":1,"checkpoints":[{"x":0.2,"y":0.2},{"x":0.8,"y":0.8}]}]}
    """
}

private struct LocalMockResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    let urls: [URL]; let byRelativePath: [String: URL]
    func allResourceURLs() -> [URL] { urls }
    func resourceURL(for relativePath: String) -> URL? { byRelativePath[relativePath] }
}

private final class TempResourceFS {
    let root: URL
    var provider: LocalMockResourceProvider {
        let urls = (try? FileManager.default.subpathsOfDirectory(atPath: root.path))?.map {
            root.appendingPathComponent($0)
        } ?? []
        let map = Dictionary(uniqueKeysWithValues: urls.map { url in
            (url.path.replacingOccurrences(of: root.path + "/", with: ""), url)
        })
        return LocalMockResourceProvider(urls: urls, byRelativePath: map)
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
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class LocalMockAudioController: AudioControlling {
    private(set) var loadedFiles: [String] = []
    private(set) var suspendForLifecycleCount = 0
    private(set) var resumeAfterLifecycleCount = 0
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var cancelPendingLifecycleWorkCount = 0
    private(set) var setAdaptivePlaybackCount = 0
    func loadAudioFile(named fileName: String, autoplay: Bool) { loadedFiles.append(fileName) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptivePlaybackCount += 1 }
    func play() { playCount += 1 }
    func stop() { stopCount += 1 }
    func restart() {}
    func suspendForLifecycle() { suspendForLifecycleCount += 1 }
    func resumeAfterLifecycle() { resumeAfterLifecycleCount += 1 }
    func cancelPendingLifecycleWork() { cancelPendingLifecycleWorkCount += 1 }
}
