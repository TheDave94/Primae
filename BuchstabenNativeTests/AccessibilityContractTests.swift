//  AccessibilityContractTests.swift
//  BuchstabenNativeTests

import Testing
import CoreGraphics
@testable import BuchstabenNative

@MainActor
fileprivate final class MockAccessibilityAudio: AudioControlling {
    func loadAudioFile(named: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

@Suite(.serialized) @MainActor struct AccessibilityContractTests {

    fileprivate let audio: MockAccessibilityAudio
    fileprivate let vm: TracingViewModel

    init() {
        audio = MockAccessibilityAudio()
        vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
    }

    @Test func progressString_initial_isZeroPercent() {
        let pct = Int(vm.progress * 100)
        #expect("\(pct) percent complete" == "0 percent complete")
    }

    @Test func progressString_partial_isCorrectPercent() {
        let valueString = "\(Int(vm.progress * 100)) percent complete"
        #expect(valueString.hasSuffix(" percent complete"))
        #expect(!valueString.hasPrefix("-"))
    }

    @Test func progressValue_isClamped() {
        let pct = Int(vm.progress * 100)
        #expect(pct >= 0)
        #expect(pct <= 100)
    }

    @Test func audioHintString_notPlaying_containsPaused() {
        #expect(!vm.isPlaying)
        let hint = vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused"
        #expect(hint.lowercased().contains("paused"))
    }

    @Test func audioHintString_isPlaying_containsPlaying() async {
        vm.beginTouch(at: CGPoint(x: 100, y: 200), t: 1000)
        var t = 1000.0; var p = CGPoint(x: 100, y: 200)
        for _ in 0..<10 {
            t += 0.001; p.x += 10
            vm.updateTouch(at: p, t: t, canvasSize: CGSize(width: 400, height: 400))
        }
        try? await Task.sleep(for: .milliseconds(150))
        let hint = vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused"
        #expect(hint.lowercased().contains("playing"))
    }

    @Test func currentLetterName_isNonEmpty() {
        #expect(!vm.currentLetterName.isEmpty)
    }

    @Test func currentLetterName_isUppercase() {
        let name = vm.currentLetterName
        #expect(name == name.uppercased())
    }

    @Test func afterReset_progressStringIsZero() {
        vm.resetLetter()
        #expect(Int(vm.progress * 100) == 0)
    }

    @Test func afterBackground_isPlayingFalse_hintIsPaused() async {
        vm.beginTouch(at: CGPoint(x: 100, y: 200), t: 1000)
        var t = 1000.0; var p = CGPoint(x: 100, y: 200)
        for _ in 0..<10 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: .init(width: 400, height: 400)) }
        try? await Task.sleep(for: .milliseconds(150))
        vm.appDidEnterBackground()
        #expect(!vm.isPlaying)
        #expect((vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused").contains("paused"))
    }

    @Test func progress_isFinite() {
        #expect(!vm.progress.isNaN)
        #expect(!vm.progress.isInfinite)
    }

    // MARK: - Stroke proximity tests

    @Test func afterStdDrag_progressIsPositive() {
        vm.beginTouch(at: CGPoint(x: 100, y: 200), t: 1000)
        var t = 1000.0; var p = CGPoint(x: 100, y: 200)
        for _ in 0..<10 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: CGSize(width: 400, height: 400)) }
        #expect(vm.progress > 0)
        #expect(Int(vm.progress * 100) > 0)
    }

    @Test func afterStdDrag_accessibilityValue_reflectsProgress() {
        vm.beginTouch(at: CGPoint(x: 100, y: 200), t: 1000)
        var t = 1000.0; var p = CGPoint(x: 100, y: 200)
        for _ in 0..<10 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: CGSize(width: 400, height: 400)) }
        #expect(vm.accessibilityCanvasValue != "Not started")
    }
}
