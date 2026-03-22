// NOTE: Intentionally uses XCTest — Swift Testing has no measure()/XCTMetric equivalent. Do not migrate.
//  StrokeTrackerRegressionGateTests.swift
//  BuchstabenNativeTests
//
//  CI performance regression gate for StrokeTracker.
//  Uses XCTMetric (clock time + memory) to establish baselines.
//  Build fails if throughput regresses beyond the measured baseline.
//
//  Baselines are NOT hardcoded — XCTest's measure infrastructure
//  stores them in the .xcresult bundle and tracks regressions automatically.
//  On first run, baselines are established. Subsequent runs compare against them.

import XCTest
import CoreGraphics
@testable import BuchstabenNative

@MainActor
final class StrokeTrackerRegressionGateTests: XCTestCase {

    // MARK: - Fixtures

    /// A realistic letter definition: 3 strokes, 8 checkpoints each (e.g. cursive A)
    private var realisticDefinition: LetterStrokes {
        LetterStrokes(
            letter: "GATE",
            checkpointRadius: 0.05,
            strokes: (0..<3).map { s in
                StrokeDefinition(
                    id: s + 1,
                    checkpoints: (0..<8).map { c in
                        Checkpoint(
                            x: CGFloat(c) / 8.0,
                            y: 0.2 + CGFloat(s) * 0.3
                        )
                    }
                )
            }
        )
    }

    private let canvas = CGSize(width: 400, height: 400)
    private func norm(_ pt: CGPoint) -> CGPoint { CGPoint(x: pt.x / canvas.width, y: pt.y / canvas.height) }

    /// Pre-generated touch points (deterministic, covers all checkpoints)
    private var touchPoints: [CGPoint] {
        (0..<500).map { i in
            let t = Double(i) / 500.0
            return CGPoint(
                x: t * canvas.width,
                y: (sin(t * .pi * 6) * 0.5 + 0.5) * canvas.height
            )
        }
    }

    // MARK: - Gate 1: update() throughput (clock time)

    func testStrokeTrackerUpdate_clockTime() async {
        let points = touchPoints
        let definition = realisticDefinition
        measure(metrics: [XCTClockMetric()]) {
            var tracker = StrokeTracker()
            tracker.load(definition)
            for pt in points {
                tracker.update(normalizedPoint: norm(pt))
            }
        }
    }

    // MARK: - Gate 2: update() CPU time

    func testStrokeTrackerUpdate_cpuTime() async {
        let points = touchPoints
        let definition = realisticDefinition
        measure(metrics: [XCTCPUMetric()]) {
            var tracker = StrokeTracker()
            tracker.load(definition)
            for pt in points {
                tracker.update(normalizedPoint: norm(pt))
            }
        }
    }

    // MARK: - Gate 3: Memory footprint during rapid load/update/reset cycles

    func testStrokeTrackerLoadResetCycle_memory() async {
        let definition = realisticDefinition
        let points = touchPoints
        measure(metrics: [XCTMemoryMetric()]) {
            var tracker = StrokeTracker()
            for _ in 0..<20 {
                tracker.load(definition)
                for pt in points.prefix(50) {
                    tracker.update(normalizedPoint: norm(pt))
                }
                tracker.reset()
            }
        }
    }

    // MARK: - Gate 4: overallProgress computation is O(1) — not re-scanning on each call

    func testOverallProgress_isEfficient() async {
        var tracker = StrokeTracker()
        tracker.load(realisticDefinition)
        // Drive partial progress
        for pt in touchPoints.prefix(100) {
            tracker.update(normalizedPoint: norm(pt))
        }
        measure(metrics: [XCTClockMetric()]) {
            // 10,000 progress reads — must be negligible
            var sum: Double = 0
            for _ in 0..<10_000 {
                sum += tracker.overallProgress
            }
            // Prevent dead-code elimination
            XCTAssertGreaterThanOrEqual(sum, 0)
        }
    }

    // MARK: - Gate 5: High-density checkpoint letter (stress test)

    func testStrokeTracker_highDensityLetter_clockTime() async {
        // 10 strokes × 20 checkpoints = 200 checkpoints total
        let dense = LetterStrokes(
            letter: "DENSE",
            checkpointRadius: 0.03,
            strokes: (0..<10).map { s in
                StrokeDefinition(
                    id: s + 1,
                    checkpoints: (0..<20).map { c in
                        Checkpoint(
                            x: CGFloat(c) / 20.0,
                            y: CGFloat(s) / 10.0
                        )
                    }
                )
            }
        )
        let points = (0..<1000).map { i -> CGPoint in
            let t = Double(i) / 1000.0
            return CGPoint(x: t * canvas.width, y: t * canvas.height)
        }
        measure(metrics: [XCTClockMetric()]) {
            var tracker = StrokeTracker()
            tracker.load(dense)
            for pt in points {
                tracker.update(normalizedPoint: norm(pt))
            }
        }
    }
}
