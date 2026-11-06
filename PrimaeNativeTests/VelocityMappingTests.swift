import Testing
import CoreGraphics
@testable import PrimaeNative

// Mapping M3 (R17D, RULINGS 2026-11-06; RATE.md section 3a): 50 pt/s and
// below -> 0.8, 150 -> 1.0, 400 and above -> 1.25, piecewise linear.
struct VelocityMappingTests {

    @Test func zeroVelocity_returnsMinRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(0) == 0.8)
    }

    @Test func lowBoundary_returnsMinRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(50) == 0.8)
    }

    /// R17D (e): rate 1 at 150 pt/s, the M3 knee.
    @Test func referenceSpeed_returnsNaturalRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(150) == 1.0)
    }

    @Test func highBoundary_returnsMaxRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(400) == 1.25)
    }

    @Test func aboveHigh_clampsToMaxRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(401) == 1.25)
        #expect(TouchDispatcher.mapVelocityToSpeed(800) == 1.25)
        #expect(TouchDispatcher.mapVelocityToSpeed(5000) == 1.25)
        #expect(TouchDispatcher.mapVelocityToSpeed(.greatestFiniteMagnitude) == 1.25)
    }

    @Test func belowLow_returnsMinRate() {
        #expect(TouchDispatcher.mapVelocityToSpeed(30)  == 0.8)
        #expect(TouchDispatcher.mapVelocityToSpeed(49)  == 0.8)
    }

    /// Linear on each side of the knee (RATE.md's table: 75 -> 0.85, 100 -> 0.90, 200 -> 1.05, 250 -> 1.10, 300 -> 1.15).
    @Test func segments_areLinear() {
        let table: [(CGFloat, Float)] = [(75, 0.85), (100, 0.90), (125, 0.95), (200, 1.05), (250, 1.10), (300, 1.15), (350, 1.20)]
        for (v, r) in table {
            #expect(abs(TouchDispatcher.mapVelocityToSpeed(v) - r) < 1e-5, "v=\(v)")
        }
    }

    @Test func monotonicallyNonDecreasing() {
        var prev: Float = 0.8
        for v in stride(from: CGFloat(0), through: 2000, by: 10) {
            let speed = TouchDispatcher.mapVelocityToSpeed(v)
            #expect(speed >= prev - 1e-6,
                "Speed must be non-decreasing: v=\(v) gave \(speed) < prev \(prev)")
            prev = speed
        }
    }

    @Test func result_alwaysInRange() {
        var rng = SeededRNGLocal()
        for _ in 0..<10_000 {
            let v = CGFloat(Double.random(in: 0...5000, using: &rng))
            let speed = TouchDispatcher.mapVelocityToSpeed(v)
            #expect(speed >= 0.8)
            #expect(speed <= 1.25)
            #expect(!speed.isNaN)
            #expect(!speed.isInfinite)
        }
    }

    @Test func negativeVelocity_treatedLikeZero() {
        #expect(TouchDispatcher.mapVelocityToSpeed(-100) == 0.8)
    }

    /// The engine clamps (LiveSonificationAudio 0.5...2, kernel, TDPSOLA) were left wide (R17D item 4): every value
    /// the map can produce lies inside them, so nothing outside [0.8, 1.25] reaches them from the coupling.
    @Test func mapLiesInsideTheEngineClamps() {
        for v in stride(from: CGFloat(-50), through: 1000, by: 0.5) {
            let r = TouchDispatcher.mapVelocityToSpeed(v)
            #expect(r >= 0.8 && r <= 1.25, "v=\(v) -> \(r)")
        }
    }

    // REMOVED 2026-09-17 — `returnType_isFloat` asserted
    // `type(of: result) == Float.self` on a function DECLARED to return
    // `Float`. It could not fail at runtime for any input: if the return
    // type changed, this file would fail to COMPILE rather than fail the
    // assertion. The compiler already enforces it, so the test added a
    // count and no evidence — which this suite's review identified as
    // worse than no test, because it is counted as coverage.
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
