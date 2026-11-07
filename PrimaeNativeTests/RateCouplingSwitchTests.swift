import Testing
import CoreGraphics
@testable import PrimaeNative

// r18 slice 1 (R18DIM): the "Tempo folgt dem Stift" switch at seam A
// (ArmCoupling, pure) and seam B (the stamp, in ComparisonConfigurationStampTests).
// The observe dot is covered in ProtocolMatrixTests.observeRateIsOneWhenRateCouplingIsOff.
// Pan (panningEnabled) already has its switch, Settings row and stamp test;
// its seam A pair is pinned here too.
struct RateCouplingSwitchTests {

    private let slowPen: CGFloat = 20     // below the M3 floor (50 pt/s)
    private let fastPen: CGFloat = 600    // above the M3 ceiling (400 pt/s)

    @Test("rate coupling off: a slow and a fast stroke both play at 1.0, in both arms",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func offHoldsRateAtOne(arm: PilotAudioCondition) {
        for v in [slowPen, 150, fastPen] {
            let p = ArmCoupling.parameters(canvasNormalized: CGPoint(x: 0.3, y: 0.6), velocity: v,
                                           panningEnabled: true, rateCouplingEnabled: false, arm: arm)
            #expect(p.speed == 1.0, "\(arm) at \(v) pt/s: got \(p.speed)")
        }
    }

    @Test("rate coupling on (the r17 default): slow and fast differ and follow the M3 map",
          arguments: [PilotAudioCondition.phoneme, .spatial])
    func onFollowsTheMap(arm: PilotAudioCondition) {
        let slow = ArmCoupling.parameters(canvasNormalized: CGPoint(x: 0.5, y: 0.5), velocity: slowPen,
                                          panningEnabled: true, rateCouplingEnabled: true, arm: arm)
        let fast = ArmCoupling.parameters(canvasNormalized: CGPoint(x: 0.5, y: 0.5), velocity: fastPen,
                                          panningEnabled: true, rateCouplingEnabled: true, arm: arm)
        #expect(slow.speed == 0.8 && fast.speed == 1.25, "slow \(slow.speed), fast \(fast.speed)")
    }

    @Test("rate coupling touches only the rate: pan and pitch are unchanged by it")
    func offLeavesPanAndPitchAlone() {
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let pt = CGPoint(x: 0.8, y: 0.2)
            let on  = ArmCoupling.parameters(canvasNormalized: pt, velocity: 300, panningEnabled: true,
                                             rateCouplingEnabled: true, arm: arm)
            let off = ArmCoupling.parameters(canvasNormalized: pt, velocity: 300, panningEnabled: true,
                                             rateCouplingEnabled: false, arm: arm)
            #expect(on.horizontalBias == off.horizontalBias && on.spatialPitchCents == off.spatialPitchCents)
        }
    }

    @Test("the lift's frozen tail uses the same switch")
    func liftTailHonoursTheSwitch() {
        #expect(ArmCoupling.speed(forVelocity: fastPen, rateCouplingEnabled: false) == 1.0)
        #expect(ArmCoupling.speed(forVelocity: fastPen, rateCouplingEnabled: true) == 1.25)
    }

    @Test("pan switch: off centres the bias, on follows x, identical in both arms")
    func panSwitchSeamA() {
        for arm in [PilotAudioCondition.phoneme, .spatial] {
            let right = CGPoint(x: 0.9, y: 0.5)
            let on  = ArmCoupling.parameters(canvasNormalized: right, velocity: 150, panningEnabled: true,
                                             rateCouplingEnabled: true, arm: arm)
            let off = ArmCoupling.parameters(canvasNormalized: right, velocity: 150, panningEnabled: false,
                                             rateCouplingEnabled: true, arm: arm)
            #expect(on.horizontalBias > 0.7, "\(arm): \(on.horizontalBias)")
            #expect(off.horizontalBias == 0, "\(arm): \(off.horizontalBias)")
        }
    }

    @Test("the switch is stamped and stored under its own key, default on")
    func keyAndDefault() {
        #expect(StudyComparisonSettings.rateCouplingDefault == true)
        #expect(StudyComparisonSettings.rateCouplingKey.hasSuffix("rateCoupling"))
        var c = StudyComparisonConfiguration.defaults
        #expect(c.nonDefaultStamp == nil)
        c.rateCoupling = false
        #expect(c.nonDefaultStamp == "rateCoupling=false")
    }
}
