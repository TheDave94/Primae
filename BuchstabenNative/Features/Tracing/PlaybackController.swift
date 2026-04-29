// PlaybackController.swift
// BuchstabenNative
//
// Encapsulates the audio-playback state machine, its debounced state
// transitions, and the play-intent wall-time deduplication used during
// rapid tap bursts. Extracted from TracingViewModel to keep its God-object
// scope smaller.
//
// DESIGN NOTES (re LESSONS.md audio fragility):
//   - This controller is MainActor-bound like the VM. No audio command moves
//     off the main thread; we only move the state machine + timing bookkeeping.
//   - `request(_:immediate:)` with immediate=true remains fully synchronous —
//     `load(letter:)` in the VM still calls us with immediate=true and the
//     corresponding audio command is issued before we return, preserving the
//     sync-load contract LESSONS.md flags as CRITICAL.
//   - Debounce timings (activeDebounceSeconds / idleDebounceSeconds) must match
//     the values tests assert against in TracingViewModelTests; exposed as
//     constructor parameters so tests can still tune if needed.

import Foundation
import QuartzCore

@MainActor
final class PlaybackController {

    // MARK: - Injected

    private let audio: AudioControlling
    /// Invoked when the audible playing state changes. VM uses this to
    /// update its @Observable `isPlaying` mirror.
    ///
    /// Settable post-init so the owning VM can capture `[weak self]`
    /// AFTER `self.playback` has already been assigned (W-16). Pass the
    /// real callback at init when you can; assign it later when the
    /// callback needs to capture an enclosing object that can't escape
    /// Swift's two-phase init rules.
    var onIsPlayingChanged: (Bool) -> Void

    // MARK: - Tunable timings (live-adjustable from the debug audio panel)

    var activeDebounceSeconds: TimeInterval
    var idleDebounceSeconds: TimeInterval
    /// Coalesces rapid tap bursts (begin→update→end in quick succession) into
    /// a single audible playback. Without this, each short cycle produces a
    /// fresh idle→active transition and a new audio.play() call.
    var playIntentDebounceSeconds: CFTimeInterval

    // MARK: - State

    private var machine = PlaybackStateMachine()
    /// In-flight debounced transition. Exposed read-only so tests can await it
    /// instead of sleeping past the debounce on the wall clock.
    private(set) var pendingTransition: Task<Void, Never>?
    private var lastPlayIntentWallTime: CFTimeInterval = 0

    // MARK: - Sleep injection

    typealias Sleeper = @Sendable (Duration) async throws -> Void
    private let sleep: Sleeper

    // MARK: - Init

    init(audio: AudioControlling,
         activeDebounceSeconds: TimeInterval = 0.03,
         idleDebounceSeconds: TimeInterval = 0.12,
         playIntentDebounceSeconds: CFTimeInterval = 0.1,
         sleep: @escaping Sleeper = { try await Task.sleep(for: $0) },
         onIsPlayingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.audio = audio
        self.activeDebounceSeconds = activeDebounceSeconds
        self.idleDebounceSeconds = idleDebounceSeconds
        self.playIntentDebounceSeconds = playIntentDebounceSeconds
        self.sleep = sleep
        self.onIsPlayingChanged = onIsPlayingChanged
    }

    // MARK: - Machine access

    var state: PlaybackStateMachine.State { machine.state }

    var appIsForeground: Bool {
        get { machine.appIsForeground }
        set { machine.appIsForeground = newValue }
    }

    var resumeIntent: Bool {
        get { machine.resumeIntent }
        set { machine.resumeIntent = newValue }
    }

    func forceIdle() { machine.forceIdle() }

    /// Direct synchronous state transition (no debounce). Used by the
    /// app-lifecycle path where semantics require immediate effect.
    @discardableResult
    func transition(to target: PlaybackStateMachine.State) -> PlaybackStateMachine.Command {
        machine.transition(to: target)
    }

    /// Apply a command from `transition(to:)`. Lifts the audio call out so
    /// lifecycle callers can choose when to issue the audio side-effect.
    func apply(_ cmd: PlaybackStateMachine.Command) {
        switch cmd {
        case .play:
            let now = CACurrentMediaTime()
            if now - lastPlayIntentWallTime < playIntentDebounceSeconds {
                onIsPlayingChanged(true)
                return
            }
            lastPlayIntentWallTime = now
            audio.play()
            onIsPlayingChanged(true)
        case .stop:
            audio.stop()
            onIsPlayingChanged(false)
        case .none:
            break
        }
    }

    /// Request a transition to the target state. With `immediate=true` the
    /// corresponding audio command fires synchronously before return. Without
    /// immediate, the transition is debounced by the active/idle timing.
    func request(_ target: PlaybackStateMachine.State, immediate: Bool) {
        pendingTransition?.cancel()
        pendingTransition = nil

        let wouldChange: Bool
        if target == .active && (!machine.appIsForeground || !machine.resumeIntent) {
            wouldChange = machine.state != .idle
        } else {
            wouldChange = machine.state != target
        }

        if immediate {
            apply(machine.transition(to: target))
            return
        }

        guard wouldChange else { return }

        let delay = target == .active ? activeDebounceSeconds : idleDebounceSeconds
        let sleeper = sleep
        pendingTransition = Task { [weak self] in
            try? await sleeper(.seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.machine.transition(to: target))
        }
    }

    /// Cancel any in-flight debounced transition AND any pending audio
    /// lifecycle work (AVAudioSession deactivation etc.). Mirror of the
    /// former `cancelPendingPlaybackWork()` in VM.
    func cancelPending() {
        pendingTransition?.cancel()
        pendingTransition = nil
        audio.cancelPendingLifecycleWork()
    }

    /// Reset the play-intent wall clock (used on app-background to avoid
    /// a stale "just played" debouncing a legitimate resume).
    func resetPlayIntentClock() {
        lastPlayIntentWallTime = 0
    }
}
