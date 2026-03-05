//  VelocityMappingTests.swift
//  BuchstabenNativeTests
//
//  Tests for TracingViewModel.mapVelocityToSpeed — pure static method,
//  no MainActor/audio/touch needed.

import XCTest
import CoreGraphics
@testable import BuchstabenNative

final class VelocityMappingTests: XCTestCase {

    // Constants mirrored from TracingViewModel (not exposed, so duplicated here)
    private let low:  CGFloat = 120.0
    private let high: CGFloat = 1300.0
    private let speedAtLow:  Float = 2.0
    private let speedAtHigh: Float = 0.5

    // MARK: 1 — v=0 returns max speed (2.0)

    func testZeroVelocity_returnsMaxSpeed() {
        XCTAssertEqual(TracingViewModel.mapVelocityToSpeed(0), 2.0, accuracy: 1e-6)
    }

    // MARK: 2 — v at low boundary returns 2.0

    func testLowBoundary_returnsMaxSpeed() {
        XCTAssertEqual(TracingViewModel.mapVelocityToSpeed(120), 2.0, accuracy: 1e-6)
    }

    // MARK: 3 — v at high boundary returns 0.5

    func testHighBoundary_returnsMinSpeed() {
        XCTAssertEqual(TracingViewModel.mapVelocityToSpeed(1300), 0.5, accuracy: 1e-6)
    }

    // MARK: 4 — v > high clamps to 0.5

    func testAboveHigh_clampsToMinSpeed() {
        XCTAssertEqual(TracingViewModel.mapVelocityToSpeed(5000), 0.5, accuracy: 1e-6)
        XCTAssertEqual(TracingViewModel.mapVelocityToSpeed(.greatestFiniteMagnitude), 0.5, accuracy: 1e-6)
    }

    // MARK: 5 — v < low (but > 0) returns 2.0

    func testBelowLow_returnsMaxSpeed() {
        XCTAssertEqual(TracingViewModel.mapVelocityToSpeed(50),  2.0, accuracy: 1e-6)
        XCTAssertEqual(TracingViewModel.mapVelocityToSpeed(119), 2.0, accuracy: 1e-6)
    }

    // MARK: 6 — Midpoint v=710 is halfway → speed = 2.0 - 1.5*0.5 = 1.25

    func testMidpoint_returnsLinearInterpolation() {
        let mid: CGFloat = (120 + 1300) / 2.0  // 710
        let expected: Float = 2.0 - (1.5 * 0.5)  // 1.25
        XCTAssertEqual(TracingViewModel.mapVelocityToSpeed(mid), expected, accuracy: 1e-5)
    }

    // MARK: 7 — Result is monotonically non-increasing

    func testMonotonicallyNonIncreasing() {
        var prev: Float = 2.0
        for v in stride(from: CGFloat(0), through: 2000, by: 10) {
            let speed = TracingViewModel.mapVelocityToSpeed(v)
            XCTAssertLessThanOrEqual(speed, prev + 1e-6,
                                     "Speed must be non-increasing: v=\(v) gave \(speed) > prev \(prev)")
            prev = speed
        }
    }

    // MARK: 8 — Result always in [0.5, 2.0]

    func testResult_alwaysInRange() {
        var rng = SeededRNGLocal()
        for _ in 0..<10_000 {
            let v = CGFloat(Double.random(in: 0...5000, using: &rng))
            let speed = TracingViewModel.mapVelocityToSpeed(v)
            XCTAssertGreaterThanOrEqual(speed, 0.5, "speed must be >= 0.5 for v=\(v)")
            XCTAssertLessThanOrEqual(speed, 2.0,    "speed must be <= 2.0 for v=\(v)")
            XCTAssertFalse(speed.isNaN,      "speed must not be NaN for v=\(v)")
            XCTAssertFalse(speed.isInfinite, "speed must not be Inf for v=\(v)")
        }
    }

    // MARK: 9 — Negative velocity treated like zero (returns 2.0)

    func testNegativeVelocity_treatedLikeZero() {
        // hypot always returns positive; direct negative call tests the clamp path
        XCTAssertEqual(TracingViewModel.mapVelocityToSpeed(-100), 2.0, accuracy: 1e-6)
    }

    // MARK: 10 — Return type is Float (not Double)

    func testReturnType_isFloat() {
        let result = TracingViewModel.mapVelocityToSpeed(500)
        // Compiler enforces this, but a runtime check documents the contract.
        XCTAssertTrue(type(of: result) == Float.self)
    }
}

// MARK: - Local seeded RNG (avoids import collision with StrokeTrackerTests)

private struct SeededRNGLocal: RandomNumberGenerator {
    private var state: UInt64 = 0xfeedface_deadc0de
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}
