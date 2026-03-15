//  DifficultyAdaptationTests.swift
//  BuchstabenNativeTests

import XCTest
import CoreGraphics
@testable import BuchstabenNative

private func sample(_ accuracy: CGFloat, letter: String = "A") -> AdaptationSample {
    AdaptationSample(letter: letter, accuracy: accuracy, completionTime: 3.0)
}

private func makePolicy(
    windowSize: Int = 5,
    hysteresisCount: Int = 2,
    promotionThreshold: CGFloat = 0.85,
    demotionThreshold: CGFloat = 0.55,
    initial: DifficultyTier = .standard
) -> MovingAverageAdaptationPolicy {
    MovingAverageAdaptationPolicy(
        windowSize: windowSize,
        hysteresisCount: hysteresisCount,
        promotionAccuracyThreshold: promotionThreshold,
        demotionAccuracyThreshold: demotionThreshold,
        initialTier: initial
    )
}

@MainActor
final class DifficultyTierTests: XCTestCase {

    func testTierOrdering() {
        XCTAssertLessThan(DifficultyTier.easy, .standard)
        XCTAssertLessThan(DifficultyTier.standard, .strict)
        XCTAssertGreaterThan(DifficultyTier.strict, .easy)
    }

    func testRadiusMultiplier_easyLargest() {
        XCTAssertGreaterThan(DifficultyTier.easy.radiusMultiplier, DifficultyTier.standard.radiusMultiplier)
        XCTAssertGreaterThan(DifficultyTier.standard.radiusMultiplier, DifficultyTier.strict.radiusMultiplier)
    }

    func testRadiusMultiplier_standardIsOne() {
        XCTAssertEqual(DifficultyTier.standard.radiusMultiplier, 1.0, accuracy: 1e-9)
    }

    func testAllCases_count() {
        XCTAssertEqual(DifficultyTier.allCases.count, 3)
    }
}

final class FixedAdaptationPolicyTests: XCTestCase {

    func testFixed_alwaysReturnsSameTier() {
        var policy = FixedAdaptationPolicy(currentTier: .easy)
        policy.record(sample(1.0))
        policy.record(sample(1.0))
        XCTAssertEqual(policy.currentTier, .easy)
    }

    func testFixed_resetNoOp() {
        var policy = FixedAdaptationPolicy(currentTier: .strict)
        policy.reset()
        XCTAssertEqual(policy.currentTier, .strict)
    }
}

final class MovingAverageAdaptationPolicyTests: XCTestCase {

    // MARK: Initial state

    func testInitialTier_isStandard() {
        let policy = makePolicy()
        XCTAssertEqual(policy.currentTier, .standard)
    }

    func testInitialWindowAccuracy_isZero() {
        let policy = makePolicy()
        XCTAssertEqual(policy.windowAccuracy, 0, accuracy: 1e-9)
    }

    // MARK: No change before window fills

    func testNoPromotion_beforeWindowFills() {
        var policy = makePolicy(windowSize: 5, hysteresisCount: 2)
        // Add 4 perfect samples — window not yet full
        for _ in 0..<4 { policy.record(sample(1.0)) }
        XCTAssertEqual(policy.currentTier, .standard)
    }

    // MARK: Promotion

    func testPromotion_afterWindowAndHysteresis() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 2, promotionThreshold: 0.85)
        // Fill window with high accuracy, then 2 more evaluations above threshold
        for _ in 0..<3 { policy.record(sample(0.9)) }  // window fills, eval 1
        XCTAssertEqual(policy.currentTier, .standard)  // only 1 consecutive yet
        policy.record(sample(0.9))  // eval 2 — should promote
        XCTAssertEqual(policy.currentTier, .strict)
    }

    func testPromotion_capsAtStrict() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 1, initial: .strict)
        for _ in 0..<10 { policy.record(sample(1.0)) }
        XCTAssertEqual(policy.currentTier, .strict)
    }

    // MARK: Demotion

    func testDemotion_afterWindowAndHysteresis() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 2, demotionThreshold: 0.55)
        for _ in 0..<3 { policy.record(sample(0.4)) }  // eval 1
        XCTAssertEqual(policy.currentTier, .standard)
        policy.record(sample(0.4))  // eval 2 — demote
        XCTAssertEqual(policy.currentTier, .easy)
    }

    func testDemotion_floorAtEasy() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 1, initial: .easy)
        for _ in 0..<10 { policy.record(sample(0.1)) }
        XCTAssertEqual(policy.currentTier, .easy)
    }

    // MARK: Hysteresis prevents rapid flipping

    func testHysteresis_doesNotFlipOnSingleAboveThreshold() {
        var policy = makePolicy(windowSize: 5, hysteresisCount: 3, promotionThreshold: 0.85)
        // Fill window
        for _ in 0..<5 { policy.record(sample(0.9)) }  // 1 consecutive
        XCTAssertEqual(policy.currentTier, .standard)   // needs 3 consecutive
        policy.record(sample(0.4))  // reset consecutive count
        for _ in 0..<5 { policy.record(sample(0.9)) }  // back to 1
        XCTAssertEqual(policy.currentTier, .standard)
    }

    // MARK: Window size — only last N samples counted

    func testWindowAccuracy_onlyLastNSamples() {
        var policy = makePolicy(windowSize: 3)
        policy.record(sample(0.0))
        policy.record(sample(0.0))
        policy.record(sample(1.0))
        policy.record(sample(1.0))
        policy.record(sample(1.0))
        // Window of last 3 = all 1.0 → accuracy = 1.0
        XCTAssertEqual(policy.windowAccuracy, 1.0, accuracy: 1e-6)
    }

    // MARK: Reset

    func testReset_clearsSamplesAndTier() {
        var policy = makePolicy(windowSize: 3, hysteresisCount: 1)
        for _ in 0..<5 { policy.record(sample(1.0)) }
        XCTAssertEqual(policy.currentTier, .strict)
        policy.reset()
        XCTAssertEqual(policy.currentTier, .standard)
        XCTAssertTrue(policy.samples.isEmpty)
        XCTAssertEqual(policy.windowAccuracy, 0, accuracy: 1e-9)
    }

    // MARK: Sparse history (fewer than window)

    func testSparseHistory_noEvaluation() {
        var policy = makePolicy(windowSize: 10, hysteresisCount: 2)
        policy.record(sample(1.0))
        policy.record(sample(1.0))
        XCTAssertEqual(policy.currentTier, .standard, "No evaluation until window fills")
    }

    // MARK: Mixed accuracy in window

    func testMixedAccuracy_staysInMidZone() {
        var policy = makePolicy(windowSize: 4, hysteresisCount: 2,
                                promotionThreshold: 0.85, demotionThreshold: 0.55)
        // Average ~0.7 — in the middle band, no change
        for _ in 0..<6 {
            policy.record(sample(0.7))
        }
        XCTAssertEqual(policy.currentTier, .standard)
    }
}
