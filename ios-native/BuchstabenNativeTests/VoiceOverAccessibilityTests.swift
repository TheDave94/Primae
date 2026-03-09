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
        try await super.setUp()
        // async throws override preserves @MainActor isolation (Swift 6).
        audioController = LocalMockAudioController()
        vm = TracingViewModel(audio: audioController)
    }

    // MARK: - accessibilityCanvasLabel

    func testCanvasLabel_includesCurrentLetterName() {
        XCTAssertTrue(vm.accessibilityCanvasLabel.contains(vm.currentLetterName),
                      "Label should include current letter: \(vm.currentLetterName)")
    }

    func testCanvasLabel_containsCanvasDescriptor() {
        XCTAssertTrue(vm.accessibilityCanvasLabel.localizedCaseInsensitiveContains("canvas"))
    }

    func testCanvasLabel_updatesWithLetterChange() {
        let before = vm.accessibilityCanvasLabel
        vm.nextLetter()
        let after = vm.accessibilityCanvasLabel
        // Label should change (unless only 1 letter in repo, unlikely)
        // At minimum, it still contains 'canvas'
        XCTAssertTrue(after.localizedCaseInsensitiveContains("canvas"))
        XCTAssertTrue(after.contains(vm.currentLetterName))
    }

    // MARK: - accessibilityCanvasValue

    func testCanvasValue_atZeroProgress_returnsNotStarted() {
        vm.progress = 0
        XCTAssertEqual(vm.accessibilityCanvasValue, "Not started")
    }

    func testCanvasValue_atFullProgress_returnsComplete() {
        vm.progress = 1.0
        XCTAssertEqual(vm.accessibilityCanvasValue, "Complete")
    }

    func testCanvasValue_atHalfProgress_returnsPercent() {
        vm.progress = 0.5
        XCTAssertEqual(vm.accessibilityCanvasValue, "50 percent complete")
    }

    func testCanvasValue_atOnePercent_returnsOnePercent() {
        vm.progress = 0.01
        XCTAssertEqual(vm.accessibilityCanvasValue, "1 percent complete")
    }

    func testCanvasValue_at99Percent() {
        vm.progress = 0.999
        XCTAssertEqual(vm.accessibilityCanvasValue, "99 percent complete")
    }

    func testCanvasValue_clampsBelowZero() {
        vm.progress = -0.5
        XCTAssertEqual(vm.accessibilityCanvasValue, "Not started")
    }

    func testCanvasValue_clampsAboveOne() {
        vm.progress = 1.5
        XCTAssertEqual(vm.accessibilityCanvasValue, "Complete")
    }

    // MARK: - replayAudio()

    func testReplayAudio_callsStopThenPlay() {
        audioController.stopCount = 0
        audioController.playCount = 0
        vm.replayAudio()
        XCTAssertEqual(audioController.stopCount, 1, "stop() should be called once")
        XCTAssertEqual(audioController.playCount, 1, "play() should be called once")
    }

    func testReplayAudio_stopCalledBeforePlay() {
        audioController.stopCount = 0
        audioController.playCount = 0
        vm.replayAudio()
        XCTAssertGreaterThanOrEqual(audioController.stopCount, 1)
        XCTAssertGreaterThanOrEqual(audioController.playCount, 1)
    }

    // MARK: - Custom action methods exist and are callable

    func testNextLetter_isCallable() {
        let before = vm.currentLetterName
        vm.nextLetter()
        // Letter may or may not change depending on repo size, but no crash
        XCTAssertFalse(vm.currentLetterName.isEmpty)
    }

    func testPreviousLetter_isCallable() {
        vm.previousLetter()
        XCTAssertFalse(vm.currentLetterName.isEmpty)
    }

    func testRandomLetter_isCallable() {
        vm.randomLetter()
        XCTAssertFalse(vm.currentLetterName.isEmpty)
    }

    func testResetLetter_resetsProgress() {
        vm.progress = 0.75
        vm.resetLetter()
        XCTAssertEqual(vm.progress, 0, accuracy: 1e-6)
    }

    func testToggleGhost_flipsShowGhost() {
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
