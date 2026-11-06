// SessionEndScreenUITests.swift
// PrimaeUITests
//
// 2026-11-04 (David's rulings: the A's left stroke goes UP, and a separate
// visual end screen follows the third letter).
//
//  - testEndScreenAppearsOnlyAfterThirdLetter: a child's three-letter
//    training session, every letter drawn along its real strokes
//    (`LetterTracer`). The end screen (`sessionEndScreen`) must be absent
//    after letters 1 and 2, present after letter 3, and gone once the
//    proctor enrols the next child with the rail double-tap. Screenshots of
//    the start, the middle and the resting state are attached.
//  - testCaptureLetterAObserveAndGuided: reaches the A through the chevrons
//    and attaches a burst of observe-animation frames and the guided start
//    dot, for the visual review of the new stroke direction.
//
// Both run only on the physical iPad with the passcode entered (they are
// not part of CI, like the rest of PrimaeUITests).

import XCTest
import UIKit
import Foundation

final class SessionEndScreenUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // The trained set "AFI" is walked in the fixed study order I, F, A.
    private let subset = "AFI"

    @MainActor
    func testEndScreenAppearsOnlyAfterThirdLetter() {
        let app = launchAndEnrol(arm: "silent")
        let endScreen = app.descendants(matching: .any)["sessionEndScreen"]
        var traced: [String] = []

        for round in 1...3 {
            var last: TracingHookSnapshot?
            guard let guided = LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
                $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked && !traced.contains($0.letter)
            }) else {
                return XCTFail("letter \(round) never reached guided after \(traced): \(last?.summary ?? "no hook")")
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
            traced.append(letter)
            if round < 3 {
                XCTAssertFalse(endScreen.exists, "the end screen must not appear after letter \(round) of 3 (\(letter))")
            }
        }

        XCTAssertEqual(traced.count, 3)
        XCTAssertTrue(endScreen.waitForExistence(timeout: 15), "the end screen must appear after the third letter")
        // A filmstrip: back-to-back screenshots (~0.2 s apart) cover the whole
        // main animation; the last one is the resting state.
        XCTContext.runActivity(named: "Reduce Motion enabled on this device: \(UIAccessibility.isReduceMotionEnabled)") { _ in }
        let t0 = Date()
        for i in 0..<26 {
            attach(String(format: "END-%02d-t%04dms", i, Int(Date().timeIntervalSince(t0) * 1000)))
        }
        Thread.sleep(forTimeInterval: 3.0)
        attach("END-rest")
        XCTAssertTrue(endScreen.exists, "the end screen rests until the proctor moves on")

        // The proctor's way on is unchanged: rail double-tap, next child.
        let rail = app.descendants(matching: .any)["Navigationsleiste"]
        rail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let next = app.descendants(matching: .any)["Nächstes Kind"]
        XCTAssertTrue(next.waitUntilHittable(timeout: 8), "the rail must be reachable from the end screen")
        next.tap()
        let confirm = app.buttons["Neues Kind starten"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["newChildReadyToast"].waitForExistence(timeout: 5),
                      "the ready toast must show above/after the end screen")
        XCTAssertFalse(endScreen.waitForExistence(timeout: 2), "the next child starts without the end screen")
    }

    @MainActor
    func testCaptureLetterAObserveAndGuided() {
        let app = launchAndEnrol(arm: "silent")
        // I -> F -> A through the study chevron.
        let nextButton = app.descendants(matching: .any)["Nächster Buchstabe"]
        var last: TracingHookSnapshot?
        for _ in 0..<3 {
            if LetterTracer.snapshot(app)?.letter == "A" { break }
            XCTAssertTrue(nextButton.waitUntilHittable(timeout: 10), "the chevron must be hittable")
            nextButton.tap()
            Thread.sleep(forTimeInterval: 1.0)
        }
        guard LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { $0.letter == "A" }) != nil else {
            return XCTFail("never reached A: \(last?.summary ?? "no hook")")
        }
        // Burst of observe frames; each screenshot costs a few hundred ms.
        let t0 = Date()
        for i in 0..<14 {
            attach(String(format: "A-observe-%02d-t%04dms", i, Int(Date().timeIntervalSince(t0) * 1000)))
        }
        guard let guided = LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
            $0.letter == "A" && $0.phase == "guided" && !$0.strokes.isEmpty
        }) else {
            return XCTFail("A never reached guided: \(last?.summary ?? "no hook")")
        }
        Thread.sleep(forTimeInterval: 1.5)
        attach("A-guided-start-dot")
        if let first = guided.strokes.first, first.count > 2 {
            XCTContext.runActivity(named: "A stroke 0 first y=\(first[0][1]) last y=\(first[first.count - 1][1]) (window points)") { _ in }
            XCTAssertGreaterThan(first[0][1], first[first.count - 1][1],
                                 "stroke 0 of A must start at the bottom (larger y) and end at the apex")
        }
    }

    // MARK: - Helpers

    @MainActor
    private func attach(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
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
