// OneArmPerSessionTests.swift
// PrimaeNativeTests
//
// One audio arm per child, by construction (David's ruling 2026-11-25,
// `docs/DECISIONS.md`). The researcher switch `cycleAllConditions`, which
// stepped one child through every arm one letter at a time, was removed
// from the study build; nothing in a letter load may change the arm now.
// The arm changes in place on exactly one path: in-place enrolment of the
// next child (`reapplyParticipantIdentity` → `applyArm`), and that path
// must carry the silent arm's authority (ruling C3-2) with it.
//
// This file replaces `CycleAllConditionsTests`. Its cycle tests went with
// the switch; the enrolment-path authority test and the silent-step
// engine test are kept here, driven through the `applyArm` seam.
//
// WHAT THEY CANNOT SEE. Everything here is asserted on view-model state
// and on recorded collaborator calls. Whether sound actually leaves the
// speaker is not observable in-process by any test, on simulator or
// device — the same caveat `SilentArmAuthorityTests` carries.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
fileprivate final class RecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var loadedFiles: [String] = []
    private(set) var stopCount = 0
    private(set) var playCount = 0
    func loadAudioFile(named: String, autoplay: Bool) { loadedFiles.append(named) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func setSpatialPitch(cents: Float) {}
    func play()    { playCount += 1 }
    func stop()    { stopCount += 1 }
    func restart() { playCount += 1 }
    func suspendForLifecycle()        {}
    func resumeAfterLifecycle()       {}
    func cancelPendingLifecycleWork() {}
}

@MainActor
fileprivate final class SpySpeech: SpeechSynthesizing {
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    func speak(_ text: String) { spoken.append(text) }
    func stop() { stopCount += 1 }
}

@MainActor
fileprivate final class SpyPromptPlayer: PromptPlaying {
    private(set) var plays = 0
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) { plays += 1 }
    func stop() {}
    func playSuccessChime()  { plays += 1 }
    func playTapChime()      { plays += 1 }
    func playWrongTapChime() { plays += 1 }
    func playStrokeTick()    { plays += 1 }
}

@Suite(.serialized) @MainActor struct OneArmPerSessionTests {

    private let canvas = CGSize(width: 400, height: 400)

    /// A letter with no strokes (the arm is asserted, no tracing here) but
    /// WITH a phoneme recording — without one the phoneme arm fails
    /// closed and its file list is empty, which would make the positive
    /// controls below vacuous.
    private func makeAsset(_ name: String) -> LetterAsset {
        LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper,
                    audioFiles: ["\(name).mp3"],
                    strokes: LetterStrokes(letter: name, checkpointRadius: 0.1, strokes: []),
                    phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
    }

    /// The stub subset is "AFI", so these three are the study pool.
    private func studyPool() -> [LetterAsset] { ["A", "F", "I"].map(makeAsset) }

