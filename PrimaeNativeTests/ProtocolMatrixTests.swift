// ProtocolMatrixTests.swift
// PrimaeNativeTests
//
// THE PILOT PROTOCOL AS A MATRIX (David, final, 2026-10-04), pinned arm
// by arm and pass by pass in plain Swift — no rendering, no engine:
//
//   P1  silent arm: writing makes NO sound, in any pass.
//   P2  phoneme / spatial: writing makes sound in EVERY writing part —
//       guided, free-writing, and the outcome passes (the cold pretest,
//       post-test and delayed probes; the trained letters' post-test is
//       the session free-writing row). No sound-free pass, by design.
//   P3  the SPOKEN content is identical in all three arms (David's rule;
//       "instructions only" was a supervisor paraphrase, withdrawn).
//   P4  the sound arms hear their sound, steady, for the WHOLE observe
//       animation — from the end of the spoken observe instruction: the
//       cue plays first and the sound waits it out (flag 3, 2026-10-04),
//       where both used to fire on the load's tick.
//
// What is observable here is the DECISION to make sound — the calls the
// view model makes into `AudioControlling` / `PromptPlaying` /
// `SpeechSynthesizing` — not the speaker. The engine itself is measured
// on the device (`AudioSignalProbe`).
//
// WRITTEN TO FAIL FIRST WHERE HEAD (c7eb93ee) WAS WRONG: at HEAD the
// silent arm's prompts were the null player and "Schau genau hin." was
// unreachable in a study build, so `observeCueReachesEveryArm` failed for
// all three arms; only the sound arms spoke "Probier's nochmal", so
// `spokenContentIsIdenticalAcrossArms` failed; and the
// observe sound was never started, so the P4 tests failed for both sound
// arms. NOT RUN FROM THE SEAT THAT WROTE THEM — see the PR description.
//
// Mutation checks (flip, confirm RED, restore — and read the test count
// out of the log, CLAUDE.md "Test Infrastructure" 5):
//   - silentArmMakesNoSoundInAnyWritingPass: in `TracingViewModel.init`,
//     `effectiveAudio = armIsSilent ? SilentAudio() : deps.audio` →
//     `deps.audio`. (Deleting only `TouchDispatcher`'s silent-arm return
//     is NOT caught here: `SilentAudio` absorbs it. The two are redundant
//     layers; this pins the outcome.)
//   - soundArmsSoundInEveryWritingPass: re-add the removed gate at the top
//     of `TouchDispatcher.updateAdaptivePlayback`'s sound-arm path:
//     `if vm.studyMode, vm.phaseController.currentPhase == .freeWrite {
//     vm.playback.request(.idle, immediate: true); return }`.
//   - observeSoundStartsAfterTheReload: move `startObservePhaseAudio()`
//     from after the file reload in `load(letter:)` into the observe
//     branch, before it.
//   - observeSoundIsNotCutAtTwoSeconds: in `load(letter:)`'s observe
//     branch, call `armPreTaskDemonstration(for: letter)` unconditionally.
//   - observeSoundIsSteady: delete the `setSpatialPitch(cents: 0)` /
//     `setAdaptivePlayback(speed: 1.0, horizontalBias: 0)` lines in
//     `startObservePhaseAudio`.
//   - observeCueReachesEveryArm: restore
//     `silenceSpeech = armIsSilent || (deps.studyMode && !spokenFeedbackInStudy)`
//     (silent arm RED), or drop `|| studyObserveCue` (every arm RED).
//   - spokenContentIsIdenticalAcrossArms: wrap
//     `vm.speech.speak("Probier's nochmal")` in `if !vm.studyMode` (RED: no
//     arm says it), or restore the `silenceSpeech` expression above (RED:
//     the silent arm differs).
//   - voiceoverPassesTheStudySpokenSet / effectsFollowTheArm: delete the
//     `guard Self.studySpokenKeys.contains(key)` / an
//     `if soundEffectsAllowed` in `StudyVoiceoverPromptPlayer`.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

// MARK: - Recording doubles (file-private, as every suite here keeps its own)

