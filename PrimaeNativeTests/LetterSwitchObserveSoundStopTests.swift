// LetterSwitchObserveSoundStopTests.swift
// PrimaeNativeTests
//
// R072FIX (2026-11-28): a letter switch while the outgoing letter's observe
// sound plays must STOP that sound (the standing stop fade) before the next
// letter's file is loaded. The R-072 capture on the iPad (fa31b72d) showed
// the spatial carrier sounding at -16.7 dB straight through four switches and
// under the next letter's spoken cue: the observe sound is started outside
// the playback machine, the machine's idle request never stopped it, and the
// live voice keeps a same-slot sound going across a reload. In the phoneme
// arm the old letter sounded on until the new letter's renderer was built
// (5.5 s on the main thread in Debug-Study).
//
// Instrument: an engine recorder (the call order the view model issues).
// It says nothing about what left the speaker; the R-072 capture does that.

import Testing
import Foundation
import CoreGraphics
@testable import PrimaeNative

@MainActor
private final class SwitchRecordingAudio: AudioControlling {
    var initializationError: String? { nil }
    private(set) var calls: [String] = []
    private(set) var plays = 0
    private var playWatchers: [CheckedContinuation<Void, Never>] = []
    func loadAudioFile(named: String, autoplay: Bool) { calls.append("load \(named)") }
    func play() {
        plays += 1
        calls.append("play")
        let due = playWatchers
        playWatchers.removeAll()
        due.forEach { $0.resume() }
    }
    /// Returns once the engine has been asked to play (resumed BY the play).
    func firstPlay() async {
        guard plays == 0 else { return }
        await withCheckedContinuation { playWatchers.append($0) }
    }
    func clearCalls() { calls.removeAll() }
    func stop() { calls.append("stop") }
    func restart() {}
    func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
    func setSpatialPitch(cents: Float) {}
    func suspendForLifecycle() {}
    func resumeAfterLifecycle() {}
    func cancelPendingLifecycleWork() {}
}

@Suite(.serialized) @MainActor
struct LetterSwitchObserveSoundStopTests {

    private func makeVM(audio: SwitchRecordingAudio, arm: PilotAudioCondition) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.audioCondition = arm
        deps.observeCueFallbackSeconds = 0.05
        deps.spokenFeedbackInStudy = StudyComparisonSettings.spokenFeedbackInStudyDefault
        let vm = TracingViewModel(deps.with(audio: audio))
        let a = vm.letters.first { $0.name == "A" } ?? vm.letters[0]
        vm.letters = ["A", "M"].map { name in
            LetterAsset(id: name, name: name, baseLetter: name, letterCase: .upper,
                        audioFiles: ["\(name).mp3"],
                        strokes: LetterStrokes(letter: name, checkpointRadius: a.strokes.checkpointRadius,
                                               strokes: a.strokes.strokes),
                        phonemeAudioFiles: ["\(name)_phoneme1.mp3"])
        }
        vm.canvasSize = CGSize(width: 1200, height: 800)
        // A study launch is parked; the observe presentation starts at the proctor's start.
        vm.startParkedLetter()
        return vm
    }

    private func switchWhileObserveSounds(arm: PilotAudioCondition) async -> (calls: [String], state: String) {
        let audio = SwitchRecordingAudio()
        let vm = makeVM(audio: audio, arm: arm)
        #expect(!vm.launchParked && vm.learningPhase == .observe, "precondition: the letter was started in observe")
        #expect(vm.sessionBlockReason == nil, "precondition: the session is not blocked")
        // The wait is the recorder's own play() event; the cue fallback (0.05 s) starts the observe sound.
        await audio.firstPlay()
        let from = vm.currentLetterName
        audio.clearCalls()
        vm.loadLetter(name: from == "A" ? "M" : "A")
        return (audio.calls, "from \(from) to \(vm.currentLetterName) | \(vm.debugObservePresentationState)")
    }

    /// Mutation check: delete `if observeSoundTracksDot { audio.stop() }` in `load(letter:)` — RED in both arms.
    @Test("a letter switch while the observe sound plays stops it before the next letter's load", .timeLimit(.minutes(30)),
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func switchStopsTheObserveSoundFirst(arm: PilotAudioCondition) async {
        let (calls, state) = await switchWhileObserveSounds(arm: arm)
        let stop = calls.firstIndex(of: "stop")
        let load = calls.firstIndex { $0.hasPrefix("load ") }
        #expect(stop != nil, "\(arm): the switch never stopped the observe sound: \(calls) — \(state)")
        if let stop, let load {
            #expect(stop < load, "\(arm): the stop came after the next letter's load: \(calls) — \(state)")
        }
    }
}
