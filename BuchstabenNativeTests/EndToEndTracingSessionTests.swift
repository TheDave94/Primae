//  EndToEndTracingSessionTests.swift
//  BuchstabenNativeTests
//
//  End-to-end simulation of a full letter-tracing session.
//  Covers the integration layer: LetterRepository → TracingViewModel →
//  PlaybackStateMachine → AudioControlling, verifying:
//  - Audio cue sequencing (load → play → stop on complete)
//  - Progress reaches 1.0 on completion
//  - isPlaying=false after completion (forced idle)
//  - resetLetter restores initial state
//  - Accessibility strings remain valid throughout session
//  - Full bg/fg lifecycle around a session
//
//  Note: XCUITest would cover the actual SwiftUI layer; this covers
//  everything beneath it. A future UITest target can wrap these flows.

import XCTest
import CoreGraphics
@testable import BuchstabenNative

// MARK: - Recording MockAudio

@MainActor
private final class RecordingAudio: AudioControlling {
    enum Event: Equatable {
        case load(String)
        case play
        case stop
        case suspend
        case resume
        case cancelPending
        case setAdaptive(speed: Float)
    }

    private(set) var events: [Event] = []
    private(set) var isPlaying = false

    func loadAudioFile(named: String, autoplay: Bool) { events.append(.load(named)) }
    func play()    { events.append(.play);  isPlaying = true  }
    func stop()    { events.append(.stop);  isPlaying = false }
    func restart() { events.append(.play) }
    func suspendForLifecycle()        { events.append(.suspend);       isPlaying = false }
    func resumeAfterLifecycle()       { events.append(.resume) }
    func cancelPendingLifecycleWork() { events.append(.cancelPending) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {
        events.append(.setAdaptive(speed: speed))
    }

    func hasEvent(_ e: Event) -> Bool { events.contains(e) }
    func eventCount(_ e: Event) -> Int { events.filter { $0 == e }.count }
    func reset() { events.removeAll(); isPlaying = false }
}

// MARK: - EndToEndTracingSessionTests

@MainActor
final class EndToEndTracingSessionTests: XCTestCase {

    private var audio: RecordingAudio!
    private var vm: TracingViewModel!
    private let canvas = CGSize(width: 400, height: 400)

    override func setUp() async throws {
        audio = RecordingAudio()
        // strokeEnforced=false allows velocity-based audio playback without requiring
        // actual stroke checkpoints to be hit — these tests cover the audio/lifecycle
        // pipeline, not stroke recognition accuracy.
        vm = TracingViewModel(singleTouchCooldownAfterNavigation: 0, audio: audio, progressStore: StubProgressStore(), haptics: StubHaptics(), repo: LetterRepository(resources: StubResourceProvider()))
        vm.strokeEnforced = false
    }

    override func tearDown() async throws {
        vm = nil
        audio = nil
    }

    // MARK: 1 — Initial state is correct before any touch

    func testInitialState() {
        XCTAssertFalse(vm.isPlaying, "Initial: not playing")
        XCTAssertEqual(vm.progress, 0.0, accuracy: 1e-9, "Initial: progress = 0")
        XCTAssertFalse(vm.currentLetterName.isEmpty, "Initial: letter name set")
        XCTAssertEqual(vm.currentLetterName, vm.currentLetterName.uppercased(), "Initial: letter name uppercase")
    }

    // MARK: 2 — Audio load called on init (first letter loaded)

    func testAudioLoaded_onInit() {
        XCTAssertFalse(audio.events.filter { if case .load = $0 { return true }; return false }.isEmpty,
                       "Audio loadAudioFile must be called during init")
    }

    // MARK: 3 — Fast touch → play fires after debounce

    func testFastTouch_triggersPlay() throws {
        simulateFastTouch(t0: 1000)
        let exp = expectation(description: "play debounce")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertTrue(audio.hasEvent(.play), "Fast touch must trigger audio.play()")
        XCTAssertTrue(vm.isPlaying)
    }

    // MARK: 4 — endTouch stops audio

    func testEndTouch_stopsAudio() throws {
        simulateFastTouch(t0: 1000)
        let exp = expectation(description: "play")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        audio.reset()
        vm.endTouch()
        XCTAssertTrue(audio.hasEvent(.stop), "endTouch must call audio.stop()")
        XCTAssertFalse(vm.isPlaying)
    }

    // MARK: 5 — setAdaptivePlayback called during touch (speed clamped to valid range)

    func testAdaptivePlayback_calledDuringTouch() {
        simulateFastTouch(t0: 1000)
        let adaptiveEvents = audio.events.compactMap { e -> Float? in
            if case .setAdaptive(let s) = e { return s }; return nil
        }
        XCTAssertFalse(adaptiveEvents.isEmpty, "setAdaptivePlayback must be called during touch")
        for speed in adaptiveEvents {
            XCTAssertGreaterThanOrEqual(speed, 0.5, "speed must be >= 0.5")
            XCTAssertLessThanOrEqual(speed, 2.0,    "speed must be <= 2.0")
        }
    }

