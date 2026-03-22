//  VoiceOverAccessibilityTests.swift
//  BuchstabenNativeTests

import Testing
@testable import BuchstabenNative

@MainActor
private final class LocalMockAudioController: AudioControlling {
    var stopCount = 0
    var playCount = 0
    func loadAudioFile(named: String, autoplay: Bool) {}
    func play() { playCount += 1 }
    func stop() { stopCount += 1 }
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

@Suite @MainActor struct VoiceOverAccessibilityTests {

    let vm: TracingViewModel
    let audioController: LocalMockAudioController

    init() {
        audioController = LocalMockAudioController()
        vm = TracingViewModel(.stub.with(audio: audioController))
    }

    @Test func canvasLabel_includesCurrentLetterName() {
        #expect(vm.accessibilityCanvasLabel.contains(vm.currentLetterName))
    }
    @Test func canvasLabel_containsCanvasDescriptor() {
        #expect(vm.accessibilityCanvasLabel.localizedCaseInsensitiveContains("canvas"))
    }
    @Test func canvasLabel_updatesWithLetterChange() {
        vm.nextLetter()
        #expect(vm.accessibilityCanvasLabel.localizedCaseInsensitiveContains("canvas"))
        #expect(vm.accessibilityCanvasLabel.contains(vm.currentLetterName))
    }
    @Test func canvasValue_atZeroProgress_returnsNotStarted() {
        vm.progress = 0
        #expect(vm.accessibilityCanvasValue == "Not started")
    }
    @Test func canvasValue_atFullProgress_returnsComplete() {
        vm.progress = 1.0
        #expect(vm.accessibilityCanvasValue == "Complete")
    }
    @Test func canvasValue_atHalfProgress_returnsPercent() {
        vm.progress = 0.5
        #expect(vm.accessibilityCanvasValue == "50 percent complete")
    }
    @Test func canvasValue_atOnePercent() {
        vm.progress = 0.01
        #expect(vm.accessibilityCanvasValue == "1 percent complete")
    }
    @Test func canvasValue_at99Percent() {
        vm.progress = 0.999
        #expect(vm.accessibilityCanvasValue == "99 percent complete")
    }
    @Test func canvasValue_clampsBelowZero() {
        vm.progress = -0.5
        #expect(vm.accessibilityCanvasValue == "Not started")
    }
    @Test func canvasValue_clampsAboveOne() {
        vm.progress = 1.5
        #expect(vm.accessibilityCanvasValue == "Complete")
    }
    @Test func replayAudio_callsStopThenPlay() {
        audioController.stopCount = 0; audioController.playCount = 0
        vm.replayAudio()
        #expect(audioController.stopCount == 1)
        #expect(audioController.playCount == 1)
    }
    @Test func replayAudio_stopCalledBeforePlay() {
        audioController.stopCount = 0; audioController.playCount = 0
        vm.replayAudio()
        #expect(audioController.stopCount >= 1)
        #expect(audioController.playCount >= 1)
    }
    @Test func nextLetter_isCallable() {
        vm.nextLetter()
        #expect(!vm.currentLetterName.isEmpty)
    }
    @Test func previousLetter_isCallable() {
        vm.previousLetter()
        #expect(!vm.currentLetterName.isEmpty)
    }
    @Test func randomLetter_isCallable() {
        vm.randomLetter()
        #expect(!vm.currentLetterName.isEmpty)
    }
    @Test func resetLetter_resetsProgress() {
        vm.progress = 0.75
        vm.resetLetter()
        #expect(abs(vm.progress) < 1e-6)
    }
    @Test func toggleGhost_flipsShowGhost() {
        let initial = vm.showGhost
        vm.toggleGhost()
        #expect(vm.showGhost == !initial)
        vm.toggleGhost()
        #expect(vm.showGhost == initial)
    }
}
