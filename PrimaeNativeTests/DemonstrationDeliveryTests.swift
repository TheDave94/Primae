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
    func loadAudioFile(named: String, autoplay: Bool) { if autoplay { autoplayLoads += 1 } }
    func play() { plays += 1 }
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
        try? await Task.sleep(for: .milliseconds(120))

        #expect(audio.autoplayLoads == 1,
                "the claim alone spent the condition: the child would hear no demonstration")
    }

    /// Positive control: once the sound HAS started, the condition is spent.
    @Test("a delivered observe sound spends the condition")
    func deliveredSoundSpendsTheCondition() async {
        let audio = DeliveryRecordingAudio()
        let vm = makeVM(audio: audio, fallback: 0.05)
        #expect(!vm.launchParked && vm.learningPhase == .observe,
                "precondition: the letter was started in observe")
        try? await Task.sleep(for: .milliseconds(300))
        #expect(audio.plays >= 1, "precondition: the observe sound started")

        vm.armPreTaskDemonstration(for: letterA(), duration: 0.05)
        try? await Task.sleep(for: .milliseconds(120))

        #expect(audio.autoplayLoads == 0,
                "the condition was demonstrated by the observe sound; a second one is a repeat")
    }
}