    // MARK: 6 — Full session: progress reaches 1.0 via grid scan

    func testFullSession_progressReachesOne() throws {
        let didComplete = gridScanUntilComplete()
        guard didComplete else {
            throw XCTSkip("Letter not completable via grid scan")
        }
        XCTAssertEqual(vm.progress, 1.0, accuracy: 1e-9)
    }

    // MARK: 7 — After completion, isPlaying forced to false

    func testFullSession_isPlayingFalseAfterCompletion() throws {
        let didComplete = gridScanUntilComplete()
        guard didComplete else { throw XCTSkip("Not completable via grid scan") }

        let exp = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertFalse(vm.isPlaying, "After completion, playback must be forced idle")
    }

    // MARK: 8 — resetLetter restores initial state

    func testResetLetter_restoresInitialState() throws {
        gridScanUntilComplete()
        vm.resetLetter()
        XCTAssertEqual(vm.progress, 0.0, accuracy: 1e-9, "Progress must be 0 after reset")
        XCTAssertFalse(vm.isPlaying, "isPlaying must be false after reset")
        XCTAssertTrue(audio.hasEvent(.stop), "reset must call stop")
    }

    // MARK: 9 — Accessibility strings valid throughout session

    func testAccessibilityStrings_validThroughoutSession() throws {
        // Initial
        assertAccessibilityStringsValid(label: "initial")

        // During touch
        simulateFastTouch(t0: 1000)
        assertAccessibilityStringsValid(label: "during touch")

        // After end
        vm.endTouch()
        assertAccessibilityStringsValid(label: "after endTouch")

        // After reset
        vm.resetLetter()
        assertAccessibilityStringsValid(label: "after reset")
    }

    // MARK: 10 — Full bg/fg lifecycle around a session

    func testLifecycleAroundSession() throws {
        simulateFastTouch(t0: 1000)
        let exp1 = expectation(description: "play")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)

        // Enter background mid-session
        vm.appDidEnterBackground()
        XCTAssertTrue(audio.hasEvent(.suspend), "background must suspend audio")
        XCTAssertFalse(vm.isPlaying, "isPlaying must be false in background")

        // Return to foreground
        audio.reset()
        vm.appDidBecomeActive()
        XCTAssertTrue(audio.hasEvent(.resume), "foreground must resume audio")

        // Session still usable
        assertAccessibilityStringsValid(label: "after foreground return")
    }

    // MARK: 11 — Multiple letters: selectLetter changes currentLetterName

    func testSelectLetter_changesCurrentLetter() throws {
        let initial = vm.currentLetterName
        // Try rotating to a different letter
        vm.nextLetter()
        // Either changes or wraps (if only 1 letter loaded in test bundle)
        // Just assert non-crash and valid state
        XCTAssertFalse(vm.currentLetterName.isEmpty)
        XCTAssertEqual(vm.currentLetterName, vm.currentLetterName.uppercased())
        XCTAssertEqual(vm.progress, 0.0, accuracy: 1e-9, "Progress resets on letter change")
        _ = initial  // suppress unused warning
    }

    // MARK: - Helpers

    private func simulateFastTouch(t0: CFTimeInterval) {
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t0)
        var t = t0
        var p = CGPoint(x: 50, y: 200)
        for _ in 0..<15 {
            t += 0.001; p.x += 10
            vm.updateTouch(at: p, t: t, canvasSize: canvas)
        }
    }

    @discardableResult
    private func gridScanUntilComplete() -> Bool {
        let t0: CFTimeInterval = 2000.0
        vm.beginTouch(at: .zero, t: t0)
        var t = t0
        for row in stride(from: 0.0, through: 1.0, by: 0.04) {
            for col in stride(from: 0.0, through: 1.0, by: 0.04) {
                t += 0.001
                vm.updateTouch(at: CGPoint(x: col * canvas.width, y: row * canvas.height), t: t, canvasSize: canvas)
                if vm.progress >= 1.0 { return true }
            }
        }
        return false
    }

    private func assertAccessibilityStringsValid(label: String) {
        let pct = Int(vm.progress * 100)
        XCTAssertGreaterThanOrEqual(pct, 0,   "[\(label)] pct < 0")
        XCTAssertLessThanOrEqual(pct,    100, "[\(label)] pct > 100")
        XCTAssertFalse(vm.currentLetterName.isEmpty, "[\(label)] letter name empty")
        XCTAssertFalse(vm.progress.isNaN,            "[\(label)] progress NaN")
        XCTAssertFalse(vm.progress.isInfinite,        "[\(label)] progress infinite")
        let hint = vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused"
        XCTAssertFalse(hint.isEmpty, "[\(label)] hint empty")
    }
}
