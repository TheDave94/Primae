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
//       where both used to fire on the load's tick. OPTION B (supervisor
//       ruling 2026-10-05): the ANIMATION waits too, and starts WITH the
//       sound, in every arm. Before, the animation started at 0.3 s and the
//       sound at 2.0 s, and observe ends after one pass — so every animation
//       ran ~1.7 s with no sound, and a short letter (I on the study iPad)
//       heard only its last ~1 s (device run R01, 2026-10-05). Every earlier
//       P4 test injected a 0.05 s gap, which is why none of them saw it;
//       `shortLetterObserveIsWholeAtTheProductionGap` runs the real 2.0 s.
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
//   - shortLetterObserveIsWholeAtTheProductionGap (Option B, one flip per
//     assertion, all in `TracingViewModel`):
//       · "presentation waits for the cue" — in `load(letter:)`'s observe
//         branch, drop the `if studyMode {` and always run
//         `animation.startAfterDelay(0.3 + presentationSpacing, …)` (the
//         pre-B start): RED, the animation starts at ~0.3 s, before the gap.
//       · "animation and sound start together" / "sound for the whole
//         pass" — in `armObservePresentationAfterCue`, delete
//         `self.startObservePhaseAudio()` and restore the pre-B
//         `armWholeObserveSoundAfterCue` start: RED, the animation runs
//         without the sound.
//       · "stops at observe end" — in `resetForPhaseTransition`, delete
//         `audio.stop()`: RED, the sound outlives observe.
//       · "the silent arm gets the same animation start, no sound" — in
//         `TracingViewModel.init`, `effectiveAudio = deps.audio` (RED, the
//         engine is reached); or make the presentation sound-arm only
//         (`if armStudyObservePresentation && startWholeObserveSound`): RED,
//         the silent arm's animation never starts and observe never ends.
//   - observeSoundIsSteady: delete the `setSpatialPitch(cents: 0)` /
//     `setAdaptivePlayback(speed: 1.0, horizontalBias: 0)` lines in
//     `startObservePhaseAudio`.
//   - observeCueReachesEveryArm: after P3 the cue reaches the child through
//     `StudyVoiceoverPromptPlayer`, which `TracingViewModel.init` builds from
//     `studyVoiceoverOn` — NOT from `silenceSpeech`. So restoring the old
//     `silenceSpeech` expression does not touch the cue and leaves this test
//     GREEN (it is the flip for `spokenContentIsIdenticalAcrossArms` below).
//     Flips that do reach it: in `init`, make it
//     `studyVoiceoverOn = deps.studyMode && spokenFeedbackInStudy && !armIsSilent`
//     (silent arm RED — it falls back to `NullPromptPlayer`); or drop
//     `|| studyObserveCue` in `load(letter:)` (every arm RED — the stub's
//     onboarding store reports incomplete, as a study build's always does).
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
    /// Probe closing-window labels, in order — `emitAudioSignalSummary` is
    /// a protocol requirement (`AudioControlling`), so the call reaches here.
    private(set) var summaryLabels: [String] = []
    func emitAudioSignalSummary(label: String) { summaryLabels.append(label) }
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

// MARK: - A short letter for the observe timing (Option B, 2026-10-05)

