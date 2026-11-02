// The research dashboard's "Keine Kopfhörer verbunden" banner (fix lane L2,
// 2026-11-02, with L1's B6 gate): headphones are required in EVERY arm from
// protocol r16, the silent arm included, so the proctor banner must show for
// a silent-arm child the gate stops, too. Until r16 it showed for the sound
// arms only. Pure functions, no global state.

import Testing
@testable import PrimaeNative

@MainActor
struct HeadphoneBannerTests {

    /// Mutation check: put `arm != .silent &&` back into
    /// `showsHeadphoneWarning` — RED for `.silent`.
    @Test("the headphone banner shows in every arm, the silent arm included",
          arguments: PilotAudioCondition.allCases)
    func bannerShowsInEveryArm(arm: PilotAudioCondition) {
        #expect(ResearchDashboardView.showsHeadphoneWarning(arm: arm, panningEnabled: true,
                                                            headphonesConnected: false),
                "\(arm): a child stopped for missing headphones gets no proctor banner")
        #expect(!ResearchDashboardView.showsHeadphoneWarning(arm: arm, panningEnabled: true,
                                                             headphonesConnected: true),
                "\(arm): control, headphones connected")
        #expect(!ResearchDashboardView.showsHeadphoneWarning(arm: arm, panningEnabled: false,
                                                             headphonesConnected: false),
                "\(arm): control, panning off waives the requirement")
    }

    @Test("the silent arm's banner names its own arm, not a pan the arm does not have")
    func silentArmTextNamesItsArm() {
        let text = ResearchDashboardView.headphoneWarningText(arm: .silent, requiresHeadphones: true)
        #expect(text.contains("stillen Arm"), "\(text)")
        #expect(!text.contains("Panning"), "\(text)")
        #expect(text.hasSuffix("erst, wenn Kopfhörer verbunden sind."), "\(text)")
    }
}
