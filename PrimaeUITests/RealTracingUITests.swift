// RealTracingUITests.swift
// PrimaeUITests
//
// A child's TRAINING session, end to end, with the letter actually drawn
// (2026-10-21, lane H). Every earlier UI test reached a freeWrite only
// through a cold probe and "drew" a straight swipe, which any shape
// completes; nothing exercised the guided phase's checkpoint gate, and no
// assertion could tell a drawn letter from a swipe.
//
// Each session test enrols a child in its own launch (the rail gesture —
// the path a proctor uses), pins the arm and the all-five trained set with
// volatile launch-argument defaults (the argument domain; nothing is
// written to the app's stored preferences), and for every study letter:
// waits out the observe demonstration, TRACES the letter in guided
// (`LetterTracer`), asserts guided completed by its own gate and advanced
// naturally to freeWrite, traces it again in freeWrite and asserts every
// checkpoint was passed and the scored production is in the passing range.
//
// The negative control proves the guided assertion can fail: the old
// straight swipe, on the same letter, must leave guided incomplete.

import XCTest
import Foundation

final class RealTracingUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testPhonemeArmTracesAllFiveStudyLetters() {
        runTrainingSession(arm: "phoneme")
    }

    @MainActor
    func testSpatialArmTracesAllFiveStudyLetters() {
        runTrainingSession(arm: "spatial")
    }

    /// NEGATIVE CONTROL. The straight two-point drag every UI test used to
    /// draw (StudyDryRunUITests' old `drawFreeWriteStroke`) must NOT
    /// complete the guided phase. Then the real trace, on the same letter,
    /// must — so the control cannot pass by the guided gate being dead.
    @MainActor
    func testStraightSwipeDoesNotCompleteGuided() {
        let app = launchAndEnrol(arm: "phoneme")
        var last: TracingHookSnapshot?
        guard let guided = LetterTracer.waitForSnapshot(app, timeout: 45, last: &last, where: {
            $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked
        }) else {
            return XCTFail("never reached guided: \(last?.summary ?? "no hook")")
        }
        Thread.sleep(forTimeInterval: 1.0)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.55))
        start.press(forDuration: 0.15, thenDragTo: end)
        Thread.sleep(forTimeInterval: 3.0)

        guard let afterSwipe = LetterTracer.snapshot(app) else { return XCTFail("hook vanished") }
        XCTContext.runActivity(named: "negative control: \(afterSwipe.summary)") { _ in }
        XCTAssertEqual(afterSwipe.letter, guided.letter)
        XCTAssertEqual(afterSwipe.phase, "guided",
                       "a straight swipe must not complete the guided phase: \(afterSwipe.summary)")
        XCTAssertFalse(afterSwipe.trackerComplete,
                       "a straight swipe must not complete the letter's strokes: \(afterSwipe.summary)")

        // Positive half: the same letter, traced, does complete.
        LetterTracer.traceLetter(afterSwipe, in: app)
        var after: TracingHookSnapshot?
        XCTAssertNotNil(LetterTracer.waitForSnapshot(app, timeout: 6, last: &after, where: {
            $0.letter == guided.letter && $0.phase == "freeWrite"
        }), "the traced letter must complete guided where the swipe did not: \(after?.summary ?? "no hook")")
    }

    // MARK: - Session

    @MainActor
    private func runTrainingSession(arm: String) {
        let app = launchAndEnrol(arm: arm)
        var traced: [String] = []
        var checkedCanvas = false

        for _ in 0..<5 {
            var last: TracingHookSnapshot?
            // Observe runs by itself (the demonstration, then the guide
            // animation) and hands over to guided.
            guard let guided = LetterTracer.waitForSnapshot(app, timeout: 45, last: &last, where: {
                $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked && !traced.contains($0.letter)
            }) else {
                return XCTFail("[\(arm)] no further letter reached guided after \(traced): \(last?.summary ?? "no hook")")
            }
            let letter = guided.letter
            if !checkedCanvas {
                LetterTracer.assertHookMatchesCanvas(guided, in: app)
                checkedCanvas = true
            }
            // Let the phase-entry prompt start before the finger lands.
            Thread.sleep(forTimeInterval: 1.0)

            XCTContext.runActivity(named: "[\(arm)] \(letter) — guided trace") { _ in
                LetterTracer.traceLetter(guided, in: app)
                // Guided ends ONLY on its own checkpoint gate
                // (`TouchDispatcher.handleStrokeCompletionIfReached`):
                // reaching freeWrite on the same letter is the natural
                // advance, and the guided score is the checkpoint progress.
                guard let freeWrite = LetterTracer.waitForSnapshot(app, timeout: 6, last: &last, where: {
                    $0.letter == letter && $0.phase == "freeWrite"
                }) else {
                    return XCTFail("[\(arm)] \(letter): guided did not advance to freeWrite: \(last?.summary ?? "no hook")")
                }
                XCTAssertEqual(freeWrite.scores["guided"] ?? -1, 1.0, accuracy: 0.001,
                               "[\(arm)] \(letter): guided must have every checkpoint hit: \(freeWrite.summary)")
            }

            XCTContext.runActivity(named: "[\(arm)] \(letter) — freeWrite trace") { _ in
                var ready: TracingHookSnapshot?
                guard let fw = LetterTracer.waitForSnapshot(app, timeout: 5, last: &ready, where: {
                    $0.letter == letter && $0.phase == "freeWrite" && $0.checkpointsHit == 0
                }) else {
                    return XCTFail("[\(arm)] \(letter): freeWrite tracker never reset: \(ready?.summary ?? "no hook")")
                }
                Thread.sleep(forTimeInterval: 1.0)
                LetterTracer.traceLetter(fw, in: app)
                if let after = LetterTracer.snapshot(app), after.letter == letter, after.phase == "freeWrite" {
                    XCTAssertEqual(after.checkpointsHit, after.checkpointsTotal,
                                   "[\(arm)] \(letter): the freeWrite trace must pass every checkpoint: \(after.summary)")
                }
                if let entry = LetterTracer.waitForCompletion(app, letter: letter, probe: nil) {
                    XCTContext.runActivity(named: "[\(arm)] \(letter) RECOGNISED scores=\(entry.scores) "
                                           + "form=\(entry.form ?? -1) rec=\(entry.rec ?? "nil") conf=\(entry.conf ?? -1)") { _ in }
                }
            }
            traced.append(letter)
        }

        XCTAssertEqual(Set(traced), ["A", "F", "I", "L", "M"],
                       "[\(arm)] every study letter must be traced and recognised once: \(traced)")
    }

    /// Launch with the hook armed, the arm and the all-five trained set
    /// pinned for this launch only, and enrol a child through the rail.
    @MainActor
    private func launchAndEnrol(arm: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            LetterTracer.launchArgument,
            "-de.flamingistan.primae.audioConditionOverride", arm,
            "-de.flamingistan.primae.trainedSubsetOverride", "AFILM",
        ]
        app.launch()

        let rail = app.descendants(matching: .any)["Navigationsleiste"]
        XCTAssertTrue(rail.waitForExistence(timeout: 15), "the rail must be present")
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let next = app.descendants(matching: .any)["Nächstes Kind"]
        XCTAssertTrue(next.waitForExistence(timeout: 8), "a rail double-tap must reveal the enrolment control")
        next.tap()
        let confirm = app.buttons["Neues Kind starten"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the destructive confirm must appear")
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["newChildReadyToast"].waitForExistence(timeout: 5),
                      "the ready toast must appear once the child is enrolled")

        // A parked launch letter starts on the proctor's tap on the
        // observe area; an unparked one is already running.
        var last: TracingHookSnapshot?
        if let s = LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { _ in true }), s.parked {
            let observe = app.descendants(matching: .any)["Beobachtungsphase"]
            if observe.waitForExistence(timeout: 5) { observe.tap() }
        }
        return app
    }
}