@MainActor
fileprivate final class RecordingAudio: AudioControlling {
    enum Event: Equatable { case load(String), play(fade: TimeInterval), stop }
    var initializationError: String? { nil }
    private(set) var events: [Event] = []
    private(set) var setAdaptiveCalls: [(speed: Float, bias: Float)] = []
    private(set) var spatialPitches: [Float] = []
    /// Mirrors the engine: a load stops the player and plays only on
    /// autoplay; `stop()` stops.
    private(set) var isPlaying = false
    /// Phase the view model was in at each `stop()`, read through
    /// `phaseAtCall` — so a stop that ends observe early can be told from
    /// the one that ends it with the phase.
    var phaseAtCall: @MainActor () -> LearningPhase? = { nil }
    private(set) var stopsDuringObserve = 0

    func loadAudioFile(named: String, autoplay: Bool) { events.append(.load(named)); isPlaying = autoplay }
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) { setAdaptiveCalls.append((speed, horizontalBias)) }
    func setSpatialPitch(cents: Float) { spatialPitches.append(cents) }
    func play() { events.append(.play(fade: 0)); isPlaying = true }
    func play(fadeInSeconds: TimeInterval) { events.append(.play(fade: fadeInSeconds)); isPlaying = true }
    func stop() {
        events.append(.stop); isPlaying = false
        if phaseAtCall() == .observe { stopsDuringObserve += 1 }
    }
    func restart() {}
    func suspendForLifecycle() { isPlaying = false }
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}

    var playCount: Int { events.filter { if case .play = $0 { return true } else { return false } }.count }
    var anyActivity: Bool { !events.isEmpty || !setAdaptiveCalls.isEmpty || !spatialPitches.isEmpty }
}

@MainActor
fileprivate final class SpySpeech: SpeechSynthesizing {
    private(set) var spoken: [String] = []
    func speak(_ text: String) { spoken.append(text) }
    func stop() {}
}

@MainActor
fileprivate final class SpyPrompts: PromptPlaying {
    private(set) var keys: [PromptPlayer.PromptKey] = []
    private(set) var effects: [String] = []
    func play(_ key: PromptPlayer.PromptKey, fallbackText: String) { keys.append(key) }
    func stop() {}
    func playSuccessChime()  { effects.append("success") }
    func playTapChime()      { effects.append("tap") }
    func playWrongTapChime() { effects.append("wrongTap") }
    func playStrokeTick()    { effects.append("tick") }
}

// MARK: - The writing passes

/// Every pass in which a study child WRITES. The outcome passes are the
/// cold probes (`StudyProbe`); the trained letters' post-test is the
/// session free-writing row (`ParentDashboardExporter
/// .derivedTrainedPostTestIndices`), so `.sessionFreeWrite` covers it.
enum WritingPass: String, CaseIterable, CustomTestStringConvertible {
    case guided, sessionFreeWrite, pretest, posttest, delayed
    var testDescription: String { rawValue }
}

@Suite @MainActor struct ProtocolMatrixTests {

    private let canvas = CGSize(width: 400, height: 400)

    /// A study VM, three-phase, the arm under test, spoken feedback ON
    /// (the study default) pinned through the seam. By default the trained
    /// subset excludes A — the fixture's only letter — so A is untrained
    /// and the post-test probe may open it. `trainsA` keeps the fixture's
    /// "AFI", whose launch load of A is PARKED, as on a real study launch.
    private func makeVM(arm: PilotAudioCondition,
                        trainsA: Bool = false,
                        audio: RecordingAudio? = nil,
                        speech: SpySpeech? = nil,
                        prompts: SpyPrompts? = nil) -> TracingViewModel {
        // Constructed here, not in the default arguments: a
        // default-value expression is type-checked nonisolated in this
        // target, and these doubles' inits are @MainActor-isolated —
        // as default arguments they were the branch's only compile
        // errors. Callers that pass their own instance still get it
        // wired; callers that don't get a fresh one.
        let audio = audio ?? RecordingAudio()
        let speech = speech ?? SpySpeech()
        let prompts = prompts ?? SpyPrompts()
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = arm
        if !trainsA {
            deps.trainedSubset = TrainedLetterSubset.allSubsets.first { !$0.letters.contains("A") }!
        }
        deps.spokenFeedbackInStudy = true
        // The production gap is 2.0 s (the observe instruction plays out
        // before the arm's observe sound starts, flag 3); these tests
        // inject a small one so they assert the sequencing without
        // waiting it out.
        deps.observeCueToSoundGapSeconds = 0.05
        deps.audio = audio
        deps.speech = speech
        deps.makePromptPlayer = { _ in prompts }
        let vm = TracingViewModel(deps)
        vm.canvasSize = canvas
        audio.phaseAtCall = { [weak vm] in vm?.phaseController.currentPhase }
        return vm
    }

    /// Put the session in `pass`, ready for the child's pen.
    private func enter(_ pass: WritingPass, _ vm: TracingViewModel) {
        switch pass {
        case .guided:
            vm.loadLetter(name: "A")
            vm.phaseController.resume(at: .guided)
        case .sessionFreeWrite:
            vm.loadLetter(name: "A")
            vm.phaseController.resume(at: .freeWrite)
        case .pretest:  _ = vm.startColdProbe(letter: "A", kind: .pretest)
        case .posttest: _ = vm.startColdProbe(letter: "A", kind: .posttest)
        case .delayed:  _ = vm.startColdProbe(letter: "A", kind: .delayed)
        }
    }

