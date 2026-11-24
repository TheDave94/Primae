// StudyDryRunUITests.swift
// PrimaeUITests
//
// Automates the parts of docs/STUDY_DEVICE_DRYRUN.md that a UI test
// actually CAN drive: enrolment, a training letter completing, a second
// enrolment preserving the first participant, and the export containing
// both. (Until protocol r27 the middle step was a cold Vortest started
// from the research dashboard; r27 removed the probe buttons from the
// study build, so the child's first training letter, drawn along its real
// strokes, is what makes the first participant count. The method keeps its
// name because CLAUDE.md cites it as a device-run receipt.) These are the things
// that have broken silently on this project (the letter-set load, the
// cold-probe silent refusal, the participant-archive path) — worth a
// test that can fail, not a procedure a human re-reads and might not
// notice deviate.
//
// Deliberately does NOT test: pencil-specific input (pressure/azimuth —
// this suite drives the canvas with plain coordinate touches, which
// TouchDispatcher accepts identically to a finger; see the guard shape
// in TouchDispatcher.swift), palm rejection, physical audio output, or
// the three-finger proctor gesture. Those stay David's, on-device — see
// docs/STUDY_DEVICE_DRYRUN.md's own coverage table.
//
// This target is a SEPARATE .xctest bundle (product type
// com.apple.product-type.bundle.ui-testing) that drives the real
// Primae.app process via the accessibility tree — XCTest links it into
// no app target, and it ships nothing into the study binary. It imports
// only XCTest, never PrimaeNative — every interaction goes through the
// same accessibility surface a proctor or VoiceOver would use, not
// through @testable internals.

import XCTest
import Foundation

