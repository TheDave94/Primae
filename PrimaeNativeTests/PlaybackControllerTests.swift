// Direct tests for the playback state machine wrapper extracted from
// TracingViewModel. Confirms the LESSONS.md sync-load contract
// (immediate=true produces a synchronous audio side-effect) and the
// debounced idle/active timings match VM assumptions.

import Foundation
import Testing
@testable import PrimaeNative

@MainActor
final class PlaybackTestAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var playCount = 0
    private(set) var stopCount = 0
    private(set) var cancelLifecycleCount = 0
    func loadAudioFile(named: String, autoplay: Bool) {}
    func play() { playCount += 1 }
    func stop() { stopCount += 1 }
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() { cancelLifecycleCount += 1 }
}

/// Box a value type so closures that update test state compile under
/// @Sendable-like constraints without needing inout / Task-Local shenanigans.
@MainActor
final class Box<T> {
    var value: T
    init(_ v: T) { value = v }
}

@MainActor
@Suite struct PlaybackControllerTests {

    /// Build a controller + its spying audio. Default param omitted because
    /// `@MainActor final class PlaybackTestAudio`'s init is actor-isolated,
    /// which Swift 6 strict mode forbids in a default-argument expression.
    private func make() -> (PlaybackController, PlaybackTestAudio, Box<Bool>) {
        let audio = PlaybackTestAudio()
        let isPlaying = Box(false)
        let controller = PlaybackController(audio: audio,
                                             onIsPlayingChanged: { isPlaying.value = $0 })
        controller.appIsForeground = true
        controller.resumeIntent = true
        return (controller, audio, isPlaying)
    }

    @Test func immediateActiveTransition_playsSynchronously() {
        let (c, audio, isPlaying) = make()
        c.request(.active, immediate: true)
        #expect(audio.playCount == 1, "immediate=true must play synchronously")
        #expect(isPlaying.value == true)
    }

    @Test func immediateIdleTransition_stopsSynchronously() {
        let (c, audio, isPlaying) = make()
        c.request(.active, immediate: true)
        c.request(.idle, immediate: true)
        #expect(audio.stopCount == 1)
        #expect(isPlaying.value == false)
    }

