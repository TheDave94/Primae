// ObserveWaitsForRendererTests.swift
// PrimaeNativeTests: lane RENDERFREEZE2 (2026-11-28)
//
// RENDERFREEZE moved a load's renderer build off the main thread, and the observe sound then started when the
// renderer was ready: ~6.7 s (Debug-Study, iPad) AFTER the observe dot, on a letter the launch prewarm had not built.
// The observe sound tracks the dot from its first frame (DECISIONS.md, "Reversal 2026-10-05"; r26), so in a sound
// arm the observe presentation (dot + sound) now STARTS only once the sound's renderer is built; the letter stays at
// rest meanwhile and the main actor stays free. The silent arm does not wait.
//
// Instrument: the real live voice with the production off-main runner and a slow builder seam held by the test,
// driven by a study view model. It says nothing about what left the speaker.
//
// Mutation check: in `startPendingObservePresentation` treat every call as `rendererReady` (no wait) — the
// phoneme case goes RED ("the dot started before the renderer was built").

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@Suite(.serialized) @MainActor
struct ObserveWaitsForRendererTests {

    private func makeVM(arm: PilotAudioCondition, builder: RendererBuildOffMainTests.SlowBuilder)
        -> (TracingViewModel, LiveSonificationAudio) {
        let tones = ["A_phoneme1.mp3": LiveSonificationAudioTests.tone("A_phoneme1"),
                     "M_phoneme1.mp3": LiveSonificationAudioTests.tone("M_phoneme1", hz: 150),
                     SpatialSonification.carrierToneFile: LiveSonificationAudioTests.tone("carrier", hz: 120)]
        let voice = LiveSonificationAudio(host: HostSpy(), output: FakeLiveOutput(), kernel: LiveSonificationKernel(),
                                          fadeOutSeconds: 0.05, observeSession: false,
                                          buildRenderers: LiveSonificationAudio.offMainRendererBuild,
                                          makePair: { builder.make($0) },
                                          resolve: { name, _ in tones[name] })
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.audioCondition = arm
        deps.observeCueFallbackSeconds = 0.05
        deps.spokenFeedbackInStudy = StudyComparisonSettings.spokenFeedbackInStudyDefault
        // INTEG-R32B (2026-11-28): the dot's pass must not end before the test looks. One pass completes observe
        // (`armObserveAutoAdvance`), which removes the dot and stops the sound; in the full suite on the iPad the main
        // actor went without a turn for minutes (this case: 16 min for under 9 s of waits), so the pass ran out
        // between two polls and the case read "the dot never started". A near-still dot keeps the pass running.
        deps.makeAnimationGuide = {
            let guide = AnimationGuideController()
            guide.unitsPerSecond = Self.stillDotUnitsPerSecond
            return guide
        }
        let vm = TracingViewModel(deps.with(audio: voice))
        let a = vm.letters.first { $0.name == "A" } ?? vm.letters[0]
        vm.letters = ["A", "M"].map { name in
            LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper,
                        audioFiles: ["\(name).mp3"],
                        strokes: LetterStrokes(letter: name, checkpointRadius: a.strokes.checkpointRadius,
                                               strokes: a.strokes.strokes),
                        phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
        }
        vm.canvasSize = CGSize(width: 1200, height: 800)
        return (vm, voice)
    }

    /// A dot this slow cannot finish its pass while the test runs (production: `observeUnitsPerSecond`, 0.36).
    static let stillDotUnitsPerSecond: TimeInterval = 1e-6

    /// The builder's own release deadline: far past any main-actor stall, so only the test's `release` frees it.
    /// (It was 20 s; a starved main actor could pass it before the "renderer held" checks ran.)
    static let builderTimeout: TimeInterval = 900

    private static func settle(seconds: Double, _ done: @MainActor () -> Bool) async {
        for _ in 0..<Int(seconds * 100) where !done() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("a sound arm's observe dot starts only once the sound's renderer is built, together with the sound",
          .timeLimit(.minutes(30)), arguments: [PilotAudioCondition.phoneme, .spatial])
    func observeStartsWhenTheRendererIsReady(arm: PilotAudioCondition) async {
        let builder = RendererBuildOffMainTests.SlowBuilder(timeout: Self.builderTimeout)
        let (vm, voice) = makeVM(arm: arm, builder: builder)
        vm.startParkedLetter()
        #expect(!vm.launchParked && vm.learningPhase == .observe, "precondition: observe")
        #expect(vm.sessionBlockReason == nil, "precondition: not blocked")
        // The cue fallback (0.05 s) fires the presentation; with the renderer held it must wait.
        await Self.settle(seconds: 3) { vm.debugObservePresentationState.contains("awaitingRenderer") }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(vm.animation.armedStrokes == nil,
                "\(arm): the dot started before the renderer was built — \(vm.debugObservePresentationState)")
        #expect(!voice.isPlaying, "\(arm): sound before the renderer was built")
        #expect(builder.calls.allSatisfy { !$0.onMain }, "\(arm): a renderer was built on the main thread")
        builder.release(4)
        await Self.settle(seconds: 5) { vm.animation.armedStrokes != nil }
        #expect(vm.animation.armedStrokes != nil, "\(arm): the dot never started — \(vm.debugObservePresentationState)")
        #expect(voice.isPlaying && voice.kernel.gateRequested,
                "\(arm): the dot started without its sound — \(vm.debugObservePresentationState)")
    }

    @Test("the silent arm's observe dot does not wait", .timeLimit(.minutes(30)))
    func silentArmDoesNotWait() async {
        let builder = RendererBuildOffMainTests.SlowBuilder(timeout: Self.builderTimeout)
        let (vm, _) = makeVM(arm: .silent, builder: builder)
        vm.startParkedLetter()
        await Self.settle(seconds: 3) { vm.animation.armedStrokes != nil }
        #expect(vm.animation.armedStrokes != nil, "the silent arm's dot waited — \(vm.debugObservePresentationState)")
        #expect(builder.calls.isEmpty)
        builder.release(4)
    }
}
