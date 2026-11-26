// R-078: an app launched in the silent arm reads the engine's start-up error
// through `ArmGatedAudio`, which forwards to `SilentAudio` (nil). A later
// sound-arm child (arm changes in place on next-child enrolment) must still
// get the REAL engine's error surfaced to the proctor.

import Testing
import Foundation
@testable import PrimaeNative

@Suite(.serialized) @MainActor struct SilentLaunchEngineErrorTests {

    private func makeVM(launchArm: PilotAudioCondition, engineError: String?) -> TracingViewModel {
        let audio = EngineModelAudio()
        audio.initializationError = engineError
        var deps = TracingDependencies.stub
        deps.audioCondition = launchArm
        deps.audio = audio
        return TracingViewModel(deps)
    }

    @Test func movingOutOfSilentSurfacesTheRealEnginesError() {
        let vm = makeVM(launchArm: .silent, engineError: "Audio nicht verfügbar")
        #expect(vm.toastMessage == nil, "a silent launch has nothing to report")
        vm.applyArm(.phoneme)
        #expect(vm.toastMessage == "Audio nicht verfügbar")
    }

    /// SDK27: the launch start is asynchronous, so its failure lands after
    /// `init` returns. The toast must still show once the start-up settles.
    @Test func aStartFailureReportedAfterInitIsToasted() async {
        let audio = EngineModelAudio()
        audio.startupErrorOnSettle = "Ton konnte nicht gestartet werden"
        var deps = TracingDependencies.stub
        deps.audioCondition = .phoneme
        deps.audio = audio
        let vm = TracingViewModel(deps)
        await vm.startupAudioErrorTask?.value
        #expect(vm.toastMessage == "Ton konnte nicht gestartet werden")
    }

    @Test func aLateFailureInTheSilentArmIsNotToasted() async {
        let audio = EngineModelAudio()
        audio.startupErrorOnSettle = "Ton konnte nicht gestartet werden"
        var deps = TracingDependencies.stub
        deps.audioCondition = .silent
        deps.audio = audio
        let vm = TracingViewModel(deps)
        await vm.startupAudioErrorTask?.value
        #expect(vm.toastMessage == nil, "a silent launch has nothing to report")
        vm.applyArm(.phoneme)
        #expect(vm.toastMessage == "Ton konnte nicht gestartet werden")
    }

    @Test func aHealthyEngineSurfacesNothing() {
        let vm = makeVM(launchArm: .silent, engineError: nil)
        vm.applyArm(.phoneme)
        #expect(vm.toastMessage == nil)
    }
}