    /// The same pen movement `AudioArmRoutingTests` uses: across the
    /// fixture letter's stroke, in bounds.
    private func write(_ vm: TracingViewModel) {
        var t: CFTimeInterval = 1000
        var p = CGPoint(x: 50, y: 200)
        vm.beginTouch(at: p, t: t)
        for _ in 0..<15 { t += 0.001; p.x += 10; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    // MARK: - P1 / P2: sound while writing

    @Test("P1: the silent arm's writing makes no sound in any pass",
          arguments: WritingPass.allCases)
    func silentArmMakesNoSoundInAnyWritingPass(pass: WritingPass) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: .silent, audio: audio)
        enter(pass, vm)
        write(vm)
        await vm.awaitPlaybackDebounce()
        #expect(vm.audio is SilentAudio, "the silent arm's engine must be the no-op conformer")
        #expect(!audio.anyActivity,
                "silent arm, \(pass): the injected engine was reached — \(audio.events)")
    }

    @Test("P2: the sound arms' writing makes sound in every pass, outcome passes included",
          arguments: [PilotAudioCondition.phoneme, .spatial], WritingPass.allCases)
    func soundArmsSoundInEveryWritingPass(arm: PilotAudioCondition, pass: WritingPass) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, audio: audio)
        enter(pass, vm)
        if pass == .pretest || pass == .posttest || pass == .delayed {
            #expect(vm.currentProbe != nil, "precondition: the \(pass) probe was refused")
            #expect(vm.learningPhase == .freeWrite, "precondition: a cold probe lands in free-writing")
        }
        // Counted from HERE. The observe sound's delayed start never
        // fires in the session passes — `resume(at:)` leaves observe
        // before the cue gap is out, and the start's phase guard stands
        // it down — and the probe passes never armed one, so for every
        // pass the counts below start from the writing alone.
        let playsBefore = audio.playCount
        let couplingBefore = audio.setAdaptiveCalls.count
        write(vm)
        await vm.awaitPlaybackDebounce()
        #expect(audio.setAdaptiveCalls.count > couplingBefore,
                "\(arm), \(pass): the trace coupling never ran")
        #expect(audio.playCount > playsBefore,
                "\(arm), \(pass): writing did not start the arm's sound — a sound-free writing pass")
    }

    // MARK: - P4: the whole observe animation

    @Test("P4: the observe sound starts after the cue gap and the letter load's reload, and is playing",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeSoundStartsAfterTheReload(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, audio: audio)
        vm.loadLetter(name: "A")
        #expect(vm.learningPhase == .observe, "precondition: a fresh load lands in observe")
        // Flag 3: the sound must not start on the load's tick — the
        // observe instruction speaks first and the sound waits it out.
        #expect(audio.playCount == 0,
                "\(arm): the observe sound started with the cue instead of after it. Events: \(audio.events)")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(audio.isPlaying,
                "\(arm): observe is silent after the load — started before the reload, it was stopped by it. Events: \(audio.events)")
        guard case .play(let fade)? = audio.events.last else {
            Issue.record("\(arm): the last engine call of the load must be the observe play, got \(audio.events)")
            return
        }
        #expect(fade > 0, "the observe sound must fade in, not click on")
    }

    @Test("P4: the observe sound is not cut at the old 2 s demonstration window",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeSoundIsNotCutAtTwoSeconds(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, audio: audio)
        vm.loadLetter(name: "A")
        try? await Task.sleep(for: .seconds(PreTaskDemonstration.duration + 0.3))
        // A stop that ENDS observe (the phase advancing) is recorded with
        // the next phase current; only a stop inside observe cuts it short.
        #expect(audio.stopsDuringObserve == 0,
                "\(arm): something stopped the sound while observe was still running. Events: \(audio.events)")
    }

    @Test("P4: the observe sound is steady — neutral rate and pan, and zero pitch for the carrier",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeSoundIsSteady(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, audio: audio)
        vm.loadLetter(name: "A")
        // The start waits out the observe instruction (flag 3) — let the
        // (test-shortened) gap elapse before reading the engine calls.
        try? await Task.sleep(for: .milliseconds(200))
        let last = audio.setAdaptiveCalls.last
        #expect(last?.speed == 1.0 && last?.bias == 0,
                "\(arm): observe played at a leftover rate/pan, \(String(describing: last))")
        if arm == .spatial {
            #expect(audio.spatialPitches.last == 0, "the carrier must sit at zero pitch in observe")
        }
    }

    @Test("P1: the silent arm's observe phase makes no sound")
    func silentArmObserveIsSilent() async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: .silent, audio: audio)
        vm.loadLetter(name: "A")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!audio.anyActivity, "silent arm, observe: \(audio.events)")
    }

    // MARK: - P3: the voiceover

    @Test("P3: every arm hears the observe instruction when a letter is loaded",
          arguments: [PilotAudioCondition.silent, .phoneme, .spatial])
    func observeCueReachesEveryArm(arm: PilotAudioCondition) {
        let prompts = SpyPrompts()
        let vm = makeVM(arm: arm, trainsA: true, prompts: prompts)
        #expect(vm.launchParked, "precondition: a study launch parks its first letter")
        #expect(prompts.keys.isEmpty, "the parked launch load must not speak — no child is enrolled yet")
        vm.loadLetter(name: "A")
        #expect(prompts.keys == [.phaseObserve],
                "\(arm): the observe instruction did not reach the child: \(prompts.keys)")
        #expect(vm.prompts is StudyVoiceoverPromptPlayer,
                "\(arm): the study session is not running the study voiceover")
    }

    /// David's rule: whatever a study child HEARS SPOKEN is the same in
    /// every arm. The same drive — a letter load, then a guided stroke
    /// that leaves the canvas ("Probier's nochmal") — must produce the
    /// same spoken sequence in all three arms, and it must not be empty.
    @Test("P3: the spoken content is identical across the three arms")
    func spokenContentIsIdenticalAcrossArms() {
        func spokenSequence(_ arm: PilotAudioCondition) -> (prompts: [PromptPlayer.PromptKey], speech: [String]) {
            let speech = SpySpeech()
            let prompts = SpyPrompts()
            let vm = makeVM(arm: arm, speech: speech, prompts: prompts)
            vm.loadLetter(name: "A")
            vm.phaseController.resume(at: .guided)
            // In bounds, then out: the "Probier's nochmal" edge.
            vm.beginTouch(at: CGPoint(x: 50, y: 200), t: 1000)
            vm.updateTouch(at: CGPoint(x: 60, y: 200), t: 1000.01, canvasSize: canvas)
            vm.updateTouch(at: CGPoint(x: canvas.width + 40, y: 200), t: 1000.02, canvasSize: canvas)
            return (prompts.keys, speech.spoken)
        }
        let silent = spokenSequence(.silent)
        let phoneme = spokenSequence(.phoneme)
        let spatial = spokenSequence(.spatial)
        #expect(silent.prompts == phoneme.prompts && phoneme.prompts == spatial.prompts,
                "spoken prompts differ by arm — silent \(silent.prompts), phoneme \(phoneme.prompts), spatial \(spatial.prompts)")
        #expect(silent.speech == phoneme.speech && phoneme.speech == spatial.speech,
                "spoken lines differ by arm — silent \(silent.speech), phoneme \(phoneme.speech), spatial \(spatial.speech)")
        // Positive controls: identical-because-empty would prove nothing.
        #expect(phoneme.prompts.contains(.phaseObserve), "the drive spoke no prompt: \(phoneme.prompts)")
        #expect(phoneme.speech.contains("Probier's nochmal"), "the drive spoke no line: \(phoneme.speech)")
    }

    @Test("P3: the voiceover passes the study's spoken phrases, and no score-dependent praise")
    func voiceoverPassesTheStudySpokenSet() {
        let inner = SpyPrompts()
        let voiceover = StudyVoiceoverPromptPlayer(inner: inner, soundEffectsAllowed: true)
        for key in PromptPlayer.PromptKey.allCases { voiceover.play(key, fallbackText: "") }
        #expect(inner.keys == [.phaseObserve, .phaseDirect, .phaseGuided, .phaseFreeWrite, .celebration],
                "the praise tiers, paper and retrieval phrases must stay unreachable: \(inner.keys)")
    }

    @Test("sound effects follow the arm: forwarded for the sound arms, dropped for the silent arm")
    func effectsFollowTheArm() {
        let inner = SpyPrompts()
        let voiceover = StudyVoiceoverPromptPlayer(inner: inner, soundEffectsAllowed: false)
        voiceover.playStrokeTick(); voiceover.playSuccessChime()
        voiceover.playTapChime(); voiceover.playWrongTapChime()
        #expect(inner.effects.isEmpty, "the silent arm heard \(inner.effects)")
        voiceover.soundEffectsAllowed = true
        voiceover.playStrokeTick(); voiceover.playSuccessChime()
        #expect(inner.effects == ["tick", "success"])
    }

    @Test("an arm reached mid-session keeps the voiceover and switches only the effects")
    func armChangeKeepsVoiceover() {
        let prompts = SpyPrompts()
        let vm = makeVM(arm: .phoneme, prompts: prompts)
        let voiceover = vm.prompts
        vm.applyArm(.silent)
        #expect((vm.prompts as AnyObject) === (voiceover as AnyObject),
                "the silent arm lost the voiceover on an arm change")
        vm.prompts.playStrokeTick()
        #expect(prompts.effects.isEmpty, "the silent arm reached mid-session heard a tick")
        vm.applyArm(.spatial)
        vm.prompts.playStrokeTick()
        #expect(prompts.effects == ["tick"])
    }
}
