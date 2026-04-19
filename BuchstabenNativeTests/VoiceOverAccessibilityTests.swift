//  VoiceOverAccessibilityTests.swift
//  BuchstabenNativeTests

import Testing
@testable import BuchstabenNative

@MainActor
fileprivate final class LocalMockAudioController: AudioControlling {
    var stopCount = 0
    var playCount = 0
    var loadedFiles: [String] = []
    var loadedAutoplay: [Bool] = []
    func loadAudioFile(named: String, autoplay: Bool) {
        loadedFiles.append(named)
        loadedAutoplay.append(autoplay)
        if autoplay { playCount += 1 }
    }
    func play() { playCount += 1 }
    func stop() { stopCount += 1 }
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

@Suite @MainActor struct VoiceOverAccessibilityTests {

    fileprivate let vm: TracingViewModel
    fileprivate let audioController: LocalMockAudioController

    init() {
        audioController = LocalMockAudioController()
        vm = TracingViewModel(.stub.with(audio: audioController))
    }

    @Test func canvasLabel_includesCurrentLetterName() {
        #expect(vm.accessibilityCanvasLabel.contains(vm.currentLetterName))
    }
    @Test func canvasLabel_containsCanvasDescriptor() {
        // Label is German ("Schreibfläche" = "writing surface"); check for that
        // descriptor instead of the previous English "canvas".
        #expect(vm.accessibilityCanvasLabel.localizedCaseInsensitiveContains("schreibfläche"))
    }
    @Test func canvasLabel_updatesWithLetterChange() {
        vm.nextLetter()
        #expect(vm.accessibilityCanvasLabel.localizedCaseInsensitiveContains("schreibfläche"))
        #expect(vm.accessibilityCanvasLabel.contains(vm.currentLetterName))
    }
    @Test func canvasValue_atZeroProgress_returnsNotStarted() {
        vm.progress = 0
        #expect(vm.accessibilityCanvasValue == "Nicht begonnen")
    }
    @Test func canvasValue_atFullProgress_returnsComplete() {
        vm.progress = 1.0
        #expect(vm.accessibilityCanvasValue == "Fertig")
    }
    @Test func canvasValue_atHalfProgress_returnsPercent() {
        vm.progress = 0.5
        #expect(vm.accessibilityCanvasValue == "50 Prozent fertig")
    }
    @Test func canvasValue_atOnePercent() {
        vm.progress = 0.01
        #expect(vm.accessibilityCanvasValue == "1 Prozent fertig")
    }
    @Test func canvasValue_at99Percent() {
        vm.progress = 0.999
        #expect(vm.accessibilityCanvasValue == "99 Prozent fertig")
    }
    @Test func canvasValue_clampsBelowZero() {
        vm.progress = -0.5
        #expect(vm.accessibilityCanvasValue == "Nicht begonnen")
    }
    @Test func canvasValue_clampsAboveOne() {
        vm.progress = 1.5
        #expect(vm.accessibilityCanvasValue == "Fertig")
    }
    @Test func replayAudio_reloadsCurrentFileWithAutoplay() {
        // The new replayAudio shape (commit f73f71b) reloads the current
        // letter's audio with autoplay=true instead of the old
        // stop()-then-play() which was a no-op because stop() nils
        // currentFile and play() guards on it. Assert the new contract:
        // loadAudioFile was called with autoplay=true at least once.
        audioController.loadedFiles.removeAll()
        audioController.loadedAutoplay.removeAll()
        vm.replayAudio()
        #expect(!audioController.loadedFiles.isEmpty,
                "replayAudio must call loadAudioFile(named:autoplay:)")
        #expect(audioController.loadedAutoplay.last == true,
                "replayAudio must request autoplay so the file actually plays")
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
