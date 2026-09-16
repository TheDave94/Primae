// StudyAdvanceProbeUITests.swift
// PrimaeUITests
//
// Targeted checks for the three device reports of 2026-09-16, driven in a
// SIMULATOR because no device is reachable from this seat. Same discipline
// as StudyDryRunUITests: a separate .xctest bundle that drives the real
// app through the accessibility tree, importing only XCTest and never
// PrimaeNative. Nothing here touches app code or the study binary.
//
// WHAT THIS CAN AND CANNOT SETTLE. These are code-behaviour checks. The
// simulator is an iPad Pro 11-inch (M5) on iOS 27.0 built with Xcode 27.0,
// against the pilot artefact's Release-Study on a 13-inch/A16 iPad under
// Xcode 26.4 — no parity. Nothing here observes sound reaching a speaker;
// check 2 below is deliberately absent for that reason (see its note).
//
// The two checks that ARE here:
//   A. chevron advance  — report 1. Compares the letter pill's label
//      before/after tapping "Nächster Buchstabe" (navArrow,
//      SchuleWorldView.swift:502; pill label ":434").
//   B. second enrolment — report 3. Enrols, then enrols again, and
//      confirms the incoming participant is usable WITHOUT a relaunch.

import XCTest
import Foundation

final class StudyAdvanceProbeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Check A — does the chevron advance the letter?

    /// Report 1 says a session cannot move past one letter. The study
    /// build has no auto-advance by design (the celebration overlay that
    /// would drive it is `#if !STUDY_BUILD`), so the chevron is the
    /// documented path (STUDY_DEVICE_DRYRUN.md:286-292). This tells us
    /// whether that path actually works.
    @MainActor
    func testChevronAdvancesLetter() {
        let app = XCUIApplication()
        app.launch()

        attach(app, name: "A-01-launch")

        guard let before = currentLetter(app) else {
            // Fail loudly with the screen attached rather than timing out
            // cryptically — onboarding or a missing pill is a real finding.
            attach(app, name: "A-02-no-letter-pill-FAILURE")
            XCTFail("no 'Aktueller Buchstabe …' element after launch; see the attached screenshot")
            return
        }

        let next = element(label: "Nächster Buchstabe", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: 10),
                      "the right-chevron nav button must exist in the study build")
        attach(app, name: "A-03-before-chevron-\(before)")

        next.tap()
        // nextLetter() -> load(letter:), which resets the phase controller
        // and reloads checkpoints; give it a beat to settle before reading.
        Thread.sleep(forTimeInterval: 2.0)

        let after = currentLetter(app)
        attach(app, name: "A-04-after-chevron-\(after ?? "nil")")

        XCTAssertNotEqual(
            before, after,
            "tapping 'Nächster Buchstabe' did not change the current letter: stayed on '\(before)'"
        )
    }

    /// The other half of report 1: after the chevron lands on a new letter,
    /// is that letter actually usable — i.e. did it load a fresh phase
    /// state rather than a completed one? `load(letter:)` calls
    /// `phaseController.reset()`, which clears `isLetterSessionComplete`;
    /// this confirms the visible consequence (phase indicator back to 0).
    @MainActor
    func testChevronLandsOnUsableLetter() {
        let app = XCUIApplication()
        app.launch()

        guard currentLetter(app) != nil else {
            attach(app, name: "A2-01-no-letter-pill-FAILURE")
            XCTFail("no 'Aktueller Buchstabe …' element after launch")
            return
        }

        let next = element(label: "Nächster Buchstabe", in: app)
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        Thread.sleep(forTimeInterval: 2.0)

        let indicator = element(labelPrefix: "Lernphase", in: app)
        XCTAssertTrue(indicator.waitForExistence(timeout: 8),
                      "the phase indicator must be present after the chevron lands")
        attach(app, name: "A2-02-after-chevron")

        let value = indicator.value as? String ?? ""
        XCTAssertEqual(
            value, "0 von 4 abgeschlossen",
            "a freshly loaded letter should start with no phases completed, got '\(value)'"
        )
    }

    // MARK: - Check B — second enrolment usable without relaunch

    /// Report 3 says enrolling a new participant still requires Settings +
    /// relaunch. The relaunch half should no longer hold: `thesisCondition`
    /// /`audioCondition`/`trainedSubset` became `var` on 2026-09-14 so
    /// `reapplyParticipantIdentity` can re-seed in place
    /// (TracingViewModel.swift:710-725). This drives enrolment twice and
    /// uses the second participant WITHOUT relaunching; the app is launched
    /// exactly once, at the top.
    @MainActor
    func testSecondEnrolmentUsableWithoutRelaunch() {
        let app = XCUIApplication()
        app.launch()   // the ONLY launch in this test

        openParentArea(app)
        attach(app, name: "B-01-parent-area")

        enrolNewParticipant(app)
        XCTAssertTrue(waitFor(label: "Vortest starten: A", in: app, timeout: 12),
                      "the research dashboard should be usable after the first enrolment")
        attach(app, name: "B-02-first-participant-dashboard")

        // Second enrolment, still no relaunch.
        enrolNewParticipant(app)
        XCTAssertTrue(waitFor(label: "Vortest starten: A", in: app, timeout: 12),
                      "the research dashboard should be usable for the SECOND participant without relaunching")
        attach(app, name: "B-03-second-participant-dashboard")
    }

    // MARK: - Check C (report 2) — deliberately NOT automated
    //
    // Report 2 is about AUDIO. A simulator's software audio stack does not
    // carry real AVAudioSession timing, and an XCUITest cannot observe
    // whether sound left a speaker at all — this project's own
    // scripts/run_device_uitests.sh header gives that as the reason CI
    // never runs UI tests as a per-push audio proof. So no assertion is
    // written here that would pretend to settle it. What the simulator
    // CAN show is whether playback is requested, which needs the unified
    // log, not the accessibility tree — see the report accompanying this
    // file.

    // MARK: - Flow helpers

    private func openParentArea(_ app: XCUIApplication) {
        let gear = element(label: "Eltern-Bereich", in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the parent-area gear must be reachable")
        // 2.0s minimumDuration (WorldSwitcherRail.swift) + margin.
        gear.press(forDuration: 2.3)
        XCTAssertTrue(waitFor(label: "Datenexport", in: app, timeout: 6),
                      "the parent-area sidebar should be visible after the gear long-press")
    }

    private func enrolNewParticipant(_ app: XCUIApplication) {
        let newParticipant = element(label: "Neuer Teilnehmer", in: app)
        XCTAssertTrue(newParticipant.waitForExistence(timeout: 6), "Neuer Teilnehmer button must exist")
        newParticipant.tap()

        XCTAssertTrue(waitForShareSheet(app, timeout: 8), "the pre-wipe export share sheet should appear")
        dismissShareSheet(app)

        let confirm = element(label: "Löschen & neu starten", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 6),
                      "the destructive confirm dialog should appear after the share sheet closes")
        confirm.tap()

        let relaunchOK = app.alerts["Neustart erforderlich"].buttons["OK"]
        XCTAssertTrue(relaunchOK.waitForExistence(timeout: 6), "the relaunch alert should appear")
        // Dismissed, NOT acted on — no relaunch happens in this test, by design.
        relaunchOK.tap()
    }

    /// The current letter, read off the pill's own label. Rendered in both
    /// branches of `letterPill`, so it is present under STUDY_BUILD.
    private func currentLetter(_ app: XCUIApplication) -> String? {
        let prefix = "Aktueller Buchstabe "
        let e = element(labelPrefix: prefix, in: app)
        guard e.waitForExistence(timeout: 8) else { return nil }
        return String(e.label.dropFirst(prefix.count))
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    // MARK: - Element lookup (label/text only, matching StudyDryRunUITests)

    private func element(label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func element(labelPrefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
    }

    private func waitFor(label: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        element(label: label, in: app).waitForExistence(timeout: timeout)
    }

    private func waitForShareSheet(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let sheet = app.sheets.firstMatch
        let popover = app.otherElements["ActivityListView"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sheet.exists || popover.exists || app.collectionViews["ActivityListView"].exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Same dismissal StudyDryRunUITests settled on: swipe down on the
    /// sheet, rather than a locale-specific Cancel label or a tap-outside.
    private func dismissShareSheet(_ app: XCUIApplication) {
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            sheet.swipeDown(velocity: .fast)
        } else {
            app.swipeDown(velocity: .fast)
        }
    }
}
