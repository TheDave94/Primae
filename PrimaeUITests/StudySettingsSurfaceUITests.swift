// StudySettingsSurfaceUITests.swift
// PrimaeUITests
//
// VERIFY-12 (2026-11-02): eight Einstellungen controls do nothing in the
// study build, yet were shown — Schriftart, Buchstabenreihenfolge, "Letzten
// Strich zuerst", Erinnerungstest, Lautwert, Geisterbuchstabe,
// Erscheinungsbild, "Schreiben auf Papier". A proctor could read "Lautwert
// wiedergeben: aus" as "the phoneme arm hears letter names". They are now
// compiled out of the study build. This walks the whole Einstellungen
// screen on the device and asserts none of them is there, and that the
// screen WAS walked (the comparison-mode reset row at its end is found).

import XCTest
import Foundation

final class StudySettingsSurfaceUITests: XCTestCase {

    /// Labels of the eight inert controls (a row title or, for the two
    /// list-style sections, the section's own rows).
    private static let inertLabels = [
        "Druckschrift",                 // Schriftart rows
        "Buchstabenreihenfolge",
        "Letzten Strich zuerst",
        "Erinnerungstest aktivieren",
        "Lautwert wiedergeben",
        "Geisterbuchstabe anzeigen",
        "Erscheinungsbild",
        "Schreiben auf Papier",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testInertControlsAreNotShownInStudySettings() {
        let app = XCUIApplication.primaeUnderTest()
        app.launch()

        let gear = element(labelPrefix: "Eltern-Bereich", in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 15), "the parent-area gear must be reachable")
        gear.press(forDuration: 2.3)
        let settings = element(label: "Einstellungen", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "the Einstellungen entry must exist in the parent sidebar")
        settings.tap()
        Thread.sleep(forTimeInterval: 1.0)

        let endOfScreen = element(label: "Vergleichsmodus zurücksetzen", in: app)
        var seen: Set<String> = []
        for _ in 0..<12 {
            for label in Self.inertLabels where element(label: label, in: app).exists {
                seen.insert(label)
            }
            if endOfScreen.exists { break }
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        for label in Self.inertLabels where element(label: label, in: app).exists {
            seen.insert(label)
        }
        XCTAssertTrue(endOfScreen.exists,
                      "the walk never reached the end of Einstellungen, so the absence checks prove nothing")
        XCTAssertTrue(seen.isEmpty,
                      "controls that do nothing in the study build are still shown: \(seen.sorted())")
    }

    /// VERIFY-2/3, UI half (A24): once the live child has a phase row, the
    /// Studienarm, audio-arm and trained-subset overrides can no longer take effect for
    /// that child (the launch refuses them), so the pickers are disabled
    /// and say why. Reached by tracing one letter through guided and
    /// freeWrite; its completion writes the child's rows.
    @MainActor
    func testAssignmentPickersLockAfterTheFirstLetter() {
        let app = XCUIApplication.primaeUnderTest()
        app.launchArguments += [LetterTracer.launchArgument]
        app.launch()

        XCTAssertTrue(app.enrolNextChildViaRail(), "a child must be enrolled through the rail")

        var last: TracingHookSnapshot?
        if let s = LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { _ in true }), s.parked {
            let observe = app.descendants(matching: .any)["Beobachtungsphase"]
            if observe.waitForExistence(timeout: 5) { observe.tap() }
        }
        guard let guided = LetterTracer.waitForSnapshot(app, timeout: 45, last: &last, where: {
            $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked
        }) else {
            return XCTFail("never reached guided: \(last?.summary ?? "no hook")")
        }
        Thread.sleep(forTimeInterval: 1.0)
        LetterTracer.traceLetter(guided, in: app)
        // The child's rows are written when the LETTER completes (all its
        // phases at once), not per phase, so trace freeWrite too.
        guard let freeWrite = LetterTracer.waitForSnapshot(app, timeout: 6, last: &last, where: {
            $0.letter == guided.letter && $0.phase == "freeWrite" && $0.checkpointsHit == 0
        }) else {
            return XCTFail("the traced letter must complete guided: \(last?.summary ?? "no hook")")
        }
        Thread.sleep(forTimeInterval: 1.0)
        LetterTracer.traceLetter(freeWrite, in: app)
        XCTAssertNotNil(LetterTracer.waitForCompletion(app, letter: guided.letter, probe: nil),
                        "the letter must complete, which writes the child's rows")

        let gear = element(labelPrefix: "Eltern-Bereich", in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the parent-area gear must be reachable")
        gear.press(forDuration: 2.3)
        let settings = element(label: "Einstellungen", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 8), "the Einstellungen entry must exist in the parent sidebar")
        settings.tap()
        Thread.sleep(forTimeInterval: 1.0)

        let condition = app.descendants(matching: .any)["thesis-condition-override-picker"]
        let arm = app.descendants(matching: .any)["audio-arm-override-picker"]
        let subset = app.descendants(matching: .any)["trained-subset-override-picker"]
        for _ in 0..<10 where !(condition.exists && arm.exists && subset.exists) {
            app.swipeUp()
            Thread.sleep(forTimeInterval: 0.4)
        }
        XCTAssertTrue(condition.exists && arm.exists && subset.exists,
                      "all three override pickers must be on Einstellungen for an enrolled child")
        XCTAssertFalse(condition.isEnabled, "the Studienarm override is still offered after the child's first letter")
        XCTAssertFalse(arm.isEnabled, "the audio-arm override is still offered after the child's first letter")
        XCTAssertFalse(subset.isEnabled, "the trained-subset override is still offered after the child's first letter")
        XCTAssertTrue(app.descendants(matching: .any)["assignment-override-locked-note"].exists,
                      "the locked pickers must say why (nur vor dem ersten Buchstaben)")
    }

    private func element(label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func element(labelPrefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
    }
}