final class StudyDryRunUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// One continuous session, matching what actually happens on the
    /// study binary: `resetForNewParticipant()` reapplies the new
    /// participant's identity IN PLACE under studyMode (TracingViewModel
    /// .swift's `reapplyParticipantIdentity`) — the "Neustart
    /// erforderlich" alert text is shown regardless, but no real
    /// relaunch is required, and this test does not perform one.
    @MainActor
    func testEnrolmentProbeCompletionSecondEnrolmentExport() {
        let app = XCUIApplication.primaeUnderTest()
        // Arms the DEBUG-only geometry hook the letter tracer reads.
        app.launchArguments += [LetterTracer.launchArgument]
        app.launch()

        openParentArea(app)

        // The count BEFORE this test enrols anyone (2026-10-22). The device
        // keeps its archive between runs, so an absolute count depends on
        // what earlier runs left behind; the delta does not.
        let baseline = exportParticipantCount(app)
        let research = element(label: "Forschungs-Daten", in: app)
        XCTAssertTrue(research.waitForExistence(timeout: 5), "Forschungs-Daten sidebar entry must exist")
        research.tap()

        XCTContext.runActivity(named: "1 — enrolment") { _ in
            enrolNewParticipant(app)
            // Lands back on the research dashboard (ParentAreaView's
            // STUDY_BUILD default selection is .research). r27: its
            // read-only "Abschlusstest" section replaced the probe buttons,
            // and no probe button may be left in the study build.
            XCTAssertTrue(
                waitFor(label: "Abschlusstest", in: app, timeout: 10),
                "expected the research dashboard's Abschlusstest section to be visible after enrolment"
            )
            XCTAssertFalse(element(labelPrefix: "Vortest starten", in: app).exists,
                           "r27: the probe buttons must not be in the study build")
        }

        XCTContext.runActivity(named: "2 — back to the child") { _ in
            let back = element(label: "Zurück zur App", in: app)
            XCTAssertTrue(back.waitForExistence(timeout: 5), "the parent area must offer 'Zurück zur App'")
            back.tap()
            XCTAssertTrue(
                waitFor(labelDisappear: "Datenexport", in: app, timeout: 10),
                "the parent area should have closed onto the canvas"
            )
            // Enrolment leaves the first letter parked on its observe screen
            // (R-007); the proctor starts it with a tap.
            var last: TracingHookSnapshot?
            if let s = LetterTracer.waitForSnapshot(app, timeout: 10, last: &last, where: { _ in true }), s.parked {
                let observe = element(label: "Beobachtungsphase", in: app)
                if observe.waitForExistence(timeout: 5) { observe.tap() }
            }
        }

        XCTContext.runActivity(named: "3 — a training letter completing") { _ in
            // The first trained letter, observe -> guided -> free writing,
            // each pass drawn along the letter's own strokes (LetterTracer),
            // and the free-writing production scored in the passing range.
            var last: TracingHookSnapshot?
            guard let guided = LetterTracer.waitForSnapshot(app, timeout: 60, last: &last, where: {
                $0.phase == "guided" && !$0.strokes.isEmpty && !$0.blocked
            }) else {
                return XCTFail("the first letter never reached guided: \(last?.summary ?? "no hook")")
            }
            let letter = guided.letter
            Thread.sleep(forTimeInterval: 1.0)
            LetterTracer.traceLetter(guided, in: app)
            guard let fw = LetterTracer.waitForSnapshot(app, timeout: 8, last: &last, where: {
                $0.letter == letter && $0.phase == "freeWrite" && $0.checkpointsHit == 0
            }) else {
                return XCTFail("\(letter): guided did not advance to freeWrite: \(last?.summary ?? "no hook")")
            }
            // PhaseDotIndicator's accessibilityValue reports "N von M
            // abgeschlossen", M the session's phase count. A study session
            // runs THREE phases (D5; this pinned "von 4" until 2026-09-21,
            // caught only by running the suite on the iPad), and in free
            // writing observe and guided are behind the child.
            let phaseIndicator = element(labelPrefix: "Lernphase", in: app)
            XCTAssertTrue(phaseIndicator.waitForExistence(timeout: 5), "the phase indicator must be on screen")
            XCTAssertEqual(phaseIndicator.value as? String, "2 von 3 abgeschlossen",
                           "free writing follows the two completed phases of a three-phase session")
            Thread.sleep(forTimeInterval: 1.0)
            LetterTracer.traceLetter(fw, in: app)
            _ = LetterTracer.waitForCompletion(app, letter: letter, probe: nil)
        }

        openParentArea(app)

        XCTContext.runActivity(named: "4 — a second enrolment preserving the first participant") { _ in
            enrolNewParticipant(app)
            // The new (second) participant's own dashboard must be
            // usable too -- this is what "preserving the first" is
            // actually for: the reset must not have left the app in a
            // half-reapplied state where the outgoing participant's
            // data survived but the incoming one can't proceed.
            XCTAssertTrue(
                waitFor(label: "Abschlusstest", in: app, timeout: 10),
                "expected the research dashboard to be usable for the newly-enrolled second participant too"
            )
        }

        XCTContext.runActivity(named: "5 — the export containing both") { _ in
            // NOTE (2026-09-15, second pass): this phase originally also
            // read the exported CSV's actual bytes via `xcrun simctl
            // get_app_container` + `Process`. `Process`/`NSTask` is not
            // in Foundation's iOS SDK surface at all -- not a missing
            // import, a genuine platform restriction (iOS apps cannot
            // spawn subprocesses), confirmed by CI compile failure on
            // this exact target. A UI test bundle is still an iOS-SDK
            // binary even though it drives a simulator, so that path
            // isn't available here. Reduced to what's actually
            // achievable from inside the bundle: `vm
            // .allParticipantExportSources` is the EXACT data structure
            // `ParentDashboardExporter.combinedExportFileURL` writes
            // from, and its count is what the hint text below
            // interpolates -- so confirming the count here is confirming
            // the same source the file would be built from, not a
            // separate/weaker signal. A future CI-workflow-level shell
            // step (outside this Swift target, where simctl is directly
            // callable) could still read the file's actual bytes if that
            // proves worth the added complexity.
            // Exactly ONE more than before (2026-10-22; this asserted ">= 2",
            // which R-059 (#47) made wrong). Only a participant who did
            // something is counted (`participantDidAnything`): the first
            // child completed a training letter and is sealed, the second did nothing
            // and is in the enrolment block only. Whoever was current before
            // the test is in `baseline` already if they did anything, and
            // still counted once after being sealed.
            let count = exportParticipantCount(app)
            XCTAssertEqual(
                count, baseline + 1,
                "expected the first participant and only them to be added (baseline \(baseline)); a zero-activity enrolment must not be counted"
            )

            let csvButton = element(label: "CSV exportieren", in: app)
            XCTAssertTrue(csvButton.waitForExistence(timeout: 5))
            csvButton.tap()

            // The share sheet appearing proves ParentDashboardExporter
            // .combinedExportFileURL() succeeded synchronously (export(
            // format:) in ParentAreaView.swift only presents it on
            // success) -- a throw sets showError instead, and no sheet
            // would ever appear.
            XCTAssertTrue(
                waitForShareSheet(app, timeout: 5),
                "the export share sheet should appear after a successful export"
            )
        }
    }

    // MARK: - Flow helpers

    private func openParentArea(_ app: XCUIApplication) {
        let gear = element(label: "Eltern-Bereich", in: app)
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "the parent-area gear must be reachable")
        // 2.0s minimumDuration (WorldSwitcherRail.swift) + margin.
        gear.press(forDuration: 2.3)
        XCTAssertTrue(
            waitFor(label: "Datenexport", in: app, timeout: 5),
            "the parent-area sidebar should be visible after the gear long-press"
        )
    }

    /// Drives the "Neuer Teilnehmer" flow to completion: tap -> confirm
    /// the destructive dialog -> dismiss the ready alert.
    ///
    /// Two steps that used to be here are gone as of 2026-10-01, both
    /// deliberately: the pre-wipe export SHARE SHEET (the outgoing child
    /// is sealed to `ParticipantArchive/`, which is what
    /// `allParticipantExportSources` reads for the end-of-session
    /// combined export, so 30-40 share sheets bought no data safety),
    /// and the "Neustart erforderlich" relaunch prompt
    /// (`reapplyParticipantIdentity()` re-derives the arms in place).
    /// What this test now pins is that the flow reaches a usable state
    /// for the NEXT child without either of them.
    private func enrolNewParticipant(_ app: XCUIApplication) {
        let newParticipant = element(label: "Neuer Teilnehmer", in: app)
        XCTAssertTrue(newParticipant.waitForExistence(timeout: 5), "Neuer Teilnehmer button must exist")
        newParticipant.tap()

        let confirm = element(label: "Neues Kind starten", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the destructive confirm dialog should appear")
        confirm.tap()

        // Dashboard path: a modal alert (see `NewChildReadyPresentation`).
        let readyOK = app.alerts["Neues Kind bereit"].buttons["OK"]
        XCTAssertTrue(readyOK.waitForExistence(timeout: 5), "the ready alert should appear")
        readyOK.tap()
    }

    // MARK: - Element lookup (label/text only — no accessibilityIdentifier
    // exists anywhere in this codebase today, per a full-repo grep before
    // writing this file; adding one would be new app-reaching surface
    // for a test to depend on, which this suite deliberately avoids)

    private func element(label: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func element(labelPrefix: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", labelPrefix)).firstMatch
    }

    private func element(labelContains: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", labelContains)).firstMatch
    }

    private func waitFor(label: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        element(label: label, in: app).waitForExistence(timeout: timeout)
    }

    private func waitFor(labelDisappear label: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in !self.element(label: label, in: app).exists }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// UIActivityViewController on iPad presents as a popover; detecting
    /// it robustly (rather than guessing a locale-specific "Cancel"
    /// label) means checking for ANY new sheet/popover-class element —
    /// the presence of the activity list itself is enough.
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

    /// Dismiss a UIActivityViewController without depending on a
    /// locale-specific "Cancel"/"Abbrechen" label. SwiftUI's `.sheet` on
    /// iPad presents this as a drag-to-dismiss sheet, not a tap-outside
    /// popover (2026-09-15, confirmed by CI: a top-left coordinate tap
    /// left the sheet up and the confirm dialog never appeared) — swipe
    /// down on the sheet itself, the standard XCUITest dismissal for
    /// either presentation style.
    private func dismissShareSheet(_ app: XCUIApplication) {
        let sheet = app.sheets.firstMatch
        if sheet.exists {
            sheet.swipeDown(velocity: .fast)
        } else {
            app.swipeDown(velocity: .fast)
        }
    }

    /// Opens Datenexport and reads the participant count from its hint.
    private func exportParticipantCount(_ app: XCUIApplication) -> Int {
        let exportLink = element(label: "Datenexport", in: app)
        XCTAssertTrue(exportLink.waitForExistence(timeout: 5), "Datenexport sidebar entry must exist")
        exportLink.tap()
        let countText = element(labelContains: "Teilnehmer aktuell gespeichert", in: app)
        XCTAssertTrue(countText.waitForExistence(timeout: 5), "the participant-count hint must be visible")
        let count = participantCount(fromHint: countText.label)
        XCTAssertGreaterThanOrEqual(count, 0, "unreadable count in '\(countText.label)'")
        return count
    }

    private func participantCount(fromHint label: String) -> Int {
        // "...(<N> Teilnehmer aktuell gespeichert)..." — extract the
        // integer immediately preceding the marker phrase.
        guard let range = label.range(of: " Teilnehmer aktuell gespeichert") else { return -1 }
        let before = label[..<range.lowerBound]
        let digits = before.reversed().prefix(while: { $0.isNumber }).reversed()
        return Int(String(digits)) ?? -1
    }
}
