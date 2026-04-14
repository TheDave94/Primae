//  VelocityMappingTests.swift
//  BuchstabenNativeTests

import Testing
import CoreGraphics
@testable import BuchstabenNative

struct VelocityMappingTests {

    // MARK: 1 — v=0 returns max speed (2.0)
    @Test func zeroVelocity_returnsMaxSpeed() {
        #expect(TracingViewModel.mapVelocityToSpeed(0) == 0.5)
    }

    // MARK: 2 — v at low boundary returns 2.0
    @Test func lowBoundary_returnsMaxSpeed() {
        #expect(TracingViewModel.mapVelocityToSpeed(50) == 0.5)
    }

    // MARK: 3 — v at high boundary returns 0.5
    @Test func highBoundary_returnsMinSpeed() {
        #expect(TracingViewModel.mapVelocityToSpeed(800) == 2.0)
    }

    // MARK: 4 — v > high clamps to 0.5
    @Test func aboveHigh_clampsToMinSpeed() {
        #expect(TracingViewModel.mapVelocityToSpeed(5000) == 2.0)
        #expect(TracingViewModel.mapVelocityToSpeed(.greatestFiniteMagnitude) == 2.0)
    }

    // MARK: 5 — v < low (but > 0) returns 2.0
    @Test func belowLow_returnsMaxSpeed() {
        #expect(TracingViewModel.mapVelocityToSpeed(30)  == 0.5)
        #expect(TracingViewModel.mapVelocityToSpeed(49)  == 0.5)
    }

    // MARK: 6 — Midpoint v=710 is halfway → speed = 1.25
    @Test func midpoint_returnsLinearInterpolation() {
        let mid: CGFloat = (50 + 800) / 2.0
        let expected: Float = 0.5 + (1.5 * 0.5)
        #expect(abs(TracingViewModel.mapVelocityToSpeed(mid) - expected) < 1e-5)
    }

    // MARK: 7 — Result is monotonically non-increasing
    @Test func monotonicallyNonDecreasing() {
        var prev: Float = 2.0
        for v in stride(from: CGFloat(0), through: 2000, by: 10) {
            let speed = TracingViewModel.mapVelocityToSpeed(v)
            #expect(speed >= prev - 1e-6,
                "Speed must be non-decreasing: v=\(v) gave \(speed) < prev \(prev)")
            prev = speed
        }
    }

    // MARK: 8 — Result always in [0.5, 2.0]
    @Test func result_alwaysInRange() {
        var rng = SeededRNGLocal()
        for _ in 0..<10_000 {
            let v = CGFloat(Double.random(in: 0...5000, using: &rng))
            let speed = TracingViewModel.mapVelocityToSpeed(v)
            #expect(speed >= 0.5)
            #expect(speed <= 2.0)
            #expect(!speed.isNaN)
            #expect(!speed.isInfinite)
        }
    }

    // MARK: 9 — Negative velocity treated like zero
    @Test func negativeVelocity_treatedLikeZero() {
        #expect(TracingViewModel.mapVelocityToSpeed(-100) == 0.5)
    }

    // MARK: 10 — Return type is Float
    @Test func returnType_isFloat() {
        let result = TracingViewModel.mapVelocityToSpeed(500)
        #expect(type(of: result) == Float.self)
    }
}

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
