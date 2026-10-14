// ArmEngineCarryOverTests.swift
// PrimaeNativeTests
//
// Engine state must not carry over from one ARM to the next — across the
// in-place enrolment of the next child (`resetForNewParticipant`, PR #22),
// across the comparison cycle (`cycleAllConditions`), and across any arm
// step (`applyArm`). Two defects, found by a read-only audit 2026-10-13:
//
//   D1  The view model's engine was chosen ONCE, at construction:
//       `effectiveAudio = armIsSilent ? SilentAudio() : deps.audio`, held by
//       the VM and by the playback controller for the VM's whole life. An
//       app LAUNCHED in the silent arm (the current child silent, a silent
//       researcher override, or a cycle starting silent) kept the no-op
//       engine after the arm changed — so every later phoneme/spatial child
//       on that iPad heard NOTHING, while their rows recorded the sound arm
//       and the observe sound / demonstration was marked delivered.
//
//   D2  Pitch is set only on the spatial arm's paths and was never reset —
//       not by an arm change, not by a participant change, not by the
//       engine's stop or load. A phoneme child enrolled after a spatial
//       child in the same app run heard every phoneme shifted by the last
//       pen height (up to ±1200 cents).
//
// Engine double: `EngineModelAudio` (TestFixtures), which models the
// engine's load-stops-playback, stop-drops-the-file, play-needs-a-file and
// rate/pan/pitch-as-state.
//
// `resetForNewParticipant` mints a random UUID, so the incoming arm is
// drawn, not chosen. `enrol(until:)` re-enrols until the wanted arm is
// drawn (p = 1/3 per draw; 64 draws), which exercises the REAL enrolment
// path — the `applyArm` seam covers the fixed directed pairs. Participant
// identity is global: every test that enrols restores it.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct ArmEngineCarryOverTests {

    private let canvas = CGSize(width: 400, height: 400)

    // MARK: - Fixture

    /// A study VM, three-phase, spoken feedback ON (the study default) pinned
    /// through the seam, the arm under test assigned at LAUNCH.
    private func makeVM(launchArm: PilotAudioCondition,
                        audio: EngineModelAudio,
                        cycle: Bool = false) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = launchArm
        deps.spokenFeedbackInStudy = true
        deps.cycleAllConditions = cycle
        deps.observeCueFallbackSeconds = 0.05
        deps.observeCueEndToPresentationSeconds = 0.05
        deps.audio = audio
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        return vm
    }

    /// The stub's A (one horizontal stroke at y = 0.5, radius 0.5) under
    /// the subset's three names, each with a phoneme take — so a guided
    /// stroke anywhere across the middle of the canvas is on the letter
    /// for every one of them, and the cycle has letters to step across.
    private func installStudyPool(_ vm: TracingViewModel) {
        guard let a = vm.letters.first(where: { $0.name == "A" }) else {
            Issue.record("precondition: the stub fixture's A is loaded"); return
        }
        vm.letters = ["A", "F", "I"].map { name in
            LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper,
                        audioFiles: ["\(name).mp3"],
                        strokes: LetterStrokes(letter: name,
                                               checkpointRadius: a.strokes.checkpointRadius,
                                               strokes: a.strokes.strokes),
                        phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
        }
    }

    /// Guided on `letter`, ready for the pen.
    private func enterGuided(_ vm: TracingViewModel, letter: String = "A") {
        vm.loadLetter(name: letter)
        vm.phaseController.resume(at: .guided)
    }

    /// A guided stroke across the letter at canvas height `y`.
    private func write(_ vm: TracingViewModel, y: CGFloat = 200, t0: CFTimeInterval = 1000) {
        var t = t0
        var p = CGPoint(x: 50, y: y)
        vm.beginTouch(at: p, t: t)
        for _ in 0..<15 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
        vm.endTouch()
    }

    /// The arm's file for `letter`, as the view model resolves it.
    private func armFile(_ vm: TracingViewModel, _ letter: String = "A") -> String? {
        vm.letters.first { $0.name == letter }.flatMap { vm.activeAudioFiles(for: $0).first }
    }

    /// Plays since `mark` that the engine could make audible: a file was
    /// loaded when `play` arrived.
    private func audiblePlays(_ audio: EngineModelAudio, since mark: Int) -> [EngineModelAudio.PlaySnapshot] {
        audio.plays.dropFirst(mark).filter { $0.file != nil }
    }

    /// Re-enrol until the drawn arm is `arm`.
    private func enrol(until arm: PilotAudioCondition, _ vm: TracingViewModel) {
        for _ in 0..<64 where vm.audioCondition != arm {
            _ = vm.resetForNewParticipant()
        }
        #expect(vm.audioCondition == arm, "precondition: 64 enrolments never drew \(arm)")
    }

    /// Restore global participant identity after a test that enrols.
    private static let identityKeys = [
        "de.flamingistan.primae.participantId",
        "de.flamingistan.primae.thesisEnrolled",
        "de.flamingistan.primae.thesisEnrolledAt",
        "de.flamingistan.primae.thesisConditionOverride",
        "de.flamingistan.primae.audioConditionOverride",
        "de.flamingistan.primae.trainedSubsetOverride",
        RetrievalScheduler.counterKey,
    ]
    private func withRestoredIdentity(_ body: () async -> Void) async {
        let saved = Self.identityKeys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(Self.identityKeys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        await body()
    }

    // MARK: - D1: the engine follows the arm

    @Test("D1: a sound-arm child enrolled after a SILENT launch hears their sound — load + play reach the engine",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func enrolmentAfterSilentLaunchSounds(arm: PilotAudioCondition) async {
        await withRestoredIdentity {
            let audio = EngineModelAudio()
            let vm = makeVM(launchArm: .silent, audio: audio)
            installStudyPool(vm)
            enterGuided(vm)
            write(vm)
            #expect(!audio.anyActivity, "precondition: the silent launch child reached the engine: \(audio.events)")

            enrol(until: arm, vm)
            #expect(vm.engineFollowsArm, "\(arm) child after a silent launch: the engine gate does not follow the arm")
            installStudyPool(vm)
            let mark = audio.plays.count
            let eventsMark = audio.events.count
            enterGuided(vm)
            write(vm)
            let expected = armFile(vm)
            let since = Array(audio.events.dropFirst(eventsMark))
            #expect(expected != nil && since.contains(.load(expected!)),
                    "\(arm) child after a silent launch: the arm's file never reached the engine. Events: \(since)")
            #expect(audiblePlays(audio, since: mark).contains { $0.file == expected },
                    "\(arm) child after a silent launch: no audible play of \(expected ?? "nil"). Plays: \(audio.plays.dropFirst(mark))")
        }
    }

    @Test("D1: a SILENT child enrolled after a sound-arm child reaches nothing",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func enrolmentIntoSilentStaysSilent(from: PilotAudioCondition) async {
        await withRestoredIdentity {
            let audio = EngineModelAudio()
            let vm = makeVM(launchArm: from, audio: audio)
            installStudyPool(vm)
            enterGuided(vm)
            write(vm)
            #expect(!audiblePlays(audio, since: 0).isEmpty, "precondition: the \(from) launch child sounded")

            enrol(until: .silent, vm)
            installStudyPool(vm)
            #expect(audio.loadedFile == nil, "entering the silent arm left a file loaded in the engine: \(audio.loadedFile ?? "")")
            let eventsMark = audio.events.count
            let adaptiveMark = audio.setAdaptiveCalls.count
            let pitchMark = audio.spatialPitches.count
            enterGuided(vm)
            write(vm)
            #expect(audio.events.count == eventsMark && audio.setAdaptiveCalls.count == adaptiveMark
                    && audio.spatialPitches.count == pitchMark,
                    "silent child after \(from): the engine was reached — \(audio.events.dropFirst(eventsMark))")
        }
    }

    /// Every directed arm step through the seam both enrolment and the cycle
    /// use. The silent arm must reach nothing; a sound arm must load its file
    /// and play it.
    @Test("D1: every arm step — silent stays silent, a sound arm sounds",
          arguments: [(PilotAudioCondition.silent, PilotAudioCondition.phoneme), (.silent, .spatial),
                      (.phoneme, .silent), (.spatial, .silent), (.phoneme, .spatial), (.spatial, .phoneme)])
    func everyArmStep(from: PilotAudioCondition, to: PilotAudioCondition) {
        let audio = EngineModelAudio()
        let vm = makeVM(launchArm: from, audio: audio)
        installStudyPool(vm)
        vm.applyArm(to)
        #expect(vm.audioCondition == to)
        #expect(vm.engineFollowsArm, "\(from) → \(to): the engine gate does not follow the arm")
        let eventsMark = audio.events.count
        let playsMark = audio.plays.count
        let adaptiveMark = audio.setAdaptiveCalls.count
        enterGuided(vm)
        write(vm)
        if to == .silent {
            #expect(audio.events.count == eventsMark && audio.setAdaptiveCalls.count == adaptiveMark,
                    "\(from) → silent: the engine was reached — \(audio.events.dropFirst(eventsMark))")
        } else {
            let expected = armFile(vm)
            #expect(audiblePlays(audio, since: playsMark).contains { $0.file == expected },
                    "\(from) → \(to): no audible play of \(expected ?? "nil"). Events: \(audio.events.dropFirst(eventsMark))")
        }
    }

    /// An arm step while the outgoing arm's sound is still held after a lift
    /// (`SoundEnvelope.liftHoldSeconds`). The step stops the engine and drops
    /// its file, so the playback machine must go idle with it: left `.active`,
    /// the next touch-down skips the reload (protocol r7 keeps a held sound)
    /// and the next stroke plays nothing — or, without the arm gate, the OUTGOING arm's
    /// file. No letter load in between, so nothing else re-idles the machine.
    @Test("D1: an arm step inside the lift hold — the next stroke plays the NEW arm's file",
          arguments: [(PilotAudioCondition.phoneme, PilotAudioCondition.spatial), (.spatial, .phoneme)])
    func armStepInsideTheLiftHold(from: PilotAudioCondition, to: PilotAudioCondition) {
        let audio = EngineModelAudio()
        let vm = makeVM(launchArm: from, audio: audio)
        installStudyPool(vm)
        enterGuided(vm)
        write(vm)                              // ends with the lift: the hold is pending
        #expect(vm.playback.state == .active, "precondition: the lift is holding the \(from) sound")
        vm.applyArm(to)
        let mark = audio.plays.count
        write(vm, t0: 2000)
        let expected = armFile(vm)
        #expect(audiblePlays(audio, since: mark).contains { $0.file == expected },
                "\(from) → \(to) inside the hold: the next stroke did not play \(expected ?? "nil"). Plays: \(audio.plays.dropFirst(mark))")
    }

    @Test("D1: a comparison cycle that STARTS silent sounds on the next letter (silent → phoneme)")
    func cycleStartingSilentSoundsOnTheNextLetter() {
        let audio = EngineModelAudio()
        let vm = makeVM(launchArm: .silent, audio: audio, cycle: true)
        installStudyPool(vm)
        enterGuided(vm, letter: "A")           // adopts the launch arm
        #expect(vm.audioCondition == .silent, "precondition: the cycle's first letter adopts the launch arm")
        write(vm)
        #expect(!audio.anyActivity, "precondition: the silent letter reached the engine: \(audio.events)")
        enterGuided(vm, letter: "F")           // the cycle steps
        #expect(vm.audioCondition == .phoneme, "precondition: the cycle stepped silent → phoneme")
        let playsMark = audio.plays.count
        write(vm, t0: 2000)
        #expect(audiblePlays(audio, since: playsMark).contains { $0.file == armFile(vm, "F") },
                "cycle silent → phoneme: the phoneme letter was silent. Events: \(audio.events)")
    }

    // MARK: - D2: pitch does not carry from the spatial arm

    @Test("D2: a phoneme child enrolled after a spatial child hears the phoneme at neutral pitch")
    func phonemeAfterSpatialEnrolmentIsUnshifted() async {
        await withRestoredIdentity {
            let audio = EngineModelAudio()
            let vm = makeVM(launchArm: .spatial, audio: audio)
            installStudyPool(vm)
            enterGuided(vm)
            write(vm, y: 100)                  // y = 0.25 → +600 cents
            #expect(audio.pitchCents == 600, "precondition: the spatial child left the engine at +600 cents (\(audio.pitchCents))")

            enrol(until: .phoneme, vm)
            installStudyPool(vm)
            let mark = audio.plays.count
            enterGuided(vm)
            write(vm, t0: 2000)
            let plays = audiblePlays(audio, since: mark)
            #expect(!plays.isEmpty, "precondition: the phoneme child sounded")
            #expect(plays.allSatisfy { $0.pitchCents == 0 },
                    "phoneme child after a spatial child: played shifted by \(plays.map(\.pitchCents)) cents")
        }
    }

    /// The SAME arm for the incoming child: `applyArm` is a no-op for an
    /// unchanged arm, so this pins the path that re-applies the authority
    /// anyway. A fresh VM per draw, so the one reset under test is the only
    /// one — an intervening other arm would neutralise the engine itself.
    @Test("D2: a spatial child enrolled after a spatial child starts from neutral rate, pan and pitch")
    func sameArmEnrolmentNeutralises() async {
        await withRestoredIdentity {
            for _ in 0..<64 {
                let audio = EngineModelAudio()
                let vm = makeVM(launchArm: .spatial, audio: audio)
                installStudyPool(vm)
                enterGuided(vm)
                write(vm, y: 100)
                #expect(audio.pitchCents == 600, "precondition: +600 cents left behind (\(audio.pitchCents))")
                _ = vm.resetForNewParticipant()
                guard vm.audioCondition == .spatial else { continue }
                #expect(vm.engineFollowsArm)
                #expect(audio.pitchCents == 0 && audio.rate == 1 && audio.pan == 0,
                        "spatial → spatial enrolment: the engine kept rate \(audio.rate), pan \(audio.pan), pitch \(audio.pitchCents)")
                return
            }
            Issue.record("precondition: 64 enrolments never drew spatial")
        }
    }

    @Test("D2: the phoneme observe sound after a spatial child starts at neutral pitch")
    func phonemeObserveAfterSpatialIsUnshifted() async {
        await withRestoredIdentity {
            let audio = EngineModelAudio()
            let vm = makeVM(launchArm: .spatial, audio: audio)
            installStudyPool(vm)
            enterGuided(vm)
            write(vm, y: 100)
            #expect(audio.pitchCents == 600, "precondition: +600 cents left behind (\(audio.pitchCents))")

            enrol(until: .phoneme, vm)
            installStudyPool(vm)
            let mark = audio.plays.count
            vm.loadLetter(name: "A")
            #expect(vm.learningPhase == .observe, "precondition: a fresh load lands in observe")
            // The observe sound starts after the cue fallback (0.05 s here).
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(300)
            while audiblePlays(audio, since: mark).isEmpty && clock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            let plays = audiblePlays(audio, since: mark)
            #expect(!plays.isEmpty, "precondition: the phoneme observe sound started")
            #expect(plays.allSatisfy { $0.pitchCents == 0 },
                    "the phoneme observe sound played shifted by \(plays.map(\.pitchCents)) cents")
        }
    }

    @Test("D2: an arm step out of spatial leaves the engine at neutral rate, pan and pitch",
          arguments: [PilotAudioCondition.phoneme, .silent])
    func armStepOutOfSpatialNeutralises(to: PilotAudioCondition) {
        let audio = EngineModelAudio()
        let vm = makeVM(launchArm: .spatial, audio: audio)
        installStudyPool(vm)
        enterGuided(vm)
        write(vm, y: 100)
        #expect(audio.pitchCents == 600, "precondition: +600 cents left behind (\(audio.pitchCents))")
        vm.applyArm(to)
        #expect(audio.pitchCents == 0 && audio.rate == 1 && audio.pan == 0,
                "spatial → \(to): the engine kept rate \(audio.rate), pan \(audio.pan), pitch \(audio.pitchCents)")
    }

    /// The GATE itself, after a sound → silent step, member by member.
    /// `enrolmentIntoSilentStaysSilent` and `everyArmStep`'s silent branch
    /// drive a guided stroke; measured 2026-10-14, they go RED with the gate
    /// held open, but only through a single `stop()` event — the load,
    /// play and coupling members never reach the gate on that drive
    /// (`activeAudioFiles` is [] and `TouchDispatcher` returns before the
    /// coupling). This drives every playback member of `vm.audio` directly
    /// after the arm has stepped INTO silence, the case the launch-time
    /// direct-drive checks (AudioArmRouting / SilentArmAuthority /
    /// StudyCleanConfig / ProtocolMatrix) do not reach.
    ///
    /// Mutation check: in `ArmGatedAudio`, `private var live:
    /// AudioControlling { engine }` (gate open whatever the arm) → RED.
    @Test("D1: after a sound → silent step, driving the engine directly reaches nothing",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func silentStepGateAbsorbsDirectCalls(from: PilotAudioCondition) {
        let audio = EngineModelAudio()
        let vm = makeVM(launchArm: from, audio: audio)
        installStudyPool(vm)
        enterGuided(vm)
        write(vm)
        #expect(!audiblePlays(audio, since: 0).isEmpty, "precondition: the \(from) arm sounded")
        vm.applyArm(.silent)
        let eventsMark = audio.events.count
        let adaptiveMark = audio.setAdaptiveCalls.count
        let pitchMark = audio.spatialPitches.count
        vm.audio.loadAudioFile(named: "probe.wav", autoplay: true)
        vm.audio.play()
        vm.audio.play(fadeInSeconds: 0.2)
        vm.audio.setAdaptivePlayback(speed: 2, horizontalBias: 1)
        vm.audio.setSpatialPitch(cents: 600)
        vm.audio.stop()
        #expect(audio.events.count == eventsMark && audio.setAdaptiveCalls.count == adaptiveMark
                && audio.spatialPitches.count == pitchMark && audio.loadedFile == nil,
                "\(from) → silent: a direct call reached the engine — \(audio.events.dropFirst(eventsMark))")
    }

    @Test("D2: a comparison cycle spatial → silent → phoneme plays the phoneme at neutral pitch")
    func cycleSpatialToPhonemeIsUnshifted() {
        let audio = EngineModelAudio()
        let vm = makeVM(launchArm: .spatial, audio: audio, cycle: true)
        installStudyPool(vm)
        enterGuided(vm, letter: "A")           // spatial
        write(vm, y: 100)
        #expect(audio.pitchCents == 600, "precondition: +600 cents left behind (\(audio.pitchCents))")
        enterGuided(vm, letter: "F")           // silent
        enterGuided(vm, letter: "I")           // phoneme
        #expect(vm.audioCondition == .phoneme, "precondition: the cycle reached phoneme")
        let mark = audio.plays.count
        write(vm, t0: 2000)
        let plays = audiblePlays(audio, since: mark)
        #expect(!plays.isEmpty, "precondition: the phoneme letter sounded")
        #expect(plays.allSatisfy { $0.pitchCents == 0 },
                "cycle spatial → silent → phoneme: played shifted by \(plays.map(\.pitchCents)) cents")
    }
}