/// The stub fixture's A (one long stroke) plus a letter I with the REAL
/// Regular I stroke — one straight stroke, 40 checkpoints from (0.710,
/// 0.040) to (0.310, 0.960), radius 0.1 (`Resources/Letters/Regular/I/
/// strokes.json`) — the shortest observe pass of the study letters. With
/// phoneme takes, so a phoneme-arm study load is not refused. Written to
/// its own temporary directory, so the shared fixture is untouched.
fileprivate final class LetterIResourceProvider: LetterResourceProviding {
    private let base = StubResourceProvider()
    var bundle: Bundle { base.bundle }
    var searchBundles: [Bundle] { base.searchBundles }

    private static let dir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtocolMatrixLetterI", isDirectory: true)
        let letterDir = dir.appendingPathComponent("Letters/Regular/I", isDirectory: true)
        try? FileManager.default.createDirectory(at: letterDir, withIntermediateDirectories: true)
        let n = 40
        let checkpoints: [[String: Double]] = (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            return ["x": 0.710 + (0.310 - 0.710) * t, "y": 0.040 + (0.960 - 0.040) * t]
        }
        let strokes: [String: Any] = [
            "letter": "I", "checkpointRadius": 0.1,
            "strokes": [["id": 1, "checkpoints": checkpoints]],
        ]
        let data = try! JSONSerialization.data(withJSONObject: strokes, options: .prettyPrinted)
        try? data.write(to: letterDir.appendingPathComponent("strokes.json"))
        try? Data().write(to: letterDir.appendingPathComponent("I.mp3"))
        try? Data().write(to: letterDir.appendingPathComponent("I_phoneme1.mp3"))
        return dir
    }()

    func allResourceURLs() -> [URL] {
        let own = FileManager.default.enumerator(at: Self.dir, includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: [.skipsHiddenFiles])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true } ?? []
        return base.allResourceURLs() + own
    }

    func resourceURL(for relativePath: String) -> URL? {
        let url = Self.dir.appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : base.resourceURL(for: relativePath)
    }
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
    /// The production observe gap (`TracingDependencies` default) — what
    /// the device runs, and what the 0.05 s test gap hid (R01, 2026-10-05).
    private var productionGap: TimeInterval { TracingDependencies.stub.observeCueToPresentationSeconds }

    private func makeVM(arm: PilotAudioCondition,
                        trainsA: Bool = false,
                        audio: RecordingAudio? = nil,
                        speech: SpySpeech? = nil,
                        prompts: SpyPrompts? = nil,
                        gap: TimeInterval = 0.05,
                        withLetterI: Bool = false) -> TracingViewModel {
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
        // before the observe presentation — animation and sound — starts,
        // flag 3 / Option B); most tests inject a small one so they assert
        // the sequencing without waiting it out. The short-letter test
        // passes `productionGap`, because the small gap is exactly what hid
        // the R01 defect.
        deps.observeCueToPresentationSeconds = gap
        if withLetterI {
            deps.repo = LetterRepository(resources: LetterIResourceProvider(), cache: NullLetterCache())
            deps.trainedSubset = TrainedLetterSubset.allSubsets.first {
                !$0.letters.contains("A") && !$0.letters.contains("I")
            }!
        }
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

    @Test("P4: the observe presentation — animation and sound — starts after the cue gap and the load's reload, and is playing",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeSoundStartsAfterTheReload(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, audio: audio)
        vm.loadLetter(name: "A")
        #expect(vm.learningPhase == .observe, "precondition: a fresh load lands in observe")
        // Flag 3 / Option B: neither the sound nor the animation starts on
        // the load's tick — the observe instruction speaks first.
        #expect(audio.playCount == 0,
                "\(arm): the observe sound started with the cue instead of after it. Events: \(audio.events)")
        #expect(vm.animation.armedStrokes == nil,
                "\(arm): the observe animation started with the cue instead of after it")
        // Polled, not a fixed sleep: under the full suite the main actor is
        // contended and a 200 ms window was not always enough for the
        // (0.05 s) start to run. `armedStrokes` is set synchronously by
        // `AnimationGuideController.start`, in the same turn as the play.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(300)
        while !audio.isPlaying && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(vm.animation.armedStrokes != nil,
                "\(arm): the observe animation did not start after the cue gap")
        #expect(audio.isPlaying,
                "\(arm): observe is silent after the load — started before the reload, it was stopped by it. Events: \(audio.events)")
        guard case .play(let fade)? = audio.events.last else {
            Issue.record("\(arm): the last engine call of the load must be the observe play, got \(audio.events)")
            return
        }
        #expect(fade > 0, "the observe sound must fade in, not click on")
    }

    @Test("P4: the observe sound is not cut — not at the old 2 s demonstration window, not before observe ends",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeSoundIsNotCutAtTwoSeconds(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, audio: audio)
        vm.loadLetter(name: "A")
        // Past the old 2 s window, then on until observe ends by itself
        // (one animation pass, `armObserveAutoAdvance`). The deadline is
        // generous on purpose: the pass is a 60 Hz frame loop on the main
        // actor, which the parallel full suite slows many times over.
        try? await Task.sleep(for: .seconds(PreTaskDemonstration.duration + 0.3))
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(300)
        while vm.learningPhase == .observe && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(vm.learningPhase != .observe, "\(arm): observe never ended — the animation never completed its pass")
        // A stop that ENDS observe (the phase advancing) is recorded with
        // the next phase current; only a stop inside observe cuts it short.
        #expect(audio.stopsDuringObserve == 0,
                "\(arm): something stopped the sound while observe was still running. Events: \(audio.events)")
    }

    /// Option B (supervisor ruling 2026-10-05), at the PRODUCTION gap, for
    /// the shortest study letter. Polls every 20 ms on the main actor, so
    /// it can never see the two halves of one synchronous start apart —
    /// "together" is exactly that.
    @Test("P4 (Option B): a short letter at the production gap — cue first, then animation and sound together for the whole pass, stopped when observe ends; the silent arm gets the same start and no sound",
          arguments: [PilotAudioCondition.phoneme, .spatial, .silent])
    func shortLetterObserveIsWholeAtTheProductionGap(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let prompts = SpyPrompts()
        let gap = productionGap
        #expect(gap == 2.0, "precondition: the production gap is the 2.0 s the device runs")
        let vm = makeVM(arm: arm, audio: audio, prompts: prompts, gap: gap, withLetterI: true)
        let cuesBefore = prompts.keys.count
        vm.loadLetter(name: "I")
        #expect(vm.currentLetterName == "I" && vm.learningPhase == .observe,
                "precondition: letter I loaded into observe (\(vm.currentLetterName), \(vm.learningPhase))")
        // Cue first: spoken on the load, with nothing presented yet.
        #expect(prompts.keys.count == cuesBefore + 1 && prompts.keys.last == .phaseObserve,
                "\(arm): the observe instruction was not spoken on the load: \(prompts.keys)")
        #expect(vm.animation.armedStrokes == nil && audio.playCount == 0,
                "\(arm): the presentation started with the cue, not after it")

        let clock = ContinuousClock()
        let loaded = clock.now
        var animationStart: Duration?
        var animationWithoutSound = 0
        var soundWithoutAnimation = 0
        // "Animating" = armed by `AnimationGuideController.start`, which is
        // set synchronously in the same turn as the observe play and
        // cleared by `stop()` when observe completes. (`guidePoint` is set
        // inside the controller's own task and lags it under load.) The
        // deadline is generous: under the parallel full suite the main
        // actor runs the 60 Hz pass many times slower than on a device.
        while vm.learningPhase == .observe && clock.now - loaded < .seconds(300) {
            let animating = vm.animation.armedStrokes != nil
            if animating && animationStart == nil { animationStart = clock.now - loaded }
            if arm != .silent {
                if animating && !audio.isPlaying { animationWithoutSound += 1 }
                // Only BEFORE the animation has started: after its pass the
                // controller clears the dot and pauses 0.5 s before the
                // cycle completes and observe ends
                // (`AnimationGuideController.start`, end of cycle), and the
                // sound rightly plays on until observe ends.
                if audio.isPlaying && animationStart == nil { soundWithoutAnimation += 1 }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(vm.learningPhase != .observe, "\(arm): observe never ended")
        guard let start = animationStart else {
            Issue.record("\(arm): the observe animation never started")
            return
        }
        // The presentation waits for the cue: never before the gap. There is
        // deliberately NO upper bound: measured 2026-10-05, a run with
        // StudyLaunchTests alongside held the shared main actor for ~37 s
        // and every start in that run read ~39 s — a Task's wake-up is
        // scheduling, not the app. The deadlines above only matter on failure.
        #expect(start >= .seconds(gap - 0.05),
                "\(arm): the animation started at \(start), before the \(gap) s cue gap")
        if arm == .silent {
            #expect(!audio.anyActivity, "silent arm: the engine was reached — \(audio.events)")
        } else {
            #expect(animationWithoutSound == 0,
                    "\(arm): the animation ran without the arm's sound in \(animationWithoutSound) polls — the sound did not cover the whole pass. Events: \(audio.events)")
            #expect(soundWithoutAnimation == 0,
                    "\(arm): the sound started before the animation, in \(soundWithoutAnimation) polls")
            #expect(audio.playCount == 1, "\(arm): exactly one observe start expected, got \(audio.events)")
            #expect(audio.stopsDuringObserve == 0, "\(arm): the sound was stopped inside observe: \(audio.events)")
            #expect(!audio.isPlaying, "\(arm): observe ended but the sound kept playing: \(audio.events)")
        }
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

    /// The device probe (`AudioSignalProbe`) closes a measurement window at
    /// every phase transition. That window must carry the name of the phase
    /// that is ENDING: it used to be emitted after the advance and so named
    /// the NEXT phase, which put observe's last window — with the observe
    /// sound in it — under "guided" (device run R01, 2026-10-05).
    /// Mutation: move the emit in `PhaseTransitionCoordinator.advance` back
    /// below `vm.phaseController.advance(score:)` — RED, the label is "guided".
    @Test("probe: the closing window at a phase transition carries the ENDING phase's name")
    func probeClosingWindowNamesTheEndingPhase() {
        let audio = RecordingAudio()
        let vm = makeVM(arm: .phoneme, audio: audio)
        vm.loadLetter(name: "A")
        #expect(vm.learningPhase == .observe, "precondition: a fresh load lands in observe")
        let before = audio.summaryLabels.count
        vm.completeObservePhase()
        #expect(vm.learningPhase == .guided, "precondition: observe advanced to guided")
        #expect(Array(audio.summaryLabels.dropFirst(before)) == ["observe"],
                "the window closed at the observe→guided transition must be labelled observe: \(audio.summaryLabels)")
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
        // Option B: the instruction comes FIRST, in every arm — when it is
        // spoken, the observe animation has not started yet.
        #expect(vm.animation.armedStrokes == nil,
                "\(arm): the observe animation started with the instruction, not after it")
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
