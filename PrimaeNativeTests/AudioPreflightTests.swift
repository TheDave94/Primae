// AudioPreflightTests.swift
// R-018 (audit 2026-10-13, A2-02): the audio session is mixable
// (`.interruptSpokenAudioAndMixWithOthers`), so another app's audio plays
// through every arm — the silent arm included. Changing the category is an
// AudioEngine ruling (NEEDS DAVID, D7); this batch reads the state instead:
// a proctor warning beside the headphone banner, and a flag on every phase
// row and every enrolment. Nothing here blocks a session (D7 default).
//
// UNVERIFIED on hardware: whether `isOtherAudioPlaying` /
// `secondaryAudioShouldBeSilencedHint` read true with Music playing on the
// study iPad (register M-series). These tests drive the injected reader.

import Testing
import Foundation
@testable import PrimaeNative

@Suite @MainActor struct AudioPreflightTests {

    private func vm(arm: PilotAudioCondition, env: FixedDeliveryEnvironment) -> TracingViewModel {
        var deps = TracingDependencies.stub
        deps.studyMode = true
        deps.thesisCondition = .threePhase
        deps.audioCondition = arm
        deps.deliveryEnvironment = env
        return TracingViewModel(deps)
    }

    @Test("R-018: no warning while no other audio plays")
    func quietDeviceHasNoWarning() {
        for arm in PilotAudioCondition.allCases {
            #expect(vm(arm: arm, env: FixedDeliveryEnvironment()).audioPreflightWarning == nil, "\(arm)")
        }
    }

    @Test("R-018: other audio playing is warned in EVERY arm, the silent arm included")
    func otherAudioIsWarnedInEveryArm() {
        let env = FixedDeliveryEnvironment()
        env.stamp.otherAudioPlaying = true
        for arm in PilotAudioCondition.allCases {
            let warning = vm(arm: arm, env: env).audioPreflightWarning
            #expect(warning != nil, "\(arm): another app's audio was not warned")
            #expect(warning?.contains("andere App") == true, "\(String(describing: warning))")
        }
    }

    @Test("R-018: the system's 'silence secondary audio' hint alone is warned too")
    func secondaryHintIsWarned() {
        let env = FixedDeliveryEnvironment()
        env.stamp.secondaryAudioHint = true
        #expect(vm(arm: .silent, env: env).audioPreflightWarning != nil)
    }

    @Test("R-018: the flag rides on the phase row — the state at the phase's start")
    func flagIsOnTheRow() {
        let env = FixedDeliveryEnvironment()
        env.stamp.otherAudioPlaying = true
        env.stamp.secondaryAudioHint = true
        let rig = LifecycleRig(arm: .silent) { $0.deliveryEnvironment = env }
        rig.vm.loadLetter(name: "A")
        let atStart = rig.vm.phaseRowContext(for: .observe, finalizedBy: .child).delivery?.atStart
        #expect(atStart?.otherAudioPlaying == true)
        #expect(atStart?.secondaryAudioHint == true)
    }
}
