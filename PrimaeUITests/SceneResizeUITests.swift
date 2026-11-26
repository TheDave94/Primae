// SceneResizeUITests.swift
// PrimaeUITests
//
// Regression guards for the landscape lock. The study build declares iPad
// orientations landscape-only and sets UIRequiresFullScreen = YES (David's
// ruling A, 2026-11-25; docs/DECISIONS.md "Rotation and
// UIRequiresFullScreen"). MEASURED on iPadOS 27.3 with that build: turning
// the iPad to portrait leaves the session landscape, and a launch while the
// iPad is held in portrait comes up landscape. Apple has deprecated the key
// (TN3192: "from iOS 27 no longer opts out of resizing"), so these two
// tests are the tripwire for an iPadOS that stops honouring it: either one
// going red means a child's rotation can now turn the session.
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

    /// (b) Launched while the iPad is held in portrait, the session comes
    /// up landscape.
    @MainActor
    func testPortraitHeldLaunchComesUpLandscape() {
        XCUIDevice.shared.orientation = .portrait
        let app = launchEnrolled(arm: "silent")
        var last: TracingHookSnapshot?
        guard let s = LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
            !$0.strokes.isEmpty && !$0.blocked
        }) else { return XCTFail("no letter: \(last?.summary ?? "no hook")") }
        attach("P1-portrait-held-launch-is-landscape")
        XCTAssertGreaterThan(s.canvasFrame.width, s.canvasFrame.height,
                             "a portrait-held launch must come up landscape: \(s.canvasFrame)")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, window.height, "the window must be landscape: \(window)")
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
