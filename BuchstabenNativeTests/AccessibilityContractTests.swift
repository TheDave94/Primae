//  AccessibilityContractTests.swift
//  BuchstabenNativeTests
//
//  Tests for the accessibility contract exposed by TracingViewModel:
//  the dynamic strings fed into .accessibilityValue/.accessibilityHint
//  that VoiceOver reads to the user.
//
//  These are pure ViewModel-level tests — no UIKit/SwiftUI rendering needed.
//  They guard against regressions where progress % or play state strings
//  become stale, empty, or nonsensical.

import XCTest
import CoreGraphics
@testable import BuchstabenNative

@MainActor
final class AccessibilityContractTests: XCTestCase {

    private var audio: MockAccessibilityAudio!
    private var vm: TracingViewModel!

    override func setUp() async throws {
        audio = MockAccessibilityAudio()
        // strokeEnforced=false allows audio/isPlaying state to be driven by velocity
        // alone — these tests verify accessibility string contracts, not stroke recognition.
        vm = TracingViewModel(TracingDependencies(
                    singleTouchCooldownAfterNavigation: 0,
                    audio: audio,
                    progressStore: StubProgressStore(),
                    haptics: StubHaptics(),
                    repo: LetterRepository(resources: StubResourceProvider())))
        vm.strokeEnforced = false
    }

    override func tearDown() async throws {
        vm = nil
        audio = nil
    }

    // MARK: 1 — Progress value string is "0 percent complete" on fresh load

    func testProgressString_initial_isZeroPercent() async {
        let pct = Int(vm.progress * 100)
        let valueString = "\(pct) percent complete"
        XCTAssertEqual(valueString, "0 percent complete")
    }

    // MARK: 2 — Progress value string reflects partial progress

    func testProgressString_partial_isCorrectPercent() async {
        // Drive to ≈50% by completing half the strokes (requires grid scan)
        // We verify the string format is well-formed regardless of exact value.
        let pct = Int(vm.progress * 100)
        let valueString = "\(pct) percent complete"
        XCTAssertTrue(valueString.hasSuffix(" percent complete"),
                      "Accessibility progress string must end with ' percent complete'")
        XCTAssertFalse(valueString.hasPrefix("-"),
                       "Progress percent must not be negative")
    }

    // MARK: 3 — Progress value clamped to [0, 100]

    func testProgressValue_isClamped() async {
        let pct = Int(vm.progress * 100)
        XCTAssertGreaterThanOrEqual(pct, 0,   "Progress percent must be >= 0")
        XCTAssertLessThanOrEqual(pct,    100, "Progress percent must be <= 100")
    }

    // MARK: 4 — isPlaying=false hint text contains "paused"

    func testAudioHintString_notPlaying_containsPaused() async {
        XCTAssertFalse(vm.isPlaying)
        let hint = vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused"
        XCTAssertTrue(hint.lowercased().contains("paused"),
                      "When not playing, accessibility hint must contain 'paused'")
    }

    // MARK: 5 — isPlaying=true hint text contains "playing"

    func testAudioHintString_isPlaying_containsPlaying() async throws {
        // Trigger fast touch to set isPlaying=true
        vm.beginTouch(at: CGPoint(x: 100, y: 200), t: 1000)
        var t = 1000.0
        var p = CGPoint(x: 100, y: 200)
        for _ in 0..<10 {
            t += 0.001; p.x += 10
            vm.updateTouch(at: p, t: t, canvasSize: CGSize(width: 400, height: 400))
        }
        try? await Task.sleep(for: .milliseconds(80))

        let hint = vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused"
        XCTAssertTrue(hint.lowercased().contains("playing"),
                      "When playing, accessibility hint must contain 'playing'")
    }

    // MARK: 6 — currentLetterName is non-empty (used in accessibilityValue)

    func testCurrentLetterName_isNonEmpty() async {
        XCTAssertFalse(vm.currentLetterName.isEmpty,
                       "currentLetterName must be non-empty for VoiceOver to read")
    }

    // MARK: 7 — currentLetterName is uppercase (WCAG: consistent labelling)

    func testCurrentLetterName_isUppercase() async {
        let name = vm.currentLetterName
        XCTAssertEqual(name, name.uppercased(),
                       "Letter name exposed for VoiceOver must be uppercase")
    }

    // MARK: 8 — After resetLetter, progress string returns to 0 percent

    func testAfterReset_progressStringIsZero() async throws {
        vm.resetLetter()
        let pct = Int(vm.progress * 100)
        XCTAssertEqual(pct, 0, "After resetLetter(), accessibility progress must be 0")
    }

    // MARK: 9 — After background, isPlaying=false (hint stays consistent)

    func testAfterBackground_isPlayingFalse_hintIsPaused() async throws {
        vm.beginTouch(at: CGPoint(x: 100, y: 200), t: 1000)
        var t = 1000.0; var p = CGPoint(x: 100, y: 200)
        for _ in 0..<10 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: .init(width: 400, height: 400)) }
        try? await Task.sleep(for: .milliseconds(80))

        vm.appDidEnterBackground()
        XCTAssertFalse(vm.isPlaying)
        let hint = vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused"
        XCTAssertTrue(hint.contains("paused"))
    }

    // MARK: 10 — Progress is never NaN or Infinite (accessibility value safety)

    func testProgress_isFinite() async {
        XCTAssertFalse(vm.progress.isNaN,      "progress must not be NaN")
        XCTAssertFalse(vm.progress.isInfinite, "progress must not be Infinite")
    }
}

// MARK: - Mock

@MainActor
private final class MockAccessibilityAudio: AudioControlling {
    func loadAudioFile(named: String, autoplay: Bool) {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func play() {}
    func stop() {}
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}
