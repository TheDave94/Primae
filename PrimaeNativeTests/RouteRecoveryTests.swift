// RouteRecoveryTests.swift
//
// A LOST ROUTE MUST RECOVER — and a route that was never lost must do nothing.
//
// `handleAudioRouteChange` used to stop the sound on an output loss and never
// resume it, so a child whose route came back (headphones unplugged and
// re-plugged, a Bluetooth drop, a dock) stayed silent for the rest of the
// session. The recovery is gated on a PRIOR loss; the second test here is the
// one that matters most, because recovering on every route notification
// replays the arm's file mid-observe and that is how the first attempt at this
// turned three observe-cycle tests red.

import Testing
import Foundation
@testable import PrimaeNative

@MainActor
@Suite struct RouteRecoveryTests {

    /// The fakes are per-file (`fileprivate`) in this suite's convention, so
    /// this file carries its own. `play()` is what the recovery path reaches —
    /// `playback.request(.active)` reloads the arm's file via `reloadBeforePlay`
    /// and then plays — so that is what the assertions count.
    fileprivate final class RecordingAudio: AudioControlling {
        private(set) var playCount = 0
        private(set) var stopCount = 0
        private(set) var isPlaying = false
        private(set) var loadedFiles: [String] = []
        var initializationError: String? { nil }

        func loadAudioFile(named fileName: String, autoplay: Bool) { loadedFiles.append(fileName) }
        func setAdaptivePlayback(speed: Float, horizontalBias: Float) {}
        func play() { playCount += 1; isPlaying = true }
        func stop() { stopCount += 1; isPlaying = false }
        func restart() {}
        func suspendForLifecycle() { isPlaying = false }
        func resumeAfterLifecycle() {}
        func cancelPendingLifecycleWork() {}
    }

    private func makeVM(arm: PilotAudioCondition) -> (TracingViewModel, RecordingAudio) {
        let audio = RecordingAudio()
        let vm = TracingViewModel(.stub
            .with(audio: audio)
            .with(studyMode: true)
            .with(audioCondition: arm))
        return (vm, audio)
    }

    @Test("a route that was NEVER lost must not replay audio")
    func aValidRouteWithoutAPriorLossDoesNothing() {
        let (vm, audio) = makeVM(arm: .phoneme)
        vm.loadLetter(name: "A")
        let before = audio.playCount

        vm.handleAudioRouteChange(reasonRawValue: nil, outputLost: false,
                                  outputPortType: "Speaker")

        #expect(audio.playCount == before,
                "a route notification with no prior loss replayed the arm's file mid-observe")
    }

    @Test("a lost route that comes back recovers playback")
    func aRestoredRouteRecoversPlayback() {
        let (vm, audio) = makeVM(arm: .phoneme)
        vm.loadLetter(name: "A")
        let before = audio.playCount

        // The loss: the engine is stopped and the machine forced idle.
        vm.handleAudioRouteChange(reasonRawValue: nil, outputLost: true,
                                  outputPortType: "Speaker")
        #expect(vm.isPlaying == false, "an output loss must stop the sound")

        // …and the output returning.
        vm.handleAudioRouteChange(reasonRawValue: nil, outputLost: false,
                                  outputPortType: "Headphones")

        #expect(audio.playCount > before,
                "a restored route did not recover playback — the child stays silent for the session")
    }

    @Test("recovery is one-shot: a second valid route does not replay again")
    func recoveryHappensOnce() {
        let (vm, audio) = makeVM(arm: .phoneme)
        vm.loadLetter(name: "A")

        vm.handleAudioRouteChange(reasonRawValue: nil, outputLost: true, outputPortType: "Speaker")
        vm.handleAudioRouteChange(reasonRawValue: nil, outputLost: false, outputPortType: "Headphones")
        let afterRecovery = audio.playCount

        vm.handleAudioRouteChange(reasonRawValue: nil, outputLost: false, outputPortType: "Speaker")

        #expect(audio.playCount == afterRecovery,
                "a second valid route replayed the file again — the gate is not one-shot")
    }

    @Test("the silent arm recovers to silence, not to sound")
    func theSilentArmStaysSilent() {
        let (vm, audio) = makeVM(arm: .silent)
        vm.loadLetter(name: "A")
        let before = audio.playCount

        vm.handleAudioRouteChange(reasonRawValue: nil, outputLost: true, outputPortType: "Speaker")
        vm.handleAudioRouteChange(reasonRawValue: nil, outputLost: false, outputPortType: "Headphones")

        #expect(audio.playCount == before,
                "the silent arm must not acquire sound through the recovery path")
    }
}
