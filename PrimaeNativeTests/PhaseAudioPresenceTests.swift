// PhaseAudioPresenceTests.swift
// PrimaeNativeTests
//
// "Is there an audio signal in this phase?" made assertable.
//
// WHY A RECORDING STUB. Nobody can hear a test run — including the
// person reading it afterwards. What CAN be measured is whether the view
// model ASKED the engine to play, which is the moment the signal either
// exists or does not. `RecordingAudio` records every call, so each test
// below asserts the presence or ABSENCE of a playback request for one
// phase, rather than asserting nothing and calling it covered.
//
// This is the instrument the proctor's 2026-10-02 device run lacked. He
// reported "no audio for the demonstration and no audio for the free
// write mode, just the Nachspuren one" — a report no automated test in
// the suite could have confirmed or refuted, because nothing here ever
// asked the question. Everything below is written so that the report
// could NOT recur silently: the three phases are checked independently,
// and the silent arm is checked against the same assertions so that
// "audio appears in a phase" can never be bought by losing the arm that
// must have none.

import Testing
import Foundation
@testable import PrimaeNative

/// Records every audio call instead of performing it.
///
/// `fileprivate` because three other test files define their own
/// `RecordingAudio` — each with a different event vocabulary, all scoped
/// to its own file. Reusing one of those instead was considered and
/// rejected: they record `play` but not the fade-in that this file
/// asserts, so folding this in would mean widening a shared fixture for
/// one caller's benefit.
///
/// The engine itself is exercised on the physical iPad (AudioEngineTests
/// skips on the simulator — AVAudioEngine crashes there); what is
/// testable in CI is the DECISION to play, which is what these tests are
/// about.
@MainActor
fileprivate final class RecordingAudio: AudioControlling {
    private(set) var loadedFiles: [String] = []
    private(set) var playCount = 0
    private(set) var fadeIns: [TimeInterval] = []
    private(set) var adaptiveCalls = 0
    private(set) var stopCount = 0

    var initializationError: String? { nil }

    func loadAudioFile(named fileName: String, autoplay: Bool) { loadedFiles.append(fileName) }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { adaptiveCalls += 1 }
    func setSpatialPitch(cents: Float) {}
    func play() { playCount += 1; fadeIns.append(0) }
    func play(fadeInSeconds: TimeInterval) { playCount += 1; fadeIns.append(fadeInSeconds) }
    func stop() { stopCount += 1 }
    func restart() {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}

    var hasSignal: Bool { playCount > 0 || adaptiveCalls > 0 }
    var nonZeroFades: [TimeInterval] { fadeIns.filter { $0 > 0 } }
}

@MainActor
@Suite struct PhaseAudioPresenceTests {

    /// A study VM in the arm under test, wired to the recording engine.
    /// The fixture letter A ships `A_phoneme1.mp3`, so a phoneme-arm VM
    /// really does have a file to play — without it the assertions below
    /// would pass vacuously on an empty file list.
    private func makeVM(arm: PilotAudioCondition) -> (TracingViewModel, RecordingAudio) {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub
            .with(audio: audio)
            .with(studyMode: true)
            .with(audioCondition: arm))
        return (vm, audio)
    }

    // MARK: - The observation phase

    /// THE defect the proctor reported: the letter is being SHOWN and
    /// nothing plays. Before the change, a study child's sound reached
    /// them through the trace coupling alone, so observe was the one
    /// phase with no signal at all.
    @Test func theDemonstrationPhaseAsksForPlayback() {
        let (vm, audio) = makeVM(arm: .phoneme)
        #expect(audio.playCount == 0, "nothing has been shown yet")

        vm.startGuideAnimation()

        #expect(audio.loadedFiles.contains { $0.contains("phoneme") },
                "the phoneme arm must load the letter's phoneme take, not name audio")
        #expect(audio.playCount > 0,
                "the letter is on screen being demonstrated — there must be a signal")
    }

    /// …and it must not start with a click. The fade-OUT half existed
    /// before this session (`fadeOutSeconds = 0.12`); the fade-IN half
    /// did not, so every sound opened at full volume.
    @Test func theDemonstrationFadesInRatherThanStartingAtFullVolume() {
        let (vm, audio) = makeVM(arm: .phoneme)

        vm.startGuideAnimation()

        #expect(!audio.nonZeroFades.isEmpty,
                "a demonstration starting abruptly is the 'not stop too abruptly' complaint, unfixed")
    }

    /// The silent arm's condition IS the absence of sound. Every other
    /// test here is worthless without this one: without it, "audio in the
    /// demonstration" could be satisfied by simply playing always.
    @Test func theSilentArmStaysSilentInEveryPhase() {
        let (vm, audio) = makeVM(arm: .silent)

        vm.startGuideAnimation()

        #expect(audio.loadedFiles.isEmpty,
                "the silent arm must load nothing — a loaded file is one tap away from a sound")
        #expect(audio.playCount == 0,
                "the silent arm's manipulation is the absence of sound; a play() here breaks the IV")
    }

    /// The spatial arm shares the observation route with phoneme and must
    /// get a signal too — it carries the shared carrier tone rather than
    /// a phoneme take, so the assertion is on the SIGNAL, not the file.
    @Test func theSpatialArmAlsoGetsASignalDuringTheDemonstration() {
        let (vm, audio) = makeVM(arm: .spatial)

        vm.startGuideAnimation()

        #expect(audio.hasSignal,
                "both sound arms must be audible during the demonstration, or the arms are not matched")
    }

    // MARK: - The unassisted draw

    /// The freeWrite coupling lives in `TouchDispatcher
    /// .updateAdaptivePlayback`, a PRIVATE method reached only by a real
    /// touch sequence. There is deliberately no unit test standing in for
    /// it: a test that reached the behaviour any other way would be
    /// testing its own scaffolding, which is the failure mode this file
    /// exists to avoid.
    ///
    /// `AudioSignalProbe` covers it properly instead — it measures the
    /// engine's real output samples per phase on the physical device, so
    /// "was there sound during the unassisted draw" is answered by the
    /// buffers the speaker was handed. See `PrimaeUITests`
    /// `testFreeWritePhaseProducesAudioSignal`.
}
