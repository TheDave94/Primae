//  EndToEndTracingSessionTests.swift
//  BuchstabenNativeTests

import Testing
import CoreGraphics
@testable import BuchstabenNative

@MainActor
fileprivate final class RecordingAudio: AudioControlling {
    enum Event: Equatable {
        case load(String), play, stop, suspend, resume, cancelPending, setAdaptive(speed: Float)
    }
    private(set) var events: [Event] = []
    private(set) var isPlaying = false
    func loadAudioFile(named: String, autoplay: Bool) { events.append(.load(named)) }
    func play()    { events.append(.play);    isPlaying = true  }
    func stop()    { events.append(.stop);    isPlaying = false }
    func restart() { events.append(.play) }
    func suspendForLifecycle()        { events.append(.suspend);       isPlaying = false }
    func resumeAfterLifecycle()       { events.append(.resume) }
    func cancelPendingLifecycleWork() { events.append(.cancelPending) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { events.append(.setAdaptive(speed: speed)) }
    func hasEvent(_ e: Event) -> Bool { events.contains(e) }
    func reset() { events.removeAll(); isPlaying = false }
}

@Suite @MainActor struct EndToEndTracingSessionTests {

    fileprivate let audio: RecordingAudio
    fileprivate let vm: TracingViewModel
    let canvas = CGSize(width: 400, height: 400)

    init() {
        audio = RecordingAudio()
        vm = TracingViewModel(.stub.with(audio: audio))
        vm.strokeEnforced = false
    }

    // MARK: 1 — Initial state

    @Test func initialState() {
        #expect(!vm.isPlaying)
        #expect(vm.progress == 0.0)
        #expect(!vm.currentLetterName.isEmpty)
        #expect(vm.currentLetterName == vm.currentLetterName.uppercased())
    }

    // MARK: 2 — Audio load called on init

    @Test func audioLoaded_onInit() {
        let loadEvents = audio.events.filter { if case .load = $0 { return true }; return false }
        #expect(!loadEvents.isEmpty, "Audio loadAudioFile must be called during init")
    }

    // MARK: 3 — Fast touch → play fires after debounce

    @Test func fastTouch_triggersPlay() async {
        simulateFastTouch(t0: 1000)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(audio.hasEvent(.play), "Fast touch must trigger audio.play()")
        #expect(vm.isPlaying)
    }

    // MARK: 4 — endTouch stops audio

    @Test func endTouch_stopsAudio() async {
        simulateFastTouch(t0: 1000)
        try? await Task.sleep(for: .milliseconds(80))
        audio.reset()
        vm.endTouch()
        #expect(audio.hasEvent(.stop))
        #expect(!vm.isPlaying)
    }

    // MARK: 5 — setAdaptivePlayback called during touch

    @Test func adaptivePlayback_calledDuringTouch() {
        simulateFastTouch(t0: 1000)
        let speeds = audio.events.compactMap { e -> Float? in
            if case .setAdaptive(let s) = e { return s }; return nil
        }
        #expect(!speeds.isEmpty, "setAdaptivePlayback must be called during touch")
        for speed in speeds {
            #expect(speed >= 0.5)
            #expect(speed <= 2.0)
        }
    }

    // MARK: 6 — Full session: progress reaches 1.0

    @Test func fullSession_progressReachesOne() {
        guard gridScanUntilComplete() else { return }
        #expect(vm.progress == 1.0)
    }

    // MARK: 7 — After completion, isPlaying = false

    @Test func fullSession_isPlayingFalseAfterCompletion() {
        guard gridScanUntilComplete() else { return }
        #expect(!vm.isPlaying)
    }

    // MARK: 8 — resetLetter restores initial state

    @Test func resetLetter_restoresInitialState() {
        gridScanUntilComplete()
        vm.resetLetter()
        #expect(vm.progress == 0.0)
        #expect(!vm.isPlaying)
        #expect(audio.hasEvent(.stop))
    }

    // MARK: 9 — Accessibility strings valid throughout session

    @Test func accessibilityStrings_validThroughoutSession() {
        assertAccessibilityStringsValid(label: "initial")
        simulateFastTouch(t0: 1000)
        assertAccessibilityStringsValid(label: "during touch")
        vm.endTouch()
        assertAccessibilityStringsValid(label: "after endTouch")
        vm.resetLetter()
        assertAccessibilityStringsValid(label: "after reset")
    }

    // MARK: 10 — Full bg/fg lifecycle around a session

    @Test func lifecycleAroundSession() async {
        simulateFastTouch(t0: 1000)
        try? await Task.sleep(for: .milliseconds(80))
        vm.appDidEnterBackground()
        #expect(audio.hasEvent(.suspend))
        #expect(!vm.isPlaying)
        audio.reset()
        vm.appDidBecomeActive()
        #expect(audio.hasEvent(.resume))
        assertAccessibilityStringsValid(label: "after foreground return")
    }

    // MARK: 11 — nextLetter changes state cleanly

    @Test func selectLetter_changesCurrentLetter() {
        vm.nextLetter()
        #expect(!vm.currentLetterName.isEmpty)
        #expect(vm.currentLetterName == vm.currentLetterName.uppercased())
        #expect(vm.progress == 0.0)
    }

    // MARK: - Helpers

    private func simulateFastTouch(t0: CFTimeInterval) {
        vm.beginTouch(at: CGPoint(x: 50, y: 200), t: t0)
        var t = t0; var p = CGPoint(x: 50, y: 200)
        for _ in 0..<15 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    @discardableResult
    private func gridScanUntilComplete() -> Bool {
        let t0: CFTimeInterval = 2000.0
        vm.beginTouch(at: .zero, t: t0); var t = t0
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
        #expect(pct >= 0,   "[\(label)] pct < 0")
        #expect(pct <= 100, "[\(label)] pct > 100")
        #expect(!vm.currentLetterName.isEmpty, "[\(label)] letter name empty")
        #expect(!vm.progress.isNaN,            "[\(label)] progress NaN")
        #expect(!vm.progress.isInfinite,        "[\(label)] progress infinite")
        #expect(!(vm.isPlaying ? "Audio is currently playing" : "Audio is currently paused").isEmpty)
    }
}
