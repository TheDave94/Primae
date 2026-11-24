// FinalTestCueUITests.swift
// PrimaeUITests
//
// 2026-11-23 (David: no 👆 turn-cue pill at any final-test stage; the end
// of the test keeps the practice screen away). A visual-evidence walk, not
// an assertion of the pill: the pill is `accessibilityHidden`, so its
// absence is read off the screenshots. The decision itself is pinned by
// `PhaseCueTests.finalTestShowsNoCue`.
//
// One silent-arm session, every letter drawn along its real strokes
// (`LetterTracer`): three training letters, the bubble pause (30 s, the
// shortest the domain allows), then each test letter written from memory
// and closed with the check button, up to the session end screen. At the
// states worth looking at (writing with an empty canvas, writing with ink,
// the end screen) it attaches a screenshot and HOLDS, printing an
// `FTCUE-HOLD` marker, so a device screenshot can be taken from outside
// while the app rests there.
//
// Runs only on the physical iPad (not part of CI, like the rest of
// PrimaeUITests).

import XCTest
import UIKit
import Foundation

final class FinalTestCueUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private let subset = "AFI"
    /// How long each marked state is held for an outside screenshot.
    private let holdSeconds: TimeInterval = 20

    @MainActor
    func testFinalTestShowsNoCueThroughToTheEnd() {
        let app = launchAndEnrol(arm: "silent")
        var trained: [String] = []

        for round in 1...3 {
            var last: TracingHookSnapshot?
            guard let guided = LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
                $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked && !trained.contains($0.letter)
            }) else {
                return XCTFail("letter \(round) never reached guided after \(trained): \(last?.summary ?? "no hook")")
            }
            let letter = guided.letter
            Thread.sleep(forTimeInterval: 1.0)
            LetterTracer.traceLetter(guided, in: app)
            guard let fw = LetterTracer.waitForSnapshot(app, timeout: 8, last: &last, where: {
                $0.letter == letter && $0.phase == "freeWrite" && $0.checkpointsHit == 0
            }) else {
                return XCTFail("\(letter): guided did not advance to freeWrite: \(last?.summary ?? "no hook")")
            }
            Thread.sleep(forTimeInterval: 1.0)
            LetterTracer.traceLetter(fw, in: app)
            _ = LetterTracer.waitForCompletion(app, letter: letter, probe: nil)
            trained.append(letter)
        }

        let pause = app.descendants(matching: .any)["finalTestPause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20), "the bubble pause must follow the third training letter")
        attach("FT-00-pause")

        var tested: [String] = []
        let check = app.descendants(matching: .any)["finalTestCheck"]
        for n in 0..<3 {
            var last: TracingHookSnapshot?
            guard let snap = LetterTracer.waitForSnapshot(app, timeout: 90, last: &last, where: {
                $0.probe == "finalTest" && !$0.strokes.isEmpty && !tested.contains($0.letter)
            }) else {
                return XCTFail("test letter \(n + 1) never loaded after \(tested): \(last?.summary ?? "no hook")")
            }
            let letter = snap.letter
            // Past the glimpse (3 s plus "Merk ihn dir gut.") and into writing.
            Thread.sleep(forTimeInterval: 8.0)
            if n == 0 { hold("writing-empty-\(letter)", shot: "FT-01-writing-empty-\(letter)") }

            LetterTracer.traceLetter(snap, in: app)
            if !check.waitForExistence(timeout: 6) {
                // The glimpse ran long: the canvas took no touch. Once more.
                Thread.sleep(forTimeInterval: 3.0)
                LetterTracer.traceLetter(snap, in: app)
            }
            XCTAssertTrue(check.waitUntilHittable(timeout: 8), "\(letter): the check button must follow the first stroke")
            if n == 0 { hold("writing-inked-\(letter)", shot: "FT-02-writing-inked-\(letter)") }
            check.tap()
            tested.append(letter)
        }

        let endScreen = app.descendants(matching: .any)["sessionEndScreen"]
        XCTAssertTrue(endScreen.waitForExistence(timeout: 20), "the end screen must follow the last test letter")
        attach("FT-03-ended-early")
        Thread.sleep(forTimeInterval: 3.0)
        hold("ended", shot: "FT-04-ended-rest")
        XCTAssertEqual(tested.count, 3)
    }

    // MARK: - Helpers

    @MainActor
    private func hold(_ marker: String, shot: String) {
        attach(shot)
        print("FTCUE-HOLD \(marker) BEGIN \(Date().timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: holdSeconds)
        print("FTCUE-HOLD \(marker) END \(Date().timeIntervalSince1970)")
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func launchAndEnrol(arm: String) -> XCUIApplication {
        let app = XCUIApplication.primaeUnderTest()
        app.launchArguments += [
            LetterTracer.launchArgument,
            "-de.flamingistan.primae.audioConditionOverride", arm,
            "-de.flamingistan.primae.trainedSubsetOverride", subset,
            "-de.flamingistan.primae.comparison.pauseSeconds", "30",
        ]
        app.launch()
        let rail = app.descendants(matching: .any)["Navigationsleiste"]
        XCTAssertTrue(rail.waitForExistence(timeout: 15), "the rail must be present")
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let next = app.descendants(matching: .any)["Nächstes Kind"]
        XCTAssertTrue(next.waitUntilHittable(timeout: 8), "a rail double-tap must reveal the enrolment control")
        next.tap()
        let confirm = app.buttons["Neues Kind starten"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the destructive confirm must appear")
        confirm.tap()
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
