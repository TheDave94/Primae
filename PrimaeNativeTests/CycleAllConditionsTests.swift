// CycleAllConditionsTests.swift
// PrimaeNativeTests
//
// `StudyComparisonSettings.cycleAllConditions` — the eighth and last of
// the researcher switches, and the only one that changes the DESIGN
// rather than a presentation detail: ON steps the session through all
// three audio arms, one per letter, instead of running the single arm
// assigned from the participant identifier.
//
// WHY THIS FILE EXISTS. Until 2026-09-17 the switch existed, persisted,
// and did NOTHING — `SettingsView` shipped it `.disabled(true)` with the
// reason "Ein Wechsel der Audio-Bedingung mitten in der Sitzung verlangt,
// dass die Arm-Autorität (C3-2 ...) nachträglich veränderbar wird". That
// is a real hazard and not a formality: at launch the silent arm's
// authority is established by CONSTRUCTION (a `SilentAudio` engine, a null
// speech/prompt pair — `TracingViewModel.init`), and construction happens
// once. An arm reached later has to be made authoritative on the way in,
// or the one arm whose entire manipulation is the absence of sound would
// start making some. These tests drive the wiring and the authority, so
// neither can pass by being inert.
//
// WHAT THEY CANNOT SEE. Everything here is asserted on view-model state
// and on recorded collaborator calls. Whether sound actually leaves the
// speaker is not observable in-process by any test, on simulator or
// device — the same caveat `SilentArmAuthorityTests` carries.
//
// The switch is reached through `TracingDependencies.cycleAllConditions`,
// NOT through `UserDefaults`. `StudyComparisonSwitchesTests` flips the
// real key (that is its job — it pins the storage), and suites run in
// PARALLEL, so a fixture that read the global would hand whichever view
// model happened to be constructed inside that window a cycling session.
// The trap is documented at the top of `LetterWeightFallbackTests`.

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

/// Records every phase row with the arm it was stamped under, so the
/// ORDER of the arm step against the unload record is observable.
@MainActor
fileprivate final class CapturingArmStore: ParentDashboardStoring {
    struct Row { let letter: String; let phase: String; let arm: PilotAudioCondition }
    private(set) var rows: [Row] = []
    var snapshot: DashboardSnapshot { DashboardSnapshot() }
    func recordSession(letter: String, accuracy: Double, durationSeconds: TimeInterval,
                       wallClockSeconds: TimeInterval?, date: Date, condition: ThesisCondition,
                       inputDevice: String?) {}
    func recordPhaseSession(letter: String, phase: String, completed: Bool, score: Double, schedulerPriority: Double, condition: ThesisCondition, audioCondition: PilotAudioCondition, assessment: WritingAssessment?, recognition: RecognitionSample?, inputDevice: String?, rawTraceID: UUID?, trainedSubset: String?, phaseDurationSeconds: Double?, frechetDistance: Double?, checkpointCoverage: Double?, spatialDeviation: Double?, strokeCount: Int?, strokeOrder: String?, reversedStrokeCount: Int?, studyMode: Bool?, probe: String?) {
        rows.append(Row(letter: letter, phase: phase, arm: audioCondition))
    }
    func reset() {}
}

@Suite(.serialized) @MainActor struct CycleAllConditionsTests {

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

    /// The stub subset is "AFI", so these three are the study pool and the
    /// cycle has exactly three letters to walk — one arm each.
    private func studyPool() -> [LetterAsset] { ["A", "F", "I"].map(makeAsset) }

