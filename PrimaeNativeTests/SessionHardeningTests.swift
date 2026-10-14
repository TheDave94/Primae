// SessionHardeningTests.swift
// R-044 (audit 2026-10-13, H1-12): nothing kept the display awake during a
// session. Observe has no touch for 6–14 s and the proctor talks to the
// child between letters, so Auto-Lock could lock the iPad mid-session —
// `.inactive` then `.background`, and a passcode while the child waits.
// The view model now says when the screen must stay awake (a study
// session with an enrolled child, scene active); `MainAppView` applies it
// to `UIApplication.isIdleTimerDisabled`. The other half of R-044 —
// `.defersSystemGestures(on: .all)` on the shell — is a view modifier with
// no unit-testable surface; it is a device measurement (register M3).

import Testing
import SwiftUI
@testable import PrimaeNative

@Suite @MainActor struct SessionHardeningTests {

    @Test("an enrolled study session keeps the screen awake while the scene is active, and only then")
    func awakeWhileActive() async {
        let rig = LifecycleRig()
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.vm.keepsScreenAwake, "Auto-Lock can lock the iPad in the middle of a session")
        await rig.vm.scenePhaseDidChange(to: .inactive)?.value
        #expect(!rig.vm.keepsScreenAwake, "the idle timer must be the system's again once the scene is not active")
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(rig.vm.keepsScreenAwake)
        await rig.vm.scenePhaseDidChange(to: .background)?.value
        #expect(!rig.vm.keepsScreenAwake)
    }

    @Test("no enrolled child: the device is not held awake")
    func notEnrolledNotAwake() async {
        let rig = LifecycleRig { $0.participantEnrolled = false }
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(!rig.vm.keepsScreenAwake)
    }

    @Test("outside a study session the idle timer is left alone")
    func casualNotAwake() async {
        let rig = LifecycleRig { $0.studyMode = false }
        await rig.vm.scenePhaseDidChange(to: .active)?.value
        #expect(!rig.vm.keepsScreenAwake)
    }
}
