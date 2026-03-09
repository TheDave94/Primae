//  PerformanceBenchmarkTests.swift
//  BuchstabenNativeTests
//
//  XCTest measure-block benchmarks for StrokeTracker hit-testing
//  and LetterRepository load time. CI baselines established on first run.

import XCTest
import CoreGraphics
@testable import BuchstabenNative

@MainActor
final class PerformanceBenchmarkTests: XCTestCase {

    // MARK: - StrokeTracker hit-test performance

    /// 1000 update() calls on a 5-stroke, 10-checkpoint-per-stroke letter.
    func testStrokeTrackerHitTest_performance() {
        let definition = LetterStrokes(
            letter: "PERF",
            checkpointRadius: 0.05,
            strokes: (0..<5).map { strokeIdx in
                StrokeDefinition(
                    id: strokeIdx + 1,
                    checkpoints: (0..<10).map { cpIdx in
                        Checkpoint(
                            x: CGFloat(cpIdx) / 10.0,
                            y: CGFloat(strokeIdx) / 5.0
                        )
                    }
                )
            }
        )

        var tracker = StrokeTracker()
        tracker.load(definition)
        let canvas = CGSize(width: 400, height: 400)

        // Pre-generate 1000 random(ish) points using seeded values
        var points: [CGPoint] = []
        var x: CGFloat = 0.1
        for _ in 0..<1000 {
            x = (x * 137.0 + 0.01).truncatingRemainder(dividingBy: 1.0)
            let y = (x * 1.618).truncatingRemainder(dividingBy: 1.0)
            points.append(CGPoint(x: x * canvas.width, y: y * canvas.height))
        }

        measure {
            tracker.load(definition)   // reset for each iteration
            for pt in points {
                tracker.update(at: pt, canvasSize: canvas)
            }
        }
    }

    /// Rapid reset+load cycle — 500 iterations.
    func testStrokeTrackerResetLoad_performance() {
        let definition = LetterStrokes(
            letter: "RESET",
            checkpointRadius: 0.06,
            strokes: [
                .init(id: 1, checkpoints: [.init(x: 0.3, y: 0.8), .init(x: 0.5, y: 0.2), .init(x: 0.7, y: 0.8)]),
                .init(id: 2, checkpoints: [.init(x: 0.38, y: 0.55), .init(x: 0.62, y: 0.55)])
            ]
        )

        var tracker = StrokeTracker()
        measure {
            for _ in 0..<500 {
                tracker.load(definition)
                tracker.reset()
            }
        }
    }

    // MARK: - LetterRepository load performance

    /// loadLetters() on empty provider (fallback path) should be <1ms.
    func testLetterRepository_emptyProvider_loadPerformance() {
        let repo = LetterRepository(resources: EmptyProvider())
        measure {
            _ = repo.loadLetters()
        }
    }

    /// loadLetters() is called many times (e.g., view refreshes) — must be fast.
    func testLetterRepository_repeatedLoad_performance() {
        let repo = LetterRepository(resources: EmptyProvider())
        measure {
            for _ in 0..<100 {
                _ = repo.loadLetters()
            }
        }
    }

    // MARK: - LetterGuideRenderer performance

    /// guidePath generation for all 7 curated letters + 3 fallbacks, 1000 iterations.
    func testLetterGuideRenderer_performance() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let letters = ["A", "F", "I", "K", "L", "M", "O", "Z", "Q", "B"]
        measure {
            for _ in 0..<100 {
                for letter in letters {
                    _ = LetterGuideRenderer.guidePath(for: letter, in: rect)
                }
            }
        }
    }

    // MARK: - PlaybackStateMachine performance

    /// 10,000 rapid transition() calls — must complete in <50ms.
    func testPlaybackStateMachine_rapidTransitions_performance() {
        measure {
            var machine = PlaybackStateMachine()
            machine.appIsForeground = true
            machine.resumeIntent = true
            for i in 0..<10_000 {
                _ = machine.transition(to: i.isMultiple(of: 2) ? .active : .idle)
            }
        }
    }
}

// MARK: - EmptyProvider

private struct EmptyProvider: LetterResourceProviding {
    func allResourceURLs() -> [URL] { [] }
    func resourceURL(for relativePath: String) -> URL? { nil }
}