    /// The dedup window coalesces only what is ALREADY SOUNDING.
    ///
    /// Rewritten 2026-09-17. This test used to fire five idle/active
    /// cycles and assert `playCount <= 2` — pinning the window as
    /// swallowing plays for a STOPPED engine too. That is the behaviour a
    /// supervisor's device review reported as "alle sounds müssen
    /// spielen": a play intent arriving inside the window on a silent
    /// engine was deferred to the end of the window, and only fired if
    /// the machine was still active by then. A stroke that both began and
    /// ended inside the window therefore never sounded at all, and one
    /// that outlived it started up to 100 ms late — their "Latenz?".
    /// A, F and L are the multi-stroke study letters, so this was the
    /// ordinary cadence of three of the five.
    ///
    /// What the window is still FOR is the other case, tested second
    /// below: repeated play intents within a single stroke, where the
    /// sound is already running and a fresh `audio.play()` is pure churn.
    ///
    /// Uses `apply` directly rather than `request` so the two cases are
    /// distinguished by engine state alone, with no dependence on how the
    /// state machine folds repeated transitions.
    @Test func playIntentWindow_coalescesWhileSounding_only() {
        let (c, audio, _) = make()
        c.apply(.play)
        #expect(audio.playCount == 1)
        // Still sounding: a second intent inside the window is churn.
        c.apply(.play)
        #expect(audio.playCount == 1,
                "a play intent while the engine is already sounding must be swallowed; got \(audio.playCount)")
        // Pen up, then pen down — the engine is silent now, so the sound
        // must start at once: no deferral, and no dropped stroke.
        c.apply(.stop)
        c.apply(.play)
        #expect(audio.playCount == 2,
                "a play intent while the engine is SILENT must start sound immediately; got \(audio.playCount)")
    }

    /// The multi-stroke cadence: every pen-down must sound, even inside
    /// one dedup window. This is the regression the rewrite above closes.
    @Test func playIntentWindow_neverSwallowsAStrokeStart() {
        let (c, audio, _) = make()
        for _ in 0..<5 {
            c.apply(.stop)
            c.apply(.play)
        }
        #expect(audio.playCount == 5,
                "every stroke start must sound, even inside the dedup window; got \(audio.playCount)")
    }

    @Test func activeWithoutResumeIntent_doesNotPlay() {
        let (c, audio, _) = make()
        c.resumeIntent = false
        c.request(.active, immediate: true)
        // Machine forces active→idle when resumeIntent=false; audio.play should not fire.
        #expect(audio.playCount == 0)
    }

    @Test func activeWhileBackgrounded_doesNotPlay() {
        let (c, audio, _) = make()
        c.appIsForeground = false
        c.request(.active, immediate: true)
        #expect(audio.playCount == 0)
    }

    @Test func cancelPending_callsAudioCancelLifecycle() {
        let (c, audio, _) = make()
        c.cancelPending()
        #expect(audio.cancelLifecycleCount >= 1)
    }

    /// F9 (touch-path sweep, 2026-09-06): the out-of-bounds path stops
    /// the engine directly, then calls `forceIdle()` purely to reset the
    /// pure state machine — `forceIdle()` must ALSO reset `audioIsRunning`
    /// to match, or a `.play` that lands inside the play-intent debounce
    /// window right after (a quick re-entry) reports `isPlaying = true`
    /// while never actually calling `audio.play()` again: the debounce
    /// branch's own deferred-play fallback exists exactly for a stopped
    /// engine and refuses to believe one just because `audioIsRunning`
    /// was left stale-true.
    @Test func forceIdle_thenQuickReplay_stillResumesAudio() async {
        let audio = PlaybackTestAudio()
        // A huge debounce window guarantees the second request below
        // lands inside it regardless of real wall-clock timing.
        let c = PlaybackController(audio: audio, playIntentDebounceSeconds: 100,
                                   sleep: { _ in }, onIsPlayingChanged: { _ in })
        c.appIsForeground = true
        c.resumeIntent = true
        c.request(.active, immediate: true)
        #expect(audio.playCount == 1)
        // Out-of-bounds path: the engine was stopped directly (bypassing
        // apply), then the machine is force-reset — audio.stop() is not
        // called here on purpose, matching every production call site.
        c.forceIdle()
        c.request(.active, immediate: true)
        for _ in 0..<200 where audio.playCount < 2 { await Task.yield() }
        #expect(audio.playCount == 2,
                "the deferred fallback must still resume the engine after forceIdle()")
    }

    @Test func debouncedActive_firesAfterDelay() async {
        // Inject an instant sleep so the debounce fires deterministically — no wall clock.
        let audio = PlaybackTestAudio()
        let isPlaying = Box(false)
        let c = PlaybackController(audio: audio,
                                   activeDebounceSeconds: 0.05,
                                   idleDebounceSeconds: 0.10,
                                   sleep: { _ in },
                                   onIsPlayingChanged: { isPlaying.value = $0 })
        c.appIsForeground = true
        c.resumeIntent = true
        c.request(.active, immediate: false)
        #expect(audio.playCount == 0, "Debounced transition must NOT fire synchronously")
        await c.pendingTransition?.value
        #expect(audio.playCount == 1, "Debounced transition should fire after sleeper resumes")
    }

    /// The engine discards its file on stop(); a play() without a
    /// reload is a no-op. The reload hook must run before EVERY play,
    /// the immediate one and the deferred one (audit 2026-09-06).
    @Test func reloadHook_runsBeforeEveryPlay() async {
        let audio = PlaybackTestAudio()
        let order = Box<[String]>([])
        let c = PlaybackController(audio: audio, playIntentDebounceSeconds: 0.0,
                                   sleep: { _ in }, onIsPlayingChanged: { _ in })
        c.appIsForeground = true
        c.resumeIntent = true
        c.reloadBeforePlay = { order.value.append("reload:\(audio.playCount)") }
        c.request(.active, immediate: true)
        #expect(audio.playCount == 1)
        #expect(order.value == ["reload:0"], "reload must precede the first play")
        c.request(.idle, immediate: true)
        c.request(.active, immediate: true)
        #expect(audio.playCount == 2)
        #expect(order.value == ["reload:0", "reload:1"], "reload must precede the play after a stop")
    }

    /// A debounced idle request repeated on every move sample must not
    /// restart the timer, or continuous off-path movement never goes
    /// idle (audit 2026-09-06). An active request still cancels it.
    @Test func repeatedIdleRequest_keepsThePendingTimer() async {
        final class Gate: @unchecked Sendable {
            let lock = NSLock(); var sleeps = 0
            func hit() { lock.lock(); sleeps += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return sleeps }
        }
        let gate = Gate()
        let audio = PlaybackTestAudio()
        let c = PlaybackController(audio: audio, idleDebounceSeconds: 0.10,
                                   sleep: { _ in gate.hit(); try await Task.sleep(for: .seconds(60)) },
                                   onIsPlayingChanged: { _ in })
        c.appIsForeground = true
        c.resumeIntent = true
        c.request(.active, immediate: true)
        c.request(.idle, immediate: false)
        let first = c.pendingTransition
        #expect(first != nil)
        for _ in 0..<20 { c.request(.idle, immediate: false) }
        #expect(c.pendingTransition == first, "the same idle timer must survive repeated idle requests")
        for _ in 0..<200 where gate.count < 1 { await Task.yield() }
        #expect(gate.count == 1, "exactly one idle sleep in flight, got \(gate.count)")
        // Back on-path: the immediate active request replaces the pending
        // idle with a fresh stall timeout (AE-2b) — a new task, not none.
        c.request(.active, immediate: true)
        #expect(c.pendingTransition != nil && c.pendingTransition != first,
                "an active sample re-arms the stall timeout")
        #expect(audio.stopCount == 0, "idle never fired")
        c.cancelPending()
    }

    /// Ruling AE-2b: a pen that stops sends no samples; the last active
    /// sample's stall timeout must stop the sound, and the next active
    /// sample must start it again.
    @Test func immediateActive_armsStallIdle_thatStopsAStationaryPen() async {
        let audio = PlaybackTestAudio()
        let c = PlaybackController(audio: audio, idleDebounceSeconds: 0.12,
                                   playIntentDebounceSeconds: 0,
                                   sleep: { _ in }, onIsPlayingChanged: { _ in })
        c.appIsForeground = true
        c.resumeIntent = true
        c.request(.active, immediate: true)
        #expect(audio.playCount == 1)
        #expect(c.pendingTransition != nil, "an active sample must arm the stall timeout")
        await c.pendingTransition?.value
        #expect(audio.stopCount == 1, "no further sample → the stall timeout stops the sound")
        c.request(.active, immediate: true)
        #expect(audio.playCount == 2, "the next movement resumes the sound")
        await c.pendingTransition?.value
        #expect(audio.stopCount == 2)
    }

    @Test func resetPlayIntentClock_allowsImmediateReplay() {
        let (c, audio, _) = make()
        c.request(.active, immediate: true)  // play #1
        c.request(.idle, immediate: true)
        c.resetPlayIntentClock()             // clear the 0.1s dedup window
        c.request(.active, immediate: true)  // should play again
        #expect(audio.playCount == 2,
                "After resetPlayIntentClock, a new play within the dedup window should still fire; got \(audio.playCount)")
    }
}
