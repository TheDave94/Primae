// DemonstrationDeliveryTests.swift
// PrimaeNativeTests
//
// Audit R-076: the once-per-condition ledger (`demonstratedAudioConditions`)
// used to be written when the whole-observe sound was CLAIMED at letter load,
// before the sound was delivered. A claim that never plays (the letter
// changes, the phase ends, the session is interrupted) still used the
// condition up, and the child never heard its demonstration. The ledger is
// now written when the sound starts.
//
// Instrument: an engine recorder. "Delivered" is an engine `play()` after a
// non-autoplay load; "demonstrated" is an autoplay load. Neither says sound
// left the speaker.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
private final class DeliveryRecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var autoplayLoads = 0
    private(set) var plays = 0
    private var playWatchers: [CheckedContinuation<Void, Never>] = []
    func loadAudioFile(named: String, autoplay: Bool) { if autoplay { autoplayLoads += 1 } }
    func play() {
        plays += 1
        let due = playWatchers
        playWatchers.removeAll()
        due.forEach { $0.resume() }
    }
    /// Returns when the engine has been asked to play at least once: resumed
    /// BY the play, so neither a clock nor a count of turns decides it.
    func firstPlay() async {
        guard plays == 0 else { return }
        await withCheckedContinuation { playWatchers.append($0) }
    }
    func stop() {}
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func setSpatialPitch(cents: Float) {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

@Suite(.serialized) @MainActor
struct DemonstrationDeliveryTests {

    private func letterA() -> LetterAsset {
        LetterAsset(id: "A", name: "A", baseLetter: "A", letterCase: .upper,
                    audioFiles: ["A.mp3"],
                    strokes: LetterStrokes(letter: "A", checkpointRadius: 0.1, strokes: []),
                    phonemeAudioFiles: ["A_phoneme1.mp3"])
    }

    /// Give the main actor a turn so a task another test needs can run.
    ///
    /// MEASURED 2026-11-17/18, physical iPad, full `PrimaeNativeTests`
    /// target on main e7f0bb1e: this suite runs in parallel with 238
    /// others and the main actor is saturated while they start — a
    /// `Task.sleep(for: .milliseconds(10))` in THIS test took 201.5 s to
    /// come back. Any assertion built on a wall-clock deadline ("0.05 s
    /// has surely passed", "10 s is surely enough") therefore fails for a
    /// reason that has nothing to do with the behaviour under test: with
    /// that deadline expired the loop stopped yielding, and the armed
    /// observe presentation (`pending=armed(gen 1) task(live) arm=phoneme
    /// files=1 silenced=false`, measured) never got its turn.
    ///
    /// So the wait watches the EVENT and only ever yields the actor: no
    /// timer, no deadline. 20 000 yields is a safety stop far above the
    /// few turns this needs once the actor is free, and an exhausted wait
    /// fails the expectation below with the state in the message rather
    /// than reading as a slow machine.
    private func waitForEvent(_ condition: () -> Bool,
                              attempts: Int = 20_000) async {
        var turn = 0
        while !condition() && turn < attempts {
            turn += 1
            await Task.yield()
        }
    }

    /// The state worth putting in a failure message: the same facts that
    /// took three device runs to establish by hand.
    private func state(_ vm: TracingViewModel, _ audio: DeliveryRecordingAudio) -> String {
        "plays=\(audio.plays) autoplay=\(audio.autoplayLoads) "
            + "phase=\(vm.learningPhase) parked=\(vm.launchParked) "
            + "enrolled=\(vm.participantEnrolled) block=\(vm.sessionBlockReason ?? "nil") "
            + "| \(vm.debugObservePresentationState)"
    }

    private func makeVM(audio: DeliveryRecordingAudio, fallback: TimeInterval) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.audioCondition = .phoneme
        deps.oncePerCondition = true
        deps.observeCueFallbackSeconds = fallback
        deps.spokenFeedbackInStudy = StudyComparisonSettings.spokenFeedbackInStudyDefault
        let vm = TracingViewModel(deps.with(audio: audio))
        // A study launch is PARKED (StudyLaunchTests.studyLaunchIsParked):
        // the init load claims nothing and arms nothing. The claim and the
        // observe presentation under test happen at the proctor's start.
        // Without this both tests ran against a VM that never reached the
        // claim, so the negative test passed vacuously and the positive
        // control could never see a play (measured on device 2026-11-16).
        vm.canvasSize = CGSize(width: 1200, height: 800)
        vm.startParkedLetter()
        return vm
    }

    /// The init load claims the observe sound, whose start waits for the
    /// cue (fallback 30 s here, so it never starts in this test). Nothing
    /// was delivered, so the condition is unspent and the demonstration
    /// still plays.
    @Test("a claimed observe sound that never starts does not spend the condition")
    func undeliveredClaimDoesNotSpendTheCondition() async {
        let audio = DeliveryRecordingAudio()
        let vm = makeVM(audio: audio, fallback: 30)
        #expect(!vm.launchParked && vm.learningPhase == .observe,
                "precondition: the letter was started in observe, so the observe sound was claimed")
        #expect(audio.plays == 0, "precondition: the claimed sound has not started")

        vm.armPreTaskDemonstration(for: letterA(), duration: 0.05)
        await waitForEvent { audio.autoplayLoads >= 1 }

        #expect(audio.autoplayLoads == 1,
                "the claim alone spent the condition: the child would hear no demonstration — \(state(vm, audio))")
    }

    /// Positive control: once the sound HAS started, the condition is spent.
    ///
    /// The start comes from the production cue-fallback timer (0.05 s here),
    /// a wall-clock sleep, and the wait used to be at most 20 000 main-actor
    /// yields: on an idle actor those can all run before 50 ms have passed,
    /// and on a saturated one (CI, 2026-11-17: 229-424 s into the run) the
    /// order is the scheduler's. The wait is now the recorder's own `play()`
    /// event. A play that never comes would hang it, so the time limit is
    /// that hang's report, not a speed budget: it is minutes, and firing late
    /// on a busy runner cannot fail a test that already finished.
    @Test("a delivered observe sound spends the condition", .timeLimit(.minutes(30)))
    func deliveredSoundSpendsTheCondition() async {
        let audio = DeliveryRecordingAudio()
        let vm = makeVM(audio: audio, fallback: 0.05)
        #expect(!vm.launchParked && vm.learningPhase == .observe,
                "precondition: the letter was started in observe")
        // A blocked session starts no arm sound at all (`startObservePhaseAudio`
        // guards on `sessionBlockReason`), so a block would look exactly like
        // "the sound never came": name it here rather than blame the timing.
        #expect(vm.sessionBlockReason == nil,
                "precondition: the session is not blocked")
        await audio.firstPlay()
        #expect(audio.plays >= 1,
                "precondition: the observe sound started — \(state(vm, audio))")

        vm.armPreTaskDemonstration(for: letterA(), duration: 0.05)
        // Negative expectation: give the demonstration every chance to
        // arrive before asserting it did not. A fixed number of turns, not
        // a duration, for the reason in `waitForEvent`.
        await waitForEvent({ audio.autoplayLoads >= 1 }, attempts: 200)

        #expect(audio.autoplayLoads == 0,
                "the condition was demonstrated by the observe sound; a second one is a repeat — \(state(vm, audio))")
    }
}
