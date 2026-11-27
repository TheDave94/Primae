// SceneResizeUITests.swift
// PrimaeUITests
//
// Regression guards for the landscape lock. Since protocol r30 (David's
// ruling 2026-11-26, "Real fix + turn prompt"; docs/DECISIONS.md "Landscape
// without UIRequiresFullScreen") the study build declares every iPad
// orientation and no longer sets the deprecated UIRequiresFullScreen; the
// session keeps landscape at runtime: a landscape scene locks its orientation,
// and a portrait scene (a launch while the iPad is held in portrait) shows
// the turn prompt and holds the session until the iPad is turned.
//
// Physical iPad only (not in CI), like the rest of PrimaeUITests. The
// rotation is XCUIDevice's simulated device orientation.

import XCTest
import UIKit

final class SceneResizeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .landscapeLeft
        super.tearDown()
    }

    /// (a) Turned to portrait mid-session, the session stays landscape and
    /// the canvas does not move.
    @MainActor
    func testTurnToPortraitKeepsSessionLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchEnrolled(arm: "silent")
        var last: TracingHookSnapshot?
        guard let before = LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
            !$0.strokes.isEmpty && !$0.blocked
        }) else { return XCTFail("no letter: \(last?.summary ?? "no hook")") }
        XCTAssertGreaterThan(before.canvasFrame.width, before.canvasFrame.height,
                             "the session must start landscape: \(before.canvasFrame)")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 4.0)
        attach("L1-turned-to-portrait-stays-landscape")
        guard let after = LetterTracer.snapshot(app) else { return XCTFail("no hook after turning") }
        XCTAssertEqual(after.canvasFrame, before.canvasFrame,
                       "turning the iPad must not move the canvas: \(before.canvasFrame) -> \(after.canvasFrame)")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "the window must stay landscape: \(window)")
    }

    /// (b) Launched while the iPad is held in portrait: the turn prompt
    /// covers the screen and the session is held; turning the iPad to
    /// landscape removes it, the session runs landscape, the letter can be
    /// traced along its real strokes, and turning back to portrait leaves
    /// it landscape (the lock engaged once the scene was landscape).
    @MainActor
    func testPortraitLaunchShowsTurnPromptThenTracesLandscape() {
        portraitLaunchTurnPromptThenTrace(arm: "silent")
    }

    /// (b) in the two sound arms: the prompt and the hold are arm-independent.
    @MainActor
    func testPortraitLaunchTurnPromptPhonemeArm() {
        portraitLaunchTurnPromptThenTrace(arm: "phoneme")
    }

    @MainActor
    func testPortraitLaunchTurnPromptSpatialArm() {
        portraitLaunchTurnPromptThenTrace(arm: "spatial")
    }

    @MainActor
    private func portraitLaunchTurnPromptThenTrace(arm: String) {
        // The proctor enrols the child in landscape (the prompt covers the
        // rail in portrait); the relaunch is what is held in portrait.
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launchEnrolled(arm: arm)
        var last: TracingHookSnapshot?
        guard LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
            !$0.strokes.isEmpty && !$0.blocked
        }) != nil else { return XCTFail("[\(arm)] no letter after enrolment: \(last?.summary ?? "no hook")") }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        guard LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
            $0.orientationHold == "turnToLandscape"
        }) != nil else { return XCTFail("no turn prompt on a portrait launch: \(last?.summary ?? "no hook")") }
        let prompt = app.descendants(matching: .any)["turnDevicePrompt"]
        XCTAssertTrue(prompt.waitForExistence(timeout: 5), "the turn prompt is not on screen")
        attach("P1-\(arm)-portrait-launch-turn-prompt")
        let portraitWindow = app.windows.firstMatch.frame
        XCTAssertGreaterThan(portraitWindow.height, portraitWindow.width,
                             "the scene should be portrait under the prompt: \(portraitWindow)")

        XCUIDevice.shared.orientation = .landscapeLeft
        guard let landscape = LetterTracer.waitForSnapshot(app, timeout: 30, last: &last, where: {
            $0.orientationHold == "none" && !$0.strokes.isEmpty && !$0.blocked
                && $0.canvasFrame.width > $0.canvasFrame.height
        }) else { return XCTFail("turning to landscape did not lift the prompt: \(last?.summary ?? "no hook")") }
        XCTAssertFalse(prompt.exists, "the turn prompt stayed after turning to landscape")
        attach("P2-\(arm)-turned-landscape-prompt-gone")
        // A relaunch parks the session until the proctor starts observe.
        if let s = LetterTracer.snapshot(app), s.parked {
            let observe = app.descendants(matching: .any)["Beobachtungsphase"]
            if observe.waitForExistence(timeout: 5) { observe.tap() }
        }

        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 4.0)
        attach("P3-\(arm)-turned-back-portrait-stays-landscape")
        guard let locked = LetterTracer.snapshot(app) else { return XCTFail("no hook after turning back") }
        XCTAssertEqual(locked.orientationHold, "none", "turning back to portrait brought the prompt back")
        XCTAssertEqual(locked.canvasFrame, landscape.canvasFrame,
                       "turning back to portrait moved the canvas: the lock did not engage")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "the window must stay landscape: \(window)")

        // Trace the letter, in the orientation the lock holds.
        guard let guided = LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
            $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked && $0.orientationHold == "none"
        }) else { return XCTFail("never reached guided after the turn: \(last?.summary ?? "no hook")") }
        Thread.sleep(forTimeInterval: 1.0)
        guard let ready = LetterTracer.snapshot(app) else { return XCTFail("hook vanished") }
        LetterTracer.traceLetter(ready, in: app)
        XCTAssertNotNil(LetterTracer.waitForSnapshot(app, timeout: 8, last: &last, where: {
            $0.letter == guided.letter && $0.phase == "freeWrite"
        }), "the traced letter did not complete guided: \(last?.summary ?? "no hook")")
        attach("P4-\(arm)-traced-guided")
    }

    // MARK: - Helpers

    @MainActor
    private func launchEnrolled(arm: String) -> XCUIApplication {
        let app = XCUIApplication.primaeUnderTest()
        app.launchArguments += [LetterTracer.launchArgument,
                                "-de.flamingistan.primae.audioConditionOverride", arm,
                                "-de.flamingistan.primae.trainedSubsetOverride", "AFI"]
            + StudySessionFlow.shortTimingArguments
        app.launch()
        XCTAssertTrue(app.enrolNextChildViaRail(), "the child must be enrolled through the rail")
        var last: TracingHookSnapshot?
        if let s = LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { _ in true }), s.parked {
            let observe = app.descendants(matching: .any)["Beobachtungsphase"]
            if observe.waitForExistence(timeout: 5) { observe.tap() }
        }
        return app
    }

    @discardableResult
    private func attach(_ name: String) -> XCUIScreenshot {
        let shot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: shot)
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        return shot
    }
}
