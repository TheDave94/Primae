// RestingContactUITests.swift
// PrimaeUITests
//
// A child traces with one hand and steadies the iPad with the other, or
// rests the heel of the tracing hand on the glass (UI-1, round-2 bug hunt,
// 2026-11-02). Measured on the iPad before the fix: a thumb resting on the
// rail, or a palm resting on the canvas BEFORE the finger landed, made the
// canvas ignore a perfect trace (`hit=0/40`, still in guided), with no cue
// to the child. Two causes:
//
// - A20: the canvas counted every touch in the WINDOW, so a thumb on the
//   rail made the tracing finger the second touch, and only a lone touch
//   was ever tracked. Fixed by counting this view's touches.
// - B10 (ruled by David): a palm that lands first on the canvas is the lone
//   touch, so it is tracked and the finger is not. Fixed by handing the
//   tracking over when the tracked touch rests and a new touch moves
//   (`CanvasTouchArbiter`).
//
// Every trace goes through the app's own geometry hook (`LetterTracer`) and
// the same event synthesis, with the resting contact added as a second
// finger in the same synthesized record.

import XCTest
import Foundation

final class RestingContactUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A20: a thumb resting on the rail (outside the canvas) through the
    /// whole trace must not stop guided from completing.
    @MainActor
    func testThumbOnRailDoesNotBlockGuidedTrace() {
        let app = launchAndEnrol()
        guard let guided = waitForGuided(app) else { return }
        let rail = app.descendants(matching: .any)["Navigationsleiste"].frame
        XCTAssertFalse(rail.isEmpty, "the rail must be on screen to rest a thumb on")
        let thumb = CGPoint(x: rail.midX, y: rail.maxY - 120)
        // One record per stroke, the thumb down before the finger and up after it.
        let toScreen = LetterTracer.screenTransform(app)
        for (index, stroke) in guided.strokes.enumerated() {
            let trace = Self.trace(stroke, startingAt: 0.3)
            let held = Self.hold(thumb, from: 0, to: (trace.last?.offset ?? 1) + 0.2)
            LetterTracer.synthesize(paths: [held, trace].map { Self.toScreen($0, toScreen) },
                                    name: "thumb on rail + stroke \(index + 1)")
            Thread.sleep(forTimeInterval: 0.4)
        }
        assertGuidedCompleted(app, letter: guided.letter, case: "thumb on the rail")
    }

    /// B10: the heel of the hand rests on the canvas (bottom right, away
    /// from the letter) BEFORE the finger lands, and stays down for the
    /// whole letter, every stroke included.
    @MainActor
    func testPalmRestingOnCanvasFirstDoesNotBlockGuidedTrace() {
        let app = launchAndEnrol()
        guard let guided = waitForGuided(app) else { return }
        let canvas = guided.canvasFrame
        let palm = CGPoint(x: canvas.maxX - 60, y: canvas.maxY - 60)
        var paths: [[(point: CGPoint, offset: TimeInterval)]] = []
        var t: TimeInterval = 0.3
        for stroke in guided.strokes {
            let trace = Self.trace(stroke, startingAt: t)
            paths.append(trace)
            t = (trace.last?.offset ?? t) + 0.4
        }
        paths.insert(Self.hold(palm, from: 0, to: t), at: 0)
        LetterTracer.synthesize(paths: paths.map { Self.toScreen($0, LetterTracer.screenTransform(app)) },
                                name: "palm first + whole letter")
        assertGuidedCompleted(app, letter: guided.letter, case: "a palm resting on the canvas first")
    }

    /// Control for the hand-over rule: the finger lands FIRST and is moving
    /// when the palm comes down mid-stroke. The palm must not take the
    /// stroke over (a moving pen is never handed over). Passed before the
    /// fix too (round 2, E2c); kept so the hand-over cannot regress it.
    @MainActor
    func testPalmLandingMidStrokeDoesNotTakeTheStroke() {
        let app = launchAndEnrol()
        guard let guided = waitForGuided(app) else { return }
        let canvas = guided.canvasFrame
        let palm = CGPoint(x: canvas.maxX - 60, y: canvas.maxY - 60)
        let toScreen = LetterTracer.screenTransform(app)
        for (index, stroke) in guided.strokes.enumerated() {
            let trace = Self.trace(stroke, startingAt: 0)
            let end = trace.last?.offset ?? 1
            let held = Self.hold(palm, from: min(0.4, end / 3), to: end + 0.2)
            LetterTracer.synthesize(paths: [trace, held].map { Self.toScreen($0, toScreen) },
                                    name: "stroke + palm mid-stroke \(index + 1)")
            Thread.sleep(forTimeInterval: 0.4)
        }
        assertGuidedCompleted(app, letter: guided.letter, case: "a palm landing mid-stroke")
    }

    // MARK: - Helpers

    @MainActor
    private func assertGuidedCompleted(_ app: XCUIApplication, letter: String, case label: String) {
        var last: TracingHookSnapshot?
        let done = LetterTracer.waitForSnapshot(app, timeout: 6, last: &last, where: {
            $0.letter == letter && $0.phase == "freeWrite"
        })
        XCTAssertNotNil(done, "with \(label) the child's correct trace did not complete guided: \(last?.summary ?? "no hook")")
        if let done {
            XCTAssertEqual(done.scores["guided"] ?? -1, 1.0, accuracy: 0.001,
                           "with \(label) guided must have every checkpoint hit: \(done.summary)")
        }
    }

    @MainActor
    private func waitForGuided(_ app: XCUIApplication) -> TracingHookSnapshot? {
        var last: TracingHookSnapshot?
        guard let guided = LetterTracer.waitForSnapshot(app, timeout: 45, last: &last, where: {
            $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked && $0.checkpointsHit == 0
        }) else {
            XCTFail("never reached guided: \(last?.summary ?? "no hook")")
            return nil
        }
        // Let the phase-entry prompt start before the finger lands.
        Thread.sleep(forTimeInterval: 1.0)
        return guided
    }

    /// One stroke at child speed, in window points, offset to `t0`.
    private static func trace(_ stroke: [[Double]], startingAt t0: TimeInterval)
        -> [(point: CGPoint, offset: TimeInterval)] {
        let points = stroke.map { CGPoint(x: $0[0], y: $0[1]) }
        guard points.count >= 2 else { return [] }
        return LetterTracer.densified(points).map { ($0.point, $0.offset + t0) }
    }

    /// A resting contact at `p` from `t0` to `t1`, with a 0.3 pt tremor.
    private static func hold(_ p: CGPoint, from t0: TimeInterval, to t1: TimeInterval)
        -> [(point: CGPoint, offset: TimeInterval)] {
        var out: [(point: CGPoint, offset: TimeInterval)] = [(p, t0)]
        var t = t0
        while t < t1 {
            t += 0.1
            out.append((CGPoint(x: p.x + 0.3, y: p.y), t))
        }
        return out
    }

    private static func toScreen(_ samples: [(point: CGPoint, offset: TimeInterval)],
                                 _ transform: CGAffineTransform) -> [(point: CGPoint, offset: TimeInterval)] {
        samples.map { ($0.point.applying(transform), $0.offset) }
    }

    /// Launch with the hook armed and the phoneme arm and all-five set
    /// pinned for this launch only, and enrol a child through the rail.
    @MainActor
    private func launchAndEnrol() -> XCUIApplication {
        let app = XCUIApplication.primaeUnderTest()
        app.launchArguments += [
            LetterTracer.launchArgument,
            "-de.flamingistan.primae.audioConditionOverride", "phoneme",
            "-de.flamingistan.primae.trainedSubsetOverride", "AFILM",
        ]
        app.launch()

        XCTAssertTrue(app.enrolNextChildViaRail(), "a child must be enrolled through the rail")
        XCTAssertTrue(app.descendants(matching: .any)["newChildReadyToast"].waitForExistence(timeout: 5),
                      "the ready toast must appear once the child is enrolled")

        var last: TracingHookSnapshot?
        if let s = LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { _ in true }), s.parked {
            let observe = app.descendants(matching: .any)["Beobachtungsphase"]
            if observe.waitForExistence(timeout: 5) { observe.tap() }
        }
        return app
    }
}
