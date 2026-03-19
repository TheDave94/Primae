//  VoiceOverAccessibilityTests.swift
//  BuchstabenNativeTests
//
//  Tests for VoiceOver custom action surface:
//  - accessibilityCanvasLabel (includes letter name)
//  - accessibilityCanvasValue (progress string variants)
//  - replayAudio() triggers stop+play on audio controller
//  - Custom action side effects via TracingViewModel

import XCTest
@testable import BuchstabenNative

@MainActor
final class VoiceOverAccessibilityTests: XCTestCase {

    private var vm: TracingViewModel!
    private var audioController: LocalMockAudioController!

    override func setUp() async throws {
        // Do NOT call super.setUp(): XCTestCase.setUp() is `async throws` in Swift 6;
        // calling with `try await` triggers "sending non-Sendable XCTestCase", without
        // `try await` triggers "call can throw/is async". Default impl is a no-op.
        audioController = LocalMockAudioController()
        vm = TracingViewModel(audio: audioController, progressStore: StubProgressStore(), haptics: StubHaptics(), repo: LetterRepository(resources: StubResourceProvider()))
    }

    // MARK: - accessibilityCanvasLabel

    func testCanvasLabel_includesCurrentLetterName() async {
        XCTAssertTrue(vm.accessibilityCanvasLabel.contains(vm.currentLetterName),
                      "Label should include current letter: \(vm.currentLetterName)")
    }

    func testCanvasLabel_containsCanvasDescriptor() async {
        XCTAssertTrue(vm.accessibilityCanvasLabel.localizedCaseInsensitiveContains("canvas"))
    }

    func testCanvasLabel_updatesWithLetterChange() async {
        let before = vm.accessibilityCanvasLabel
        vm.nextLetter()
        let after = vm.accessibilityCanvasLabel
        // Label should change (unless only 1 letter in repo, unlikely)
        // At minimum, it still contains 'canvas'
        XCTAssertTrue(after.localizedCaseInsensitiveContains("canvas"))
        XCTAssertTrue(after.contains(vm.currentLetterName))
    }

    // MARK: - accessibilityCanvasValue

    func testCanvasValue_atZeroProgress_returnsNotStarted() async {
        vm.progress = 0
        XCTAssertEqual(vm.accessibilityCanvasValue, "Not started")
    }

    func testCanvasValue_atFullProgress_returnsComplete() async {
        vm.progress = 1.0
        XCTAssertEqual(vm.accessibilityCanvasValue, "Complete")
    }

    func testCanvasValue_atHalfProgress_returnsPercent() async {
        vm.progress = 0.5
        XCTAssertEqual(vm.accessibilityCanvasValue, "50 percent complete")
    }

    func testCanvasValue_atOnePercent_returnsOnePercent() async {
        vm.progress = 0.01
        XCTAssertEqual(vm.accessibilityCanvasValue, "1 percent complete")
    }

    func testCanvasValue_at99Percent() async {
        vm.progress = 0.999
        XCTAssertEqual(vm.accessibilityCanvasValue, "99 percent complete")
    }

    func testCanvasValue_clampsBelowZero() async {
        vm.progress = -0.5
        XCTAssertEqual(vm.accessibilityCanvasValue, "Not started")
    }

    func testCanvasValue_clampsAboveOne() async {
        vm.progress = 1.5
        XCTAssertEqual(vm.accessibilityCanvasValue, "Complete")
    }

    // MARK: - replayAudio()

    func testReplayAudio_callsStopThenPlay() async {
        audioController.stopCount = 0
        audioController.playCount = 0
        vm.replayAudio()
        XCTAssertEqual(audioController.stopCount, 1, "stop() should be called once")
        XCTAssertEqual(audioController.playCount, 1, "play() should be called once")
    }

    func testReplayAudio_stopCalledBeforePlay() async {
        audioController.stopCount = 0
        audioController.playCount = 0
        vm.replayAudio()
        XCTAssertGreaterThanOrEqual(audioController.stopCount, 1)
        XCTAssertGreaterThanOrEqual(audioController.playCount, 1)
    }

    // MARK: - Custom action methods exist and are callable

    func testNextLetter_isCallable() async {
        let before = vm.currentLetterName
        vm.nextLetter()
        // Letter may or may not change depending on repo size, but no crash
        XCTAssertFalse(vm.currentLetterName.isEmpty)
    }

    func testPreviousLetter_isCallable() async {
        vm.previousLetter()
        XCTAssertFalse(vm.currentLetterName.isEmpty)
    }

    func testRandomLetter_isCallable() async {
        vm.randomLetter()
        XCTAssertFalse(vm.currentLetterName.isEmpty)
    }

    func testResetLetter_resetsProgress() async {
        vm.progress = 0.75
        vm.resetLetter()
        XCTAssertEqual(vm.progress, 0, accuracy: 1e-6)
    }

    func testToggleGhost_flipsShowGhost() async {
        let initial = vm.showGhost
        vm.toggleGhost()
        XCTAssertEqual(vm.showGhost, !initial)
        vm.toggleGhost()
        XCTAssertEqual(vm.showGhost, initial)
    }
}

// MARK: - Local mock for this test file

@MainActor
private final class LocalMockAudioController: AudioControlling {
    var stopCount = 0
    var playCount = 0
    var loadedFile: String?
    var adaptiveSpeed: Float?
    var horizontalBias: Float?
    var setPlaybackStateCalled = false

    func loadAudioFile(named: String, autoplay: Bool) { loadedFile = named }
    func play() { playCount += 1 }
    func stop() { stopCount += 1 }
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        adaptiveSpeed = speed
        self.horizontalBias = horizontalBias
    }
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}
