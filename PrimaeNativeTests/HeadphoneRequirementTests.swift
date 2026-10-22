// HeadphoneRequirementTests.swift
// PrimaeNativeTests
//
// Protocol r14 (David, 2026-10-22): a sound-arm study session runs only
// over headphones. Without them the session screen is the proctor-facing
// stop, live with the route; the silent arm and the panning-off comparison
// configuration are unaffected; automated tests waive it with a launch
// argument.

import AVFoundation
import Testing
@testable import PrimaeNative

@MainActor
@Suite struct HeadphoneRequirementTests {

    private static func stamp(route: String?) -> EnvironmentStamp {
        let d = FixedDeliveryEnvironment.defaultStamp
        return EnvironmentStamp(
            outputRoute: route, outputVolume: d.outputVolume, outputLatency: d.outputLatency,
            otherAudioPlaying: d.otherAudioPlaying, secondaryAudioHint: d.secondaryAudioHint,
            guidedAccess: d.guidedAccess, idleTimerDisabled: d.idleTimerDisabled,
            lowPowerMode: d.lowPowerMode, thermalState: d.thermalState,
            batteryLevel: d.batteryLevel)
    }

    private func studyVM(arm: PilotAudioCondition, route: String?,
                         required: Bool = true, panning: Bool = true) -> TracingViewModel {
        var deps = TracingDependencies.stub.with(studyMode: true)
        deps.audioCondition = arm
        deps.panningEnabled = panning
        deps.requiresHeadphones = required
        deps.deliveryEnvironment = FixedDeliveryEnvironment(Self.stamp(route: route))
        return TracingViewModel(deps)
    }

    @Test("a sound arm on the loudspeaker is stopped", arguments: [PilotAudioCondition.phoneme, .spatial])
    func soundArmWithoutHeadphonesIsStopped(arm: PilotAudioCondition) {
        let vm = studyVM(arm: arm, route: AVAudioSession.Port.builtInSpeaker.rawValue)
        #expect(vm.sessionBlockReason == HeadphoneRequirement.refusal,
                "\(arm): got \(String(describing: vm.sessionBlockReason))")
    }

    @Test("the same arm over headphones runs")
    func soundArmOverHeadphonesRuns() {
        let vm = studyVM(arm: .phoneme, route: AVAudioSession.Port.headphones.rawValue)
        #expect(vm.sessionBlockReason == nil)
    }

    @Test("plugging headphones in lifts the stop; unplugging brings it back")
    func theStopFollowsTheRoute() {
        let vm = studyVM(arm: .phoneme, route: AVAudioSession.Port.builtInSpeaker.rawValue)
        #expect(vm.sessionBlockReason == HeadphoneRequirement.refusal, "precondition")

        vm.handleAudioRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue,
                                  outputLost: false,
                                  outputPortType: AVAudioSession.Port.headphones.rawValue)
        #expect(vm.sessionBlockReason == nil, "headphones in: the session carries on")

        vm.handleAudioRouteChange(reasonRawValue: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue,
                                  outputLost: true,
                                  outputPortType: AVAudioSession.Port.builtInSpeaker.rawValue,
                                  previousOutputPortType: AVAudioSession.Port.headphones.rawValue)
        #expect(vm.sessionBlockReason == HeadphoneRequirement.refusal, "headphones out: stopped again")
    }

    @Test("the silent arm needs no headphones")
    func silentArmIsNeverStopped() {
        let vm = studyVM(arm: .silent, route: AVAudioSession.Port.builtInSpeaker.rawValue)
        #expect(vm.sessionBlockReason == nil)
    }

    @Test("with panning off the sound arms are built for a loudspeaker")
    func panningOffIsNotStopped() {
        let vm = studyVM(arm: .spatial, route: AVAudioSession.Port.builtInSpeaker.rawValue, panning: false)
        #expect(vm.sessionBlockReason == nil)
    }

    @Test("a waived run is not stopped")
    func waivedRunIsNotStopped() {
        let vm = studyVM(arm: .phoneme, route: AVAudioSession.Port.builtInSpeaker.rawValue, required: false)
        #expect(vm.sessionBlockReason == nil)
    }

    @Test("only the test launch argument waives the requirement")
    func waiverIsTheLaunchArgument() {
        #expect(HeadphoneRequirement.waived(arguments: ["Primae", "-allowNonHeadphoneRoute"]))
        #expect(!HeadphoneRequirement.waived(arguments: ["Primae"]))
        #expect(!HeadphoneRequirement.waived(arguments: ["Primae", "-audioSignalProbe"]))
    }

    @Test("wired, Bluetooth and USB outputs count as headphones; the speaker does not")
    func headphoneClassPorts() {
        for port in [AVAudioSession.Port.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .usbAudio] {
            #expect(HeadphoneRequirement.isHeadphones(port.rawValue), "\(port.rawValue)")
        }
        #expect(!HeadphoneRequirement.isHeadphones(AVAudioSession.Port.builtInSpeaker.rawValue))
        #expect(!HeadphoneRequirement.isHeadphones(AVAudioSession.Port.builtInReceiver.rawValue))
        #expect(!HeadphoneRequirement.isHeadphones(nil))
    }
}
