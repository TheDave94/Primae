import Testing
import CoreGraphics
@testable import PrimaeNative

private func sample(_ accuracy: CGFloat, letter: String = "A") -> AdaptationSample {
    AdaptationSample(letter: letter, accuracy: accuracy, completionTime: 3.0)
}

private func makePolicy(
    windowSize: Int = 5, hysteresisCount: Int = 2,
    promotionThreshold: CGFloat = 0.85, demotionThreshold: CGFloat = 0.55,
    initial: DifficultyTier = .standard
) -> MovingAverageAdaptationPolicy {
    MovingAverageAdaptationPolicy(
        windowSize: windowSize, hysteresisCount: hysteresisCount,
        promotionAccuracyThreshold: promotionThreshold,
        demotionAccuracyThreshold: demotionThreshold,
        initialTier: initial
    )
}

@Suite @MainActor struct DifficultyTierTests {
    @Test func tierOrdering() {
        #expect(DifficultyTier.easy < .standard)
        #expect(DifficultyTier.standard < .strict)
        #expect(DifficultyTier.strict > .easy)
    }
    @Test func radiusMultiplier_easyLargest() {
        #expect(DifficultyTier.easy.radiusMultiplier > DifficultyTier.standard.radiusMultiplier)
        #expect(DifficultyTier.standard.radiusMultiplier > DifficultyTier.strict.radiusMultiplier)
    }
    @Test func radiusMultiplier_standardIsOne() {
        #expect(abs(DifficultyTier.standard.radiusMultiplier - 1.0) < 1e-9)
    }
    @Test func allCases_count() {
        #expect(DifficultyTier.allCases.count == 3)
    }
}

@Suite struct FixedAdaptationPolicyTests {
    @Test func fixed_alwaysReturnsSameTier() {
        var policy = FixedAdaptationPolicy(currentTier: .easy)
        policy.record(sample(1.0)); policy.record(sample(1.0))
        #expect(policy.currentTier == .easy)
    }
    @Test func fixed_resetNoOp() {
        var policy = FixedAdaptationPolicy(currentTier: .strict)
        policy.reset()
        #expect(policy.currentTier == .strict)
    }
}

@Suite struct MovingAverageAdaptationPolicyTests {
    @Test func initialTier_isStandard() {
        #expect(makePolicy().currentTier == .standard)
    }
    @Test func initialWindowAccuracy_isZero() {
        #expect(abs(makePolicy().windowAccuracy) < 1e-9)
    }
    @Test func noPromotion_beforeWindowFills() {
        var policy = makePolicy(windowSize: 5, hysteresisCount: 2)
        for _ in 0..<4 { policy.record(sample(1.0)) }
        #expect(policy.currentTier == .standard)
    }
    @Test func promotion_afterWindowAndHysteresis() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 2, promotionThreshold: 0.85)
        for _ in 0..<3 { policy.record(sample(0.9)) }
        #expect(policy.currentTier == .standard)
        policy.record(sample(0.9))
        #expect(policy.currentTier == .strict)
    }
    @Test func promotion_capsAtStrict() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 1, initial: .strict)
        for _ in 0..<10 { policy.record(sample(1.0)) }
        #expect(policy.currentTier == .strict)
    }
    @Test func demotion_afterWindowAndHysteresis() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 2, demotionThreshold: 0.55)
        for _ in 0..<3 { policy.record(sample(0.4)) }
        #expect(policy.currentTier == .standard)
        policy.record(sample(0.4))
        #expect(policy.currentTier == .easy)
    }
    @Test func demotion_floorAtEasy() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 1, initial: .easy)
        for _ in 0..<10 { policy.record(sample(0.1)) }
        #expect(policy.currentTier == .easy)
    }
    @Test func hysteresis_doesNotFlipOnSingleAboveThreshold() {
        var policy = makePolicy(windowSize: 5, hysteresisCount: 3, promotionThreshold: 0.85)
        for _ in 0..<5 { policy.record(sample(0.9)) }
        #expect(policy.currentTier == .standard)
        policy.record(sample(0.4))
        for _ in 0..<5 { policy.record(sample(0.9)) }
        #expect(policy.currentTier == .standard)
    }
    @Test func windowAccuracy_onlyLastNSamples() {
        var policy = makePolicy(windowSize: 3)
        policy.record(sample(0.0)); policy.record(sample(0.0))
        policy.record(sample(1.0)); policy.record(sample(1.0)); policy.record(sample(1.0))
        #expect(abs(policy.windowAccuracy - 1.0) < 1e-6)
    }
    @Test func reset_clearsSamplesAndTier() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 1)
        for _ in 0..<5 { policy.record(sample(1.0)) }
        #expect(policy.currentTier == .strict)
        policy.reset()
        #expect(policy.currentTier == .standard)
        #expect(policy.samples.isEmpty)
        #expect(abs(policy.windowAccuracy) < 1e-9)
    }
    @Test func sparseHistory_noEvaluation() {
        var policy = makePolicy(windowSize: 10, hysteresisCount: 2)
        policy.record(sample(1.0)); policy.record(sample(1.0))
        #expect(policy.currentTier == .standard)
    }
    @Test func mixedAccuracy_staysInMidZone() {
        var policy = makePolicy(windowSize: 4, hysteresisCount: 2,
                                promotionThreshold: 0.85, demotionThreshold: 0.55)
        for _ in 0..<6 { policy.record(sample(0.7)) }
        #expect(policy.currentTier == .standard)
    }
}