    private func makeVM(cycle: Bool,
                        arm: PilotAudioCondition = .phoneme,
                        studyMode: Bool = true,
                        audio: AudioControlling? = nil,
                        speech: SpeechSynthesizing? = nil,
                        prompts: (any PromptPlaying)? = nil,
                        store: (any ParentDashboardStoring)? = nil,
                        pool: [LetterAsset]? = nil) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = studyMode
        deps.cycleAllConditions = cycle     // the seam, not the global key
        deps.audioCondition = arm
        if let audio   { deps.audio = audio }
        if let speech  { deps.speech = speech }
        if let prompts { deps.makePromptPlayer = { _ in prompts } }
        if let store   { deps.dashboardStore = store }
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        if let pool { vm.letters = pool }
        return vm
    }

    // MARK: - The cycle order itself

    @Test("the cycle order is phoneme → spatial → silent → phoneme")
    func cycleOrderVisitsEveryArmAndWraps() {
        #expect(PilotAudioCondition.phoneme.nextInCycle == .spatial)
        #expect(PilotAudioCondition.spatial.nextInCycle == .silent)
        #expect(PilotAudioCondition.silent.nextInCycle == .phoneme,
                "the cycle must WRAP: an all-five-letter session runs more letters than there are arms")

        var seen: Set<PilotAudioCondition> = []
        var arm = PilotAudioCondition.phoneme
        for _ in 0..<PilotAudioCondition.allCases.count { seen.insert(arm); arm = arm.nextInCycle }
        #expect(seen == Set(PilotAudioCondition.allCases),
                "a full lap must visit every arm, not repeat one: \(seen)")
        #expect(arm == PilotAudioCondition.phoneme, "a full lap must return to its start")
    }

    // MARK: - OFF is the between-subjects design, unchanged

    @Test("with the switch OFF the assigned arm survives every letter")
    func switchOffKeepsTheAssignedArm() {
        let vm = makeVM(cycle: false, arm: .phoneme, pool: studyPool())
        #expect(vm.audioCondition == .phoneme)
        for step in 1...3 {
            vm.nextLetter()
            #expect(vm.audioCondition == .phoneme,
                    "the arm moved at letter \(step) with the cycle switch OFF — OFF is the between-subjects design and must be inert")
        }
    }

    // MARK: - ON steps once per letter

    @Test("with the switch ON the arm steps one per letter and wraps")
    func switchOnStepsOncePerLetter() {
        let vm = makeVM(cycle: true, arm: .phoneme, pool: studyPool())

        #expect(vm.audioCondition == .phoneme,
                "the launch letter must run the arm assigned from the identifier, not the second one")

        var visited: [PilotAudioCondition] = [vm.audioCondition]
        var letters: [String] = [vm.currentLetterName]
        for step in 1...3 {
            let previous = vm.currentLetterName
            vm.nextLetter()
            #expect(vm.currentLetterName != previous,
                    "precondition: step \(step) must actually change the letter, or the assertion below is vacuous")
            letters.append(vm.currentLetterName)
            visited.append(vm.audioCondition)
        }

        #expect(visited == [.phoneme, .spatial, .silent, .phoneme],
                "one step per letter, wrapping after the third: \(zip(letters, visited).map { "\($0.0)=\($0.1.rawValue)" })")
    }

    @Test("the launch letter keeps the identifier's arm, whatever it is")
    func launchLetterAdoptsTheAssignedArm() {
        // .spatial, so "did it step?" is distinguishable from "did it
        // start at the documented default?".
        let vm = makeVM(cycle: true, arm: .spatial, pool: studyPool())
        #expect(vm.audioCondition == .spatial,
                "the first letter consumed a cycle step instead of adopting the assigned arm")
        vm.nextLetter()
        #expect(vm.audioCondition == .silent,
                "the first boundary must be exactly ONE step from the assigned arm (spatial → silent), not two")
    }

    @Test("a re-load of the same letter does not consume an arm")
    func reloadingTheSameLetterKeepsTheArm() {
        let vm = makeVM(cycle: true, arm: .phoneme, pool: studyPool())
        #expect(vm.launchParked, "precondition: a study launch loads its letter parked")

        // Three ways the SAME letter is loaded again in production: the
        // parked launch un-parking, a proctor re-entry (and every cold
        // probe, which routes through `loadLetter`), and the repeat pass.
        // None is a new trial, so none may consume an arm.
        vm.startParkedLetter()
        #expect(vm.audioCondition == .phoneme,
                "un-parking the launch letter consumed an arm — the child would lose an arm before writing anything")

        vm.loadLetter(name: vm.currentLetterName)
        #expect(vm.audioCondition == .phoneme,
                "re-loading the current letter consumed an arm (probe / proctor re-entry path)")

        vm.nextLetter()
        #expect(vm.audioCondition == .spatial,
                "the first real boundary must be exactly ONE step — the two re-loads above consumed none")
    }

    // MARK: - The arm's authority travels with the arm (C3-2)

    @Test("stepping into the silent arm silences the session, and stepping out restores it")
    func silentArmAuthorityTravelsWithTheArm() {
        let audio = RecordingAudio()
        let speech = SpySpeech()
        let prompts = SpyPromptPlayer()
        // studyMode OFF deliberately: outside study mode the injected
        // speech IS the session's speech, so the swap is OBSERVABLE. Under
        // study mode it is already the null synthesiser, and the assertion
        // could not fail.
        let vm = makeVM(cycle: true, arm: .phoneme, studyMode: false,
                        audio: audio, speech: speech, prompts: prompts, pool: studyPool())
        #expect((vm.speech as AnyObject) === speech,
                "precondition: the injected speech must be in use before the arm turns silent")

        vm.nextLetter()                                   // phoneme → spatial
        #expect(vm.audioCondition == .spatial)
        #expect((vm.speech as AnyObject) === speech, "a SOUND arm must not silence speech")

        vm.nextLetter()                                   // spatial → silent
        #expect(vm.audioCondition == .silent)
        #expect((vm.speech as AnyObject) !== speech,
                "the silent arm adopted the live speech synthesiser — C3-2 says no audio path may fire for that arm, including one REACHED mid-session")
        #expect(vm.speech is NullSpeechSynthesizer, "the silent arm's speech must be the null conformer")
        #expect(vm.prompts is NullPromptPlayer,
                "the silent arm kept a live prompt player (phase cues, chimes, stroke ticks)")

        // The two load paths the child's own tracing would reach, driven
        // while the arm is silent. The phoneme letter above loaded
        // "A.mp3", so this is not the empty-list case: something WAS
        // loadable before the arm turned.
        let baseline = audio.loadedFiles.count
        #expect(baseline > 0, "positive control: a sound arm must have reached the engine before the silent step")
        vm.autoplayActiveCellLetter()
        vm.reloadActiveAudioFile()
        #expect(audio.loadedFiles.count == baseline,
                "the silent arm loaded \(audio.loadedFiles.dropFirst(baseline))")

        vm.nextLetter()                                   // silent → phoneme (wraps)
        #expect(vm.audioCondition == .phoneme)
        #expect((vm.speech as AnyObject) === speech,
                "stepping OUT of the silent arm must restore the session's speech — the swap is a state, not a one-way ratchet")
    }

    /// The SAME C3-2 property on the ENROLMENT path, which the cycle tests
    /// above cannot reach.
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
    /// studyMode OFF for the same reason the test above gives: under study
    /// mode the speech pair is already null, and this assertion could not
    /// fail.
    @Test("applying an arm carries its authority, and leaving it restores — the enrolment path")
    func applyArmCarriesAuthorityOnTheEnrolmentPath() {
        let speech = SpySpeech()
        let prompts = SpyPromptPlayer()
        let vm = makeVM(cycle: false, arm: .phoneme, studyMode: false,
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

    @Test("no audio path loads a file in an arm reached mid-session, and the engine is stopped")
    func silentArmReachedMidSessionLoadsNothing() async {
        let audio = RecordingAudio()
        let vm = makeVM(cycle: true, arm: .phoneme, audio: audio, pool: studyPool())

        // Positive controls first: without them the assertion below could
        // hold on a session that never reaches the engine at all. Matched
        // on the SUFFIX, not the exact string: the resource provider names
        // the file with its letter folder ("A/A_phoneme1.mp3"), and pinning
        // that spelling here would make this a test of the fixture.
        #expect(audio.loadedFiles.contains { $0.hasSuffix("_phoneme1.mp3") },
                "positive control: the phoneme arm must load its phoneme at launch: \(audio.loadedFiles)")
        vm.nextLetter()
        #expect(vm.audioCondition == .spatial)
        #expect(audio.loadedFiles.contains(SpatialSonification.carrierToneFile),
                "positive control: the spatial arm must load the carrier tone: \(audio.loadedFiles)")

        // Captured BEFORE the step into the silent arm: the stop this test
        // is about happens AS PART of that step.
        let stopsBefore = audio.stopCount
        vm.nextLetter()
        #expect(vm.audioCondition == .silent)
        #expect(audio.stopCount > stopsBefore,
                "entering the silent arm did not stop the engine — its stop() is what clears the loaded file, so the previous arm's sound could still be played by the coupling")
        let baseline = audio.loadedFiles.count

        // Everything that can hand the engine a file, driven in order.
        vm.autoplayActiveCellLetter()
        vm.reloadActiveAudioFile()
        vm.armPreTaskDemonstration(for: vm.letters[0], duration: 0.01)
        try? await Task.sleep(for: .milliseconds(80))

        #expect(audio.loadedFiles.count == baseline,
                "the silent arm loaded a file: \(audio.loadedFiles.dropFirst(baseline))")
    }

    // MARK: - The export's ordering contract

    @Test("the outgoing letter's last row carries the arm that letter was run under")
    func outgoingRowCarriesTheArmItWasRunUnder() {
        let store = CapturingArmStore()
        let vm = makeVM(cycle: true, arm: .phoneme, store: store)
        // The stub fixture's own letter carries real checkpoints (the
        // synthetic pool above has none, and a touch needs a polyline).
        var pool = vm.letters
        pool.append(makeAsset("F"))
        vm.letters = pool

        vm.startParkedLetter()
        vm.phaseController.resume(at: .guided)
        let checkpoints = vm.strokeTracker.definition?.strokes.flatMap(\.checkpoints) ?? []
        #expect(checkpoints.isEmpty == false, "precondition: the fixture letter must carry checkpoints")
        let px: (Checkpoint) -> CGPoint = {
            CGPoint(x: $0.x * self.canvas.width, y: $0.y * self.canvas.height)
        }
        var t: CFTimeInterval = 1000
        vm.beginTouch(at: checkpoints.first.map(px) ?? .zero, t: t)
        for cp in checkpoints.prefix(5) { t += 0.01; vm.updateTouch(at: px(cp), t: t, canvasSize: canvas) }
        vm.endTouch()

        let outgoing = vm.currentLetterName
        let rowsBefore = store.rows.count
        vm.nextLetter()

        let unloadRows = store.rows.dropFirst(rowsBefore).filter { $0.letter == outgoing }
        #expect(unloadRows.isEmpty == false,
                "precondition: a letter worked and left mid-phase must write an abandonment row, or this test proves nothing")
        #expect(unloadRows.allSatisfy { $0.arm == .phoneme },
                "the outgoing letter's row was stamped \(unloadRows.map(\.arm)) — the arm stepped BEFORE the unload record, so a letter's last row now names the NEXT letter's arm")
        #expect(vm.audioCondition == .spatial,
                "precondition: the arm must have stepped for the incoming letter")
    }
}