    private func makeVM(arm: PilotAudioCondition,
                        studyMode: Bool = true,
                        audio: AudioControlling? = nil,
                        speech: SpeechSynthesizing? = nil,
                        prompts: (any PromptPlaying)? = nil,
                        pool: [LetterAsset]? = nil) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = studyMode
        deps.audioCondition = arm
        if let audio   { deps.audio = audio }
        if let speech  { deps.speech = speech }
        if let prompts { deps.makePromptPlayer = { _ in prompts } }
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        if let pool { vm.letters = pool }
        return vm
    }

    // MARK: - The arm never moves between letters

    /// Every way a session loads a letter — the parked launch un-parking, a
    /// re-load of the same letter (proctor re-entry, cold probes), and real
    /// letter boundaries in both chevron directions — for every arm. A study
    /// session runs the set in the fixed motor order (I · F · A for the stub
    /// subset AFI) and the fixture starts on "A", the LAST of it; a study
    /// chevron does not wrap (STATE-5), so the walk is A → F → I → F.
    @Test("the assigned arm survives every letter load, in every arm",
          arguments: PilotAudioCondition.allCases)
    func armNeverChangesBetweenLetters(arm: PilotAudioCondition) {
        let vm = makeVM(arm: arm, pool: studyPool())
        #expect(vm.audioCondition == arm, "precondition: the launch letter runs the assigned arm")

        vm.startParkedLetter()
        #expect(vm.audioCondition == arm, "un-parking the launch letter moved the arm to \(vm.audioCondition)")
        vm.loadLetter(name: vm.currentLetterName)
        #expect(vm.audioCondition == arm, "re-loading the current letter moved the arm to \(vm.audioCondition)")

        var letters: [String] = [vm.currentLetterName]
        for step in 1...3 {
            let previous = vm.currentLetterName
            if step < 3 { vm.previousLetter() } else { vm.nextLetter() }   // A → F → I → F
            #expect(vm.currentLetterName != previous,
                    "precondition: step \(step) must actually change the letter, or the assertion below is vacuous")
            letters.append(vm.currentLetterName)
            #expect(vm.audioCondition == arm,
                    "the arm moved to \(vm.audioCondition) at letter \(vm.currentLetterName) (walk \(letters)) — one arm per child must hold by construction")
            #expect(vm.engineFollowsArm, "the engine gate does not follow the \(arm) arm at \(vm.currentLetterName)")
        }
    }

    // MARK: - The arm's authority travels with the arm (C3-2)

    /// The C3-2 property on the ENROLMENT path — since the within-subject
    /// cycle was removed, the only path on which the arm changes in place.
    ///
    /// `reapplyParticipantIdentity` used to assign `audioCondition` with a
    /// bare `=`, so an incoming child assigned the silent arm kept the
    /// outgoing session's live speech and prompt pair: the arm whose whole
    /// manipulation IS the absence of sound would have spoken. It now goes
    /// through `applyArm`, which carries the authority with the arm.
    ///
    /// Driven through the seam rather than through
    /// `resetForNewParticipant`, because enrolment derives its arm from the
    /// participant UUID — a test on that path would exercise the silent
    /// branch about one draw in three and pass silently the rest of the
    /// time. A property that holds two times in three is not pinned.
    ///
    /// studyMode OFF deliberately: outside study mode the injected speech
    /// IS the session's speech, so the swap is OBSERVABLE. Under study mode
    /// the speech pair is already null, and this assertion could not fail.
    @Test("applying an arm carries its authority, and leaving it restores — the enrolment path")
    func applyArmCarriesAuthorityOnTheEnrolmentPath() {
        let speech = SpySpeech()
        let prompts = SpyPromptPlayer()
        let vm = makeVM(arm: .phoneme, studyMode: false,
                        speech: speech, prompts: prompts, pool: studyPool())
        #expect((vm.speech as AnyObject) === speech,
                "precondition: this session starts with the injected speech in use")

        vm.applyArm(.silent)
        #expect(vm.audioCondition == .silent)
        #expect(vm.speech is NullSpeechSynthesizer,
                "an arm applied mid-session kept the live speech synthesiser — this is the enrolment path, where the incoming child's silent arm must silence the OUTGOING session")
        #expect(vm.prompts is NullPromptPlayer,
                "an arm applied mid-session kept a live prompt player")

        vm.applyArm(.spatial)
        #expect((vm.speech as AnyObject) === speech,
                "applying a sound arm after a silent one must RESTORE the session's pair, not ratchet it silent")
        #expect((vm.prompts as AnyObject) === prompts,
                "the prompt player must be restored with the speech pair")
    }

    /// A sound → silent step on the enrolment seam: the engine is stopped as
    /// part of the step, and no load path hands it a file afterwards.
    @Test("no audio path loads a file after an in-place step into the silent arm, and the engine is stopped")
    func silentArmReachedInPlaceLoadsNothing() async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: .phoneme, audio: audio, pool: studyPool())

        // Positive control first: without it the assertion below could hold
        // on a session that never reaches the engine at all. Matched on the
        // SUFFIX: the resource provider names the file with its letter
        // folder ("A/A_phoneme1.mp3").
        #expect(audio.loadedFiles.contains { $0.hasSuffix("_phoneme1.mp3") },
                "positive control: the phoneme arm must load its phoneme at launch: \(audio.loadedFiles)")

        let stopsBefore = audio.stopCount
        vm.applyArm(.silent)
        #expect(vm.audioCondition == .silent)
        #expect(audio.stopCount > stopsBefore,
                "entering the silent arm did not stop the engine — its stop() is what clears the loaded file, so the previous arm's sound could still be played by the coupling")
        let baseline = audio.loadedFiles.count

        // Everything that can hand the engine a file, driven in order.
        vm.previousLetter()
        vm.autoplayActiveCellLetter()
        vm.reloadActiveAudioFile()
        vm.armPreTaskDemonstration(for: vm.letters[0], duration: 0.01)
        try? await Task.sleep(for: .milliseconds(80))

        #expect(audio.loadedFiles.count == baseline,
                "the silent arm loaded a file: \(audio.loadedFiles.dropFirst(baseline))")
    }
}
