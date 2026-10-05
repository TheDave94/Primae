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
//       `shortLetterObserveIsWholeAtTheProductionGap` runs the real timing.
//       2026-10-05 (David's own test, protocol r5): the presentation starts
//       1.0 s after the cue ENDS (the synthesiser's end report; fallback
//       3.0 s after it starts), and the observe sound no longer plays
//       steady — it TRACKS the dot through the pen's own mapping
//       (`ArmCoupling`): rate from the dot's speed, pan from x, pitch from
//       y in the spatial arm only; a still dot plays at the slowest rate; a
//       stroke-to-stroke jump is not velocity (D9's steady carrier reversed).
//   ENVELOPE (r5): fade-out 0.4 s, stall 0.3 s, a lift holds the sound
//       0.8 s and a re-touch inside the hold keeps it (`SoundEnvelope`).
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
//   - r5 tests (2026-10-05; each flip run against this suite, RED, test
//     count read from the log — "61 tests in 4 suites"):
//       · observeSoundTracksTheDot: `guard false,` at the top of
//         `handleGuideFrame` (no tracking); `.still` velocity 0 → 100 (no
//         slowest-rate hold); ArmCoupling `arm == .spatial` → `!= .silent`
//         (phoneme gets pitch — the phoneme case goes RED).
//       · observeDotJumpIsNotVelocity: AnimationGuideController emits
//         `.move(from: prev, to: step, 1/60 s)` instead of `.jump`.
//       · cueEndStartsThePresentation: `cueUtteranceEnded` matches no text.
//       · fallbackStartsThePresentation: the fallback sleeps the cue-end
//         delay instead of `observeCueFallback`.
//       · staleAndOtherUtterancesAreIgnored: drop `pendingObserveCues == 0`.
//       · liftHoldsTheSound: `endTouch` always takes the immediate-stop branch.
//       · reTouchInsideTheHoldKeepsTheSound: the hold Task is not stored in
//         `pendingTransition` (so a re-touch cannot cancel it).
//       · envelopeValues / controllerSleepsTheEnvelope: stall default 0.12;
//         `fadeOutSeconds` 0.12.
//     NOT observable here: that `SoundEnvelope.makeAudioEngine()` applies
//     the fade to the real engine (AudioEngine cannot run on the simulator),
//     and that `UtteranceEndRelay` reports a real synthesiser's end.
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
    /// The end-of-utterance handler the VM registers; `end` plays the
    /// synthesiser's part (2026-10-05).
    private var endHandler: (@MainActor (String, Bool) -> Void)?
    func setUtteranceEndHandler(_ handler: (@MainActor (String, Bool) -> Void)?) { endHandler = handler }
    func end(_ text: String, cancelled: Bool = false) { endHandler?(text, cancelled) }
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
        // F, the real Regular strokes (three straight strokes, 40 checkpoints
        // each; strokes.json endpoints): the dot JUMPS twice between strokes,
        // which the observe sound must not read as velocity (2026-10-05).
        let fDir = dir.appendingPathComponent("Letters/Regular/F", isDirectory: true)
        try? FileManager.default.createDirectory(at: fDir, withIntermediateDirectories: true)
        func line(_ a: (Double, Double), _ b: (Double, Double)) -> [[String: Double]] {
            (0..<n).map { i in
                let t = Double(i) / Double(n - 1)
                return ["x": a.0 + (b.0 - a.0) * t, "y": a.1 + (b.1 - a.1) * t]
            }
        }
        let fStrokes: [String: Any] = [
            "letter": "F", "checkpointRadius": 0.1,
            "strokes": [["id": 1, "checkpoints": line((0.190, 0.040), (0.078, 0.949))],
                        ["id": 2, "checkpoints": line((0.190, 0.041), (0.940, 0.040))],
                        ["id": 3, "checkpoints": line((0.150, 0.480), (0.780, 0.480))]],
        ]
        let fData = try! JSONSerialization.data(withJSONObject: fStrokes, options: .prettyPrinted)
        try? fData.write(to: fDir.appendingPathComponent("strokes.json"))
        try? Data().write(to: fDir.appendingPathComponent("F.mp3"))
        try? Data().write(to: fDir.appendingPathComponent("F_phoneme1.mp3"))
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
    /// The production cue timing (`TracingDependencies` defaults) — what the
    /// device runs: start 1.0 s after the cue ENDS, fallback 3.0 s after it
    /// STARTS (2026-10-05).
    private var productionCueEnd: TimeInterval { TracingDependencies.stub.observeCueEndToPresentationSeconds }
    private var productionFallback: TimeInterval { TracingDependencies.stub.observeCueFallbackSeconds }

    private func makeVM(arm: PilotAudioCondition,
                        trainsA: Bool = false,
                        audio: RecordingAudio? = nil,
                        speech: SpySpeech? = nil,
                        prompts: SpyPrompts? = nil,
                        gap: TimeInterval = 0.05,
                        cueEnd: TimeInterval = 0.05,
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
        // Production: the presentation starts 1.0 s after the observe cue
        // ENDS, or 3.0 s after it starts if no end is reported. Most tests
        // inject small values so they assert the sequencing without waiting
        // it out; the short-letter test runs the production timing, because
        // a small gap is exactly what hid the R01 defect.
        // `gap` is the FALLBACK (no cue-end report arrives from the spy unless
        // a test calls `speech.end`); `cueEnd` the delay after a reported end.
        deps.observeCueFallbackSeconds = gap
        deps.observeCueEndToPresentationSeconds = cueEnd
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

    // MARK: - r6 (2026-10-05): free-writing is UNGATED, guided keeps the gate
    //
    // David: the letter's mask must go — "it must be tracked wherever on the
    // screen it is drawn". Letter I (checkpointRadius 0.1, a narrow glyph
    // in the middle of the canvas); the pen writes in the bottom-left
    // corner, far from every checkpoint.

    /// Put the session in `pass` on letter I.
    private func enterOnI(_ pass: WritingPass, _ vm: TracingViewModel) {
        switch pass {
        case .guided:
            vm.loadLetter(name: "I")
            vm.phaseController.resume(at: .guided)
        case .sessionFreeWrite:
            vm.loadLetter(name: "I")
            vm.phaseController.resume(at: .freeWrite)
        case .pretest, .posttest, .delayed:
            let kind: StudyProbe = pass == .pretest ? .pretest : pass == .posttest ? .posttest : .delayed
            let refusal = vm.startColdProbe(letter: "I", kind: kind)
            #expect(refusal == nil, "precondition: the \(pass) probe on I was refused: \(refusal ?? "")")
        }
    }

    /// A stroke in the bottom-left corner, in bounds, moving.
    private func writeFarFromTheLetter(_ vm: TracingViewModel) {
        var t: CFTimeInterval = 3000
        var p = CGPoint(x: 20, y: 370)
        vm.beginTouch(at: p, t: t)
        for _ in 0..<15 { t += 0.01; p.x += 4; vm.updateTouch(at: p, t: t, canvasSize: canvas) }
    }

    @Test("r6: in free-writing and every cold probe the sound arms sound ANYWHERE on the canvas",
          arguments: [WritingPass.sessionFreeWrite, .pretest, .posttest, .delayed],
                     [PilotAudioCondition.phoneme, .spatial])
    func freeWritingSoundsAnywhere(pass: WritingPass, arm: PilotAudioCondition) {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, audio: audio, withLetterI: true)
        enterOnI(pass, vm)
        #expect(vm.learningPhase == .freeWrite, "precondition: \(pass) runs in free-writing (\(vm.learningPhase))")
        let playsBefore = audio.playCount
        writeFarFromTheLetter(vm)
        #expect(!vm.strokeTracker.isNearStroke, "precondition: the pen is off the letter")
        #expect(audio.playCount > playsBefore && audio.isPlaying,
                "\(arm), \(pass): the pen far from the letter was silent — the free-writing mask is back. Events: \(audio.events.suffix(6))")
    }

    @Test("r6: guided KEEPS the on-letter gate — the same off-letter stroke is silent",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func guidedStaysGated(arm: PilotAudioCondition) {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, audio: audio, withLetterI: true)
        enterOnI(.guided, vm)
        #expect(vm.learningPhase == .guided, "precondition: guided (\(vm.learningPhase))")
        let playsBefore = audio.playCount
        writeFarFromTheLetter(vm)
        #expect(!vm.strokeTracker.isNearStroke, "precondition: the pen is off the letter")
        #expect(audio.playCount == playsBefore,
                "\(arm): guided sounded off the letter: \(audio.events.suffix(6))")
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

    /// P4 at the PRODUCTION cue timing (2026-10-05: 1.0 s after the cue
    /// ENDS, fallback 3.0 s after it starts) for the shortest study letter.
    /// The spy synthesiser reports the cue's end right after the load, as a
    /// real one would after speaking it. Polls every 20 ms on the main
    /// actor, so it can never see the two halves of one synchronous start
    /// apart — "together" is exactly that.
    @Test("P4: a short letter at the production cue timing — cue first, then animation and sound together 1.0 s after the cue ends, sound for the whole pass, stopped when observe ends; the silent arm gets the same start and no sound",
          arguments: [PilotAudioCondition.phoneme, .spatial, .silent])
    func shortLetterObserveIsWholeAtTheProductionGap(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let prompts = SpyPrompts()
        let speech = SpySpeech()
        let cueEnd = productionCueEnd
        let fallback = productionFallback
        #expect(cueEnd == 1.0 && fallback == 3.0, "precondition: production cue timing is 1.0 s after the end / 3.0 s fallback")
        let vm = makeVM(arm: arm, audio: audio, speech: speech, prompts: prompts,
                        gap: fallback, cueEnd: cueEnd, withLetterI: true)
        let cuesBefore = prompts.keys.count
        vm.loadLetter(name: "I")
        #expect(vm.currentLetterName == "I" && vm.learningPhase == .observe,
                "precondition: letter I loaded into observe (\(vm.currentLetterName), \(vm.learningPhase))")
        // Cue first: spoken on the load, with nothing presented yet.
        #expect(prompts.keys.count == cuesBefore + 1 && prompts.keys.last == .phaseObserve,
                "\(arm): the observe instruction was not spoken on the load: \(prompts.keys)")
        #expect(vm.animation.armedStrokes == nil && audio.playCount == 0,
                "\(arm): the presentation started with the cue, not after it")

        // The synthesiser reports the cue's end. Done synchronously, right
        // here: a poll loop on a contended main actor can wake only after
        // the 3.0 s fallback has already fired (measured: a 51 s stall in
        // the parallel suite), which would test the fallback, not the end.
        let clock = ContinuousClock()
        let loaded = clock.now
        // Every load in this VM has spoken one cue; end them all, the last
        // being this load's.
        for _ in 0..<prompts.keys.filter({ $0 == .phaseObserve }).count {
            speech.end(ChildSpeechLibrary.phaseEntry(.observe))
        }
        let cueEndedAt: Duration? = clock.now - loaded
        var animationStart: Duration?
        var animationWithoutSound = 0
        var soundWithoutAnimation = 0
        // "Animating" = armed by `AnimationGuideController.start`, set in the
        // same turn as the observe play and cleared by `stop()` when observe
        // completes. Generous deadline: a contended main actor runs the
        // 60 Hz pass far slower than a device.
        while vm.learningPhase == .observe && clock.now - loaded < .seconds(600) {
            let animating = vm.animation.armedStrokes != nil
            if animating && animationStart == nil { animationStart = clock.now - loaded }
            if arm != .silent {
                if animating && !audio.isPlaying { animationWithoutSound += 1 }
                // Only before the animation started: after its pass the
                // controller pauses 0.5 s before observe ends, and the sound
                // rightly plays on until then.
                if audio.isPlaying && animationStart == nil { soundWithoutAnimation += 1 }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(vm.learningPhase != .observe, "\(arm): observe never ended")
        guard let start = animationStart, let ended = cueEndedAt else {
            Issue.record("\(arm): the observe animation never started (cue ended: \(String(describing: cueEndedAt)))")
            return
        }
        // 1.0 s after the cue ENDED — never earlier. No upper bound (a
        // contended main actor delays a Task's wake-up; that is scheduling).
        #expect(start >= ended + .seconds(cueEnd - 0.05),
                "\(arm): the animation started at \(start), less than \(cueEnd) s after the cue ended at \(ended)")
        if arm == .silent {
            #expect(!audio.anyActivity, "silent arm: the engine was reached — \(audio.events)")
        } else {
            #expect(animationWithoutSound == 0,
                    "\(arm): the animation ran without the arm's sound in \(animationWithoutSound) polls. Events: \(audio.events)")
            #expect(soundWithoutAnimation == 0,
                    "\(arm): the sound started before the animation, in \(soundWithoutAnimation) polls")
            #expect(audio.playCount == 1, "\(arm): exactly one observe start expected, got \(audio.events)")
            #expect(audio.stopsDuringObserve == 0, "\(arm): the sound was stopped inside observe: \(audio.events)")
            #expect(!audio.isPlaying, "\(arm): observe ended but the sound kept playing: \(audio.events)")
        }
    }

    // MARK: - P4: the observe sound TRACKS the dot (David, 2026-10-05; D9 steady carrier reversed)

    /// Run one observe pass of `letter` and return the engine calls made
    /// during it, from the presentation's start.
    private func observePass(arm: PilotAudioCondition, letter: String, audio: RecordingAudio) async -> TracingViewModel {
        let vm = makeVM(arm: arm, audio: audio, withLetterI: true)
        vm.loadLetter(name: letter)
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(600)
        while vm.learningPhase == .observe && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return vm
    }

    /// The pen's speed for the dot's nominal motion: the guide moves at
    /// `observeUnitsPerSecond` cell units/s; the test cell is the 400 pt canvas.
    private var dotSpeed: Float {
        TouchDispatcher.mapVelocityToSpeed(CGFloat(AnimationGuideController.observeUnitsPerSecond) * canvas.width)
    }

    @Test("P4: the observe sound tracks the dot — starts still at the slowest rate at the dot's first point, rate follows the dot's speed, pan follows x; pitch follows y in the spatial arm only",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeSoundTracksTheDot(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let vm = await observePass(arm: arm, letter: "I", audio: audio)
        #expect(vm.learningPhase != .observe, "precondition: observe ended")
        let calls = audio.setAdaptiveCalls
        #expect(calls.count > 20, "\(arm): the observe sound was not tracked frame by frame: \(calls.count) calls")
        // Starts still at the dot's first point, slowest rate: the start
        // call and the start hold's still frame agree on the point.
        if calls.count > 1 {
            #expect(calls[0].speed == 0.5 && calls[1].speed == 0.5 && abs(calls[0].bias - calls[1].bias) < 0.001,
                    "\(arm): the observe sound did not start still at the dot's first point: \(calls.prefix(2))")
        }
        // While moving: the pen's mapping of the dot's speed.
        let moving = calls.filter { $0.speed > 0.5 }
        #expect(!moving.isEmpty && moving.allSatisfy { abs($0.speed - dotSpeed) < 0.02 },
                "\(arm): the moving dot's rate is not the pen mapping of its speed (\(dotSpeed)): \(moving.map(\.speed).prefix(8))")
        // Pan follows x: I's stroke runs right to left, so the pan only
        // moves left, start to end. (`panningEnabled` is the comparison
        // setting the VM captured; off, the pan is centred throughout.)
        let biases = calls.map(\.bias)
        if vm.panningEnabled {
            #expect(zip(biases, biases.dropFirst()).allSatisfy { $1 <= $0 + 0.001 } && (biases.first ?? 0) > (biases.last ?? 0) + 0.01,
                    "\(arm): pan did not follow the dot's x: \(biases.first ?? 0) … \(biases.last ?? 0)")
        } else {
            #expect(biases.allSatisfy { $0 == 0 }, "\(arm): panning is off but the pan moved")
        }
        if arm == .spatial {
            // Pitch follows y: I runs top to bottom, so the pitch only falls.
            let p = audio.spatialPitches
            #expect(p.count > 20 && zip(p, p.dropFirst()).allSatisfy { $1 <= $0 + 0.001 } && (p.first ?? 0) > (p.last ?? 0) + 100,
                    "spatial: the carrier pitch did not follow the dot's y: \(p.first ?? 0) … \(p.last ?? 0) over \(p.count)")
        } else {
            #expect(audio.spatialPitches.isEmpty, "phoneme: the observe sound got a pitch drive: \(audio.spatialPitches.prefix(4))")
        }
    }

    @Test("P4: a stroke-to-stroke jump of the dot is not velocity — the rate never spikes on F's two jumps")
    func observeDotJumpIsNotVelocity() async {
        let audio = RecordingAudio()
        let vm = await observePass(arm: .phoneme, letter: "F", audio: audio)
        #expect(vm.learningPhase != .observe, "precondition: observe ended")
        let speeds = audio.setAdaptiveCalls.map(\.speed)
        #expect(speeds.contains { abs($0 - dotSpeed) < 0.02 }, "precondition: the dot was tracked while moving")
        #expect((speeds.max() ?? 0) < dotSpeed + 0.02,
                "a jump entered the velocity: max rate \(speeds.max() ?? 0) > the dot's \(dotSpeed)")
        // The dwell after each jump is still: slowest rate again.
        #expect(speeds.filter { $0 == 0.5 }.count >= 3, "the still dot did not play at the slowest rate")
    }

    // MARK: - P4: the presentation waits for the cue to END (2026-10-05)

    /// Cues spoken so far in this VM (each load in observe speaks one).
    private func cuesSpoken(_ prompts: SpyPrompts) -> Int { prompts.keys.filter { $0 == .phaseObserve }.count }

    @Test("P4 timing: the cue's end starts the presentation 1.0 s (here: 0.2 s) later, long before the fallback",
          arguments: [PilotAudioCondition.phoneme, .spatial, .silent])
    func cueEndStartsThePresentation(arm: PilotAudioCondition) async {
        let prompts = SpyPrompts(); let speech = SpySpeech()
        let vm = makeVM(arm: arm, speech: speech, prompts: prompts, gap: 3600, cueEnd: 0.2, withLetterI: true)
        vm.loadLetter(name: "I")
        let clock = ContinuousClock()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(vm.animation.armedStrokes == nil, "\(arm): started before the cue ended")
        for _ in 0..<cuesSpoken(prompts) { speech.end(ChildSpeechLibrary.phaseEntry(.observe)) }
        let ended = clock.now
        let deadline = ended + .seconds(600)
        while vm.animation.armedStrokes == nil && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.animation.armedStrokes != nil, "\(arm): the cue's end did not start the presentation (fallback is 3600 s)")
        #expect(clock.now - ended >= .milliseconds(150), "\(arm): started too soon after the cue's end")
    }

    @Test("P4 timing: with no end report, the fallback starts the presentation",
          arguments: [PilotAudioCondition.phoneme, .spatial, .silent])
    func fallbackStartsThePresentation(arm: PilotAudioCondition) async {
        let prompts = SpyPrompts(); let speech = SpySpeech()
        let vm = makeVM(arm: arm, speech: speech, prompts: prompts, gap: 0.3, cueEnd: 3600, withLetterI: true)
        let clock = ContinuousClock()
        let loaded = clock.now
        vm.loadLetter(name: "I")
        let deadline = loaded + .seconds(600)
        while vm.animation.armedStrokes == nil && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.animation.armedStrokes != nil, "\(arm): the fallback never started the presentation")
        #expect(clock.now - loaded >= .milliseconds(250), "\(arm): started before the fallback")
    }

    @Test("P4 timing: an older load's cue ending, and any other utterance, start nothing; this load's cue end does")
    func staleAndOtherUtterancesAreIgnored() async {
        let prompts = SpyPrompts(); let speech = SpySpeech()
        let vm = makeVM(arm: .phoneme, speech: speech, prompts: prompts, gap: 3600, cueEnd: 0.05, withLetterI: true)
        vm.loadLetter(name: "F")
        vm.loadLetter(name: "I")      // a newer load: F's cue is now stale
        let spoken = cuesSpoken(prompts)
        #expect(spoken >= 2, "precondition: both loads spoke a cue (\(spoken))")
        speech.end("Jetzt du.")                                   // another utterance
        for _ in 0..<(spoken - 1) { speech.end(ChildSpeechLibrary.phaseEntry(.observe)) }  // older cues
        try? await Task.sleep(for: .milliseconds(500))
        #expect(vm.animation.armedStrokes == nil, "a stale cue end or another utterance started the presentation")
        speech.end(ChildSpeechLibrary.phaseEntry(.observe))       // this load's cue
        let clock = ContinuousClock(); let deadline = clock.now + .seconds(600)
        while vm.animation.armedStrokes == nil && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(vm.animation.armedStrokes != nil, "this load's cue end did not start the presentation")
        #expect(vm.currentLetterName == "I")
    }

    // MARK: - The sound envelope (2026-10-05): fade 0.4 s, stall 0.3 s, lift hold 0.8 s
    //
    // No wall-clock polling: in the parallel suite the main actor was
    // measured starved for ~160 s, so a poll can wake after its deadline
    // with the timer it is waiting for still queued. These tests await the
    // controller's own pending task, or drive it with an injected sleeper.

    @Test("envelope: the values are one named block, and the playback controller's stall default is it")
    func envelopeValues() {
        #expect(SoundEnvelope.fadeOutSeconds == 0.4 && SoundEnvelope.stallSeconds == 0.3
                && SoundEnvelope.liftHoldSeconds == 0.8)
        #expect(PlaybackController(audio: RecordingAudio()).idleDebounceSeconds == SoundEnvelope.stallSeconds)
    }

    @Test("envelope: a lift keeps the sound through the hold, then stops it",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func liftHoldsTheSound(arm: PilotAudioCondition) async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: arm, audio: audio)
        enter(.guided, vm)
        write(vm)
        #expect(audio.isPlaying, "precondition: the pen is sounding")
        let stopsBefore = audio.events.filter { $0 == .stop }.count
        let clock = ContinuousClock()
        let lifted = clock.now
        vm.endTouch()
        #expect(audio.isPlaying && audio.events.filter { $0 == .stop }.count == stopsBefore,
                "\(arm): the lift stopped the sound at once")
        guard let hold = vm.playback.pendingTransition else {
            Issue.record("\(arm): the lift armed no hold"); return
        }
        await hold.value
        #expect(audio.events.filter { $0 == .stop }.count > stopsBefore, "\(arm): the hold ended without a stop")
        #expect(clock.now - lifted >= .milliseconds(790), "\(arm): stopped before the 0.8 s hold elapsed")
    }

    @Test("envelope: a pen held still keeps sounding through the 0.3 s stall, then goes quiet")
    func stallIsThreeTenths() async {
        let audio = RecordingAudio()
        let vm = makeVM(arm: .phoneme, audio: audio)
        enter(.guided, vm)
        let clock = ContinuousClock()
        write(vm)
        let stilled = clock.now
        let stopsBefore = audio.events.filter { $0 == .stop }.count
        guard let stall = vm.playback.pendingTransition else {
            Issue.record("the moving pen armed no stall timeout"); return
        }
        await stall.value
        #expect(audio.events.filter { $0 == .stop }.count > stopsBefore, "the still pen never went quiet")
        #expect(clock.now - stilled >= .milliseconds(290), "the still pen went quiet before 0.3 s")
    }

    /// A thread-safe log for the injected sleeper (it runs off the main actor).
    private final class SleepLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [Duration] = []
        private var _holdsReturned = 0
        func record(_ d: Duration) { lock.lock(); _calls.append(d); lock.unlock() }
        func holdReturned() { lock.lock(); _holdsReturned += 1; lock.unlock() }
        var calls: [Duration] { lock.lock(); defer { lock.unlock() }; return _calls }
        var holdsReturned: Int { lock.lock(); defer { lock.unlock() }; return _holdsReturned }
    }

    @Test("envelope: a re-touch inside the lift hold cancels its stop — the sound does not cut between strokes")
    func reTouchInsideTheHoldKeepsTheSound() async {
        let audio = RecordingAudio()
        let log = SleepLog()
        let hold = Duration.seconds(SoundEnvelope.liftHoldSeconds)
        // The hold's sleep returns at once (so an UNcancelled hold stops the
        // sound immediately); every other sleep (the re-touch's stall) never
        // ends, so nothing else can stop it.
        let c = PlaybackController(audio: audio, playIntentDebounceSeconds: 0, sleep: { d in
            log.record(d)
            if d == hold { log.holdReturned(); return }
            try await Task.sleep(for: .seconds(3600))
        })
        c.appIsForeground = true
        c.resumeIntent = true
        c.request(.active, immediate: true)                  // stroke 1 sounds
        #expect(audio.playCount == 1, "precondition: the pen sounds")
        c.requestIdleAfterHold(SoundEnvelope.liftHoldSeconds) // lift
        c.request(.active, immediate: true)                  // re-touch inside the hold
        let clock = ContinuousClock(); let deadline = clock.now + .seconds(600)
        while log.holdsReturned == 0 && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        // The sleeper runs off the main actor; the rest of the hold's body
        // (the cancellation check, the stop) is queued back onto it. One
        // more main-actor sleep lets that queued job run first.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(log.holdsReturned == 1, "precondition: the hold's timer ran")
        #expect(!audio.events.contains(.stop), "the hold stopped the sound under the next stroke: \(audio.events)")
        #expect(audio.isPlaying)
    }

    @Test("envelope: the controller times the stall and the hold with the envelope's values")
    func controllerSleepsTheEnvelope() async {
        let audio = RecordingAudio()
        let log = SleepLog()
        let c = PlaybackController(audio: audio, playIntentDebounceSeconds: 0, sleep: { d in log.record(d) })
        c.appIsForeground = true
        c.resumeIntent = true
        c.request(.active, immediate: true)
        await c.pendingTransition?.value                     // the stall
        c.request(.active, immediate: true)
        c.requestIdleAfterHold(SoundEnvelope.liftHoldSeconds)
        await c.pendingTransition?.value                     // the hold
        #expect(log.calls.contains(.seconds(SoundEnvelope.stallSeconds)),
                "the stall did not sleep 0.3 s: \(log.calls)")
        #expect(log.calls.contains(.seconds(SoundEnvelope.liftHoldSeconds)),
                "the lift hold did not sleep 0.8 s: \(log.calls)")
        #expect(audio.events.filter { $0 == .stop }.count == 2, "stall and hold each stop: \(audio.events)")
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
